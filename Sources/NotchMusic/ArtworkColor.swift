import AppKit
import SwiftUI

/// 앨범 커버에서 검은 노치 위에서 잘 보이는 대표 색 하나를 뽑는다.
enum ArtworkColor {
    static let fallback = Color(white: 0.85)

    static func accent(from image: NSImage) -> Color {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return fallback }

        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return fallback }

        // 색상환을 12칸으로 나눠, 선명하고 밝은 픽셀이 가장 많이 몰린 칸을 고른다.
        // 그냥 평균을 내면 빨강과 파랑이 섞여 엉뚱한 보라가 나오기 때문이다.
        let bins = 12
        var weight = [Double](repeating: 0, count: bins)
        var red = weight, green = weight, blue = weight

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            let color = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
            color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
            guard saturation > 0.15, brightness > 0.2 else { continue }
            let w = Double(saturation * saturation * brightness)
            let bin = min(Int(hue * CGFloat(bins)), bins - 1)
            weight[bin] += w
            red[bin] += r * w
            green[bin] += g * w
            blue[bin] += b * w
        }

        guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[best] > 2 else {
            return fallback // 흑백에 가까운 커버
        }

        let average = NSColor(
            srgbRed: red[best] / weight[best], green: green[best] / weight[best], blue: blue[best] / weight[best], alpha: 1
        )
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        // 검은 배경에서 잘 보이도록 밝기는 올리고, 너무 쨍한 채도는 조금 누른다.
        return Color(nsColor: NSColor(
            hue: hue, saturation: min(max(saturation, 0.35), 0.7), brightness: max(brightness, 0.9), alpha: 1
        ))
    }
}
