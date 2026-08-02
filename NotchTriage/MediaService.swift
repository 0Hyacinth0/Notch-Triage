import AppKit
import Darwin
import Foundation

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

    private var mediaRemoteHandle: UnsafeMutableRawPointer?
    private var getNowPlayingInfo: GetNowPlayingInfo?
    private var appleScriptFallbackDisabled = false

    init(
        onSnapshot: @escaping SnapshotHandler,
        onHealth: @escaping HealthHandler
    ) {
        self.onSnapshot = onSnapshot
        self.onHealth = onHealth
        loadMediaRemote()
    }

    func start() {
        refresh()
    }

    func stop() {
        if let mediaRemoteHandle {
            dlclose(mediaRemoteHandle)
        }
        mediaRemoteHandle = nil
        getNowPlayingInfo = nil
    }

    func refresh() {
        guard let getNowPlayingInfo else {
            refreshWithAppleScript()
            return
        }

        let callback: NowPlayingCallback = { [weak self] dictionary in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let snapshot = self.parseMediaRemote(dictionary) {
                    self.onSnapshot(snapshot)
                } else {
                    // MediaRemote can briefly return an incomplete dictionary
                    // while a track is changing. Do not fall back to
                    // AppleScript here: that path invokes the automation TCC
                    // prompt and can ask again on every track transition.
                    self.onSnapshot(.idle)
                }
            }
        }

        getNowPlayingInfo(.main, callback)
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
        guard let dictionary,
              let info = dictionary as NSDictionary as? [String: Any] else {
            return nil
        }

        let title = stringValue(in: info, suffix: "Title")
        guard let title, !title.isEmpty else { return nil }

        let artist = stringValue(in: info, suffix: "Artist") ?? ""
        let duration = numberValue(in: info, suffix: "Duration") ?? 0
        let elapsed = numberValue(in: info, suffix: "ElapsedTime") ?? 0
        let rate = numberValue(in: info, suffix: "PlaybackRate") ?? 0
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
            isPlaying: rate > 0
        )
    }

    private func stringValue(in dictionary: [String: Any], suffix: String) -> String? {
        for (key, value) in dictionary where key.localizedCaseInsensitiveContains(suffix) {
            if let string = value as? String {
                return string
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
