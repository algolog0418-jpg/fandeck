//  FanDeckApp.swift — 진입점
//
//  메뉴바에 상주하면서 필요할 때만 창을 연다.
//  앱을 종료해도 팬 설정은 데몬이 계속 유지한다.

import SwiftUI

/// 메뉴 막대 아이템을 들고 있을 곳. SwiftUI 쪽에는 둘 자리가 마땅치 않다.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let model = AppModel.shared
            statusItem = StatusItemController(model: model)

            // 설정이 제어 서비스에서 올라온 뒤에 판단해야 해서 조금 기다린다.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if model.config?.checkUpdatesOnLaunch ?? true {
                    UpdateChecker.shared.check(silent: true)
                }
                if model.config?.startMinimized == true, Self.launchedAtLogin {
                    // 로그인 직후 자동 실행된 경우에만 창을 감춘다.
                    // 사용자가 직접 연 경우에는 창이 떠야 한다.
                    for window in NSApp.windows where window.frame.width > 400 {
                        window.close()
                    }
                }
            }
        }
    }

    /// 로그인하자마자 자동 실행된 것인지 가늠한다.
    ///
    /// macOS 는 "로그인 항목으로 실행됨" 을 앱에 직접 알려주지 않는다.
    /// 부팅·로그인 직후에는 시스템 가동 시간이 짧다는 점을 이용한 어림이고,
    /// 틀려도 창이 한 번 더 뜨거나 덜 뜨는 정도라 위험하지 않다.
    private static var launchedAtLogin: Bool {
        ProcessInfo.processInfo.systemUptime < 120
    }

    /// 창을 모두 닫아도 앱은 메뉴 막대에 남는다.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock 아이콘이나 Launchpad 로 다시 열었을 때 창을 띄운다.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainActor.assumeIsolated { AppModel.shared.presentMainWindow() }
        }
        return true
    }
}

@main
struct FanDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // App 구조체는 다시 만들어질 수 있으므로 모델은 전역에 한 번만 둔다.
    private let model = AppModel.shared

    var body: some Scene {
        Window("FanDeck", id: "main") {
            MainWindow(model: model)
                .frame(minWidth: 860, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 980, height: 720)

        // 메뉴 막대는 AppKit(StatusItemController)이 맡는다.
    }
}

struct MainWindow: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            Group {
                switch model.selectedTab {
                case .dashboard: DashboardView(model: model)
                case .sensors:   SensorsView(model: model)
                case .activity:  ActivityView(model: model)
                case .curve:     CurveEditorView(model: model)
                case .profiles:  ProfilesView(model: model)
                case .settings:  SettingsView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
    }

    private var titleBar: some View {
        HStack(spacing: 14) {
            TabBar(selection: $model.selectedTab)
            Spacer()

            if let fan = model.fans.first {
                HStack(spacing: 5) {
                    Image(systemName: "fan.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.fanColor(fan.loadFraction))
                    Text("\(Int(fan.currentRPM)) rpm")
                        .font(Theme.numeric(11))
                }
            }

            if let v = model.reading(SensorCatalog.cpuMaxKey) {
                HStack(spacing: 5) {
                    Image(systemName: "cpu")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.temperatureColor(v))
                    Text(String(format: "%.0f°C", v))
                        .font(Theme.numeric(11))
                }
            }

            if model.daemonAvailable {
                StatusBadge(text: model.snapshot?.activeProfileName ?? "—", color: .accentColor)
            } else {
                StatusBadge(text: "제어 꺼짐", color: .orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
