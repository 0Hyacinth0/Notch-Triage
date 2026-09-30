import Foundation

/// An explicit, reversible statusline opt-in. No OAuth credentials or transcripts are read.
enum ClaudeUsageBridge {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "NotchTriage")
            .appendingPathComponent("AIUsage")
    }
    static var cache: URL { directory.appendingPathComponent("claude-usage.json") }
    private static var state: URL { directory.appendingPathComponent("claude-bridge-state.json") }
    private static var settings: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json") }
    static var enabled: Bool { isEnabled(settingsURL: settings, supportDirectory: directory) }
    static func isEnabled(settingsURL: URL, supportDirectory: URL) -> Bool {
        let state = supportDirectory.appendingPathComponent("claude-bridge-state.json")
        guard let data = try? Data(contentsOf: state),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = saved["command"] as? String,
              let config = try? readSettings(from: settingsURL), let status = config["statusLine"] as? [String: Any] else { return false }
        return status["command"] as? String == command
    }
    private static func readSettings(from settings: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settings.path) else { return [:] }
        let data = try Data(contentsOf: settings)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIUsageError.configuration("Claude 设置不是有效 JSON，未修改原文件") }
        return object
    }
    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    @MainActor
    static func install(settingsURL: URL = settings, supportDirectory: URL = directory, clientURL: URL? = nil) throws {
        guard !isEnabled(settingsURL: settingsURL, supportDirectory: supportDirectory) else { return }
        let directory = supportDirectory, settings = settingsURL
        let state = directory.appendingPathComponent("claude-bridge-state.json")
        let cache = directory.appendingPathComponent("claude-usage.json")
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = try readSettings(from: settings)
        let original = config["statusLine"]
        if let original, !(original is [String: Any]) { throw AIUsageError.configuration("现有 Claude 状态栏配置不兼容，未修改原文件") }
        if fm.fileExists(atPath: settings.path) {
            let backup = settings.deletingLastPathComponent().appendingPathComponent("settings.notch-backup-" + UUID().uuidString + ".json")
            try fm.copyItem(at: settings, to: backup)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        guard let executable = clientURL ?? AIUsageCLI.candidates(tool: "claude").first else { throw AIUsageError.configuration("未找到 Claude Code，请先安装并登录") }
        let oldCommand = (original as? [String: Any])?["command"] as? String ?? ""
        // Runtime-only values are encoded as JSON, never interpolated into shell source.
        let runtime: [String: Any] = ["originalCommand": oldCommand, "cache": cache.path, "client": executable.path]
        try writeJSON(runtime, to: directory.appendingPathComponent("claude-runtime.json"))
        guard let appExecutable = Bundle.main.executableURL else { throw AIUsageError.configuration("无法定位应用程序") }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = quote(appExecutable.path) + " --claude-statusline " + quote(directory.appendingPathComponent("claude-runtime.json").path)
        var status = original as? [String: Any] ?? [:]
        status["type"] = "command"; status["command"] = command
        try writeJSON(["command": command, "original": original ?? NSNull()], to: state)
        config["statusLine"] = status
        try writeJSON(config, to: settings)
        try? fm.removeItem(at: cache)
    }
    static func uninstall(settingsURL: URL = settings, supportDirectory: URL = directory) throws {
        let settings = settingsURL
        let state = supportDirectory.appendingPathComponent("claude-bridge-state.json")
        let cache = supportDirectory.appendingPathComponent("claude-usage.json")
        guard let data = try? Data(contentsOf: state), let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var config = try readSettings(from: settings)
        // Restore only our own command; respect any subsequent user edits.
        if let status = config["statusLine"] as? [String: Any], status["command"] as? String == saved["command"] as? String {
            if let original = saved["original"], !(original is NSNull) { config["statusLine"] = original }
            else { config.removeValue(forKey: "statusLine") }
            try writeJSON(config, to: settings)
        }
        try? FileManager.default.removeItem(at: state)
        try? FileManager.default.removeItem(at: cache)
    }
    @MainActor
    static func read(now: Date = Date(), settingsURL: URL = settings, supportDirectory: URL = directory, clientURL: URL? = nil) async throws -> AIUsageSnapshot {
        let cache = supportDirectory.appendingPathComponent("claude-usage.json")
        guard isEnabled(settingsURL: settingsURL, supportDirectory: supportDirectory) else { throw AIUsageError.configuration("未开启 Claude Code 状态栏连接") }
        guard let data = try? Data(contentsOf: cache), data.count <= 100_000,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestamp = AIUsageNumber.double(object["updated_at"]), timestamp <= now.timeIntervalSince1970 + 30 else {
            throw AIUsageError.configuration("等待 Claude Code 正常会话首次响应；已有会话可能需要重新打开")
        }
        guard let executable = clientURL ?? AIUsageCLI.candidates(tool: "claude").first else { throw AIUsageError.configuration("未找到 Claude Code") }
        let status = try await AIUsageCLI.output(executable: executable, arguments: ["auth", "status", "--json"])
        guard let auth = try JSONSerialization.jsonObject(with: status) as? [String: Any], auth["loggedIn"] as? Bool == true,
              let email = auth["email"] as? String, !email.isEmpty else {
            try? FileManager.default.removeItem(at: cache)
            throw AIUsageError.configuration("Claude Code 未登录，请先登录")
        }
        let digest = ClaudeStatuslineRunner.accountIdentity(auth)
        guard digest != nil, object["account_hash"] as? String == digest else {
            try? FileManager.default.removeItem(at: cache)
            throw AIUsageError.configuration("Claude 账户已变化，等待新会话响应")
        }
        return try AIUsageAPI.parse(object, provider: .claude, now: Date(timeIntervalSince1970: timestamp))
    }
}
