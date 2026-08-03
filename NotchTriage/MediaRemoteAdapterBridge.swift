import Foundation

/// A line-oriented decoder for the JSON emitted by ungive's
/// `mediaremote-adapter`.  Keeping this parser independent of `Process` makes
/// the stream contract testable without launching a player or a helper.
enum MediaRemoteAdapterParser {
    /// Parses one complete JSON line.  A JSON `null`, or an object without a
    /// track title, is the adapter's idle signal and is represented as
    /// `MediaSnapshot.idle`.  Malformed/non-object JSON returns nil so a stray
    /// diagnostic line cannot replace a valid snapshot.
    static func parse(line: String) -> MediaSnapshot? {
        guard let data = line.data(using: .utf8) else { return nil }
        return parse(data: data)
    }

    static func snapshot(from line: String) -> MediaSnapshot? {
        parse(line: line)
    }

    static func parse(data: Data) -> MediaSnapshot? {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            )
        } catch {
            return nil
        }

        if object is NSNull {
            return .idle
        }
        guard let objectDictionary = object as? [String: Any] else {
            return nil
        }

        // `stream` emits an event envelope.  The metadata lives in
        // `payload`; with `--no-diff` this remains a complete snapshot rather
        // than a patch.  Keep accepting a bare metadata object for fixtures
        // and older adapter builds.
        let dictionary: [String: Any]
        if let type = stringValue(objectDictionary["type"]), type.lowercased() == "data" {
            if objectDictionary["payload"] is NSNull {
                return .idle
            }
            guard let payload = objectDictionary["payload"] as? [String: Any] else {
                return nil
            }
            dictionary = payload
        } else {
            dictionary = objectDictionary
        }

        guard let title = stringValue(dictionary["title"]), !title.isEmpty else {
            return .idle
        }

        let bundleIdentifier = stringValue(dictionary["bundleIdentifier"])
        let artist = stringValue(dictionary["artist"]) ?? ""
        let duration = max(0, numberValue(dictionary["duration"]) ?? 0)
        let elapsed = numberValue(dictionary["elapsedTime"]) ?? 0
        let rate = numberValue(dictionary["playbackRate"])
        let isPlaying = boolValue(dictionary["playing"]) ?? ((rate ?? 0) > 0)
        let timestamp = dateValue(dictionary["timestamp"])

        return MediaSnapshot(
            sourceName: sourceName(for: bundleIdentifier),
            bundleIdentifier: bundleIdentifier,
            title: title,
            artist: artist,
            duration: duration,
            elapsed: elapsed,
            isPlaying: isPlaying,
            progressAnchorDate: timestamp,
            playbackRate: rate
        )
    }

    /// Returns true for the adapter's startup envelope whose payload is an
    /// empty object.  The bridge can discard only that first event to avoid a
    /// transient idle flash before the first complete snapshot arrives.
    static func isEmptyPayload(line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(
                  with: data,
                  options: [.fragmentsAllowed]
              ),
              let dictionary = object as? [String: Any],
              stringValue(dictionary["type"])?.lowercased() == "data" else {
            return false
        }
        guard let payload = dictionary["payload"] as? [String: Any] else {
            return false
        }
        return payload.isEmpty
    }

    static func snapshot(from data: Data) -> MediaSnapshot? {
        parse(data: data)
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let string = value as? NSString {
            return string as String
        }
        return nil
    }

    private static func numberValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let string = value as? NSString {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    private static func dateValue(_ value: Any?) -> Date? {
        guard let string = stringValue(value), !string.isEmpty else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static func sourceName(for bundleIdentifier: String?) -> String {
        guard let bundleIdentifier else { return "正在播放" }
        let normalized = bundleIdentifier.lowercased()
        if normalized.contains("spotify") { return "Spotify" }
        if normalized.contains("qqmusic") { return "QQ 音乐" }
        if normalized.contains("netease") || normalized.contains("163") {
            return "网易云音乐"
        }
        if normalized == "com.apple.music" || normalized == "com.apple.musicapp" {
            return "Apple Music"
        }
        return "正在播放"
    }
}

/// Compatibility spelling for call sites/tests that refer to the adapter's
/// JSON stream explicitly.
enum MediaRemoteAdapterJSONParser {
    static func parse(line: String) -> MediaSnapshot? {
        MediaRemoteAdapterParser.parse(line: line)
    }

    static func parse(data: Data) -> MediaSnapshot? {
        MediaRemoteAdapterParser.parse(data: data)
    }

    static func snapshot(from line: String) -> MediaSnapshot? {
        MediaRemoteAdapterParser.parse(line: line)
    }

    static func snapshot(from data: Data) -> MediaSnapshot? {
        MediaRemoteAdapterParser.parse(data: data)
    }
}

@MainActor
final class MediaRemoteAdapterBridge {
    typealias SnapshotHandler = @MainActor (MediaSnapshot) -> Void
    typealias FailureHandler = @MainActor (String) -> Void

    private let onSnapshot: SnapshotHandler
    private let onFailure: FailureHandler
    private let bundle: Bundle

    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputBuffer = Data()
    private var stopping = false
    private var hasProcessedInitialPayload = false

    init(
        bundle: Bundle = .main,
        onSnapshot: @escaping SnapshotHandler,
        onFailure: @escaping FailureHandler
    ) {
        self.bundle = bundle
        self.onSnapshot = onSnapshot
        self.onFailure = onFailure
    }

    var isRunning: Bool {
        process?.isRunning == true
    }

    /// Starts one long-lived adapter process.  A false return means the
    /// packaged resources were unavailable or `perl` could not launch it;
    /// `MediaService` then uses its direct MediaRemote/AppleScript fallback.
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        stopping = false
        hasProcessedInitialPayload = false
        outputBuffer.removeAll(keepingCapacity: true)

        guard let scriptURL = resourceURL(
            "MediaRemoteAdapter/mediaremote-adapter.pl"
        ),
        let frameworkURL = privateFrameworkURL("MediaRemoteAdapter.framework") else {
            return false
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            scriptURL.path,
            frameworkURL.path,
            "stream",
            "--no-diff",
            "--no-artwork",
            "--debounce=100"
        ]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.consume(data)
            }
        }
        // Drain stderr so a verbose helper cannot block on a full pipe.  The
        // adapter's machine-readable contract is stdout only.
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleTermination()
            }
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            return false
        }

        self.process = process
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        return true
    }

    func stop() {
        stopping = true
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        outputPipe = nil
        errorPipe = nil
        outputBuffer.removeAll(keepingCapacity: false)
        hasProcessedInitialPayload = false
    }

    private func resourceURL(_ relativePath: String) -> URL? {
        guard let resourceURL = bundle.resourceURL else { return nil }
        let url = resourceURL.appendingPathComponent(relativePath)
        return FileManager.default.isReadableFile(atPath: url.path) ? url : nil
    }

    private func privateFrameworkURL(_ name: String) -> URL? {
        guard let privateFrameworksURL = bundle.privateFrameworksURL else { return nil }
        let url = privateFrameworksURL.appendingPathComponent(name)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return url
    }

    private func consume(_ data: Data) {
        guard !stopping else { return }
        outputBuffer.append(data)

        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            let end = outputBuffer.index(after: newline)
            outputBuffer.removeSubrange(outputBuffer.startIndex..<end)
            let lineData = line.last == 0x0D ? Data(line.dropLast()) : Data(line)
            guard let line = String(data: lineData, encoding: .utf8),
                  !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            if !hasProcessedInitialPayload,
               MediaRemoteAdapterParser.isEmptyPayload(line: line) {
                hasProcessedInitialPayload = true
                continue
            }
            hasProcessedInitialPayload = true
            if let snapshot = MediaRemoteAdapterParser.parse(line: line) {
                onSnapshot(snapshot)
            }
        }
    }

    private func handleTermination() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        outputPipe = nil
        errorPipe = nil
        guard !stopping else { return }
        onFailure("媒体适配器进程已退出")
    }
}
