import AppKit
import Security
import WebKit

struct AppleMusicCredential: Codable, Sendable {
    let token: String
    let storefront: String
    let expiresAt: Date?

    private static let service = "com.hyacinth.notchtriage.apple-music-lyrics"
    private static let account = "media-user-token"

    static func read() -> Self? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess,
              let data = found as? Data,
              let result = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        return result
    }

    static func save(_ credential: Self) -> Bool {
        guard let data = try? JSONEncoder().encode(credential) else { return false }
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class AppleMusicAccount: ObservableObject {
    static let shared = AppleMusicAccount()
    @Published private(set) var isConnected = AppleMusicCredential.read() != nil
    @Published private(set) var isConnecting = false
    @Published private(set) var message: String?
    private var login: AppleMusicLoginWindow?

    private init() {}

    func connect() {
        if let login {
            login.showWindow(nil)
            login.window?.makeKeyAndOrderFront(nil)
            return
        }
        isConnecting = true
        message = nil
        let controller = AppleMusicLoginWindow { [weak self] result in
            guard let self else { return }
            self.login = nil
            self.isConnecting = false
            if let result {
                self.isConnected = AppleMusicCredential.save(result)
                self.message = self.isConnected ? "Apple Music 已连接" : "无法将连接信息存入本机钥匙串"
            }
        }
        login = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func disconnect() {
        AppleMusicCredential.delete()
        isConnected = false
        message = "已断开 Apple Music 歌词连接"
    }

    func authorizationExpired() {
        AppleMusicCredential.delete()
        isConnected = false
        message = "Apple Music 授权已失效，请重新连接"
    }
}

@MainActor
private final class AppleMusicLoginWindow: NSWindowController, NSWindowDelegate {
    private let completion: @MainActor (AppleMusicCredential?) -> Void
    private let webView: WKWebView
    private var timer: Timer?
    private var finished = false
    private var firstTokenAt: Date?

    init(completion: @escaping @MainActor (AppleMusicCredential?) -> Void) {
        self.completion = completion
        let configuration = WKWebViewConfiguration()
        // A separate ephemeral store keeps the login page's cookies out of the
        // user's normal browser and out of this app after the window closes.
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        let window = NSWindow(contentRect: webView.frame,
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "连接 Apple Music 歌词"
        window.contentView = webView
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        webView.load(URLRequest(url: URL(string: "https://music.apple.com/login")!))
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.inspectCookies() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func inspectCookies() {
        guard !finished else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                guard let self, !self.finished,
                      let cookie = cookies.first(where: { $0.name == "media-user-token" && !$0.value.isEmpty }) else { return }
                let storefront = cookies.first(where: { $0.name == "itua" })?.value.lowercased() ?? ""
                if storefront.isEmpty {
                    if self.firstTokenAt == nil { self.firstTokenAt = Date() }
                    if Date().timeIntervalSince(self.firstTokenAt!) < 8 { return }
                }
                self.finished = true
                self.timer?.invalidate()
                self.timer = nil
                self.completion(AppleMusicCredential(token: cookie.value,
                                                     storefront: storefront,
                                                     expiresAt: cookie.expiresDate))
                self.close()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        if !finished { finished = true; completion(nil) }
    }
}
