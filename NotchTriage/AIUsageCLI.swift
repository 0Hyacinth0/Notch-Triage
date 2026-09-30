import AppKit
import Foundation

/// Discovers installed app bundles and common CLI installations without running shell profiles.
enum AIUsageCLI {
    @MainActor
    static func candidates(tool: String, preferred: String = "") -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths: [String] = preferred.isEmpty ? [] : [NSString(string: preferred).expandingTildeInPath]
        if tool == "codex" {
            var bundles = [URL(fileURLWithPath: "/Applications/ChatGPT.app"), URL(fileURLWithPath: "/Applications/Codex.app"),
                           home.appendingPathComponent("Applications/ChatGPT.app"), home.appendingPathComponent("Applications/Codex.app")]
            for id in ["com.openai.chat", "com.openai.codex"] {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { bundles.insert(url, at: 0) }
            }
            for bundle in bundles {
                for relative in ["Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "Contents/Resources/codex"] {
                    paths.append(bundle.appendingPathComponent(relative).path)
                }
            }
        }
        let env = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let directories = env.split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path,
               home.appendingPathComponent(".npm-global/bin").path, home.appendingPathComponent(".volta/bin").path,
               home.appendingPathComponent(".asdf/shims").path]
        paths += directories.filter { $0.hasPrefix("/") }.map { $0 + "/" + tool }
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(at: nvm, includingPropertiesForKeys: nil) {
            paths += versions.sorted { $0.lastPathComponent > $1.lastPathComponent }.map { $0.appendingPathComponent("bin/" + tool).path }
        }
        return uniqueExecutableURLs(paths)
    }
    static func uniqueExecutableURLs(_ paths: [String], isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> [URL] {
        var seen = Set<String>()
        return paths.filter { isExecutable($0) && seen.insert(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path).inserted }
            .map { URL(fileURLWithPath: $0) }
    }
    static func output(executable: URL, arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process(), pipe = Pipe()
                process.executableURL = executable; process.arguments = arguments
                process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = executable.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
                process.environment = environment
                do {
                    try process.run()
                    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                    timer.schedule(deadline: .now() + 8)
                    timer.setEventHandler { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
                    timer.resume()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit(); timer.cancel()
                    guard process.terminationStatus == 0, data.count < 100_000 else { throw AIUsageError.configuration("客户端身份查询失败，请重新登录") }
                    continuation.resume(returning: data)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
