import SwiftUI

@main
struct NotchTriageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            VStack(spacing: 12) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 34))
                Text("Notch Triage")
                    .font(.title2.weight(.semibold))
                Text("设置与诊断都在刘海展开面板中。")
                    .foregroundStyle(.secondary)
            }
            .frame(width: 360, height: 180)
            .padding()
        }
    }
}
