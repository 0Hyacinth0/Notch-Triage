import SwiftUI

@main
struct NotchTriageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsRootView(model: appDelegate.model)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    appDelegate.model.openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(after: .windowArrangement) {
                Button("显示设置") {
                    appDelegate.model.openSettings()
                }

                Button("显示刘海面板") {
                    appDelegate.showNotchPanel()
                }
            }
        }
    }
}
