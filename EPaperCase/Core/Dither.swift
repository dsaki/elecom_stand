import Foundation

struct RGB: Equatable {
    var r: Double
    var g: Double
    var b: Double
}

enum DitherMethod: String, Codable, CaseIterable, Identifiable {
    case floydSteinberg
    case atkinson
    case none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .floydSteinberg: return "なめらか"
        case .atkinson: return "くっきり"
        case .none: return "ベタ塗り"
        }
    }
}

struct ImageAdjustments: Equatable, Codable {
    /// -0.5 ... 0.5
    var brightness: Double = 0
    /// 0.5 ... 1.8
    var contrast: Double = 1.1
    /// 0 ... 2
    var saturation: Double = 1.3
    var method: DitherMethod = .floydSteinberg
}

enum Palette {
    /// 色番号の順: 0=黒, 1=白, 2=黄, 3=赤
    static let fourColor: [RGB] = [
        RGB(r: 0, g: 0, b: 0),
        RGB(r: 255, g: 255, b: 255),
        RGB(r: 255, g: 225, b: 0),
        RGB(r: 205, g: 20, b: 20)
    ]

    static let blackWhite: [RGB] = Array(fourColor.prefix(2))

    static func colors(for mode: ColorMode) -> [RGB] {
        mode == .fourColor ? fourColor : blackWhite
    }
}

enum Dither {
    /// RGBA8 画像を、パレットの色番号配列に変換する。
    static func quantize(rgba: [UInt8], width: Int, height: Int, palette: [RGB], adjustments: ImageAdjustments) -> [UInt8] {
        precondition(rgba.count == width * height * 4)
        let count = width * height

        // 調整済みの作業バッファ (R, G, B)
        var work = [Double](repeating: 0, count: count * 3)
        let c = adjustments.contrast
        let s = adjustments.saturation
        let offset = adjustments.brightness * 255
        for i in 0..<count {
            var r = Double(rgba[i * 4])
            var g = Double(rgba[i * 4 + 1])
            var b = Double(rgba[i * 4 + 2])
            let luma = 0.299 * r + 0.587 * g + 0.114 * b
            r = luma + (r - luma) * s
            g = luma + (g - luma) * s
            b = luma + (b - luma) * s
            r = (r - 127.5) * c + 127.5 + offset
            g = (g - 127.5) * c + 127.5 + offset
            b = (b - 127.5) * c + 127.5 + offset
            work[i * 3] = min(255, max(0, r))
            work[i * 3 + 1] = min(255, max(0, g))
            work[i * 3 + 2] = min(255, max(0, b))
        }

        // (dx, dy, 重み)
        let kernel: [(Int, Int, Double)]
        switch adjustments.method {
        case .floydSteinberg:
            kernel = [(1, 0, 7.0 / 16), (-1, 1, 3.0 / 16), (0, 1, 5.0 / 16), (1, 1, 1.0 / 16)]
        case .atkinson:
            kernel = [(1, 0, 0.125), (2, 0, 0.125), (-1, 1, 0.125), (0, 1, 0.125), (1, 1, 0.125), (0, 2, 0.125)]
        case .none:
            kernel = []
        }

        func luma(_ r: Double, _ g: Double, _ b: Double) -> Double {
            0.299 * r + 0.587 * g + 0.114 * b
        }
        let paletteLuma = palette.map { luma($0.r, $0.g, $0.b) }

        var out = [UInt8](repeating: 0, count: count)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let r = work[i * 3]
                let g = work[i * 3 + 1]
                let b = work[i * 3 + 2]

                // 明るさと色味を分けて比べる。RGB の単純な距離だと、灰色が赤に寄って
                // 無彩色の部分に赤や黄の粒が混ざってしまう。
                let l = luma(r, g, b)
                var best = 0
                var bestDistance = Double.greatestFiniteMagnitude
                for (index, p) in palette.enumerated() {
                    let dl = l - paletteLuma[index]
                    let dcr = (r - l) - (p.r - paletteLuma[index])
                    let dcb = (b - l) - (p.b - paletteLuma[index])
                    let d = dl * dl + dcr * dcr + dcb * dcb
                    if d < bestDistance {
                        bestDistance = d
                        best = index
                    }
                }
                out[i] = UInt8(best)

                if kernel.isEmpty { continue }
                let er = r - palette[best].r
                let eg = g - palette[best].g
                let eb = b - palette[best].b
                for (dx, dy, weight) in kernel {
                    let nx = x + dx
                    let ny = y + dy
                    if nx < 0 || nx >= width || ny >= height { continue }
                    let j = (ny * width + nx) * 3
                    work[j] += er * weight
                    work[j + 1] += eg * weight
                    work[j + 2] += eb * weight
                }
            }
        }
        return out
    }
}
