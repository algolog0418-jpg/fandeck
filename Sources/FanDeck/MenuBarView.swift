//  MenuBarView.swift — 메뉴 막대 팝오버
//
//  메뉴바에서 가장 자주 하는 일은 "지금 몇 도인지 보기"와 "프로파일 바꾸기"다.
//  그 둘을 맨 위에 두고, 창을 열지 않아도 속도를 바로 바꿀 수 있게 슬라이더를 넣었다.

import SwiftUI

private final class MenuBarState: ObservableObject {
    @Published var manualRPM: Double = 0
}

struct MenuBarView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @StateObject private var ui = MenuBarState()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let fan = model.activeFan {
                fanSection(fan)
                Divider()
            }

            temperatureSection
            Divider()
            profileSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 290)
        .id(model.language)
        .onAppear { model.isMenuOpen = true }
        .onDisappear { model.isMenuOpen = false }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "fan.fill")
                .foregroundStyle(Color.accentColor)
            Text("FanDeck").font(.system(size: 13, weight: .semibold))
            Spacer()
            if model.snapshot?.isCritical == true {
                StatusBadge(text: L.t("과열 보호", "Thermal protection"), color: .red, symbol: "exclamationmark.triangle.fill", pulsing: true)
            } else if !model.daemonAvailable {
                StatusBadge(text: L.t("제어 꺼짐", "Control off"), color: .orange)
            }
        }
    }

    private func fanSection(_ fan: FanInfo) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Int(fan.currentRPM))")
                    .font(Theme.numeric(26, weight: .bold))
                Text("rpm").font(Theme.numeric(11)).foregroundStyle(.secondary)
                Spacer()
                let db = NoiseEstimator.estimatedDB(rpm: fan.currentRPM,
                                                    minRPM: fan.minRPM, maxRPM: fan.maxRPM)
                Text("\(Int(db))dB · \(NoiseEstimator.label(forDB: db))")
                    .font(Theme.caption).foregroundStyle(.secondary)
            }

            // 속도 막대
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    Capsule()
                        .fill(Theme.fanColor(fan.loadFraction))
                        .frame(width: max(geo.size.width * fan.loadFraction, 4))
                        .animation(.easeOut(duration: 0.6), value: fan.loadFraction)
                }
            }
            .frame(height: 5)

            HStack(spacing: 8) {
                Slider(value: $ui.manualRPM, in: fan.minRPM...fan.maxRPM, step: 50) { editing in
                    if !editing { model.setFanMode(.fixed(rpm: ui.manualRPM), fanIndex: fan.index) }
                }
                .disabled(!model.daemonAvailable)
                Text("\(Int(ui.manualRPM))").font(Theme.numeric(10)).frame(width: 34, alignment: .trailing)
            }
            .onAppear { if ui.manualRPM == 0 { ui.manualRPM = fan.currentRPM } }
        }
    }

    private var temperatureSection: some View {
        VStack(spacing: 5) {
            ForEach(menuKeys, id: \.self) { key in
                if let d = model.descriptor(key), let v = model.reading(key) {
                    HStack {
                        Image(systemName: d.group.symbolName)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Text(d.displayName).font(.system(size: 11))
                        Spacer()
                        Text(model.display(v, unit: d.unit))
                            .font(Theme.numeric(12))
                            .foregroundStyle(Theme.accent(for: d.unit, value: v))
                            
                    }
                }
            }
        }
    }

    private var menuKeys: [String] {
        var keys = model.config?.favoriteSensorKeys ?? []
        for fallback in [SensorCatalog.cpuMaxKey, SensorCatalog.gpuMaxKey, "PSTR"]
        where !keys.contains(fallback) { keys.append(fallback) }
        return Array(keys.prefix(4))
    }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L.t("모드", "Mode")).font(Theme.label).foregroundStyle(.secondary)
            ForEach(model.config?.profiles ?? []) { profile in
                Button {
                    model.activate(profile: profile)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: profile.id == model.config?.activeProfileID
                              ? "checkmark.circle.fill" : profile.symbol)
                            .font(.system(size: 10))
                            .foregroundStyle(profile.id == model.config?.activeProfileID
                                             ? Color.accentColor : .secondary)
                            .frame(width: 14)
                        Text(profile.displayName).font(.system(size: 11))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.daemonAvailable)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                model.presentMainWindow()
                openWindow(id: "main")
            } label: {
                Label(L.t("창 열기", "Open window"), systemImage: "macwindow")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Text(L.t("종료", "Quit")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}
