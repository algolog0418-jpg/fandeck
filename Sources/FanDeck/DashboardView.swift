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
                HStack {
                    Text(fan.name).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if model.snapshot?.isCritical == true {
                        StatusBadge(text: "과열 보호", color: .red,
                                    symbol: "exclamationmark.triangle.fill", pulsing: true)
                    } else {
                        StatusBadge(text: runtime?.modeLabel ?? "자동",
                                    color: Theme.fanColor(fan.loadFraction))
                    }
                }

                FanGauge(fan: fan, appliedRPM: runtime?.appliedRPM, size: 196)

                let db = NoiseEstimator.estimatedDB(rpm: fan.currentRPM,
                                                    minRPM: fan.minRPM, maxRPM: fan.maxRPM)
                HStack(spacing: 0) {
                    metric("최소", "\(Int(fan.minRPM))")
                    Divider().frame(height: 26)
                    metric("체감 소음", "\(Int(db))dB", caption: NoiseEstimator.label(forDB: db))
                    Divider().frame(height: 26)
                    metric("최대", "\(Int(fan.maxRPM))")
                }
            } else {
                ContentUnavailableView("팬을 찾을 수 없습니다", systemImage: "fan.slash",
                                       description: Text("이 맥에는 제어할 수 있는 팬이 없을 수 있습니다."))
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
                    StatTile(title: d.name,
                             value: value.map { String(format: "%.\(d.unit.fractionDigits)f%@", $0, d.unit.suffix) } ?? "—",
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
            SectionHeader(title: "빠른 제어",
                          subtitle: model.daemonAvailable
                            ? "사용 중인 모드: \(model.snapshot?.activeProfileName ?? "—")"
                            : "팬 제어가 아직 켜져 있지 않습니다")

            if !model.daemonAvailable {
                daemonMissingNotice
            } else if model.snapshot?.smcWritable == false {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("팬 속도 변경이 반영되지 않고 있습니다. 다른 팬 제어 앱(Macs Fan Control 등)이 켜져 있으면 종료해 주세요.")
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

                    Button("자동") { model.setFanMode(.automatic, fanIndex: fan.index) }
                        .disabled(!model.daemonAvailable)
                    Button("최대") {
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
            SectionHeader(title: "최근 \(Int(model.chartMinutes))분 통계",
                          subtitle: "그래프와 같은 구간을 숫자로 요약합니다")

            VStack(spacing: 0) {
                HStack {
                    Text("센서").font(Theme.label).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(["최저", "평균", "최고", "현재"], id: \.self) { header in
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
                                Text(d.name).font(.system(size: 11))
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
                Text("표본을 모으는 중입니다. 잠시 뒤에 값이 채워집니다.")
                    .font(Theme.caption).foregroundStyle(.tertiary)
            }
        }
        .card()
    }

    private func statValue(_ value: Double, unit: SensorUnit, muted: Bool) -> some View {
        Text(String(format: "%.\(unit.fractionDigits)f", value))
            .font(Theme.numeric(12, weight: muted ? .regular : .semibold))
            .foregroundStyle(muted ? AnyShapeStyle(.secondary)
                                   : AnyShapeStyle(Theme.accent(for: unit, value: value)))
            .frame(width: 62, alignment: .trailing)
    }

    private var daemonMissingNotice: some View {
        EnableControlBanner(model: model)
    }

    private func profileChip(_ profile: Profile, isActive: Bool) -> some View {
        Button {
            model.activate(profile: profile)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: profile.symbol).font(.system(size: 10))
                Text(profile.name).font(.system(size: 11, weight: .medium))
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
                title: "추이",
                subtitle: "온도와 팬 속도를 함께 봅니다",
                trailing: AnyView(
                    Picker("", selection: $model.chartMinutes) {
                        Text("1분").tag(1.0)
                        Text("5분").tag(5.0)
                        Text("15분").tag(15.0)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                    .labelsHidden()
                ))

            Chart {
                ForEach(highlightKeys.prefix(3), id: \.self) { key in
                    if let d = model.descriptor(key), d.unit == .celsius {
                        ForEach(Array(model.history(forKey: key).enumerated()),
                                id: \.offset) { _, point in
                            LineMark(x: .value("시각", point.0),
                                     y: .value("온도", point.1),
                                     series: .value("센서", d.name))
                                .foregroundStyle(by: .value("센서", d.name))
                                .lineStyle(StrokeStyle(lineWidth: 1.8))
                                .interpolationMethod(.monotone)
                        }
                    }
                }
                // 팬 속도는 축이 달라서 온도 범위로 환산해 겹쳐 그린다.
                if let fan {
                    ForEach(Array(model.fanHistory(index: fan.index).enumerated()),
                            id: \.offset) { _, point in
                        let normalized = fan.maxRPM > fan.minRPM
                            ? (point.1 - fan.minRPM) / (fan.maxRPM - fan.minRPM) : 0
                        AreaMark(x: .value("시각", point.0),
                                 y: .value("온도", 20 + normalized * 80),
                                 series: .value("센서", "팬 속도"))
                            .foregroundStyle(
                                LinearGradient(colors: [Color.accentColor.opacity(0.22),
                                                        Color.accentColor.opacity(0.02)],
                                               startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                    }
                }
            }
            .chartYScale(domain: 20...100)
            .chartYAxis {
                AxisMarks(position: .leading, values: [20, 40, 60, 80, 100]) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text("\(Int(v))°").font(Theme.caption)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.08))
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .chartLegend(position: .bottom, spacing: 8)
            .chartPlotStyle { $0.clipped() }
            .frame(height: 230)
            .clipped()
        }
        .card()
    }
}
