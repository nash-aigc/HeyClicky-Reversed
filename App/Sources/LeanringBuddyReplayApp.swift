import SwiftUI
import AppKit

/// 入口：整个工程第一个窗口。
/// 原版是 LSUIElement 菜单栏应用（Info.plist LSUIElement=true，Dock 无图标，无法成为 frontmost app）。
/// 复刻版为了可观测 + macos-use 自动化可触发，故意不设 LSUIElement，保留主窗口 + Dock 图标。
/// 如需还原原版行为：在 Info.plist 加 LSUIElement=true 即可。
@main
struct LeanringBuddyReplayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 620)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: false)
                }
        }
    }
}

/// AppDelegate：窗口激活策略 —— regular app（Dock 图标 + 可 frontmost）
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // 让窗口在启动时置于最前
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.activate(ignoringOtherApps: false)
            for w in NSApp.windows where w.isVisible {
                w.makeKeyAndOrderFront(nil)
            }
        }
    }
}
