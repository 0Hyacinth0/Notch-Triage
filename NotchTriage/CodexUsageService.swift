import Foundation

@MainActor
final class CodexUsageService {
    typealias LimitsHandler = @MainActor ([CodexLimitBucket]) -> Void
    typealias UsageHandler = @MainActor ([CodexLimitBucket], CodexCreditsBalance?) -> Void
    typealias HealthHandler = @MainActor (ServiceHealth) -> Void
    private let onUsage: UsageHandler
    private let onHealth: HealthHandler
    var onConnection: (@MainActor (String, String?) -> Void)?
    var onAccountChanged: (@MainActor () -> Void)?
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var readBuffer = Data()
    private var requestID = 1
    private var pendingID: Int?
    private var initialized = false
    private var latestCredits: CodexCreditsBalance?
    private var latestLimits: [CodexLimitBucket] = []
    private var accountID: String?
    private var timeoutTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var versionTask: Task<Void, Never>?
    private var wantsRunning = false
    private var candidates: [URL] = []
    private var candidateIndex = 0
    private var retries = 0
    private let requestTimeout: Duration
    private let candidateProvider: (() -> [URL])?

    init(onUsage: @escaping UsageHandler, onHealth: @escaping HealthHandler,
         requestTimeout: Duration = .seconds(20), candidateProvider: (() -> [URL])? = nil) {
        self.onUsage = onUsage; self.onHealth = onHealth
        self.requestTimeout = requestTimeout; self.candidateProvider = candidateProvider
    }
    convenience init(onLimits: @escaping LimitsHandler, onHealth: @escaping HealthHandler) {
        self.init(onUsage: { limits, _ in onLimits(limits) }, onHealth: onHealth)
    }
    nonisolated static func parseMessage(_ message: [String: Any], previousCredits: CodexCreditsBalance? = nil) -> CodexUsageSnapshot? {
        CodexUsageParser.parseMessage(message, previousCredits: previousCredits)
    }
    nonisolated static func parseRateLimits(from payload: [String: Any], previousCredits: CodexCreditsBalance? = nil) -> CodexUsageSnapshot {
        CodexUsageParser.parseRateLimits(from: payload, previousCredits: previousCredits)
    }
    func start() {
        wantsRunning = true
        guard process == nil, retryTask == nil else { return }
        let preferred = UserDefaults.standard.string(forKey: "aiUsage.codexExecutable") ?? ""
        candidates = candidateProvider?() ?? AIUsageCLI.candidates(tool: "codex", preferred: preferred)
        candidateIndex = 0
        launchNext()
    }
    private func launchNext() {
        guard wantsRunning else { return }
        guard candidateIndex < candidates.count else {
            onConnection?("", nil)
            onHealth(.failed(candidates.isEmpty ? "没有找到 Codex 客户端，请在 AI 套餐用量中指定可执行文件" : "已尝试可用路径，但 Codex 客户端无法连接"))
            scheduleRetry(); return
        }
        let executable = candidates[candidateIndex]; candidateIndex += 1
        let current = Process(), input = Pipe(), output = Pipe(), error = Pipe()
        current.executableURL = executable
        current.arguments = ["app-server", "--stdio"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = executable.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        current.environment = environment
        current.standardInput = input; current.standardOutput = output; current.standardError = error
        output.fileHandleForReading.readabilityHandler = { [weak self, weak current] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self, weak current] in
                guard let self, self.process === current else { return }
                self.consume(data)
            }
        }
        // Drain stderr; raw client logs can contain private paths or credentials.
        error.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        current.terminationHandler = { [weak self] ended in
            Task { @MainActor [weak self] in
                guard let self, self.process === ended else { return }
                self.failConnection("Codex 客户端已停止")
            }
        }
        do {
            try current.run()
            process = current; inputPipe = input; outputPipe = output; errorPipe = error
            onConnection?(executable.path, nil)
            onHealth(.loading("正在连接 Codex"))
            send(["method": "initialize", "id": 0, "params": ["clientInfo": ["name": "notch_triage", "title": "Notch Triage", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"]]])
            armTimeout(for: current)
            versionTask = Task { [weak self, weak current] in
                guard let data = try? await AIUsageCLI.output(executable: executable, arguments: ["--version"]),
                      !Task.isCancelled, let self, self.process === current,
                      let version = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      version.count < 100 else { return }
                self.onConnection?(executable.path, version)
            }
        } catch {
            tearDown(); launchNext()
        }
    }
    func stop() {
        wantsRunning = false; retryTask?.cancel(); retryTask = nil; tearDown()
    }
    func reconnect() {
        stop(); retries = 0
        accountID = nil; latestCredits = nil; latestLimits = []
        onAccountChanged?(); start()
    }
    private func tearDown() {
        timeoutTask?.cancel(); timeoutTask = nil
        versionTask?.cancel(); versionTask = nil
        let old = process; process = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        old?.terminationHandler = nil
        if let old, old.isRunning {
            old.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if old.isRunning { kill(old.processIdentifier, SIGKILL) }
            }
        }
        inputPipe = nil; outputPipe = nil; errorPipe = nil
        readBuffer.removeAll(); initialized = false; pendingID = nil
    }
    private func scheduleRetry() {
        guard wantsRunning, retryTask == nil, retries < 5 else { return }
        let delay = min(30, 1 << retries); retries += 1
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.wantsRunning else { return }
            self.retryTask = nil; self.start()
        }
    }
    private func failConnection(_ message: String) {
        let hadInitialized = initialized
        tearDown(); onHealth(.failed(message))
        if !hadInitialized, candidateIndex < candidates.count { launchNext() }
        else { scheduleRetry() }
    }
    private func armTimeout(for current: Process) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self, weak current] in
            try? await Task.sleep(for: self?.requestTimeout ?? .seconds(20))
            guard !Task.isCancelled, let self, self.process === current else { return }
            self.failConnection("Codex 用量读取超时，正在恢复连接")
        }
    }
    func refresh() {
        guard process?.isRunning == true else { start(); return }
        guard initialized, pendingID == nil, let process else { return }
        requestID += 1; pendingID = requestID
        onHealth(.loading("正在读取 Codex 用量"))
        send(["method": "account/rateLimits/read", "id": requestID])
        if self.process === process { armTimeout(for: process) }
    }
    private func send(_ message: [String: Any]) {
        guard let inputPipe else { return }
        do {
            var data = try JSONSerialization.data(withJSONObject: message); data.append(0x0A)
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
        } catch { failConnection("Codex 请求写入失败") }
    }
    private func consume(_ data: Data) {
        readBuffer.append(data)
        guard readBuffer.count < 2_000_000 else { failConnection("Codex 响应超过安全大小"); return }
        while let newline = readBuffer.firstRange(of: Data([0x0A])) {
            let line = readBuffer.subdata(in: readBuffer.startIndex..<newline.lowerBound)
            readBuffer.removeSubrange(readBuffer.startIndex...newline.lowerBound)
            guard !line.isEmpty, let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            handle(message)
        }
    }
    private func clearAccount() {
        latestCredits = nil; latestLimits = []; accountID = nil
        onAccountChanged?()
    }
    private func handle(_ message: [String: Any]) {
        let id = message["id"] as? Int
        if id == 0 {
            guard message["error"] == nil, message["result"] != nil else { failConnection("Codex 初始化失败，请更新或重新登录客户端"); return }
            timeoutTask?.cancel(); initialized = true
            send(["method": "initialized", "params": [:]])
            refresh(); return
        }
        if message["method"] as? String == "account/updated" {
            clearAccount(); pendingID = nil; timeoutTask?.cancel(); refresh(); return
        }
        let isUpdate = message["method"] as? String == "account/rateLimits/updated"
        guard isUpdate || id == pendingID && id != nil else { return }
        if !isUpdate { pendingID = nil; timeoutTask?.cancel() }
        if message["error"] != nil {
            clearAccount()
            onHealth(.failed("Codex 账户查询失败，请检查登录和网络连接")); return
        }
        if let result = message["result"] as? [String: Any], let account = result["accountId"] as? String {
            if let accountID, account != accountID { clearAccount() }
            accountID = account
        }
        guard let snapshot = CodexUsageParser.parseMessage(message, previousCredits: latestCredits) else {
            if !isUpdate { clearAccount(); onHealth(.warning("Codex 暂未返回用量数据")) }
            return
        }
        latestLimits = isUpdate && snapshot.limits.isEmpty ? latestLimits : snapshot.limits
        latestCredits = snapshot.credits; retries = 0
        onUsage(latestLimits, latestCredits)
        onHealth(.ready("已读取 Codex 用量"))
    }
}
