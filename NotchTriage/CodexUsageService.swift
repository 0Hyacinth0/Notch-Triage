import Foundation

@MainActor
final class CodexUsageService {
    typealias LimitsHandler = @MainActor ([CodexLimitBucket]) -> Void
    typealias HealthHandler = @MainActor (ServiceHealth) -> Void

    private let onLimits: LimitsHandler
    private let onHealth: HealthHandler

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var readBuffer = Data()
    private var refreshTimer: Timer?
    private var requestID = 1

    init(
        onLimits: @escaping LimitsHandler,
        onHealth: @escaping HealthHandler
    ) {
        self.onLimits = onLimits
        self.onHealth = onHealth
    }

    func start() {
        guard process == nil else { return }
        guard let executable = findCodexExecutable() else {
            onHealth(.failed("没有找到 Codex 可执行文件"))
            return
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()

        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.consume(data)
            }
        }

        error.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let message = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.onHealth(.warning("Codex: \(message.trimmingCharacters(in: .whitespacesAndNewlines))"))
            }
        }

        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                guard let self, self.process === process else { return }
                self.onHealth(.warning("Codex App Server 已停止"))
                self.stop()
            }
        }

        do {
            try process.run()
            self.process = process
            inputPipe = input
            outputPipe = output
            errorPipe = error

            send([
                "method": "initialize",
                "id": 0,
                "params": [
                    "clientInfo": [
                        "name": "notch_triage",
                        "title": "Notch Triage",
                        "version": Bundle.main.object(
                            forInfoDictionaryKey: "CFBundleShortVersionString"
                        ) as? String ?? "0.0.0"
                    ]
                ]
            ])
            send(["method": "initialized", "params": [:]])
            refresh()

            refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            }
        } catch {
            onHealth(.failed("无法启动 Codex App Server：\(error.localizedDescription)"))
            stop()
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil

        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil

        if let process, process.isRunning {
            process.terminate()
        }

        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        readBuffer.removeAll(keepingCapacity: false)
    }

    func refresh() {
        guard process?.isRunning == true else {
            if process == nil {
                start()
            }
            return
        }

        requestID += 1
        send(["method": "account/rateLimits/read", "id": requestID])
    }

    private func send(_ message: [String: Any]) {
        guard let inputPipe else { return }

        do {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            onHealth(.failed("Codex 请求写入失败：\(error.localizedDescription)"))
        }
    }

    private func consume(_ data: Data) {
        readBuffer.append(data)

        while let newline = readBuffer.firstRange(of: Data([0x0A])) {
            let line = readBuffer.subdata(in: readBuffer.startIndex..<newline.lowerBound)
            readBuffer.removeSubrange(readBuffer.startIndex...newline.lowerBound)
            guard !line.isEmpty else { continue }

            do {
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    continue
                }
                handle(message)
            } catch {
                onHealth(.warning("忽略了一条无法解析的 Codex 消息"))
            }
        }
    }

    private func handle(_ message: [String: Any]) {
        if let error = message["error"] as? [String: Any] {
            onHealth(.failed(error["message"] as? String ?? "Codex 返回未知错误"))
            return
        }

        if let result = message["result"] as? [String: Any],
           result["rateLimits"] != nil || result["rateLimitsByLimitId"] != nil {
            onLimits(parseLimits(from: result))
            return
        }

        if message["method"] as? String == "account/rateLimits/updated",
           let params = message["params"] as? [String: Any] {
            onLimits(parseLimits(from: params))
        }
    }

    private func parseLimits(from payload: [String: Any]) -> [CodexLimitBucket] {
        var buckets: [CodexLimitBucket] = []

        if let byID = payload["rateLimitsByLimitId"] as? [String: Any] {
            for (limitID, rawValue) in byID {
                guard let rawBucket = rawValue as? [String: Any] else { continue }
                buckets.append(contentsOf: parseBucket(rawBucket, fallbackID: limitID))
            }
        } else if let rawBucket = payload["rateLimits"] as? [String: Any] {
            buckets.append(contentsOf: parseBucket(rawBucket, fallbackID: "codex"))
        }

        return buckets
            .filter { $0.windowMinutes > 0 }
            .sorted {
                if $0.windowMinutes == $1.windowMinutes {
                    return $0.id < $1.id
                }
                return $0.windowMinutes < $1.windowMinutes
            }
    }

    private func parseBucket(
        _ rawBucket: [String: Any],
        fallbackID: String
    ) -> [CodexLimitBucket] {
        let limitID = rawBucket["limitId"] as? String ?? fallbackID
        let displayName = rawBucket["limitName"] as? String ?? "Codex"
        var result: [CodexLimitBucket] = []

        if let primary = rawBucket["primary"] as? [String: Any],
           let bucket = parseWindow(primary, id: "\(limitID)-primary", name: displayName) {
            result.append(bucket)
        }

        if let secondary = rawBucket["secondary"] as? [String: Any],
           let bucket = parseWindow(secondary, id: "\(limitID)-secondary", name: displayName) {
            result.append(bucket)
        }

        return result
    }

    private func parseWindow(
        _ raw: [String: Any],
        id: String,
        name: String
    ) -> CodexLimitBucket? {
        guard let usedPercent = number(raw["usedPercent"]),
              let windowMinutesDouble = number(raw["windowDurationMins"]) else {
            return nil
        }

        let resetDate = number(raw["resetsAt"]).map {
            Date(timeIntervalSince1970: $0)
        }

        return CodexLimitBucket(
            id: id,
            name: name,
            usedPercent: usedPercent,
            windowMinutes: Int(windowMinutesDouble),
            resetsAt: resetDate
        )
    }

    private func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let double = value as? Double {
            return double
        }
        if let integer = value as? Int {
            return Double(integer)
        }
        return nil
    }

    private func findCodexExecutable() -> URL? {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]

        return candidates
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
