import SwiftUI

@main
enum NotchTriageMain {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count == 3, arguments[1] == "--claude-statusline" {
            exit(ClaudeStatuslineRunner.run(configurationURL: URL(fileURLWithPath: arguments[2])))
        }
        NotchTriageApp.main()
    }
}

struct NotchTriageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("notch.appLanguage") private var appLanguageRawValue =
        AppLanguage.simplifiedChinese.rawValue

    private var appLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageRawValue) ?? .simplifiedChinese
    }

    var body: some Scene {
        Settings {
            SettingsRootView(model: appDelegate.model)
        }
        .environment(\.locale, appLanguage.locale)
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

                Divider()

                Button("打开文件暂存架") {
                    appDelegate.model.showWorkspace(section: .shelf)
                }

                Button("打开剪贴板") {
                    appDelegate.model.showWorkspace(section: .clipboard)
                }
            }
        }
    }
}
