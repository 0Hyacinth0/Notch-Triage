import AppKit
import Darwin
import Foundation

struct QQMusicTrackMetadata: Equatable, Sendable {
    let title: String
    let artist: String
    let isPlaying: Bool
}

protocol QQMusicAccessibilityScanning: Sendable {
    func trackMetadata(
        processIdentifier: pid_t,
        cancellation: QQMusicScanCancellation
    ) async -> QQMusicTrackMetadata?
}

final class QQMusicScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

final class QQMusicAccessibilityScanner: QQMusicAccessibilityScanning, @unchecked Sendable {
    private static let maximumDepth = 8
    private static let maximumElementCount = 256
    private static let messagingTimeout: Float = 0.2

    private struct NodeSnapshot {
        let textValues: [String]
        let children: [AXUIElement]
    }

    private let queue = DispatchQueue(
        label: "com.hyacinth.notchtriage.qqmusic-accessibility",
        qos: .utility
    )

    func trackMetadata(
        processIdentifier: pid_t,
        cancellation: QQMusicScanCancellation
    ) async -> QQMusicTrackMetadata? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(
                    returning: Self.scan(
                        processIdentifier: processIdentifier,
                        cancellation: cancellation
                    )
                )
            }
        }
    }

    private static func scan(
        processIdentifier: pid_t,
        cancellation: QQMusicScanCancellation
    ) -> QQMusicTrackMetadata? {
        guard !cancellation.isCancelled else { return nil }
        let application = AXUIElementCreateApplication(processIdentifier)
        setMessagingTimeout(on: application)

        let windows = elements(application, attribute: kAXWindowsAttribute)
        guard !windows.isEmpty else { return nil }

        var stack = windows.reversed().map { ($0, 0) }
        var visitedCount = 0
        var trackText: String?
        var playbackState: Bool?

        while let (element, depth) = stack.popLast(),
              visitedCount < maximumElementCount {
            guard !cancellation.isCancelled else { return nil }
            visitedCount += 1
            setMessagingTimeout(on: element)

            let node = nodeSnapshot(
                of: element,
                includeChildren: depth < maximumDepth
            )
            let values = node.textValues
            if trackText == nil {
                trackText = values.first(where: {
                    $0.contains("歌曲名") && $0.contains("歌手名")
                })
            }

            if let state = QQMusicMetadataParser.isPlaying(from: values) {
                // A visible “暂停” action is stronger evidence than generic
                // “播放” text elsewhere in the hierarchy.
                if state || playbackState == nil {
                    playbackState = state
                }
            }

            if let trackText, playbackState == true,
               let metadata = QQMusicMetadataParser.track(
                   from: trackText,
                   isPlaying: true
               ) {
                return metadata
            }

            for child in node.children.reversed() {
                stack.append((child, depth + 1))
            }
        }

        guard let trackText else { return nil }
        return QQMusicMetadataParser.track(
            from: trackText,
            isPlaying: playbackState ?? false
        )
    }

    private static func setMessagingTimeout(on element: AXUIElement) {
        _ = AXUIElementSetMessagingTimeout(element, messagingTimeout)
    }

    private static func nodeSnapshot(
        of element: AXUIElement,
        includeChildren: Bool
    ) -> NodeSnapshot {
        var attributes = [
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXIdentifierAttribute,
            kAXValueAttribute,
            kAXHelpAttribute
        ] as [String]
        if includeChildren {
            attributes.insert(kAXChildrenAttribute, at: 0)
        }

        var rawValues: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(
            element,
            attributes as CFArray,
            [],
            &rawValues
        ) == .success,
        let values = rawValues as? [Any] else {
            return NodeSnapshot(textValues: [], children: [])
        }

        let children: [AXUIElement]
        let textStartIndex: Int
        if includeChildren {
            children = values.first as? [AXUIElement] ?? []
            textStartIndex = 1
        } else {
            children = []
            textStartIndex = 0
        }

        let textValues = values.dropFirst(textStartIndex).compactMap { value -> String? in
            if let string = value as? String {
                return string
            }
            if let string = value as? NSString {
                return string as String
            }
            return nil
        }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return NodeSnapshot(textValues: textValues, children: children)
    }

    private static func elements(
        _ element: AXUIElement,
        attribute: String
    ) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
        let elements = value as? [AXUIElement] else {
            return []
        }
        return elements
    }
}

struct QQMusicAXScanKey: Equatable, Sendable {
    let processIdentifier: pid_t
    let title: String
    let artist: String
    let isPlaying: Bool
    let shouldUseAXPlaybackState: Bool

    init(processIdentifier: pid_t, snapshot: MediaSnapshot) {
        self.processIdentifier = processIdentifier
        title = Self.normalized(snapshot.title)
        artist = Self.normalized(snapshot.artist)
        isPlaying = snapshot.isPlaying
        shouldUseAXPlaybackState = snapshot.bundleIdentifier == nil
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum QQMusicSnapshotEnricher {
    static func merge(
        _ snapshot: MediaSnapshot,
        metadata: QQMusicTrackMetadata,
        bundleIdentifier: String
    ) -> MediaSnapshot? {
        let snapshotTitle = normalized(snapshot.title)
        let metadataTitle = normalized(metadata.title)
        guard snapshotTitle.isEmpty || snapshotTitle == metadataTitle else {
            return nil
        }

        return MediaSnapshot(
            sourceName: "QQ 音乐",
            bundleIdentifier: bundleIdentifier,
            title: snapshot.title.isEmpty ? metadata.title : snapshot.title,
            artist: snapshot.artist.isEmpty ? metadata.artist : snapshot.artist,
            duration: snapshot.duration,
            elapsed: snapshot.elapsed,
            isPlaying: snapshot.bundleIdentifier == nil
                ? metadata.isPlaying
                : snapshot.isPlaying,
            progressAnchorDate: snapshot.progressAnchorDate,
            playbackRate: snapshot.playbackRate
        )
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
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
    typealias QQMusicProcessIdentifierProvider = @MainActor () -> pid_t?

    private typealias NowPlayingCallback = @convention(block) (CFDictionary?) -> Void
    private typealias GetNowPlayingInfo = @convention(c) (
        DispatchQueue,
        NowPlayingCallback
    ) -> Void

    private let onSnapshot: SnapshotHandler
    private let onHealth: HealthHandler
    private let qqMusicScanner: any QQMusicAccessibilityScanning
    private let qqMusicProcessIdentifier: QQMusicProcessIdentifierProvider

    private let qqMusicBundleIdentifier = "com.tencent.QQMusicMac"
    private let qqMusicAXFailureRetryInterval: TimeInterval = 15
    private var mediaRemoteHandle: UnsafeMutableRawPointer?
    private var getNowPlayingInfo: GetNowPlayingInfo?
    private var appleScriptFallbackDisabled = false
    private var adapterBridgeHealthy = false
    private var stopping = false

    private struct QQMusicAXRequest: Equatable {
        let key: QQMusicAXScanKey
    }

    private struct QQMusicAXCache {
        let key: QQMusicAXScanKey
        let metadata: QQMusicTrackMetadata
    }

    private var qqMusicAXTask: Task<Void, Never>?
    private var qqMusicAXCancellation: QQMusicScanCancellation?
    private var qqMusicAXActiveRequest: QQMusicAXRequest?
    private var qqMusicAXPendingRequest: QQMusicAXRequest?
    private var qqMusicAXCache: QQMusicAXCache?
    private var qqMusicAXLastCompletedKey: QQMusicAXScanKey?
    private var qqMusicAXLastCompletedDate: Date?
    private var qqMusicAXLatestSnapshot: MediaSnapshot?
    private var qqMusicAXScanIdentifier = 0

    private var qqMusicFallbackTask: Task<Void, Never>?
    private var qqMusicFallbackCancellation: QQMusicScanCancellation?
    private var qqMusicFallbackIdentifier = 0

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
        onHealth: @escaping HealthHandler,
        qqMusicScanner: any QQMusicAccessibilityScanning = QQMusicAccessibilityScanner(),
        qqMusicProcessIdentifier: @escaping QQMusicProcessIdentifierProvider = {
            NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.tencent.QQMusicMac"
            ).first?.processIdentifier
        }
    ) {
        self.onSnapshot = onSnapshot
        self.onHealth = onHealth
        self.qqMusicScanner = qqMusicScanner
        self.qqMusicProcessIdentifier = qqMusicProcessIdentifier
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
        resetQQMusicEnrichment()
        qqMusicFallbackIdentifier &+= 1
        qqMusicFallbackCancellation?.cancel()
        qqMusicFallbackCancellation = nil
        qqMusicFallbackTask?.cancel()
        qqMusicFallbackTask = nil
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
                if var snapshot = self.parseMediaRemote(dictionary) {
                    snapshot.sourceName = self.sourceName(for: snapshot.bundleIdentifier)
                    self.publish(snapshot)
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

    func receiveAdapterSnapshot(_ snapshot: MediaSnapshot) {
        guard !stopping else { return }
        if snapshot == .idle {
            resetQQMusicEnrichment()
            onSnapshot(.idle)
            return
        }
        var resolved = snapshot
        resolved.sourceName = sourceName(for: snapshot.bundleIdentifier)
        publish(resolved)
    }

    private func adapterDidFail(_ reason: String) {
        guard !stopping else { return }
        adapterBridgeHealthy = false
        resetQQMusicEnrichment()
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
        guard qqMusicFallbackTask == nil else { return }
        guard let processIdentifier = qqMusicProcessIdentifier() else {
            refreshWithPlayerScripts()
            return
        }

        qqMusicFallbackIdentifier &+= 1
        let identifier = qqMusicFallbackIdentifier
        let scanner = qqMusicScanner
        let cancellation = QQMusicScanCancellation()
        qqMusicFallbackCancellation = cancellation
        qqMusicFallbackTask = Task { @MainActor [weak self] in
            let metadata = await scanner.trackMetadata(
                processIdentifier: processIdentifier,
                cancellation: cancellation
            )
            guard let self,
                  !self.stopping,
                  self.qqMusicFallbackIdentifier == identifier else {
                return
            }
            self.qqMusicFallbackTask = nil
            self.qqMusicFallbackCancellation = nil

            if let metadata {
                self.onSnapshot(MediaSnapshot(
                    sourceName: "QQ 音乐",
                    bundleIdentifier: self.qqMusicBundleIdentifier,
                    title: metadata.title,
                    artist: metadata.artist,
                    duration: 0,
                    elapsed: 0,
                    isPlaying: metadata.isPlaying
                ))
            } else {
                self.refreshWithPlayerScripts()
            }
        }
    }

    private func refreshWithPlayerScripts() {
        guard !appleScriptFallbackDisabled else {
            onSnapshot(.idle)
            return
        }

        if let snapshot = appleMusicSnapshot() {
            onSnapshot(snapshot)
        } else if !appleScriptFallbackDisabled,
                  let snapshot = spotifySnapshot() {
            onSnapshot(snapshot)
        } else {
            onSnapshot(.idle)
        }
    }

    private func publish(_ snapshot: MediaSnapshot) {
        let normalizedBundleIdentifier = snapshot.bundleIdentifier?.lowercased()
        let isQQMusic = normalizedBundleIdentifier == qqMusicBundleIdentifier.lowercased()
        let canBeUnidentifiedQQMusic = snapshot.bundleIdentifier == nil
        // The adapter already provides authoritative progress and playback
        // state. Avoid AX entirely when its QQ metadata is complete.
        let needsAccessibilityEnrichment = canBeUnidentifiedQQMusic
            || snapshot.title.isEmpty
            || snapshot.artist.isEmpty

        guard (isQQMusic || canBeUnidentifiedQQMusic),
              needsAccessibilityEnrichment,
              let processIdentifier = qqMusicProcessIdentifier() else {
            resetQQMusicEnrichment()
            onSnapshot(snapshot)
            return
        }

        let key = QQMusicAXScanKey(
            processIdentifier: processIdentifier,
            snapshot: snapshot
        )
        qqMusicAXLatestSnapshot = snapshot

        if let cache = qqMusicAXCache,
           cache.key == key,
           let enriched = QQMusicSnapshotEnricher.merge(
               snapshot,
               metadata: cache.metadata,
               bundleIdentifier: qqMusicBundleIdentifier
           ) {
            onSnapshot(enriched)
        } else {
            onSnapshot(snapshot)
        }

        scheduleQQMusicEnrichment(QQMusicAXRequest(key: key))
    }

    private func scheduleQQMusicEnrichment(_ request: QQMusicAXRequest) {
        if qqMusicAXCache?.key == request.key {
            return
        }
        if qqMusicAXLastCompletedKey == request.key,
           let completedDate = qqMusicAXLastCompletedDate,
           Date().timeIntervalSince(completedDate) < qqMusicAXFailureRetryInterval {
            return
        }

        if let activeRequest = qqMusicAXActiveRequest {
            qqMusicAXPendingRequest = activeRequest == request ? nil : request
            if activeRequest != request {
                qqMusicAXCancellation?.cancel()
            }
            return
        }

        beginQQMusicEnrichment(request)
    }

    private func beginQQMusicEnrichment(_ request: QQMusicAXRequest) {
        guard qqMusicAXActiveRequest == nil else {
            return
        }
        if qqMusicAXLastCompletedKey == request.key,
           let completedDate = qqMusicAXLastCompletedDate,
           Date().timeIntervalSince(completedDate) < qqMusicAXFailureRetryInterval {
            return
        }

        qqMusicAXScanIdentifier &+= 1
        let identifier = qqMusicAXScanIdentifier
        let scanner = qqMusicScanner
        let cancellation = QQMusicScanCancellation()
        qqMusicAXActiveRequest = request
        qqMusicAXCancellation = cancellation
        qqMusicAXTask = Task { @MainActor [weak self] in
            let metadata = await scanner.trackMetadata(
                processIdentifier: request.key.processIdentifier,
                cancellation: cancellation
            )
            self?.finishQQMusicEnrichment(
                identifier: identifier,
                request: request,
                metadata: metadata
            )
        }
    }

    private func finishQQMusicEnrichment(
        identifier: Int,
        request: QQMusicAXRequest,
        metadata: QQMusicTrackMetadata?
    ) {
        guard identifier == qqMusicAXScanIdentifier,
              qqMusicAXActiveRequest == request else {
            return
        }

        qqMusicAXTask = nil
        qqMusicAXCancellation = nil
        qqMusicAXActiveRequest = nil
        qqMusicAXLastCompletedKey = request.key
        qqMusicAXLastCompletedDate = Date()

        if !stopping,
           let metadata,
           let latestSnapshot = qqMusicAXLatestSnapshot,
           QQMusicAXScanKey(
               processIdentifier: request.key.processIdentifier,
               snapshot: latestSnapshot
           ) == request.key,
           let enriched = QQMusicSnapshotEnricher.merge(
               latestSnapshot,
               metadata: metadata,
               bundleIdentifier: qqMusicBundleIdentifier
           ) {
            qqMusicAXCache = QQMusicAXCache(
                key: request.key,
                metadata: metadata
            )
            onSnapshot(enriched)
        }

        let pendingRequest = qqMusicAXPendingRequest
        qqMusicAXPendingRequest = nil
        if !stopping, let pendingRequest {
            beginQQMusicEnrichment(pendingRequest)
        }
    }

    private func resetQQMusicEnrichment() {
        qqMusicAXScanIdentifier &+= 1
        qqMusicAXCancellation?.cancel()
        qqMusicAXCancellation = nil
        qqMusicAXTask?.cancel()
        qqMusicAXTask = nil
        qqMusicAXActiveRequest = nil
        qqMusicAXPendingRequest = nil
        qqMusicAXCache = nil
        qqMusicAXLastCompletedKey = nil
        qqMusicAXLastCompletedDate = nil
        qqMusicAXLatestSnapshot = nil
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
