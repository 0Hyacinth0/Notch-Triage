import CryptoKit
import Foundation

/// A native CLI entry in the app, so connecting Claude never installs a Python/Node dependency.
enum ClaudeStatuslineRunner {
    static func run(configurationURL: URL) -> Int32 {
        let raw = FileHandle.standardInput.readDataToEndOfFile()
        guard let data = try? Data(contentsOf: configurationURL), data.count < 100_000,
              let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return 1 }
        var synced = false
        if raw.count < 500_000,
           let payload = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
           let client = config["client"] as? String,
           let destination = config["cache"] as? String,
           let auth = authentication(executable: URL(fileURLWithPath: client)),
           let identity = accountIdentity(auth) {
            var safe: [String: Any] = ["updated_at": Date().timeIntervalSince1970, "account_hash": identity]
            var windows: [String: Any] = [:]
            let limits = payload["rate_limits"] as? [String: Any] ?? [:]
            for key in ["five_hour", "seven_day"] {
                guard let window = limits[key] as? [String: Any], let percent = AIUsageNumber.double(window["used_percentage"]) else { continue }
                var value: [String: Any] = ["used_percentage": percent]
                if let reset = AIUsageNumber.double(window["resets_at"]) { value["resets_at"] = reset }
                windows[key] = value
            }
            safe["rate_limits"] = windows
            if let cost = payload["cost"] as? [String: Any], let value = AIUsageNumber.double(cost["total_cost_usd"]) {
                safe["cost"] = ["total_cost_usd": value]
            }
            let url = URL(fileURLWithPath: destination)
            if let data = try? JSONSerialization.data(withJSONObject: safe) {
                do {
                    try data.write(to: url, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    synced = true
                } catch { }
            }
        }
        if let command = config["originalCommand"] as? String, !command.isEmpty {
            let child = Process(), pipe = Pipe()
            child.executableURL = URL(fileURLWithPath: "/bin/sh")
            child.arguments = ["-c", command]
            child.standardInput = pipe
            child.standardOutput = FileHandle.standardOutput; child.standardError = FileHandle.standardError
            do {
                try child.run(); try? pipe.fileHandleForWriting.write(contentsOf: raw)
                try? pipe.fileHandleForWriting.close()
                child.waitUntilExit(); return child.terminationStatus
            } catch { return 1 }
        }
        let text = synced ? "AI 套餐用量已同步\n" : "AI 套餐用量等待会话数据\n"
        FileHandle.standardOutput.write(Data(text.utf8)); return 0
    }
    static func accountIdentity(_ auth: [String: Any]) -> String? {
        guard auth["loggedIn"] as? Bool == true, let email = auth["email"] as? String, !email.isEmpty else { return nil }
        let value = ["email", "authMethod", "apiProvider", "subscriptionType"].map { auth[$0] as? String ?? "" }.joined(separator: "|")
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func authentication(executable: URL) -> [String: Any]? {
        let process = Process(), output = Pipe()
        process.executableURL = executable; process.arguments = ["auth", "status", "--json"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = executable.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment
        do {
            try process.run()
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + 5)
            timer.setEventHandler { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            timer.resume()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit(); timer.cancel()
            guard process.terminationStatus == 0, data.count < 100_000 else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        } catch { return nil }
    }
}
