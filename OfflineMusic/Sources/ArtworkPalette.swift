import SwiftUI
import UIKit

enum ArtworkPalette {
    static let fallback: [Color] = [
        Color(red: 0.08, green: 0.36, blue: 0.24),
        Color(red: 0.13, green: 0.12, blue: 0.28),
        Color(red: 0.02, green: 0.025, blue: 0.024)
    ]

    static let fallbackAccent = Color(red: 0.28, green: 0.82, blue: 0.58)

    static func accentColor(from palette: [Color]) -> Color {
        guard let dominantColor = palette.first else { return fallbackAccent }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(dominantColor).getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: &alpha
        ) else { return fallbackAccent }

        return Color(
            hue: Double(hue),
            saturation: Double(max(saturation, 0.58)),
            brightness: Double(max(brightness, 0.76))
        )
    }

    nonisolated static func colors(fromImageAt path: String) -> [Color] {
        guard let image = UIImage(contentsOfFile: path),
              let pixels = image.sampledRGBA(width: 36, height: 36)
        else { return fallback }

        struct Bucket {
            var count = 0
            var red = 0
            var green = 0
            var blue = 0
        }

        var buckets: [Int: Bucket] = [:]
        for pixel in pixels where pixel.alpha > 100 {
            let key = (Int(pixel.red) / 32 << 6)
                | (Int(pixel.green) / 32 << 3)
                | (Int(pixel.blue) / 32)
            var bucket = buckets[key, default: Bucket()]
            bucket.count += 1
            bucket.red += Int(pixel.red)
            bucket.green += Int(pixel.green)
            bucket.blue += Int(pixel.blue)
            buckets[key] = bucket
        }

        let candidates = buckets.values.compactMap { bucket -> Candidate? in
            guard bucket.count > 0 else { return nil }
            let red = Double(bucket.red) / Double(bucket.count * 255)
            let green = Double(bucket.green) / Double(bucket.count * 255)
            let blue = Double(bucket.blue) / Double(bucket.count * 255)
            let maximum = max(red, green, blue)
            let minimum = min(red, green, blue)
            let saturation = maximum == 0 ? 0 : (maximum - minimum) / maximum
            let brightnessWeight = 0.35 + min(max(maximum, 0.16), 0.82)
            let score = Double(bucket.count) * (0.4 + saturation) * brightnessWeight
            return Candidate(red: red, green: green, blue: blue, score: score)
        }
        .sorted { $0.score > $1.score }

        guard let first = candidates.first else { return fallback }
        var selected = [first]
        for candidate in candidates.dropFirst() {
            guard selected.allSatisfy({ $0.distance(to: candidate) > 0.22 }) else { continue }
            selected.append(candidate)
            if selected.count == 3 { break }
        }

        while selected.count < 3 {
            selected.append(selected[0].variant(index: selected.count))
        }

        return selected.map { candidate in
            Color(
                red: min(max(candidate.red, 0.035), 0.78),
                green: min(max(candidate.green, 0.035), 0.78),
                blue: min(max(candidate.blue, 0.035), 0.78)
            )
        }
    }

    private struct Candidate {
        let red: Double
        let green: Double
        let blue: Double
        let score: Double

        func distance(to other: Candidate) -> Double {
            let redDelta = red - other.red
            let greenDelta = green - other.green
            let blueDelta = blue - other.blue
            return sqrt(redDelta * redDelta + greenDelta * greenDelta + blueDelta * blueDelta)
        }

        func variant(index: Int) -> Candidate {
            let multiplier = index == 1 ? 0.58 : 0.3
            let rotation = index == 1 ? (green, blue, red) : (blue, red, green)
            return Candidate(
                red: rotation.0 * multiplier,
                green: rotation.1 * multiplier,
                blue: rotation.2 * multiplier,
                score: 0
            )
        }
    }
}

private extension UIImage {
    struct RGBA {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8
    }

    nonisolated func sampledRGBA(width: Int, height: Int) -> [RGBA]? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage else { return nil }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return stride(from: 0, to: bytes.count, by: 4).map {
            RGBA(red: bytes[$0], green: bytes[$0 + 1], blue: bytes[$0 + 2], alpha: bytes[$0 + 3])
        }
    }
}
