//  make-icon.swift — 앱 아이콘 PNG 생성
//  팬 날개 + 온도 눈금을 한 장에 담는다. 작게 줄여도 형태가 뭉개지지 않도록
//  날개 수를 적게 두고 대비를 세게 줬다.

import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

// 배경 — 짙은 남색에서 청록으로 떨어지는 그라데이션
let bgRect = CGRect(x: 0, y: 0, width: size, height: size)
let bgPath = CGPath(roundedRect: bgRect.insetBy(dx: size * 0.06, dy: size * 0.06),
                    cornerWidth: size * 0.22, cornerHeight: size * 0.22, transform: nil)
ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
let colorSpace = CGColorSpaceCreateDeviceRGB()
let bgGradient = CGGradient(colorsSpace: colorSpace, colors: [
    CGColor(red: 0.09, green: 0.13, blue: 0.24, alpha: 1),
    CGColor(red: 0.05, green: 0.29, blue: 0.42, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bgGradient,
                       start: CGPoint(x: 0, y: size),
                       end: CGPoint(x: size, y: 0),
                       options: [])

// 아래쪽에서 올라오는 은은한 발광 — 열을 암시한다
let glow = CGGradient(colorsSpace: colorSpace, colors: [
    CGColor(red: 0.30, green: 0.85, blue: 0.95, alpha: 0.30),
    CGColor(red: 0.30, green: 0.85, blue: 0.95, alpha: 0.0),
] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow,
                       startCenter: CGPoint(x: size * 0.5, y: size * 0.28), startRadius: 0,
                       endCenter: CGPoint(x: size * 0.5, y: size * 0.28), endRadius: size * 0.55,
                       options: [])
ctx.restoreGState()

let center = CGPoint(x: size / 2, y: size / 2)

// 바깥 게이지 호 — 270도만 그려서 계기판 느낌을 준다
ctx.saveGState()
ctx.setLineCap(.round)
ctx.setLineWidth(size * 0.045)
// 트랙은 아래쪽이 터진 270도 호다(135도에서 시작해 405도에서 끝난다).
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.15))
ctx.addArc(center: center, radius: size * 0.345,
           startAngle: .pi * 1.25, endAngle: .pi * 2.75, clockwise: false)
ctx.strokePath()

// 채워진 구간 — 전체의 약 72%. 청록에서 끝부분만 호박색으로 넘어간다.
ctx.setStrokeColor(CGColor(red: 0.35, green: 0.86, blue: 0.80, alpha: 1))
ctx.addArc(center: center, radius: size * 0.345,
           startAngle: .pi * 1.25, endAngle: .pi * 2.33, clockwise: false)
ctx.strokePath()
ctx.setStrokeColor(CGColor(red: 1.0, green: 0.72, blue: 0.30, alpha: 1))
ctx.addArc(center: center, radius: size * 0.345,
           startAngle: .pi * 2.33, endAngle: .pi * 2.55, clockwise: false)
ctx.strokePath()
ctx.restoreGState()

// 팬 날개 5장
let bladeCount = 5
let bladeRadius = size * 0.255
for i in 0..<bladeCount {
    let base = Double(i) / Double(bladeCount) * 2 * .pi + 0.35
    let path = CGMutablePath()
    path.move(to: center)
    // 끝이 넓고 뿌리가 좁은 곡선 날개
    path.addArc(center: center, radius: bladeRadius,
                startAngle: base, endAngle: base + 0.78, clockwise: false)
    path.closeSubpath()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let bladeGradient = CGGradient(colorsSpace: colorSpace, colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.95),
        CGColor(red: 0.62, green: 0.88, blue: 1.0, alpha: 0.55),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bladeGradient,
                           start: CGPoint(x: center.x, y: center.y + bladeRadius),
                           end: CGPoint(x: center.x, y: center.y - bladeRadius),
                           options: [])
    ctx.restoreGState()
}

// 허브
ctx.setFillColor(CGColor(red: 0.07, green: 0.12, blue: 0.22, alpha: 1))
ctx.fillEllipse(in: CGRect(x: center.x - size * 0.072, y: center.y - size * 0.072,
                           width: size * 0.144, height: size * 0.144))
ctx.setFillColor(CGColor(red: 0.35, green: 0.86, blue: 0.80, alpha: 1))
ctx.fillEllipse(in: CGRect(x: center.x - size * 0.028, y: center.y - size * 0.028,
                           width: size * 0.056, height: size * 0.056))

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
try! png.write(to: URL(fileURLWithPath: out))
print("아이콘 생성: \(out)")
