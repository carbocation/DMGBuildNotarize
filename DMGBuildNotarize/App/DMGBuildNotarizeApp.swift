import SwiftUI

@main
struct DMGBuildNotarizeApp: App {
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            ContentView(settings: settings)
                .frame(minWidth: 920, minHeight: 640)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(settings: settings)
                .frame(width: 620)
        }
    }
}
