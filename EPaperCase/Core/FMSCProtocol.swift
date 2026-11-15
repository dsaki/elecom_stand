import Foundation

/// 復旦微電子 (FMSC) 系の無電源 NFC 電子ペーパー基板で使われている APDU。
///
/// 参考にした公開情報（いずれも同系統の別製品の解析結果）:
/// - https://gist.github.com/niw/3885b22d502bb1e145984d41568f202d
/// - https://github.com/solar2ain/ink-nfc-fmsc-by-pn532 (docs/protocol.md)
///
/// このアプリは「画像スロットへの書き込み (D2/D3)」と「保存済みドライバでの再描画 (D4)」だけを使い、
/// 基板内のパネル設定を書き換えるコマンド (DA / DB) は一切送らない。
enum FMSC {
    static let blockSize = 2000
    static let packetStride = 250

    /// 基板情報 (TLV) の読み出し
    static let readInfo = Data([0x00, 0xD1, 0x00, 0x00, 0x00])
    /// アクセス権の確認。6985 なら PIN が必要。
    static let checkAccess = Data([0xF0, 0xD8, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x0E])
    /// 描画中かどうか。応答 01=描画中 / 00=待機中
    static let busyStatus = Data([0xF0, 0xDE, 0x00, 0x00, 0x01])

    static func verifyPIN(_ pin: Data) -> Data {
        Data([0x00, 0x20, 0x00, 0x01, UInt8(pin.count)]) + pin
    }

    /// 保存済みの画像を画面に反映する。
    /// - Parameters:
    ///   - blocking: P2。true (0x00) なら基板が応答を保留する（どこまで待つかは基板による）。
    ///   - skipDetection: P1 の最上位ビット。下位は電源投入の待ち時間（100ms 単位、ここでは 5）。
    static func refresh(blocking: Bool, skipDetection: Bool = true) -> Data {
        let p1: UInt8 = skipDetection ? 0x85 : 0x05
        let p2: UInt8 = blocking ? 0x00 : 0x80
        return Data([0xF0, 0xD4, p1, p2, 0x00])
    }

    /// 再開の単位。1ブロック分のパケットは必ず続けて送る。
    struct UploadBlock: Equatable {
        var packets: [Data]
    }

    enum EncodeError: Error, Equatable {
        case frameTooLarge
        case roundTripFailed(block: Int)
    }

    /// D3: 2000バイトごとに LZO 圧縮し、250バイトずつ送る。
    static func compressedUpload(frame: Data, slot: UInt8 = 0) throws -> [UploadBlock] {
        guard !frame.isEmpty, frame.count <= blockSize * 256 else { throw EncodeError.frameTooLarge }
        let bytes = [UInt8](frame)
        var blocks: [UploadBlock] = []
        var blockIndex = 0
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + blockSize, bytes.count)
            let part = Data(bytes[offset..<end])
            let stream = LZO1X.compress(part)
            // 壊れたデータを基板に送らないよう、送信前に必ず展開して照合する。
            guard let restored = try? LZO1X.decompress(stream), restored == part else {
                throw EncodeError.roundTripFailed(block: blockIndex)
            }
            let streamBytes = [UInt8](stream)
            var packets: [Data] = []
            var sub = 0
            var start = 0
            while start < streamBytes.count {
                let stop = min(start + packetStride, streamBytes.count)
                let isLast = stop == streamBytes.count
                var packet = Data([0xF0, 0xD3, slot, isLast ? 0x01 : 0x00, UInt8(stop - start + 2), UInt8(blockIndex), UInt8(sub)])
                packet.append(contentsOf: streamBytes[start..<stop])
                packets.append(packet)
                sub += 1
                start = stop
            }
            blocks.append(UploadBlock(packets: packets))
            blockIndex += 1
            offset = end
        }
        return blocks
    }

    /// D2: 無圧縮で 250 バイトずつ送る（圧縮非対応の基板用。64000 バイトまで）。
    static func rawUpload(frame: Data, slot: UInt8 = 0) throws -> [UploadBlock] {
        guard !frame.isEmpty, frame.count <= packetStride * 256 else { throw EncodeError.frameTooLarge }
        let bytes = [UInt8](frame)
        var blocks: [UploadBlock] = []
        var index = 0
        var start = 0
        while start < bytes.count {
            let stop = min(start + packetStride, bytes.count)
            var packet = Data([0xF0, 0xD2, slot, UInt8(index), UInt8(stop - start)])
            packet.append(contentsOf: bytes[start..<stop])
            blocks.append(UploadBlock(packets: [packet]))
            index += 1
            start = stop
        }
        return blocks
    }

    static func statusMessage(_ sw: UInt16) -> String {
        switch sw {
        case 0x9000: return "成功"
        case 0x6454: return "画面の更新に失敗"
        case 0x6455, 0x68C6, 0x6986: return "パネルのリセットに失敗（パネルが応答しません）"
        case 0x6502: return "電力不足で書き込みが中断"
        case 0x650F, 0x6982: return "実行権限がありません"
        case 0x6700: return "データ長の誤り"
        case 0x68CA, 0x698A: return "電力不足（スマホとケースの位置を合わせ直してください）"
        case 0x68CB: return "画面更新のタイムアウト"
        case 0x6985: return "使用条件を満たしていません（PIN が必要な可能性）"
        case 0x6991: return "圧縮機能が初期化されていません"
        case 0x6992: return "展開に失敗"
        case 0x6993: return "展開後の長さが不正"
        case 0x6994: return "圧縮データの長さが不正"
        case 0x6995: return "パケットの順番が不正"
        case 0x6A80: return "データが不正"
        case 0x6A82: return "アプリケーションが見つかりません"
        case 0x6A86: return "パラメータ (P1/P2) が不正"
        case 0x6A96: return "画像スロット番号が不正"
        case 0x6D00: return "未対応のコマンド（このアプリが想定する方式ではない可能性）"
        case 0x6E00: return "未対応のコマンドクラス（このアプリが想定する方式ではない可能性）"
        default: return "不明なステータス"
        }
    }
}
