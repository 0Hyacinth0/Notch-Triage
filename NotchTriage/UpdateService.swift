import CryptoKit
import Foundation

actor UpdateService {
    private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/0Hyacinth0/Notch-Triage/releases/latest"
    )!
    private static let expectedBundleIdentifier = "com.hyacinth.notchtriage"

    func latestRelease() async throws -> AppRelease {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("NotchTriage-Updater", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200 else {
            throw UpdateServiceError.invalidReleaseResponse
        }

        let payload = try JSONDecoder().decode(ReleasePayload.self, from: data)
        guard let asset = payload.assets.first(where: { asset in
            asset.name.localizedCaseInsensitiveContains("macOS-universal")
                && asset.name.lowercased().hasSuffix(".dmg")
        }) ?? payload.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else {
            throw UpdateServiceError.missingInstaller
        }

        guard asset.downloadURL.host?.lowercased() == "github.com",
              asset.downloadURL.path.contains(
                "/0Hyacinth0/Notch-Triage/releases/download/"
              ) else {
            throw UpdateServiceError.untrustedDownloadLocation
        }

        return AppRelease(
            tagName: payload.tagName,
            version: Self.normalizedVersion(payload.tagName),
            title: payload.name ?? payload.tagName,
            notes: payload.body ?? "",
            releaseURL: payload.htmlURL,
            downloadURL: asset.downloadURL,
            assetName: asset.name,
            assetSize: asset.size,
            digest: asset.digest
        )
    }

    func prepareUpdate(
        _ release: AppRelease,
        replacing currentAppURL: URL
    ) async throws -> PreparedAppUpdate {
        let (downloadedURL, response) = try await URLSession.shared.download(
            from: release.downloadURL
        )
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw UpdateServiceError.downloadFailed
        }

        let attributes = try FileManager.default.attributesOfItem(
            atPath: downloadedURL.path
        )
        if let fileSize = attributes[.size] as? NSNumber,
           release.assetSize > 0,
           fileSize.intValue != release.assetSize {
            throw UpdateServiceError.downloadSizeMismatch
        }

        if let expectedDigest = release.digest?.lowercased(),
           expectedDigest.hasPrefix("sha256:") {
            let data = try Data(contentsOf: downloadedURL, options: .mappedIfSafe)
            let actualDigest = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            guard actualDigest == String(expectedDigest.dropFirst("sha256:".count)) else {
                throw UpdateServiceError.downloadDigestMismatch
            }
        }

        let mountURL = try mountDiskImage(at: downloadedURL)
        defer {
            try? detachDiskImage(at: mountURL)
        }

        let appURL = try installerApp(in: mountURL)
        try validate(
            appAt: appURL,
            expectedVersion: release.version,
            currentAppURL: currentAppURL
        )

        let replacementDirectory = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: currentAppURL,
            create: true
        )
        let stagedAppURL = replacementDirectory.appendingPathComponent(
            "NotchTriage.app",
            isDirectory: true
        )
        try FileManager.default.copyItem(at: appURL, to: stagedAppURL)
        try validate(
            appAt: stagedAppURL,
            expectedVersion: release.version,
            currentAppURL: currentAppURL
        )

        return PreparedAppUpdate(
            appURL: stagedAppURL,
            replacementDirectory: replacementDirectory
        )
    }

    private func mountDiskImage(at url: URL) throws -> URL {
        let result = try runProcess(
            executable: "/usr/bin/hdiutil",
            arguments: ["attach", "-nobrowse", "-readonly", "-plist", url.path]
        )
        guard result.status == 0 else {
            throw UpdateServiceError.mountFailed(result.errorText)
        }

        let propertyList = try PropertyListSerialization.propertyList(
            from: result.output,
            options: [],
            format: nil
        )
        guard let dictionary = propertyList as? [String: Any],
              let entities = dictionary["system-entities"] as? [[String: Any]],
              let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw UpdateServiceError.mountFailed("系统没有返回挂载路径")
        }
        return URL(fileURLWithPath: mountPoint, isDirectory: true)
    }

    private func detachDiskImage(at url: URL) throws {
        _ = try runProcess(
            executable: "/usr/bin/hdiutil",
            arguments: ["detach", url.path]
        )
    }

    private func installerApp(in mountURL: URL) throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(
            at: mountURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        guard let appURL = contents.first(where: { url in
            url.pathExtension.lowercased() == "app"
                && Bundle(url: url)?.bundleIdentifier == Self.expectedBundleIdentifier
        }) else {
            throw UpdateServiceError.invalidInstaller
        }
        return appURL
    }

    private func validate(
        appAt appURL: URL,
        expectedVersion: String,
        currentAppURL: URL
    ) throws {
        guard let bundle = Bundle(url: appURL),
              bundle.bundleIdentifier == Self.expectedBundleIdentifier else {
            throw UpdateServiceError.invalidBundleIdentifier
        }
        let installedVersion = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? ""
        guard Self.normalizedVersion(installedVersion)
                == Self.normalizedVersion(expectedVersion) else {
            throw UpdateServiceError.versionMismatch
        }

        let verification = try runProcess(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", appURL.path]
        )
        guard verification.status == 0 else {
            throw UpdateServiceError.invalidSignature(verification.errorText)
        }

        let currentTeam = try teamIdentifier(for: currentAppURL)
        let updateTeam = try teamIdentifier(for: appURL)
        guard !currentTeam.isEmpty, currentTeam == updateTeam else {
            throw UpdateServiceError.signingTeamMismatch
        }
    }

    private func teamIdentifier(for appURL: URL) throws -> String {
        let result = try runProcess(
            executable: "/usr/bin/codesign",
            arguments: ["-d", "--verbose=4", appURL.path]
        )
        guard result.status == 0 else {
            throw UpdateServiceError.invalidSignature(result.errorText)
        }

        let lines = result.errorText.split(separator: "\n")
        guard let line = lines.first(where: { $0.hasPrefix("TeamIdentifier=") }) else {
            throw UpdateServiceError.missingSigningTeam
        }
        return String(line.dropFirst("TeamIdentifier=".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runProcess(
        executable: String,
        arguments: [String]
    ) throws -> ProcessResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        return ProcessResult(
            status: process.terminationStatus,
            output: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            error: errorPipe.fileHandleForReading.readDataToEndOfFile()
        )
    }

    private static func normalizedVersion(_ version: String) -> String {
        version.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^[vV]", with: "", options: .regularExpression)
    }
}

private struct ReleasePayload: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL
    let assets: [ReleaseAssetPayload]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case assets
    }
}

private struct ReleaseAssetPayload: Decodable {
    let name: String
    let size: Int
    let digest: String?
    let downloadURL: URL

    private enum CodingKeys: String, CodingKey {
        case name
        case size
        case digest
        case downloadURL = "browser_download_url"
    }
}

private struct ProcessResult {
    let status: Int32
    let output: Data
    let error: Data

    var errorText: String {
        String(data: error, encoding: .utf8) ?? "未知进程错误"
    }
}

enum UpdateServiceError: LocalizedError {
    case invalidReleaseResponse
    case missingInstaller
    case untrustedDownloadLocation
    case downloadFailed
    case downloadSizeMismatch
    case downloadDigestMismatch
    case mountFailed(String)
    case invalidInstaller
    case invalidBundleIdentifier
    case versionMismatch
    case invalidSignature(String)
    case missingSigningTeam
    case signingTeamMismatch

    var errorDescription: String? {
        switch self {
        case .invalidReleaseResponse:
            return "无法读取 GitHub 最新版本"
        case .missingInstaller:
            return "最新 Release 中没有 macOS DMG 安装包"
        case .untrustedDownloadLocation:
            return "安装包下载地址不属于 Notch Triage 官方仓库"
        case .downloadFailed:
            return "安装包下载失败"
        case .downloadSizeMismatch:
            return "安装包大小与 GitHub 记录不一致"
        case .downloadDigestMismatch:
            return "安装包 SHA-256 校验失败"
        case .mountFailed(let detail):
            return "无法打开安装包：\(detail)"
        case .invalidInstaller:
            return "DMG 中没有有效的 NotchTriage.app"
        case .invalidBundleIdentifier:
            return "更新包的 Bundle ID 不匹配"
        case .versionMismatch:
            return "更新包版本与 Release 标签不匹配"
        case .invalidSignature(let detail):
            return "更新包签名无效：\(detail)"
        case .missingSigningTeam:
            return "当前 App 没有稳定开发者签名，不能自动替换"
        case .signingTeamMismatch:
            return "更新包与当前 App 的开发者签名不一致"
        }
    }
}
