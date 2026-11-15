import Foundation

/// 色番号（0=黒, 1=白, 2=黄, 3=赤）の配列を、基板へ送るバイト列に詰める。
enum FramePacker {
    /// - Parameter portrait: ケースを縦に持ったときの見た目どおりの画像。
    ///   `layout.portraitWidth × layout.portraitHeight` 個、左上から行優先。
    static func pack(portrait: [UInt8], layout: PanelLayout, flipHorizontal: Bool = false, flipVertical: Bool = false) -> Data {
        let pw = layout.portraitWidth
        let ph = layout.portraitHeight
        precondition(portrait.count == pw * ph, "画像サイズがレイアウトと一致しません")

        let nw = layout.nativeWidth
        let nh = layout.nativeHeight
        let landscapeNative = nw > nh

        // パネル本来の座標 (x, y) の色を返す。
        func native(_ x: Int, _ y: Int) -> UInt8 {
            var px: Int
            var py: Int
            if landscapeNative {
                // 縦長画像を時計回りに90°回した向きで載っているとみなす。
                px = y
                py = ph - 1 - x
            } else {
                px = x
                py = y
            }
            if flipHorizontal { px = pw - 1 - px }
            if flipVertical { py = ph - 1 - py }
            return portrait[py * pw + px]
        }

        let bpp = layout.colorMode.bitsPerPixel
        let mask = UInt8((1 << bpp) - 1)
        var out = [UInt8]()
        out.reserveCapacity(layout.frameByteCount)

        for line in 0..<layout.lineCount {
            var acc: UInt8 = 0
            var filled = 0
            for k in 0..<layout.pixelsPerLine {
                let color: UInt8
                switch layout.scanMode {
                case .vertical:
                    // 列を左から右へ、各列は上から下へ。
                    color = native(line, k)
                case .horizontal:
                    // 行を上から下へ、各行は右から左へ。
                    color = native(nw - 1 - k, line)
                }
                acc = (acc << UInt8(bpp)) | (color & mask)
                filled += bpp
                if filled == 8 {
                    out.append(acc)
                    acc = 0
                    filled = 0
                }
            }
            if filled > 0 {
                out.append(acc << UInt8(8 - filled))
            }
        }
        return Data(out)
    }
}
