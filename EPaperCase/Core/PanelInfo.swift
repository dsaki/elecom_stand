import Foundation

/// 「00 D1 00 00 00」(基板情報の読み出し) の応答 TLV。
///
/// 既知のタグ:
/// - A0 (7バイト): パネル形状。[1]=色種別, [3...4]=1ライン方向のビット数, [5...6]=もう一方の画素数
/// - A1 (7バイト): スキャン設定。[0]=0:縦スキャン / 1:横スキャン
/// - B1: 画像スロット数
/// - C0: APPID もしくは機種名
/// - C1: UID
/// - D1: [0]=1 なら圧縮転送 (D3) に対応
struct PanelInfo: Equatable {
    var tags: [UInt8] = []
    var fields: [UInt8: Data] = [:]

    init(tlv: Data) {
        let bytes = [UInt8](tlv)
        var offset = 0
        while offset + 2 <= bytes.count {
            let tag = bytes[offset]
            let length = Int(bytes[offset + 1])
            offset += 2
            guard offset + length <= bytes.count else { break }
            if fields[tag] == nil {
                tags.append(tag)
                fields[tag] = Data(bytes[offset..<offset + length])
            }
            offset += length
        }
    }

    private func bytes(_ tag: UInt8, count: Int) -> [UInt8]? {
        guard let data = fields[tag], data.count == count else { return nil }
        return [UInt8](data)
    }

    var colorCode: UInt8? { bytes(0xA0, count: 7)?[1] }

    /// A0[3...4]: 1ライン方向のビット数（= 画素数 × 1画素あたりのビット数）。
    var bitDimension: Int? {
        guard let b = bytes(0xA0, count: 7) else { return nil }
        return (Int(b[3]) << 8) | Int(b[4])
    }

    /// A0[5...6]
    var pixelDimension: Int? {
        guard let b = bytes(0xA0, count: 7) else { return nil }
        return (Int(b[5]) << 8) | Int(b[6])
    }

    var scanByte: UInt8? { fields[0xA1]?.first }
    var slotCount: Int? { fields[0xB1]?.first.map(Int.init) }
    var uid: Data? { fields[0xC1] }
    var supportsCompression: Bool? { fields[0xD1]?.first.map { $0 == 1 } }

    /// ログ・診断表示用。
    var dump: String {
        tags.map { String(format: "%02X=", $0) + (fields[$0]?.hexString ?? "") }.joined(separator: " ")
    }
}

enum ScanMode: String, Codable, CaseIterable {
    /// データの1ライン = パネルの縦1列
    case vertical
    /// データの1ライン = パネルの横1行
    case horizontal
}

enum ColorMode: String, Codable, CaseIterable {
    case blackWhite
    case fourColor

    var bitsPerPixel: Int { self == .fourColor ? 2 : 1 }
    var colorCount: Int { self == .fourColor ? 4 : 2 }
}

/// ユーザーが設定画面で上書きできる項目。
struct LayoutOverrides: Equatable, Codable {
    var colorMode: ColorMode?
    var scanMode: ScanMode?
    var flipHorizontal = false
    var flipVertical = false
}

/// 画像データの並び方。
struct PanelLayout: Equatable, Codable {
    var colorMode: ColorMode
    /// パネル本来の向きでの幅・高さ（画素）
    var nativeWidth: Int
    var nativeHeight: Int
    var scanMode: ScanMode

    /// エレコム PM-A24AEINK01 / PM-A25AEINK01 の公称値（480×800・4色）。
    /// ケースから情報を読み取るまでのプレビュー用。
    static let nominal = PanelLayout(colorMode: .fourColor, nativeWidth: 480, nativeHeight: 800, scanMode: .vertical)

    var lineCount: Int { scanMode == .vertical ? nativeWidth : nativeHeight }
    var pixelsPerLine: Int { scanMode == .vertical ? nativeHeight : nativeWidth }
    var bytesPerLine: Int { (pixelsPerLine * colorMode.bitsPerPixel + 7) / 8 }
    var frameByteCount: Int { lineCount * bytesPerLine }

    /// ケースを縦に持ったときの見た目のサイズ。
    var portraitWidth: Int { min(nativeWidth, nativeHeight) }
    var portraitHeight: Int { max(nativeWidth, nativeHeight) }

    var summary: String {
        "\(nativeWidth)×\(nativeHeight) \(colorMode == .fourColor ? "4色" : "白黒") \(scanMode == .vertical ? "縦" : "横")スキャン"
    }

    enum LayoutError: Error, Equatable {
        case missingGeometry
        case implausible(String)
    }

    /// D1 応答からレイアウトを決める。
    init(info: PanelInfo, overrides: LayoutOverrides = LayoutOverrides()) throws {
        guard let bits = info.bitDimension, let pixels = info.pixelDimension else {
            throw LayoutError.missingGeometry
        }

        let color: ColorMode
        if let forced = overrides.colorMode {
            color = forced
        } else {
            switch info.colorCode {
            case 0x07, 0xC7:
                color = .fourColor
            case 0x01, 0x47:
                color = .blackWhite
            default:
                // 未知の色コード。この製品は4色パネルなので4色として扱う。
                color = .fourColor
            }
        }

        let scan: ScanMode
        if let forced = overrides.scanMode {
            scan = forced
        } else {
            scan = info.scanByte == 0x01 ? .horizontal : .vertical
        }

        guard bits % color.bitsPerPixel == 0 else {
            throw LayoutError.implausible("A0 のビット数 \(bits) が色数と合いません")
        }
        self.init(colorMode: color, nativeWidth: pixels, nativeHeight: bits / color.bitsPerPixel, scanMode: scan)

        guard (8...2048).contains(nativeWidth), (8...2048).contains(nativeHeight) else {
            throw LayoutError.implausible("パネルサイズ \(nativeWidth)×\(nativeHeight) が想定外です")
        }
        guard (pixelsPerLine * color.bitsPerPixel) % 8 == 0 else {
            throw LayoutError.implausible("1ラインのビット数が8の倍数ではありません")
        }
        guard frameByteCount <= 256 * 2000 else {
            throw LayoutError.implausible("画像データが大きすぎます (\(frameByteCount) バイト)")
        }
    }

    init(colorMode: ColorMode, nativeWidth: Int, nativeHeight: Int, scanMode: ScanMode) {
        self.colorMode = colorMode
        self.nativeWidth = nativeWidth
        self.nativeHeight = nativeHeight
        self.scanMode = scanMode
    }
}
