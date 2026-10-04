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
    //
    // 색을 한 벌만 두면 한쪽 테마에서 반드시 묻힌다. 밝은 배경에서 잘 보이는 색은
    // 어두운 배경에서 탁하고, 어두운 배경에서 선명한 색은 밝은 배경에서 희미하다.
    // 특히 메뉴 막대 팝오버는 배경이 비쳐서 더 심하다. 그래서 두 벌을 두고
    // 시스템 테마에 따라 고르게 한다.

    private typealias RGB = (r: Double, g: Double, b: Double)

    /// 밝은 배경용 — 충분히 어둡고 진하게.
    private static let lightStops: [(Double, RGB)] = [
        (30, (0.08, 0.45, 0.58)),
        (50, (0.10, 0.50, 0.32)),
        (65, (0.68, 0.46, 0.05)),
        (80, (0.78, 0.33, 0.06)),
        (95, (0.76, 0.13, 0.16)),
    ]

    /// 어두운 배경용 — 밝고 선명하게.
    private static let darkStops: [(Double, RGB)] = [
        (30, (0.35, 0.78, 0.90)),
        (50, (0.35, 0.85, 0.60)),
        (65, (0.97, 0.80, 0.35)),
        (80, (1.00, 0.60, 0.30)),
        (95, (1.00, 0.40, 0.42)),
    ]

    private static func interpolate(_ stops: [(Double, RGB)], _ value: Double) -> RGB {
        guard let first = stops.first, let last = stops.last else { return (0.5, 0.5, 0.5) }
        if value <= first.0 { return first.1 }
        if value >= last.0 { return last.1 }
        for i in 0..<(stops.count - 1) {
            let (v0, c0) = stops[i]
            let (v1, c1) = stops[i + 1]
            if value >= v0 && value <= v1 {
                let t = (value - v0) / (v1 - v0)
                return (c0.r + (c1.r - c0.r) * t,
                        c0.g + (c1.g - c0.g) * t,
                        c0.b + (c1.b - c0.b) * t)
            }
        }
        return last.1
    }

    /// 테마에 따라 알아서 바뀌는 색을 만든다.
    private static func adaptive(light: RGB, dark: RGB) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        })
    }

    static func temperatureColor(_ celsius: Double) -> Color {
        adaptive(light: interpolate(lightStops, celsius),
                 dark: interpolate(darkStops, celsius))
    }

    /// 단위에 맞는 강조색. 온도가 아닌 값은 고정색을 쓴다.
    static func accent(for unit: SensorUnit, value: Double) -> Color {
        switch unit {
        case .celsius: return temperatureColor(value)
        case .watt:    return adaptive(light: (0.33, 0.33, 0.78), dark: (0.62, 0.62, 1.00))
        case .volt:    return adaptive(light: (0.70, 0.45, 0.10), dark: (0.98, 0.76, 0.45))
        case .ampere:  return adaptive(light: (0.12, 0.48, 0.45), dark: (0.50, 0.85, 0.80))
        case .rpm:     return adaptive(light: (0.12, 0.42, 0.70), dark: (0.45, 0.74, 1.00))
        case .percent: return adaptive(light: (0.30, 0.40, 0.55), dark: (0.68, 0.80, 0.95))
        }
    }

    /// 팬 속도 비율에 따른 색. 조용할수록 차분하고, 빨라질수록 선명해진다.
    static func fanColor(_ fraction: Double) -> Color {
        let f = min(max(fraction, 0), 1)
        let light: RGB = (0.12 + (0.76 - 0.12) * f,
                          0.42 + (0.28 - 0.42) * f,
                          0.70 + (0.16 - 0.70) * f)
        let dark: RGB = (0.45 + (1.00 - 0.45) * f,
                         0.74 + (0.52 - 0.74) * f,
                         1.00 + (0.42 - 1.00) * f)
        return adaptive(light: light, dark: dark)
    }

    static func blend(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let t = min(max(t, 0), 1)
        let ca = NSColor(a).usingColorSpace(.sRGB) ?? .white
        let cb = NSColor(b).usingColorSpace(.sRGB) ?? .white
        return Color(red:   ca.redComponent   + (cb.redComponent   - ca.redComponent)   * t,
                     green: ca.greenComponent + (cb.greenComponent - ca.greenComponent) * t,
                     blue:  ca.blueComponent  + (cb.blueComponent  - ca.blueComponent)  * t)
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
