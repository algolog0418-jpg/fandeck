//  TrendChart.swift — 대시보드 추이 그래프
//
//  Swift Charts 로 그리면 선언이 간결한 대신, 값이 매초 바뀌는 화면에서는
//  차트 구조를 통째로 다시 만들고 레이아웃을 다시 계산한다. 대시보드가 CPU 를
//  30% 가까이 쓰던 가장 큰 이유였다.
//
//  여기서 필요한 건 선 몇 개와 눈금뿐이라 직접 그린다.

import SwiftUI

struct TrendChart: View {
    let model: AppModel
    let keys: [String]
    let fan: FanInfo?

    /// 온도 선 색. 범례와 순서를 맞춘다.
    static let seriesColors: [Color] = [
        Color(red: 0.95, green: 0.45, blue: 0.35),
        Color(red: 0.35, green: 0.72, blue: 0.95),
        Color(red: 0.55, green: 0.80, blue: 0.45),
    ]

    /// 세로축은 섭씨 20~100 으로 고정한다. 값에 따라 축이 움직이면
    /// 선이 가만히 있어도 그래프가 출렁거려서 추이를 읽기 어렵다.
    private let lowerBound = 20.0
    private let upperBound = 100.0

    var body: some View {
        Canvas { context, size in
            let left: CGFloat = 34
            let bottom: CGFloat = 18
            let plot = CGRect(x: left, y: 4,
                              width: max(size.width - left - 6, 10),
                              height: max(size.height - bottom - 8, 10))

            drawGrid(context: context, plot: plot)
            drawFanArea(context: context, plot: plot)
            drawTemperatureLines(context: context, plot: plot)
        }
        .drawingGroup()
    }

    private func y(_ celsius: Double, in plot: CGRect) -> CGFloat {
        let ratio = (celsius - lowerBound) / (upperBound - lowerBound)
        return plot.maxY - plot.height * CGFloat(min(max(ratio, 0), 1))
    }

    private func drawGrid(context: GraphicsContext, plot: CGRect) {
        let unit = model.format.temperatureUnit
        for value in stride(from: lowerBound, through: upperBound, by: 20) {
            let py = y(value, in: plot)
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: py))
            line.addLine(to: CGPoint(x: plot.maxX, y: py))
            context.stroke(line, with: .color(.secondary.opacity(0.12)), lineWidth: 1)

            let label = "\(Int(unit.convert(value).rounded()))\(unit.shortSuffix)"
            context.draw(Text(label).font(Theme.caption).foregroundStyle(.tertiary),
                         at: CGPoint(x: plot.minX - 16, y: py), anchor: .center)
        }
    }

    /// 팬 속도는 축이 달라서, 온도 범위에 비례해 깔아 둔다. 정확한 값보다
    /// "온도가 오를 때 팬이 따라 올라갔는가" 를 보기 위한 것이다.
    private func drawFanArea(context: GraphicsContext, plot: CGRect) {
        guard let fan, fan.maxRPM > fan.minRPM else { return }
        let points = model.fanHistory(index: fan.index)
        guard points.count >= 2 else { return }

        var path = Path()
        for (i, point) in points.enumerated() {
            let ratio = (point.1 - fan.minRPM) / (fan.maxRPM - fan.minRPM)
            let px = plot.minX + plot.width * CGFloat(i) / CGFloat(points.count - 1)
            let py = y(lowerBound + min(max(ratio, 0), 1) * (upperBound - lowerBound), in: plot)
            if i == 0 { path.move(to: CGPoint(x: px, y: py)) }
            else { path.addLine(to: CGPoint(x: px, y: py)) }
        }
        var area = path
        area.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        area.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
        area.closeSubpath()
        context.fill(area, with: .linearGradient(
            Gradient(colors: [Color.accentColor.opacity(0.22), Color.accentColor.opacity(0.02)]),
            startPoint: CGPoint(x: 0, y: plot.minY),
            endPoint: CGPoint(x: 0, y: plot.maxY)))
    }

    private func drawTemperatureLines(context: GraphicsContext, plot: CGRect) {
        for (index, key) in keys.enumerated() {
            guard let descriptor = model.descriptor(key), descriptor.unit == .celsius else { continue }
            let points = model.history(forKey: key)
            guard points.count >= 2 else { continue }

            var path = Path()
            for (i, point) in points.enumerated() {
                let px = plot.minX + plot.width * CGFloat(i) / CGFloat(points.count - 1)
                let py = y(point.1, in: plot)
                if i == 0 { path.move(to: CGPoint(x: px, y: py)) }
                else { path.addLine(to: CGPoint(x: px, y: py)) }
            }
            context.stroke(path,
                           with: .color(Self.seriesColors[index % Self.seriesColors.count]),
                           style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
    }
}
