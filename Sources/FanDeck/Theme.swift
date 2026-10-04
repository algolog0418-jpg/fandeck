//  Theme.swift — FanDeck 디자인 시스템
//
//  숫자를 많이 띄우는 앱이라, 색은 장식이 아니라 "지금 뜨거운가"를 한눈에 알려주는 정보다.
//  그래서 온도 색은 임의로 고르지 않고 하나의 연속 스케일에서 뽑아 쓴다.

import SwiftUI

enum Theme {

    // MARK: 온도 스케일
    //
    // 차가움(청록) → 적정(초록) → 주의(호박) → 뜨거움(주황) → 위험(빨강)
    // 구간을 끊지 않고 보간해서, 온도가 오를 때 색도 연속적으로 변한다.

    private static let temperatureStops: [(Double, Color)] = [
        (30, Color(red: 0.22, green: 0.72, blue: 0.85)),
        (50, Color(red: 0.25, green: 0.80, blue: 0.55)),
        (65, Color(red: 0.95, green: 0.75, blue: 0.25)),
        (80, Color(red: 0.98, green: 0.52, blue: 0.22)),
        (95, Color(red: 0.95, green: 0.27, blue: 0.30)),
    ]

    static func temperatureColor(_ celsius: Double) -> Color {
        guard let first = temperatureStops.first else { return .gray }
        if celsius <= first.0 { return first.1 }
        if let last = temperatureStops.last, celsius >= last.0 { return last.1 }
        for i in 0..<(temperatureStops.count - 1) {
            let (t0, c0) = temperatureStops[i]
            let (t1, c1) = temperatureStops[i + 1]
            if celsius >= t0 && celsius <= t1 {
                return blend(c0, c1, (celsius - t0) / (t1 - t0))
            }
        }
        return temperatureStops.last!.1
    }

    /// 단위에 맞는 강조색. 온도가 아닌 값은 고정색을 쓴다.
    static func accent(for unit: SensorUnit, value: Double) -> Color {
        switch unit {
        case .celsius: return temperatureColor(value)
        case .watt:    return Color(red: 0.55, green: 0.55, blue: 0.95)
        case .volt:    return Color(red: 0.95, green: 0.70, blue: 0.40)
        case .ampere:  return Color(red: 0.45, green: 0.80, blue: 0.75)
        case .rpm:     return Color(red: 0.35, green: 0.68, blue: 0.95)
        case .percent: return Color(red: 0.60, green: 0.75, blue: 0.90)
        }
    }

    static func blend(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let t = min(max(t, 0), 1)
        let ca = NSColor(a).usingColorSpace(.sRGB) ?? .white
        let cb = NSColor(b).usingColorSpace(.sRGB) ?? .white
        return Color(red:   ca.redComponent   + (cb.redComponent   - ca.redComponent)   * t,
                     green: ca.greenComponent + (cb.greenComponent - ca.greenComponent) * t,
                     blue:  ca.blueComponent  + (cb.blueComponent  - ca.blueComponent)  * t)
    }

    /// 팬 속도 비율에 따른 색. 조용할수록 차분하고, 빨라질수록 선명해진다.
    static func fanColor(_ fraction: Double) -> Color {
        blend(Color(red: 0.35, green: 0.68, blue: 0.95),
              Color(red: 0.98, green: 0.45, blue: 0.35), fraction)
    }

    // MARK: 치수

    static let cardRadius: CGFloat = 16
    static let cardPadding: CGFloat = 18
    static let gridSpacing: CGFloat = 14

    // MARK: 글꼴
    //
    // 수치는 전부 고정폭 숫자로 띄운다. 값이 바뀔 때마다 글자 폭이 달라지면
    // 숫자가 덜덜 떨려서 읽기 어렵다.

    static func numeric(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    static let label = Font.system(size: 11, weight: .medium)
    static let caption = Font.system(size: 10, weight: .regular)
}

/// 어디서나 쓰는 카드 배경.
///
/// 처음에는 `.regularMaterial` 을 썼는데, 값이 매초 바뀌는 화면에서는
/// 카드마다 가우시안 블러를 다시 계산하느라 CPU 를 40% 넘게 먹었다
/// (프로파일러에 vImage 의 블러 함수가 최상위로 잡혔다).
/// 반투명을 포기하고 불투명 색으로 칠하면 그 비용이 사라진다.
/// 층을 나누는 느낌은 테두리와 아주 옅은 색조로 대신한다.
struct CardBackground: ViewModifier {
    var tint: Color? = nil
    var padding: CGFloat = Theme.cardPadding

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        if let tint {
                            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                                .fill(tint.opacity(0.06))
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                    }
            }
    }
}

extension View {
    func card(tint: Color? = nil, padding: CGFloat = Theme.cardPadding) -> some View {
        modifier(CardBackground(tint: tint, padding: padding))
    }
}
