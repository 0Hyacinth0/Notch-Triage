import AppKit
import Foundation

/// Reads the HTML media clock in the selected tab. Browser automation and
/// "Allow JavaScript from Apple Events" must both be enabled by the user.
enum BrowserPlaybackProbe {
    enum Result { case snapshot(MediaSnapshot), denied, unavailable }

    static func supports(_ bundle: String) -> Bool {
        ["com.apple.safari", "com.google.chrome", "com.microsoft.edgemac",
         "com.brave.browser", "company.thebrowser.browser"].contains(bundle.lowercased())
    }

    static func read(bundleIdentifier bundle: String, current: MediaSnapshot? = nil) -> Result {
        guard supports(bundle) else { return .unavailable }
        let application: String
        switch bundle.lowercased() {
        case "com.apple.safari": application = "Safari"
        case "com.google.chrome": application = "Google Chrome"
        case "com.microsoft.edgemac": application = "Microsoft Edge"
        case "com.brave.browser": application = "Brave Browser"
        case "company.thebrowser.browser": application = "Arc"
        default: return .unavailable
        }
        let javascript = "(function(){var m=Array.from(document.querySelectorAll('audio,video')).find(x=>!x.paused&&isFinite(x.currentTime))||Array.from(document.querySelectorAll('audio,video')).find(x=>isFinite(x.currentTime));if(!m)return '';var d=navigator.mediaSession&&navigator.mediaSession.metadata;return JSON.stringify({title:d&&d.title||'',artist:d&&d.artist||'',album:d&&d.album||'',time:m.currentTime,duration:isFinite(m.duration)?m.duration:0,playing:!m.paused})})()"
        let escaped = javascript.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let command = bundle.lowercased() == "com.apple.safari"
            ? "do JavaScript \"\(escaped)\" in current tab of window wi"
            : "execute (active tab of window wi) javascript \"\(escaped)\""
        let source = """
        if application "\(application)" is running then
            tell application "\(application)"
                set found to {}
                set winCount to count of windows
                if winCount > 5 then set winCount to 5
                repeat with wi from 1 to winCount
                    try
                        with timeout of 1 seconds
                            set itemResult to \(command)
                        end timeout
                        if itemResult is not "" then set end of found to itemResult
                    end try
                end repeat
                return found
            end tell
        end if
        return {}
        """
        let started = Date()
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error) else {
            return (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue == -1743 ? .denied : .unavailable
        }
        guard result.numberOfItems > 0 else { return .unavailable }
        for index in 1...result.numberOfItems {
            guard let string = result.atIndex(index)?.stringValue,
                  let snapshot = parse(string, bundle: bundle, current: current, started: started) else { continue }
            return .snapshot(snapshot)
        }
        return .unavailable
    }

    private static func parse(_ string: String, bundle: String,
                              current: MediaSnapshot?, started: Date) -> MediaSnapshot? {
        guard let data = string.data(using: .utf8),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elapsed = fields["time"] as? Double, elapsed.isFinite, elapsed >= 0 else { return nil }
        let title = fields["title"] as? String ?? ""
        let artist = fields["artist"] as? String ?? ""
        guard !title.isEmpty else { return nil }
        if let current {
            guard LyricsProvider.normalized(title) == LyricsProvider.normalized(current.title),
                  artist.isEmpty || current.artist.isEmpty
                    || LyricsProvider.normalized(artist) == LyricsProvider.normalized(current.artist) else { return nil }
        } else if artist.isEmpty || fields["playing"] as? Bool != true { return nil }
        let duration = fields["duration"] as? Double ?? 0
        if let current, current.duration > 0, duration > 0,
           abs(current.duration - duration) >= 5 { return nil }
        var snapshot = current ?? MediaSnapshot(
            sourceName: PlaybackPlayerPreference.title(for: bundle),
            bundleIdentifier: bundle,
            title: title,
            artist: artist,
            duration: duration,
            elapsed: elapsed,
            isPlaying: fields["playing"] as? Bool ?? false,
            album: fields["album"] as? String ?? "",
            positionSource: .playerScript
        )
        snapshot.elapsed = elapsed
        snapshot.isPlaying = fields["playing"] as? Bool ?? current?.isPlaying ?? false
        snapshot.progressAnchorDate = started.addingTimeInterval(Date().timeIntervalSince(started) / 2)
        snapshot.positionSource = .playerScript
        return snapshot
    }
}
