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
        // 팝오버 기본 배경은 반투명이라 뒤쪽 화면이 비친다. 그 위에서는 수치 색이
        // 묻혀서 읽기 어려웠다. 불투명하게 깔아 글자와 배경의 대비를 확보한다.
        .background(Color(nsColor: .windowBackgroundColor))
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
        // 뱃지는 글자보다 키가 커서, 나타났다 사라질 때마다 아래 내용이 통째로
        // 몇 픽셀씩 밀렸다. 제어 서비스 응답이 한 번 늦기만 해도 "제어 꺼짐" 이
        // 잠깐 떴다 사라지므로, 속도 막대가 내려갔다 올라오는 것처럼 보였다.
        // 줄 높이를 뱃지에 맞춰 고정해 두면 무엇이 떠도 아래가 움직이지 않는다.
        .frame(height: 22)
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
                    .lineLimit(1)
            }
            // 소음 문구 길이가 바뀌어도 이 줄의 높이는 그대로여야 한다.
            .frame(height: 32)

            // 속도 막대 — 최소~최대 사이에서 지금 어디쯤인지.
            //
            // 예전에는 막대만 덩그러니 있어서, 팬이 최저 속도로 돌 때(이 맥은 1,000rpm)
            // 왼쪽 끝에 점 하나만 찍힌 꼴이 됐다. 눈금이 없으니 그게 "범위의 맨 아래"인지
            // 그리기 오류인지 알 수 없었다. 양 끝에 최소·최대 rpm 을 적어 눈금을 준다.
            VStack(alignment: .leading, spacing: 3) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.09))
                        Capsule()
                            .fill(Theme.fanColor(fan.loadFraction))
                            // 최소 너비를 막대 높이에 맞춰야 눌린 네모가 아니라 동그라미로 끝난다.
                            .frame(width: max(geo.size.width * fan.loadFraction, geo.size.height))
                    }
                }
                .frame(height: 6)

                HStack(spacing: 0) {
                    Text("\(Int(fan.minRPM))")
                    Spacer()
                    Text("\(Int(fan.maxRPM))")
                }
                .font(Theme.numeric(9, weight: .regular))
                .foregroundStyle(.tertiary)
            }

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
