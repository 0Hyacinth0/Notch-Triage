import AppKit
import Darwin
import Foundation

struct QQMusicTrackMetadata: Equatable {
    let title: String
    let artist: String
    let isPlaying: Bool
}

enum QQMusicMetadataParser {
    static func track(from text: String, isPlaying: Bool) -> QQMusicTrackMetadata? {
        let normalized = text.replacingOccurrences(of: "：", with: ":")
        guard let titleMarker = normalized.range(of: "歌曲名:"),
              let artistMarker = normalized.range(of: "歌手名:",
                                                  range: titleMarker.upperBound..<normalized.endIndex) else {
            return nil
        }

        let title = normalized[titleMarker.upperBound..<artistMarker.lowerBound]
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
                .union(CharacterSet(charactersIn: "-–—")))
        let artist = normalized[artistMarker.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !title.isEmpty else { return nil }
        return QQMusicTrackMetadata(
            title: title,
            artist: artist,
            isPlaying: isPlaying
        )
    }

    static func isPlaying(from actionTexts: [String]) -> Bool? {
        let normalized = actionTexts.map {
            $0.replacingOccurrences(of: "：", with: ":")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // QQ Music exposes the action of the play/pause button rather than
        // a separate state value: “暂停” means the track is playing, while
        // “播放” means the track is paused.
        if normalized.contains(where: {
            $0 == "暂停" || ($0.contains("暂停") && !$0.contains("列表"))
        }) {
            return true
        }
        if normalized.contains(where: {
            $0 == "播放" || ($0.hasPrefix("播放") && !$0.contains("列表"))
        }) {
            return false
        }
        return nil
    }
}

@MainActor
final class MediaService {
    typealias SnapshotHandler = @MainActor (MediaSnapshot) -> Void
    typealias HealthHandler = @MainActor (ServiceHealth) -> Void

    private typealias NowPlayingCallback = @convention(block) (CFDictionary?) -> Void
    private typealias GetNowPlayingInfo = @convention(c) (
        DispatchQueue,
        NowPlayingCallback
    ) -> Void

    private let onSnapshot: SnapshotHandler
    private let onHealth: HealthHandler

    private let qqMusicBundleIdentifier = "com.tencent.QQMusicMac"
    private var mediaRemoteHandle: UnsafeMutableRawPointer?
    private var getNowPlayingInfo: GetNowPlayingInfo?
    private var appleScriptFallbackDisabled = false
    private var adapterBridgeHealthy = false
    private var stopping = false

    private lazy var adapterBridge = MediaRemoteAdapterBridge(
        onSnapshot: { [weak self] snapshot in
            self?.receiveAdapterSnapshot(snapshot)
        },
        onFailure: { [weak self] reason in
            self?.adapterDidFail(reason)
        }
    )

    init(
        onSnapshot: @escaping SnapshotHandler,
        onHealth: @escaping HealthHandler
    ) {
        self.onSnapshot = onSnapshot
        self.onHealth = onHealth
        loadMediaRemote()
    }

    func start() {
        stopping = false
        adapterBridgeHealthy = true
        if adapterBridge.start() {
            onHealth(.ready("已连接媒体适配器"))
            return
        }

        adapterBridgeHealthy = false
        onHealth(.warning("媒体适配器不可用，将使用系统播放桥接"))
        refreshDirect()
    }

    func stop() {
        stopping = true
        adapterBridge.stop()
        adapterBridgeHealthy = false
        if let mediaRemoteHandle {
            dlclose(mediaRemoteHandle)
        }
        mediaRemoteHandle = nil
        getNowPlayingInfo = nil
    }

    func refresh() {
        if adapterBridgeHealthy {
            if adapterBridge.isRunning {
                return
            }
            adapterBridgeHealthy = false
        }
        refreshDirect()
    }

    private func refreshDirect() {
        guard let getNowPlayingInfo else {
            refreshWithAppleScript()
            return
        }

        let callback: NowPlayingCallback = { [weak self] dictionary in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let parsedSnapshot = self.parseMediaRemote(dictionary)
                if let snapshot = self.resolvedMediaRemoteSnapshot(parsedSnapshot) {
                    self.onSnapshot(snapshot)
                } else {
                    // MediaRemote can briefly return an incomplete dictionary
                    // while a track is changing. Use the guarded fallback
                    // only when MediaRemote did not provide a usable snapshot;
                    // a denied automation request is then permanently
                    // suppressed for this app run.
                    self.refreshWithAppleScript()
                }
            }
        }

        getNowPlayingInfo(.main, callback)
    }

    private func receiveAdapterSnapshot(_ snapshot: MediaSnapshot) {
        guard !stopping else { return }
        if snapshot == .idle {
            onSnapshot(.idle)
            return
        }
        var resolved = snapshot
        resolved.sourceName = sourceName(for: snapshot.bundleIdentifier)
        resolved = resolvedAdapterSnapshot(resolved)
        onSnapshot(resolved)
    }

    private func adapterDidFail(_ reason: String) {
        guard !stopping else { return }
        adapterBridgeHealthy = false
        onHealth(.warning("媒体适配器异常：\(reason)；已切换系统播放桥接"))
        refreshDirect()
    }

    private func loadMediaRemote() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_LAZY),
              let symbol = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else {
            onHealth(.warning("系统播放桥接不可用，将尝试播放器脚本"))
            return
        }

        mediaRemoteHandle = handle
        getNowPlayingInfo = unsafeBitCast(symbol, to: GetNowPlayingInfo.self)
    }

    private func parseMediaRemote(_ dictionary: CFDictionary?) -> MediaSnapshot? {
        guard let dictionary else {
            return nil
        }

        let info = (dictionary as NSDictionary).reduce(into: [String: Any]()) {
            result,
            entry in
            result[String(describing: entry.key)] = entry.value
        }

        let title = stringValue(in: info, suffix: "Title")
        guard let title, !title.isEmpty else { return nil }

        let artist = stringValue(in: info, suffix: "Artist") ?? ""
        let duration = numberValue(in: info, suffix: "Duration") ?? 0
        let elapsed = numberValue(in: info, suffix: "ElapsedTime") ?? 0
        let rate = numberValue(in: info, suffix: "PlaybackRate") ?? 0
        let timestamp = dateValue(in: info, suffix: "Timestamp")
        let bundleIdentifier =
            stringValue(in: info, suffix: "ClientBundleIdentifier")
            ?? stringValue(in: info, suffix: "ApplicationBundleIdentifier")

        return MediaSnapshot(
            sourceName: sourceName(for: bundleIdentifier),
            bundleIdentifier: bundleIdentifier,
            title: title,
            artist: artist,
            duration: duration,
            elapsed: elapsed,
            isPlaying: rate > 0,
            progressAnchorDate: timestamp,
            playbackRate: rate
        )
    }

    private func stringValue(in dictionary: [String: Any], suffix: String) -> String? {
        for (key, value) in dictionary where key.localizedCaseInsensitiveContains(suffix) {
            if let string = value as? String {
                return string
            }
            if let string = value as? NSString {
                return string as String
            }
        }
        return nil
    }

    private func numberValue(in dictionary: [String: Any], suffix: String) -> Double? {
        for (key, value) in dictionary where key.localizedCaseInsensitiveContains(suffix) {
            if let number = value as? NSNumber {
                return number.doubleValue
            }
        }
        return nil
    }

    private func dateValue(in dictionary: [String: Any], suffix: String) -> Date? {
        for (key, value) in dictionary where key.localizedCaseInsensitiveContains(suffix) {
            if let date = value as? Date {
                return date
            }
            if let string = value as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: string) {
                    return date
                }
                formatter.formatOptions = [.withInternetDateTime]
                return formatter.date(from: string)
            }
        }
        return nil
    }

    private func sourceName(for bundleIdentifier: String?) -> String {
        guard let bundleIdentifier else { return "正在播放" }
        let normalized = bundleIdentifier.lowercased()
        if normalized.contains("spotify") { return "Spotify" }
        if normalized.contains("qqmusic") { return "QQ 音乐" }
        if normalized.contains("netease") || normalized.contains("163") { return "网易云音乐" }
        if normalized == "com.apple.music" { return "Apple Music" }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            .flatMap(Bundle.init(url:))?
            .object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? "正在播放"
    }

    private func refreshWithAppleScript() {
        guard !appleScriptFallbackDisabled else {
            onSnapshot(qqMusicSnapshot() ?? .idle)
            return
        }

        if let snapshot = qqMusicSnapshot() {
            onSnapshot(snapshot)
        } else if let snapshot = appleMusicSnapshot() {
            onSnapshot(snapshot)
        } else if !appleScriptFallbackDisabled,
                  let snapshot = spotifySnapshot() {
            onSnapshot(snapshot)
        } else {
            onSnapshot(.idle)
        }
    }

    private func resolvedMediaRemoteSnapshot(
        _ snapshot: MediaSnapshot?
    ) -> MediaSnapshot? {
        guard let snapshot else {
            return qqMusicSnapshot()
        }

        // QQ Music publishes title/artist/progress through MediaRemote but
        // omits the client bundle identifier. When its AX tree has the same
        // track, use the button state and restore the source name without
        // confusing another active media app.
        guard snapshot.bundleIdentifier == nil,
              let qqSnapshot = qqMusicSnapshot(),
              normalizedMediaText(snapshot.title) == normalizedMediaText(qqSnapshot.title) else {
            return snapshot
        }

        return MediaSnapshot(
            sourceName: "QQ 音乐",
            bundleIdentifier: qqMusicBundleIdentifier,
            title: qqSnapshot.title,
            artist: qqSnapshot.artist.isEmpty ? snapshot.artist : qqSnapshot.artist,
            duration: snapshot.duration > 0 ? snapshot.duration : qqSnapshot.duration,
            elapsed: snapshot.elapsed,
            isPlaying: qqSnapshot.isPlaying,
            progressAnchorDate: snapshot.progressAnchorDate,
            playbackRate: snapshot.playbackRate
        )
    }

    private func resolvedAdapterSnapshot(_ snapshot: MediaSnapshot) -> MediaSnapshot {
        guard snapshot.bundleIdentifier?.lowercased() == qqMusicBundleIdentifier.lowercased(),
              let qqSnapshot = qqMusicSnapshot(),
              normalizedMediaText(snapshot.title) == normalizedMediaText(qqSnapshot.title) else {
            return snapshot
        }

        // The adapter has a fresh elapsed/timestamp pair and authoritative
        // playing state.  AX is only a metadata/action supplement, and must
        // never replace that progress or state with QQ's position-less AX
        // snapshot.
        return MediaSnapshot(
            sourceName: "QQ 音乐",
            bundleIdentifier: qqMusicBundleIdentifier,
            title: snapshot.title.isEmpty ? qqSnapshot.title : snapshot.title,
            artist: snapshot.artist.isEmpty ? qqSnapshot.artist : snapshot.artist,
            duration: snapshot.duration > 0 ? snapshot.duration : qqSnapshot.duration,
            elapsed: snapshot.elapsed,
            isPlaying: snapshot.isPlaying,
            progressAnchorDate: snapshot.progressAnchorDate,
            playbackRate: snapshot.playbackRate
        )
    }

    private func qqMusicSnapshot() -> MediaSnapshot? {
        guard let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: qqMusicBundleIdentifier
        ).first else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        let windows = elements(appElement, attribute: kAXWindowsAttribute)
        guard !windows.isEmpty else { return nil }
        var actionTexts: [String] = []

        for window in windows {
            for element in axElements(in: window, maximumDepth: 8) {
                let values = textValues(of: element)
                // QQ exposes transport controls as AXUnknown on current
                // builds, so inspect every element's title/description/etc.
                // rather than restricting this pass to AXButton.
                actionTexts.append(contentsOf: values)
            }
        }

        // The track row is encountered before the play button in QQ Music's
        // AX tree, so resolve the state in a second pass after collecting all
        // button labels.
        guard let trackText = windows
            .flatMap({ axElements(in: $0, maximumDepth: 8) })
            .flatMap(textValues(of:))
            .first(where: { $0.contains("歌曲名") && $0.contains("歌手名") }),
              let metadata = QQMusicMetadataParser.track(
                  from: trackText,
                  isPlaying: QQMusicMetadataParser.isPlaying(from: actionTexts) ?? false
              ) else {
            return nil
        }

        return MediaSnapshot(
            sourceName: "QQ 音乐",
            bundleIdentifier: qqMusicBundleIdentifier,
            title: metadata.title,
            artist: metadata.artist,
            duration: 0,
            elapsed: 0,
            isPlaying: metadata.isPlaying
        )
    }

    private func normalizedMediaText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func axElements(
        in root: AXUIElement,
        maximumDepth: Int
    ) -> [AXUIElement] {
        guard maximumDepth > 0 else { return [root] }
        var result = [root]
        for child in elements(root, attribute: kAXChildrenAttribute) {
            result.append(contentsOf: axElements(in: child, maximumDepth: maximumDepth - 1))
        }
        return result
    }

    private func textValues(of element: AXUIElement) -> [String] {
        [
            string(element, attribute: kAXTitleAttribute),
            string(element, attribute: kAXDescriptionAttribute),
            string(element, attribute: kAXIdentifierAttribute),
            string(element, attribute: kAXValueAttribute),
            string(element, attribute: kAXHelpAttribute)
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func elements(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else {
            return []
        }
        return elements
    }

    private func string(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        if let string = value as? String {
            return string
        }
        if let string = value as? NSString {
            return string as String
        }
        return nil
    }

    private func appleMusicSnapshot() -> MediaSnapshot? {
        return descriptorSnapshot(
            script: """
            if application "Music" is running then
                tell application "Music"
                    if player state is not stopped then
                        return {name of current track, artist of current track, duration of current track, player position, (player state is playing)}
                    end if
                end tell
            end if
            return {}
            """,
            sourceName: "Apple Music",
            bundleIdentifier: "com.apple.Music",
            durationScale: 1
        )
    }

    private func spotifySnapshot() -> MediaSnapshot? {
        guard NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.spotify.client"
        ) != nil,
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.spotify.client"
        ).isEmpty else {
            return nil
        }

        return descriptorSnapshot(
            script: """
            if application "Spotify" is running then
                tell application "Spotify"
                    if player state is not stopped then
                        return {name of current track, artist of current track, duration of current track, player position, (player state is playing)}
                    end if
                end tell
            end if
            return {}
            """,
            sourceName: "Spotify",
            bundleIdentifier: "com.spotify.client",
            durationScale: 0.001
        )
    }

    private func descriptorSnapshot(
        script: String,
        sourceName: String,
        bundleIdentifier: String,
        durationScale: Double
    ) -> MediaSnapshot? {
        var error: NSDictionary?
        guard let descriptor = NSAppleScript(source: script)?.executeAndReturnError(&error),
              descriptor.numberOfItems >= 5 else {
            if let errorNumber = error?[NSAppleScript.errorNumber] as? NSNumber,
               errorNumber.intValue == -1743 {
                appleScriptFallbackDisabled = true
                onHealth(.warning("媒体自动化权限未授权；已停止重复请求"))
            }
            return nil
        }

        let title = descriptor.atIndex(1)?.stringValue ?? ""
        guard !title.isEmpty else { return nil }

        return MediaSnapshot(
            sourceName: sourceName,
            bundleIdentifier: bundleIdentifier,
            title: title,
            artist: descriptor.atIndex(2)?.stringValue ?? "",
            duration: (descriptor.atIndex(3)?.doubleValue ?? 0) * durationScale,
            elapsed: descriptor.atIndex(4)?.doubleValue ?? 0,
            isPlaying: descriptor.atIndex(5)?.booleanValue ?? false
        )
    }
}
