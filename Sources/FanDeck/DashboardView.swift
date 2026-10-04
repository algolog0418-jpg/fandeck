//  DashboardView.swift — 메인 대시보드
//
//  한 화면에서 "지금 상태 / 왜 그런지 / 바로 바꾸기"가 모두 되게 배치했다.
//  왼쪽은 팬, 오른쪽은 온도, 아래는 추이다.

import SwiftUI
import Charts

private final class DashboardState: ObservableObject {
    @Published var manualRPM: Double = 0
    /// 슬라이더를 잡고 있는 동안에는 실측값으로 덮어쓰지 않기 위한 플래그.
    @Published var isDraggingSlider = false
}

struct DashboardView: View {
    @Bindable var model: AppModel
    @StateObject private var ui = DashboardState()

    private var fan: FanInfo? { model.activeFan }
    private var runtime: FanRuntimeState? {
        guard let fan else { return nil }
        return model.snapshot?.runtime.first { $0.fanIndex == fan.index }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.gridSpacing) {
                topRow
                quickControl
                chartCard
                statisticsCard
            }
            .padding(Theme.gridSpacing)
        }
    }

    // MARK: 상단 — 팬 게이지 + 핵심 수치

    private var topRow: some View {
        HStack(alignment: .top, spacing: Theme.gridSpacing) {
            fanCard
                .frame(width: 262)
            statGrid
        }
    }

    private var fanCard: some View {
        VStack(spacing: 14) {
            if let fan {
                // 팬이 여러 개인 맥(맥북 프로 등)에서는 어느 팬을 볼지 고를 수 있어야 한다.
                if model.fans.count > 1 {
                    Picker("", selection: $model.selectedFanIndex) {
                        ForEach(model.fans) { f in
                            Text(f.name).tag(f.index)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                HStack {
                    Text(fan.name).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if model.snapshot?.isCritical == true {
                        StatusBadge(text: L.t("과열 보호", "Thermal protection"), color: .red,
                                    symbol: "exclamationmark.triangle.fill", pulsing: true)
                    } else {
                        StatusBadge(text: model.modeLabel(for: fan.index),
                                    color: Theme.fanColor(fan.loadFraction))
                    }
                }

                FanGauge(fan: fan, appliedRPM: runtime?.appliedRPM, size: 196)

                let db = NoiseEstimator.estimatedDB(rpm: fan.currentRPM,
                                                    minRPM: fan.minRPM, maxRPM: fan.maxRPM)
                HStack(spacing: 0) {
                    metric(L.t("최소", "Min"), "\(Int(fan.minRPM))")
                    Divider().frame(height: 26)
                    metric(L.t("체감 소음", "Noise"), "\(Int(db))dB", caption: NoiseEstimator.label(forDB: db))
                    Divider().frame(height: 26)
                    metric(L.t("최대", "Max"), "\(Int(fan.maxRPM))")
                }
            } else {
                ContentUnavailableView(L.t("팬을 찾을 수 없습니다", "No fan found"), systemImage: "fan.slash",
                                       description: Text(L.t("이 맥에는 제어할 수 있는 팬이 없을 수 있습니다.", "This Mac may have no controllable fan.")))
                    .frame(height: 220)
            }
        }
        .card()
    }

    private func metric(_ label: String, _ value: String, caption: String? = nil) -> some View {
        VStack(spacing: 2) {
            Text(label).font(Theme.caption).foregroundStyle(.secondary)
            Text(value).font(Theme.numeric(14))
            if let caption {
                Text(caption).font(Theme.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var statGrid: some View {
        let keys = highlightKeys
        // 열 개수를 고정한다. .adaptive 는 레이아웃마다 열 수를 다시 계산하는데,
        // 값이 매초 바뀌는 화면에서는 그 비용이 그대로 반복된다.
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.gridSpacing),
                                        count: 4),
                         spacing: Theme.gridSpacing) {
            ForEach(keys, id: \.self) { key in
                if let d = model.descriptor(key) {
                    let value = model.reading(key)
                    StatTile(title: d.displayName,
                             value: value.map { model.display($0, unit: d.unit) } ?? "—",
                             color: value.map { Theme.accent(for: d.unit, value: $0) } ?? .secondary,
                             symbol: d.group.symbolName,
                             series: model.history(forKey: key))
                        .frame(height: 104)
                }
            }
        }
    }

    /// 상단에 띄울 센서 — 모델이 틱마다 미리 골라 둔다.
    private var highlightKeys: [String] { model.highlightKeys }

    // MARK: 빠른 제어

    private var quickControl: some View {
        VStack(spacing: 12) {
            SectionHeader(title: L.t("빠른 제어", "Quick control"),
                          subtitle: model.daemonAvailable
                            ? L.t("사용 중인 모드: ", "Active mode: ") + model.activeProfileDisplayName
                            : model.daemonStarting
                                ? L.t("서비스를 시작하는 중입니다", "Starting the service…")
                                : L.t("팬 제어가 아직 켜져 있지 않습니다", "Fan control is not enabled yet"))

            if model.daemonStarting {
                daemonStartingNotice
            } else if !model.daemonAvailable || model.helperOutdated {
                daemonMissingNotice
            } else if model.snapshot?.smcWritable == false {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(L.t("팬 속도 변경이 반영되지 않고 있습니다. 다른 팬 제어 앱(Macs Fan Control 등)이 켜져 있으면 종료해 주세요.", "Fan speed changes are not taking effect. Quit other fan control apps (such as Macs Fan Control)."))
                        .font(.system(size: 11))
                    Spacer()
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }

            if let config {
                HStack(spacing: 6) {
                    ForEach(config.profiles) { profile in
                        profileChip(profile, isActive: profile.id == config.activeProfileID)
                    }
                    Spacer()
                }
            }

            if let fan {
                HStack(spacing: 12) {
                    Image(systemName: "wind").foregroundStyle(.secondary)
                    Slider(value: $ui.manualRPM, in: fan.minRPM...fan.maxRPM, step: 50) { editing in
                        ui.isDraggingSlider = editing
                        if !editing {
                            model.setFanMode(.fixed(rpm: ui.manualRPM), fanIndex: fan.index)
                        }
                    }
                    .disabled(!model.daemonAvailable)
                    Text("\(Int(ui.manualRPM)) rpm")
                        .font(Theme.numeric(12))
                        .frame(width: 70, alignment: .trailing)

                    Button(L.t("자동", "Auto")) { model.setFanMode(.automatic, fanIndex: fan.index) }
                        .disabled(!model.daemonAvailable)
                    Button(L.t("최대", "Max")) {
                        ui.manualRPM = fan.maxRPM
                        model.setFanMode(.fixed(rpm: fan.maxRPM), fanIndex: fan.index)
                    }
                    .disabled(!model.daemonAvailable)
                }
                .onAppear { if ui.manualRPM == 0 { ui.manualRPM = fan.currentRPM } }
                // 슬라이더를 잡고 있는 동안에는 실측값으로 덮어쓰지 않는다.
                .onChange(of: fan.currentRPM) { _, new in
                    if !ui.isDraggingSlider { ui.manualRPM = new }
                }
            }
        }
        .card()
    }

    private var config: FanDeckConfig? { model.config }

    // MARK: 통계 — 최근 구간의 최저·평균·최고

    private var statisticsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: L.t("최근 \(Int(model.chartMinutes))분 통계", "Last \(Int(model.chartMinutes)) min"),
                          subtitle: L.t("그래프와 같은 구간을 숫자로 요약합니다", "Same range as the chart, as numbers"))

            VStack(spacing: 0) {
                HStack {
                    Text(L.t("센서", "Sensor")).font(Theme.label).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach([L.t("최저","Min"), L.t("평균","Avg"), L.t("최고","Max"), L.t("현재","Now")], id: \.self) { header in
                        Text(header).font(Theme.label).foregroundStyle(.secondary)
                            .frame(width: 62, alignment: .trailing)
                    }
                }
                .padding(.vertical, 5)

                Divider()

                ForEach(highlightKeys, id: \.self) { key in
                    if let d = model.descriptor(key),
                       let stats = model.statistics(forKey: key) {
                        HStack {
                            HStack(spacing: 6) {
                                Image(systemName: d.group.symbolName)
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                                Text(d.displayName).font(.system(size: 11))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            statValue(stats.minimum, unit: d.unit, muted: true)
                            statValue(stats.average, unit: d.unit, muted: true)
                            statValue(stats.maximum, unit: d.unit, muted: false)
                            statValue(stats.current, unit: d.unit, muted: false)
                        }
                        .padding(.vertical, 5)
                        Divider().opacity(0.4)
                    }
                }
            }

            if model.liveHistory.count < 5 {
                Text(L.t("표본을 모으는 중입니다. 잠시 뒤에 값이 채워집니다.", "Collecting samples — values will fill in shortly."))
                    .font(Theme.caption).foregroundStyle(.tertiary)
            }
        }
        .card()
    }

    private func statValue(_ value: Double, unit: SensorUnit, muted: Bool) -> some View {
        Text(model.display(value, unit: unit, includeSuffix: false))
            .font(Theme.numeric(12, weight: muted ? .regular : .semibold))
            .foregroundStyle(muted ? AnyShapeStyle(.secondary)
                                   : AnyShapeStyle(Theme.accent(for: unit, value: value)))
            .frame(width: 62, alignment: .trailing)
    }

    private var daemonMissingNotice: some View {
        EnableControlBanner(model: model)
    }

    /// 서비스가 깔려 있는데 아직 대답이 없을 때. 재부팅 직후 몇 초가 여기다.
    /// 이때 "켜지지 않았다" 고 말하면 재부팅마다 권한을 다시 내놓으라는 앱이 된다.
    private var daemonStartingNotice: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(L.t("팬 제어 서비스를 시작하고 있습니다. 잠시만 기다려 주세요.",
                     "Starting the fan control service…"))
                .font(.system(size: 11))
            Spacer()
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        }
    }

    private func profileChip(_ profile: Profile, isActive: Bool) -> some View {
        Button {
            model.activate(profile: profile)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: profile.symbol).font(.system(size: 10))
                Text(profile.displayName).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background {
                Capsule().fill(isActive ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.06))
            }
            .foregroundStyle(isActive ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .disabled(!model.daemonAvailable)
    }

    // MARK: 추이 차트

    private var chartCard: some View {
        VStack(spacing: 10) {
            SectionHeader(
                title: L.t("추이", "Trend"),
                subtitle: L.t("온도와 팬 속도를 함께 봅니다", "Temperature and fan speed together"),
                trailing: AnyView(
                    Picker("", selection: $model.chartMinutes) {
                        Text(L.t("1분", "1m")).tag(1.0)
                        Text(L.t("5분", "5m")).tag(5.0)
                        Text(L.t("15분", "15m")).tag(15.0)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                    .labelsHidden()
                ))

            TrendChart(model: model,
                       keys: Array(highlightKeys.prefix(3)),
                       fan: fan)
                .frame(height: 230)

            HStack(spacing: 14) {
                ForEach(Array(highlightKeys.prefix(3).enumerated()), id: \.offset) { index, key in
                    if let d = model.descriptor(key), d.unit == .celsius {
                        legendDot(color: TrendChart.seriesColors[index % TrendChart.seriesColors.count],
                                  text: d.displayName)
                    }
                }
                if model.fans.first != nil {
                    legendDot(color: .accentColor, text: L.t("팬 속도", "Fan speed"))
                }
                Spacer()
            }
        }
        .card()
    }

    private func legendDot(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(Theme.caption).foregroundStyle(.secondary)
        }
    }
}
