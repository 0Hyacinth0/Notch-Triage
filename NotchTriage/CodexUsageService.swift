import Foundation

@MainActor
final class CodexUsageService {
    typealias LimitsHandler = @MainActor ([CodexLimitBucket]) -> Void
    typealias UsageHandler = @MainActor ([CodexLimitBucket], CodexCreditsBalance?) -> Void
    typealias HealthHandler = @MainActor (ServiceHealth) -> Void

    private let onUsage: UsageHandler
    private let onHealth: HealthHandler

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var readBuffer = Data()
    private var requestID = 1
    private var latestCredits: CodexCreditsBalance?
    private var latestLimits: [CodexLimitBucket] = []

    init(
        onUsage: @escaping UsageHandler,
        onHealth: @escaping HealthHandler
    ) {
        self.onUsage = onUsage
        self.onHealth = onHealth
    }

    /// Backwards-compatible initializer for callers that only render rate
    /// limits. New callers should use `onUsage` so credits and limits arrive in
    /// one callback.
    convenience init(
        onLimits: @escaping LimitsHandler,
        onHealth: @escaping HealthHandler
    ) {
        self.init(
            onUsage: { limits, _ in onLimits(limits) },
            onHealth: onHealth
        )
    }

    /// Forward the pure parser through the service type for lightweight unit
    /// tests without constructing a process or touching the file system.
    nonisolated static func parseMessage(
        _ message: [String: Any],
        previousCredits: CodexCreditsBalance? = nil
    ) -> CodexUsageSnapshot? {
        CodexUsageParser.parseMessage(message, previousCredits: previousCredits)
    }

    nonisolated static func parseRateLimits(
        from payload: [String: Any],
        previousCredits: CodexCreditsBalance? = nil
    ) -> CodexUsageSnapshot {
        CodexUsageParser.parseRateLimits(from: payload, previousCredits: previousCredits)
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
        } catch {
            onHealth(.failed("无法启动 Codex App Server：\(error.localizedDescription)"))
            stop()
        }
    }

    func stop() {
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

        if let snapshot = CodexUsageParser.parseMessage(
            message,
            previousCredits: latestCredits
        ) {
            let isSparseUpdate = message["method"] as? String
                == "account/rateLimits/updated"
            let limits = isSparseUpdate && snapshot.limits.isEmpty
                ? latestLimits
                : snapshot.limits
            latestLimits = limits
            latestCredits = snapshot.credits
            onUsage(limits, snapshot.credits)
        }
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
