import SwiftUI

@main
struct IncomeClockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(environment: appDelegate.environment)
        } label: {
            Image(systemName: "yensign.circle")
                .accessibilityLabel("可视收入打卡机")
                .accessibilityIdentifier("income-clock-menu-bar-extra")
        }

        Settings {
            IncomeSettingsView(environment: appDelegate.environment)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("面板") {
                Button(appDelegate.environment.isPanelVisible ? "隐藏悬浮面板" : "显示悬浮面板") {
                    appDelegate.environment.togglePanelFromShortcut()
                }
                .keyboardShortcut("i", modifiers: [.option, .command])
            }
        }
    }
}
