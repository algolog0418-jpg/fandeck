//  Components.swift — 재사용 UI 조각
//
//  팬 게이지는 실제 회전수에 비례해서 돌아간다. 숫자만 보는 것보다
//  "지금 얼마나 빨리 도는지"가 몸으로 읽힌다.

import SwiftUI
import Charts

// MARK: - 팬 게이지

/// 아래쪽 90도가 열린 270도 호. fraction 0~1 만큼 그린다.
/// SwiftUI 의 Path 는 3시 방향이 0도이고 y축이 아래로 향하므로,
/// 135도에서 시작해 405도까지 그리면 아래가 열린 계기판이 된다.
struct GaugeArc: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.width, rect.height) / 2
        let clamped = min(max(fraction, 0), 1)
        guard clamped > 0 else { return path }
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY),
                    radius: radius,
                    startAngle: .degrees(135),
                    endAngle: .degrees(135 + 270 * clamped),
                    clockwise: false)
        return path
    }
}

struct FanGauge: View {
    let fan: FanInfo
    let appliedRPM: Double?
    var size: CGFloat = 200

    private var fraction: Double { fan.loadFraction }
    private var color: Color { Theme.fanColor(fraction) }

    var body: some View {
        ZStack {
            // 배경 트랙
            GaugeArc(fraction: 1)
                .stroke(Color.primary.opacity(0.09),
                        style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round))
                .padding(size * 0.0375)

            // 현재 속도
            GaugeArc(fraction: fraction)
                .stroke(
                    AngularGradient(colors: [color.opacity(0.5), color],
                                    center: .center,
                                    startAngle: .degrees(135),
                                    endAngle: .degrees(135 + 270 * max(fraction, 0.02))),
                    style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round))
                .padding(size * 0.0375)
                .shadow(color: color.opacity(0.4), radius: size * 0.045)
                .animation(.easeOut(duration: 0.8), value: fraction)

            // 데몬이 지정한 목표 지점 표식 — 실제 속도가 목표를 따라가는 중인지 보인다.
            if let appliedRPM, fan.maxRPM > fan.minRPM {
                let targetFraction = min(max((appliedRPM - fan.minRPM) / (fan.maxRPM - fan.minRPM), 0), 1)
                GaugeArc(fraction: targetFraction)
                    .stroke(Color.primary.opacity(0.0), lineWidth: 0)
                    .overlay {
                        Circle()
                            .fill(Color.primary.opacity(0.8))
                            .frame(width: size * 0.035, height: size * 0.035)
                            .offset(y: -(size / 2 - size * 0.0375))
                            .rotationEffect(.degrees(-135 + 270 * targetFraction))
                            .animation(.easeOut(duration: 0.8), value: targetFraction)
                    }
            }

            SpinningBlades(rpm: fan.currentRPM, color: color, size: size * 0.58)

            VStack(spacing: -2) {
                Text("\(Int(fan.currentRPM.rounded()))")
                    .font(Theme.numeric(size * 0.21, weight: .bold))
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.5), value: fan.currentRPM)
                    .shadow(color: .black.opacity(0.12), radius: 3)
                Text("rpm")
                    .font(Theme.numeric(size * 0.062, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

/// 날개 모양. 한 번만 만들어 두고 회전은 Core Animation 에 맡긴다.
private struct BladesShape: Shape {
    let count: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        for i in 0..<count {
            let base = Double(i) / Double(count) * 2 * .pi
            path.move(to: center)
            path.addArc(center: center, radius: radius,
                        startAngle: .radians(base), endAngle: .radians(base + 0.42),
                        clockwise: false)
            path.closeSubpath()
        }
        // 가운데 허브
        let hub = radius * 0.22
        path.addEllipse(in: CGRect(x: center.x - hub, y: center.y - hub,
                                   width: hub * 2, height: hub * 2))
        return path
    }
}

private final class SpinState: ObservableObject {
    @Published var spinning = false
}

/// 실제 회전수에 비례해 도는 팬 날개.
///
/// 처음에는 TimelineView + Canvas 로 매 프레임 다시 그렸는데, 그것만으로
/// CPU 를 40% 넘게 썼다. 팬 제어 앱이 열을 만들면 앞뒤가 안 맞는다.
/// 지금은 모양을 한 번만 만들고 회전은 Core Animation 에 넘겨서 GPU 가 처리한다.
private struct SpinningBlades: View {
    let rpm: Double
    let color: Color
    let size: CGFloat

    @StateObject private var state = SpinState()

    /// 회전 속도를 200rpm 단위로 끊는다. 실측값이 매초 몇 rpm 씩 흔들리는데
    /// 그때마다 애니메이션을 다시 걸면 각도가 튄다.
    private var bucket: Int {
        // 화면 주사율보다 빠른 회전은 눈에 역회전으로 보이므로 표시 속도를 눌러준다.
        Int(min(rpm, 420) / 200)
    }

    private var secondsPerRevolution: Double {
        let displayRPM = max(Double(bucket) * 200 + 100, 60)
        return 60.0 / displayRPM
    }

    var body: some View {
        BladesShape(count: 7)
            .fill(color.opacity(0.22))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(state.spinning ? 360 : 0))
            .animation(.linear(duration: secondsPerRevolution).repeatForever(autoreverses: false),
                       value: state.spinning)
            .onAppear { state.spinning = true }
            .onChange(of: bucket) { _, _ in
                // 속도 구간이 바뀌면 새 속도로 다시 건다.
                state.spinning = false
                DispatchQueue.main.async { state.spinning = true }
            }
            .allowsHitTesting(false)
    }
}

// MARK: - 수치 타일

struct StatTile: View {
    let title: String
    let value: String
    var subtitle: String? = nil
    var color: Color = .accentColor
    var symbol: String? = nil
    var series: [(Date, Double)] = []
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(color)
                }
                Text(title)
                    .font(Theme.label)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(value)
                .font(Theme.numeric(isCompact ? 20 : 27, weight: .semibold))
                .foregroundStyle(color)
                
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            if !series.isEmpty {
                Sparkline(series: series, color: color)
                    .frame(height: isCompact ? 18 : 26)
                    .clipped()
            } else if let subtitle {
                Text(subtitle)
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(tint: color, padding: isCompact ? 12 : 16)
    }
}

// MARK: - 스파크라인

struct Sparkline: View {
    let series: [(Date, Double)]
    var color: Color = .accentColor
    var filled = true

    var body: some View {
        if series.count < 2 {
            // 표본이 모이기 전엔 빈 줄 대신 기준선을 보여준다.
            Rectangle()
                .fill(color.opacity(0.15))
                .frame(height: 1)
                .frame(maxHeight: .infinity, alignment: .center)
        } else {
            let values = series.map(\.1)
            let lo = values.min() ?? 0
            let hi = values.max() ?? 1
            // 변화가 거의 없을 때 선이 가운데서 요동치지 않도록 최소 폭을 준다.
            let span = max(hi - lo, 0.5)

            Chart {
                ForEach(Array(series.enumerated()), id: \.offset) { _, point in
                    if filled {
                        AreaMark(x: .value("시각", point.0), y: .value("값", point.1))
                            .foregroundStyle(
                                LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)],
                                               startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                    }
                    LineMark(x: .value("시각", point.0), y: .value("값", point.1))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        .interpolationMethod(.monotone)
                }
            }
            .chartYScale(domain: (lo - span * 0.15)...(hi + span * 0.15))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            // AreaMark 의 그라데이션은 기본적으로 프레임 밖까지 그려져서
            // 카드 아래로 흘러내린다. 반드시 잘라내야 한다.
            .chartPlotStyle { $0.clipped() }
            .clipped()
        }
    }
}

// MARK: - 센서 셀

struct SensorCell: View {
    let descriptor: SensorDescriptor
    let value: Double?
    let isFavorite: Bool
    var format: ValueFormat = .default
    let onToggleFavorite: () -> Void

    private var color: Color {
        guard let value else { return .secondary }
        return Theme.accent(for: descriptor.unit, value: value)
    }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 3, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(descriptor.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(descriptor.key)
                    .font(Theme.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 6)

            Text(value.map { String(format: "%.\(descriptor.unit.fractionDigits)f", $0) } ?? "—")
                .font(Theme.numeric(15))
                .foregroundStyle(color)
                
            Text(descriptor.unit.suffix)
                .font(Theme.caption)
                .foregroundStyle(.tertiary)

            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 10))
                    .foregroundStyle(isFavorite ? Color.yellow : Color.secondary.opacity(0.45))
            }
            .buttonStyle(.plain)
            .help(isFavorite ? "즐겨찾기에서 제거" : "즐겨찾기에 추가")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        }
    }
}

// MARK: - 상단 탭 바

struct TabBar: View {
    @Binding var selection: AppModel.Tab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppModel.Tab.allCases) { tab in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { selection = tab }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 11, weight: .semibold))
                        Text(tab.title)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background {
                        if selection == tab {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.accentColor.opacity(0.18))
                        }
                    }
                    .foregroundStyle(selection == tab ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        }
    }
}

// MARK: - 상태 배지

/// Command Line Tools 에는 SwiftUI 의 매크로 플러그인이 없어서 @State 를 쓸 수 없다.
/// 뷰 로컬 상태는 작은 ObservableObject 로 대신한다(동작은 동일하다).
private final class PulseState: ObservableObject {
    @Published var on = false
}

struct StatusBadge: View {
    let text: String
    let color: Color
    var symbol: String? = nil
    var pulsing = false

    @StateObject private var pulseState = PulseState()

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .opacity(pulsing && pulseState.on ? 0.3 : 1)
            }
            Text(text).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            Capsule().fill(color.opacity(0.14))
        }
        .onAppear {
            guard pulsing else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulseState.on = true
            }
        }
    }
}

// MARK: - 섹션 제목

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var trailing: AnyView? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let subtitle {
                    Text(subtitle).font(Theme.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let trailing { trailing }
        }
    }
}
