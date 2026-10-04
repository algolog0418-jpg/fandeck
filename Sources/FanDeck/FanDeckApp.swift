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

    /// 본 창에 최소 크기를 한 번만 지정한다.
    static func applyWindowMinimumSize() {
        DispatchQueue.main.async {
            for window in NSApp.windows where window.frame.width > 400 {
                window.minSize = NSSize(width: 860, height: 620)
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

    /// 끄기 전에 미뤄 둔 설정 변경을 저장한다.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.flushPendingConfig() }
    }

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
        // 최소 크기를 SwiftUI 의 .frame(minWidth:minHeight:) 로 주면,
        // AppKit 이 레이아웃할 때마다 "이 내용의 최소 크기가 얼마냐"고 묻고
        // SwiftUI 는 그때마다 화면 전체를 다시 재어 본다. 창을 열어 두는 동안
        // 매 프레임 그 비용을 냈다. 최소 크기는 창에 한 번만 박아 두면 된다.
        Window("FanDeck", id: "main") {
            MainWindow(model: model)
                .onAppear { AppDelegate.applyWindowMinimumSize() }
        }
        .defaultSize(width: 980, height: 720)

        // 메뉴 막대는 AppKit(StatusItemController)이 맡는다.
    }
}

struct MainWindow: View {
    @Bindable var model: AppModel

    var body: some View {
        // 창을 닫아도 SwiftUI 는 이 화면을 버리지 않는다. 그래서 창이 없는데도
        // 그래프와 팬 날개가 계속 그려지면서 CPU 를 10% 넘게 쓰고 있었다.
        // 보이지 않을 때는 빈 화면으로 바꿔 뷰 자체를 없앤다.
        Group {
            if model.isWindowVisible {
                content
            } else {
                Color.clear
            }
        }
        // 언어는 전역 값이라 바뀌어도 SwiftUI 가 다시 그리지 않는다.
        // 여기에 묶어 두면 언어가 달라질 때 화면이 통째로 새로 만들어진다.
        .id(model.language)
        .background(.background)
    }

    private var content: some View {
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
                    // 설정한 온도 단위를 따라야 한다. 예전에는 섭씨로 고정돼 있어서
                    // 화씨로 바꿔도 이 자리만 섭씨로 남았다.
                    Text(model.format.compactString(v, unit: .celsius))
                        .font(Theme.numeric(11))
                }
            }

            if model.daemonAvailable {
                StatusBadge(text: model.activeProfileDisplayName, color: .accentColor)
            } else {
                StatusBadge(text: L.t("제어 꺼짐", "Control off"), color: .orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
