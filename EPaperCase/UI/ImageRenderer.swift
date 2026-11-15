import CoreGraphics
import UIKit

/// 写真の切り抜き・拡大と、電子ペーパー用の色への変換。
enum ImageRenderer {
    /// 表示位置の調整。offset はキャンバス幅・高さに対する割合。
    struct Placement: Equatable {
        var zoom: CGFloat = 1
        var offsetX: CGFloat = 0
        var offsetY: CGFloat = 0
    }

    /// 向き情報を焼き込み、大きすぎる写真は縮めておく。
    static func normalized(_ image: UIImage, maxSide: CGFloat = 2400) -> CGImage? {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, maxSide / longest)
        let size = CGSize(width: max(1, (image.size.width * scale).rounded()), height: max(1, (image.size.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.cgImage
    }

    /// 画像をキャンバスいっぱいに敷き詰めて RGBA8 で返す（行0が上端）。
    static func rgba(from image: CGImage, width: Int, height: Int, placement: Placement) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return }
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high

            let canvasW = CGFloat(width)
            let canvasH = CGFloat(height)
            let fill = max(canvasW / CGFloat(image.width), canvasH / CGFloat(image.height)) * placement.zoom
            let drawW = CGFloat(image.width) * fill
            let drawH = CGFloat(image.height) * fill
            // Core Graphics は左下原点なので、画面上の「下へ」は y のマイナス方向。
            let x = (canvasW - drawW) / 2 + placement.offsetX * canvasW
            let y = (canvasH - drawH) / 2 - placement.offsetY * canvasH
            context.draw(image, in: CGRect(x: x, y: y, width: drawW, height: drawH))
        }
        return pixels
    }

    /// 色番号の配列を、確認用の画像にする。
    static func preview(indices: [UInt8], width: Int, height: Int) -> UIImage? {
        // 実物の電子ペーパーに近い、少しくすんだ色で表示する。
        let display: [(UInt8, UInt8, UInt8)] = [(34, 32, 36), (232, 232, 226), (236, 200, 30), (190, 44, 40)]
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<min(indices.count, width * height) {
            let color = display[Int(indices[i]) % display.count]
            pixels[i * 4] = color.0
            pixels[i * 4 + 1] = color.1
            pixels[i * 4 + 2] = color.2
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }
        return UIImage(cgImage: image)
    }

    /// 写真 → 色番号。
    static func indices(from image: CGImage, layout: PanelLayout, placement: Placement, adjustments: ImageAdjustments) -> [UInt8] {
        let width = layout.portraitWidth
        let height = layout.portraitHeight
        let pixels = rgba(from: image, width: width, height: height, placement: placement)
        return Dither.quantize(
            rgba: pixels,
            width: width,
            height: height,
            palette: Palette.colors(for: layout.colorMode),
            adjustments: adjustments
        )
    }

    /// 向き合わせ用のテスト画像。上下左右が分かるよう、四隅の色と文字を非対称にしてある。
    static func testPatternIndices(layout: PanelLayout) -> [UInt8] {
        let width = layout.portraitWidth
        let height = layout.portraitHeight
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        let black = UIColor.black
        let white = UIColor.white
        let yellow = UIColor(red: 1, green: 225.0 / 255, blue: 0, alpha: 1)
        let red = UIColor(red: 205.0 / 255, green: 20.0 / 255, blue: 20.0 / 255, alpha: 1)

        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            cg.setShouldAntialias(false)
            white.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let w = size.width
            let h = size.height
            let corner = (w * 0.22).rounded()

            // 四隅: 左上=黒 / 右上=赤 / 左下=黄 / 右下=白地に黒枠
            black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: corner, height: corner))
            red.setFill()
            context.fill(CGRect(x: w - corner, y: 0, width: corner, height: corner))
            yellow.setFill()
            context.fill(CGRect(x: 0, y: h - corner, width: corner, height: corner))
            black.setStroke()
            cg.setLineWidth(4)
            cg.stroke(CGRect(x: w - corner + 2, y: h - corner + 2, width: corner - 4, height: corner - 4))

            // 外枠
            cg.setLineWidth(2)
            cg.stroke(CGRect(x: 1, y: 1, width: w - 2, height: h - 2))

            // 中央の色帯
            let bandTop = (h * 0.42).rounded()
            let bandHeight = (h * 0.12).rounded()
            let colors = [black, white, yellow, red]
            let bandWidth = ((w - 40) / CGFloat(colors.count)).rounded(.down)
            for (index, color) in colors.enumerated() {
                color.setFill()
                context.fill(CGRect(x: 20 + CGFloat(index) * bandWidth, y: bandTop, width: bandWidth, height: bandHeight))
            }
            cg.setLineWidth(2)
            cg.stroke(CGRect(x: 20, y: bandTop, width: bandWidth * CGFloat(colors.count), height: bandHeight))

            // 上向きの矢印
            let centerX = w / 2
            let arrowTop = h * 0.20
            cg.setFillColor(red.cgColor)
            cg.move(to: CGPoint(x: centerX, y: arrowTop))
            cg.addLine(to: CGPoint(x: centerX - w * 0.14, y: arrowTop + h * 0.08))
            cg.addLine(to: CGPoint(x: centerX + w * 0.14, y: arrowTop + h * 0.08))
            cg.closePath()
            cg.fillPath()
            cg.fill(CGRect(x: centerX - w * 0.04, y: arrowTop + h * 0.08, width: w * 0.08, height: h * 0.08))

            cg.setShouldAntialias(true)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let title: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: w * 0.13, weight: .heavy),
                .foregroundColor: black,
                .paragraphStyle: paragraph
            ]
            ("上 TOP" as NSString).draw(in: CGRect(x: 0, y: h * 0.07, width: w, height: w * 0.18), withAttributes: title)
            let body: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: w * 0.075, weight: .bold),
                .foregroundColor: black,
                .paragraphStyle: paragraph
            ]
            ("左上が黒・右上が赤\n左下が黄なら正しい向き" as NSString)
                .draw(in: CGRect(x: 10, y: h * 0.60, width: w - 20, height: h * 0.2), withAttributes: body)
            ("\(width)×\(height)" as NSString)
                .draw(in: CGRect(x: 0, y: h * 0.80, width: w, height: h * 0.08), withAttributes: body)
        }

        guard let cgImage = image.cgImage else {
            return [UInt8](repeating: 1, count: width * height)
        }
        var adjustments = ImageAdjustments()
        adjustments.brightness = 0
        adjustments.contrast = 1
        adjustments.saturation = 1
        adjustments.method = .none
        return indices(from: cgImage, layout: layout, placement: Placement(), adjustments: adjustments)
    }
}
