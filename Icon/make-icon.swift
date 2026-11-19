// 앱 아이콘(Icon/AppIcon.icns)을 그린다. 그림을 바꿀 때만 돌린다.
//   swift Icon/make-icon.swift
// 앨범 색 바탕 위에, 노치에 앨범 커버와 재생 막대가 뜬 모습.
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iconset = root.appendingPathComponent("AppIcon.iconset")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

// 1024 기준 좌표(위가 0)로 그린다. macOS 아이콘 규격: 몸통 824pt, 가장자리 여백 100pt.
func draw(_ ctx: CGContext, size: CGFloat) {
    let s = size / 1024
    ctx.scaleBy(x: s, y: s)
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // 그림자
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x000000))
    ctx.fillPath()
    ctx.restoreGState()

    // 바탕: 산호색 → 보라 (앨범 색에 맞춰 물드는 느낌)
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [color(0xF7845F), color(0xE0567A), color(0x7B4FE0)] as CFArray,
                              locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 180, y: 120), end: CGPoint(x: 860, y: 920), options: [])

    // 노치: 위 가장자리에 붙고 아래 모서리만 둥근 검은 막대
    let notch = CGRect(x: 212, y: 60, width: 600, height: 330)
    let notchPath = CGMutablePath()
    let r: CGFloat = 120
    notchPath.move(to: CGPoint(x: notch.minX, y: notch.minY))
    notchPath.addLine(to: CGPoint(x: notch.maxX, y: notch.minY))
    notchPath.addLine(to: CGPoint(x: notch.maxX, y: notch.maxY - r))
    notchPath.addArc(tangent1End: CGPoint(x: notch.maxX, y: notch.maxY),
                     tangent2End: CGPoint(x: notch.maxX - r, y: notch.maxY), radius: r)
    notchPath.addLine(to: CGPoint(x: notch.minX + r, y: notch.maxY))
    notchPath.addArc(tangent1End: CGPoint(x: notch.minX, y: notch.maxY),
                     tangent2End: CGPoint(x: notch.minX, y: notch.maxY - r), radius: r)
    notchPath.closeSubpath()
    ctx.addPath(notchPath)
    ctx.setFillColor(color(0x0B0B0F))
    ctx.fillPath()

    // 앨범 커버
    let cover = CGRect(x: 272, y: 172, width: 156, height: 156)
    ctx.addPath(CGPath(roundedRect: cover, cornerWidth: 34, cornerHeight: 34, transform: nil))
    ctx.setFillColor(color(0xFFC94A))
    ctx.fillPath()
    ctx.addEllipse(in: cover.insetBy(dx: 42, dy: 42))
    ctx.setFillColor(color(0xF7845F))
    ctx.fillPath()

    // 재생 막대
    let bars: [CGFloat] = [70, 136, 96, 52]
    for (i, h) in bars.enumerated() {
        let x = 556 + CGFloat(i) * 58
        let bar = CGRect(x: x, y: 250 - h / 2, width: 32, height: h)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 16, cornerHeight: 16, transform: nil))
    }
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx, size: CGFloat(px))
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("AppIcon.icns").path]
try task.run()
task.waitUntilExit()
try FileManager.default.removeItem(at: iconset)
print("✓ Icon/AppIcon.icns")
