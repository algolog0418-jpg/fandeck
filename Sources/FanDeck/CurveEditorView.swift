//  CurveEditorView.swift — 팬 커브 에디터
//
//  원본 앱은 "A도에서 최소, B도에서 최대" 두 점만 정할 수 있다.
//  여기서는 점을 원하는 만큼 찍고 끌어서 곡선을 직접 그린다.
//  현재 온도와 실제 팬 속도를 그래프 위에 겹쳐 보여주기 때문에,
//  내가 그린 커브가 지금 어떻게 동작하는지 바로 확인할 수 있다.

import SwiftUI

private final class CurveEditorState: ObservableObject {
    @Published var draggingIndex: Int?
    @Published var selectedIndex: Int?
}

struct CurveEditorView: View {
    @Bindable var model: AppModel
    @StateObject private var ui = CurveEditorState()

    private let temperatureRange: ClosedRange<Double> = 20...105

    private var fan: FanInfo? { model.activeFan }

    /// 지금 편집 중인 설정 — 활성 프로파일의 선택된 팬.
    private var currentSetting: FanSetting? {
        guard let config = model.config, let profile = config.activeProfile, let fan else { return nil }
        return profile.setting(for: fan.index)
    }

    private var curve: FanCurve? {
        if case .curve(let c)? = currentSetting?.mode { return c }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.gridSpacing) {
                header
                if let fan {
                    graphCard(fan: fan)
                    if curve != nil {
                        pointsCard
                        smoothingCard
                    }
                } else {
                    ContentUnavailableView("팬이 없습니다", systemImage: "fan.slash")
                }
            }
            .padding(Theme.gridSpacing)
        }
    }

    // MARK: 헤더 — 모드와 센서 선택

    private var header: some View {
        VStack(spacing: 12) {
            SectionHeader(
                title: "팬 커브",
                subtitle: model.config?.activeProfile.map { "편집 중: \($0.name)" } ?? "")

            if let profile = model.config?.activeProfile, profile.isBuiltIn {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("내장 프로파일입니다. 수정하면 자동으로 복사본이 만들어집니다.")
                        .font(Theme.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }

            HStack(spacing: 10) {
                Picker("제어 방식", selection: modeSelection) {
                    Text("시스템 자동").tag(0)
                    Text("RPM 고정").tag(1)
                    Text("센서 연동 커브").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if curve != nil {
                    Picker("기준 센서", selection: sensorSelection) {
                        ForEach(temperatureSensors, id: \.key) { d in
                            Text(d.name).tag(d.key)
                        }
                    }
                    .frame(maxWidth: 220)
                    .labelsHidden()
                }
            }
        }
        .card()
    }

    private var temperatureSensors: [SensorDescriptor] {
        // 온도 센서가 174개나 되니 커브 기준으로 쓸 만한 것(집계값·코어·GPU)만 올린다.
        model.descriptors.filter {
            $0.unit == .celsius &&
            ($0.isSynthetic || $0.group == .cpuPerformance || $0.group == .cpuEfficiency
             || $0.group == .gpu || $0.group == .memory || $0.group == .storage)
        }
    }

    private var modeSelection: Binding<Int> {
        Binding(
            get: {
                switch currentSetting?.mode {
                case .automatic, .none: return 0
                case .fixed:            return 1
                case .curve:            return 2
                }
            },
            set: { newValue in
                guard let fan else { return }
                let mode: FanMode
                switch newValue {
                case 1: mode = .fixed(rpm: fan.currentRPM)
                case 2: mode = .curve(curve ?? FanCurve.defaultCurve(
                            sensorKey: SensorCatalog.cpuMaxKey,
                            minRPM: fan.minRPM, maxRPM: fan.maxRPM))
                default: mode = .automatic
                }
                updateMode(mode)
            })
    }

    private var sensorSelection: Binding<String> {
        Binding(
            get: { curve?.sensorKey ?? SensorCatalog.cpuMaxKey },
            set: { newKey in
                guard var c = curve else { return }
                c.sensorKey = newKey
                updateMode(.curve(c))
            })
    }

    // MARK: 그래프

    private func graphCard(fan: FanInfo) -> some View {
        VStack(spacing: 10) {
            SectionHeader(
                title: "커브 그래프",
                subtitle: curve == nil ? "센서 연동을 선택하면 곡선을 직접 그릴 수 있습니다"
                                       : "점을 끌어 옮기고, 빈 곳을 두 번 눌러 점을 추가하세요")

            GeometryReader { geo in
                let plot = CGRect(x: 42, y: 10,
                                  width: max(geo.size.width - 60, 10),
                                  height: max(geo.size.height - 42, 10))
                ZStack(alignment: .topLeading) {
                    grid(plot: plot, fan: fan)
                    if let curve {
                        curvePath(curve: curve, plot: plot, fan: fan)
                        currentPositionMarker(curve: curve, plot: plot, fan: fan)
                        pointHandles(curve: curve, plot: plot, fan: fan)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { location in
                    addPoint(at: location, plot: plot, fan: fan)
                }
            }
            .frame(height: 300)

            HStack(spacing: 14) {
                legendItem(color: .accentColor, text: "설정한 커브")
                legendItem(color: .orange, text: "현재 온도")
                legendItem(color: Theme.fanColor(fan.loadFraction), text: "실제 팬 속도")
                Spacer()
            }
        }
        .card()
    }

    private func legendItem(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(Theme.caption).foregroundStyle(.secondary)
        }
    }

    private func x(for temperature: Double, plot: CGRect) -> CGFloat {
        let t = (temperature - temperatureRange.lowerBound)
              / (temperatureRange.upperBound - temperatureRange.lowerBound)
        return plot.minX + plot.width * min(max(t, 0), 1)
    }

    private func y(for rpm: Double, plot: CGRect, fan: FanInfo) -> CGFloat {
        guard fan.maxRPM > fan.minRPM else { return plot.maxY }
        let r = (rpm - fan.minRPM) / (fan.maxRPM - fan.minRPM)
        return plot.maxY - plot.height * min(max(r, 0), 1)
    }

    private func temperature(forX px: CGFloat, plot: CGRect) -> Double {
        let t = (px - plot.minX) / plot.width
        return temperatureRange.lowerBound
             + Double(min(max(t, 0), 1)) * (temperatureRange.upperBound - temperatureRange.lowerBound)
    }

    private func rpm(forY py: CGFloat, plot: CGRect, fan: FanInfo) -> Double {
        let r = (plot.maxY - py) / plot.height
        return fan.minRPM + Double(min(max(r, 0), 1)) * (fan.maxRPM - fan.minRPM)
    }

    private func grid(plot: CGRect, fan: FanInfo) -> some View {
        Canvas { ctx, _ in
            let temperatureTicks = stride(from: 20.0, through: 105.0, by: 10.0)
            for t in temperatureTicks {
                let px = x(for: t, plot: plot)
                var line = Path()
                line.move(to: CGPoint(x: px, y: plot.minY))
                line.addLine(to: CGPoint(x: px, y: plot.maxY))
                ctx.stroke(line, with: .color(.secondary.opacity(0.09)), lineWidth: 1)
                ctx.draw(Text("\(Int(t))°").font(Theme.caption).foregroundStyle(.tertiary),
                         at: CGPoint(x: px, y: plot.maxY + 12))
            }
            for i in 0...4 {
                let value = fan.minRPM + (fan.maxRPM - fan.minRPM) * Double(i) / 4
                let py = y(for: value, plot: plot, fan: fan)
                var line = Path()
                line.move(to: CGPoint(x: plot.minX, y: py))
                line.addLine(to: CGPoint(x: plot.maxX, y: py))
                ctx.stroke(line, with: .color(.secondary.opacity(0.09)), lineWidth: 1)
                ctx.draw(Text("\(Int(value))").font(Theme.caption).foregroundStyle(.tertiary),
                         at: CGPoint(x: plot.minX - 20, y: py))
            }
        }
    }

    private func curvePath(curve: FanCurve, plot: CGRect, fan: FanInfo) -> some View {
        let points = curve.points.sorted()
        return ZStack {
            // 곡선 아래를 채워 "이 영역이 내 설정"임을 보이게 한다.
            Path { path in
                guard let first = points.first, let last = points.last else { return }
                path.move(to: CGPoint(x: plot.minX, y: y(for: first.rpm, plot: plot, fan: fan)))
                for p in points {
                    path.addLine(to: CGPoint(x: x(for: p.temperature, plot: plot),
                                             y: y(for: p.rpm, plot: plot, fan: fan)))
                }
                path.addLine(to: CGPoint(x: plot.maxX, y: y(for: last.rpm, plot: plot, fan: fan)))
                path.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
                path.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
                path.closeSubpath()
            }
            .fill(LinearGradient(colors: [Color.accentColor.opacity(0.22), Color.accentColor.opacity(0.02)],
                                 startPoint: .top, endPoint: .bottom))

            Path { path in
                guard let first = points.first, let last = points.last else { return }
                path.move(to: CGPoint(x: plot.minX, y: y(for: first.rpm, plot: plot, fan: fan)))
                for p in points {
                    path.addLine(to: CGPoint(x: x(for: p.temperature, plot: plot),
                                             y: y(for: p.rpm, plot: plot, fan: fan)))
                }
                path.addLine(to: CGPoint(x: plot.maxX, y: y(for: last.rpm, plot: plot, fan: fan)))
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
        }
    }

    /// 지금 온도가 커브의 어디에 해당하는지, 그래서 팬이 실제로 몇 rpm 인지 겹쳐 보여준다.
    private func currentPositionMarker(curve: FanCurve, plot: CGRect, fan: FanInfo) -> some View {
        Group {
            if let temperature = model.reading(curve.sensorKey) {
                let px = x(for: temperature, plot: plot)
                let targetY = y(for: curve.rpm(at: temperature), plot: plot, fan: fan)
                let actualY = y(for: fan.currentRPM, plot: plot, fan: fan)

                Path { p in
                    p.move(to: CGPoint(x: px, y: plot.minY))
                    p.addLine(to: CGPoint(x: px, y: plot.maxY))
                }
                .stroke(Color.orange.opacity(0.65), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))

                Circle()
                    .fill(Color.orange)
                    .frame(width: 9, height: 9)
                    .position(x: px, y: targetY)

                Circle()
                    .strokeBorder(Theme.fanColor(fan.loadFraction), lineWidth: 2.5)
                    .background(Circle().fill(Color.black.opacity(0.25)))
                    .frame(width: 13, height: 13)
                    .position(x: px, y: actualY)

                Text("\(Int(temperature))°C")
                    .font(Theme.numeric(10))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.9)))
                    .foregroundStyle(.white)
                    .position(x: px, y: plot.minY + 8)
            }
        }
    }

    private func pointHandles(curve: FanCurve, plot: CGRect, fan: FanInfo) -> some View {
        let points = curve.points.sorted()
        return ForEach(Array(points.enumerated()), id: \.offset) { index, point in
            let px = x(for: point.temperature, plot: plot)
            let py = y(for: point.rpm, plot: plot, fan: fan)
            Circle()
                .fill(Color.accentColor)
                .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2))
                .frame(width: ui.selectedIndex == index ? 17 : 13,
                       height: ui.selectedIndex == index ? 17 : 13)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .position(x: px, y: py)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            ui.draggingIndex = index
                            ui.selectedIndex = index
                            movePoint(index: index,
                                      to: drag.location,
                                      plot: plot, fan: fan)
                        }
                        .onEnded { _ in ui.draggingIndex = nil }
                )
                .help("\(Int(point.temperature))°C → \(Int(point.rpm))rpm")
        }
    }

    // MARK: 점 편집

    private func movePoint(index: Int, to location: CGPoint, plot: CGRect, fan: FanInfo) {
        guard var c = curve else { return }
        var points = c.points.sorted()
        guard points.indices.contains(index) else { return }

        var newTemperature = temperature(forX: location.x, plot: plot)
        let newRPM = rpm(forY: location.y, plot: plot, fan: fan)

        // 점끼리 순서가 뒤집히면 곡선이 꼬인다. 이웃 사이로만 움직이게 막는다.
        let lower = index > 0 ? points[index - 1].temperature + 1 : temperatureRange.lowerBound
        let upper = index < points.count - 1 ? points[index + 1].temperature - 1 : temperatureRange.upperBound
        newTemperature = min(max(newTemperature, lower), upper)

        points[index] = CurvePoint(temperature: newTemperature.rounded(),
                                   rpm: (newRPM / 10).rounded() * 10)
        c.points = points
        updateMode(.curve(c))
    }

    private func addPoint(at location: CGPoint, plot: CGRect, fan: FanInfo) {
        guard var c = curve else { return }
        let t = temperature(forX: location.x, plot: plot).rounded()
        let r = (rpm(forY: location.y, plot: plot, fan: fan) / 10).rounded() * 10
        // 이미 비슷한 위치에 점이 있으면 추가하지 않는다.
        guard !c.points.contains(where: { abs($0.temperature - t) < 2 }) else { return }
        c.points.append(CurvePoint(temperature: t, rpm: r))
        c.points.sort()
        updateMode(.curve(c))
    }

    private func deletePoint(index: Int) {
        guard var c = curve else { return }
        // 점 2개는 남겨야 곡선이 성립한다.
        guard c.points.count > 2 else { return }
        var points = c.points.sorted()
        points.remove(at: index)
        c.points = points
        ui.selectedIndex = nil
        updateMode(.curve(c))
    }

    // MARK: 점 목록 / 세부 조정

    private var pointsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "커브 점", subtitle: "숫자로 정확히 맞출 수도 있습니다")

            if let curve, let fan {
                ForEach(Array(curve.points.sorted().enumerated()), id: \.offset) { index, point in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(Theme.numeric(10))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.accentColor.opacity(0.18)))

                        Stepper(value: temperatureBinding(index: index), in: 20...105, step: 1) {
                            Text("\(Int(point.temperature))°C")
                                .font(Theme.numeric(12))
                                .frame(width: 54, alignment: .leading)
                        }

                        Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.tertiary)

                        Stepper(value: rpmBinding(index: index, fan: fan),
                                in: fan.minRPM...fan.maxRPM, step: 50) {
                            Text("\(Int(point.rpm)) rpm")
                                .font(Theme.numeric(12))
                                .frame(width: 74, alignment: .leading)
                        }

                        Spacer()

                        Button {
                            deletePoint(index: index)
                        } label: {
                            Image(systemName: "trash").font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(curve.points.count <= 2)
                    }
                    .padding(.vertical, 2)
                }

                HStack {
                    Button {
                        guard var c = self.curve else { return }
                        let sorted = c.points.sorted()
                        // 가장 간격이 넓은 두 점 사이에 새 점을 끼워 넣는다.
                        var bestGap = 0.0, bestIndex = 0
                        for i in 0..<(sorted.count - 1) {
                            let gap = sorted[i + 1].temperature - sorted[i].temperature
                            if gap > bestGap { bestGap = gap; bestIndex = i }
                        }
                        let a = sorted[bestIndex], b = sorted[bestIndex + 1]
                        c.points.append(CurvePoint(temperature: ((a.temperature + b.temperature) / 2).rounded(),
                                                   rpm: ((a.rpm + b.rpm) / 2 / 10).rounded() * 10))
                        c.points.sort()
                        updateMode(.curve(c))
                    } label: {
                        Label("점 추가", systemImage: "plus")
                    }

                    Button {
                        guard let fan = self.fan, var c = self.curve else { return }
                        c.points = FanCurve.defaultCurve(sensorKey: c.sensorKey,
                                                         minRPM: fan.minRPM,
                                                         maxRPM: fan.maxRPM).points
                        updateMode(.curve(c))
                    } label: {
                        Label("기본값으로", systemImage: "arrow.counterclockwise")
                    }
                    Spacer()
                }
                .font(.system(size: 11))
            }
        }
        .card()
    }

    private func temperatureBinding(index: Int) -> Binding<Double> {
        Binding(
            get: { curve?.points.sorted()[safe: index]?.temperature ?? 0 },
            set: { newValue in
                guard var c = curve else { return }
                var points = c.points.sorted()
                guard points.indices.contains(index) else { return }
                let lower = index > 0 ? points[index - 1].temperature + 1 : 20
                let upper = index < points.count - 1 ? points[index + 1].temperature - 1 : 105
                points[index].temperature = min(max(newValue, lower), upper)
                c.points = points
                updateMode(.curve(c))
            })
    }

    private func rpmBinding(index: Int, fan: FanInfo) -> Binding<Double> {
        Binding(
            get: { curve?.points.sorted()[safe: index]?.rpm ?? fan.minRPM },
            set: { newValue in
                guard var c = curve else { return }
                var points = c.points.sorted()
                guard points.indices.contains(index) else { return }
                points[index].rpm = min(max(newValue, fan.minRPM), fan.maxRPM)
                c.points = points
                updateMode(.curve(c))
            })
    }

    // MARK: 완충 설정

    private var smoothingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "소음 완충",
                          subtitle: "팬 속도가 들쭉날쭉 변해서 거슬리는 걸 막아줍니다")

            if model.config?.activeProfile != nil {
                slider("온도 평활", value: smoothingBinding(\.temperatureSmoothing),
                       range: 0.05...1.0, format: { String(format: "%.2f", $0) },
                       help: "낮을수록 순간적인 온도 변화를 무시합니다")
                slider("히스테리시스", value: smoothingBinding(\.hysteresis),
                       range: 0...12, format: { "\(Int($0))°C" },
                       help: "온도가 이만큼 떨어져야 속도를 낮춥니다")
                slider("상승 속도 제한", value: smoothingBinding(\.rampUpPerSecond),
                       range: 50...2000, format: { "\(Int($0)) rpm/초" },
                       help: "팬이 갑자기 빨라지지 않게 합니다")
                slider("하강 속도 제한", value: smoothingBinding(\.rampDownPerSecond),
                       range: 20...2000, format: { "\(Int($0)) rpm/초" },
                       help: "팬이 갑자기 느려지지 않게 합니다")
            }
        }
        .card()
    }

    private func slider(_ title: String, value: Binding<Double>,
                        range: ClosedRange<Double>,
                        format: @escaping (Double) -> String,
                        help: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(format(value.wrappedValue)).font(Theme.numeric(11)).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
            Text(help).font(Theme.caption).foregroundStyle(.tertiary)
        }
    }

    private func smoothingBinding(_ keyPath: WritableKeyPath<SmoothingSettings, Double>) -> Binding<Double> {
        Binding(
            get: { model.config?.activeProfile?.smoothing[keyPath: keyPath] ?? 0 },
            set: { newValue in
                guard var config = model.config,
                      let index = config.profiles.firstIndex(where: { $0.id == config.activeProfileID })
                else { return }
                var profile = materializeIfBuiltIn(config.profiles[index], config: &config)
                profile.smoothing[keyPath: keyPath] = newValue
                if let i = config.profiles.firstIndex(where: { $0.id == profile.id }) {
                    config.profiles[i] = profile
                }
                config.activeProfileID = profile.id
                model.apply(config: config)
            })
    }

    // MARK: 저장

    /// 내장 프로파일을 고치려 하면 사본을 만들어 그쪽을 편집하게 한다.
    /// 원본을 덮어쓰면 "기본값으로 돌리기"가 불가능해진다.
    private func materializeIfBuiltIn(_ profile: Profile, config: inout FanDeckConfig) -> Profile {
        guard profile.isBuiltIn else { return profile }
        var copy = profile
        copy.id = UUID()
        copy.name = profile.name + " (사용자)"
        copy.isBuiltIn = false
        config.profiles.append(copy)
        return copy
    }

    private func updateMode(_ mode: FanMode) {
        guard var config = model.config, let fan,
              let index = config.profiles.firstIndex(where: { $0.id == config.activeProfileID })
        else { return }

        var profile = materializeIfBuiltIn(config.profiles[index], config: &config)
        if let settingIndex = profile.fanSettings.firstIndex(where: { $0.fanIndex == fan.index }) {
            profile.fanSettings[settingIndex].mode = mode
        } else {
            profile.fanSettings.append(FanSetting(fanIndex: fan.index, mode: mode))
        }

        if let i = config.profiles.firstIndex(where: { $0.id == profile.id }) {
            config.profiles[i] = profile
        }
        config.activeProfileID = profile.id
        model.apply(config: config)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
