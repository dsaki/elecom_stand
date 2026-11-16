import XCTest
@testable import EPaperCore

final class LZOTests: XCTestCase {
    private func roundTrip(_ bytes: [UInt8], file: StaticString = #filePath, line: UInt = #line) throws {
        let source = Data(bytes)
        let packed = LZO1X.compress(source)
        XCTAssertEqual(try LZO1X.decompress(packed), source, file: file, line: line)
    }

    func testEmptyAndTiny() throws {
        try roundTrip([])
        try roundTrip([0x42])
        try roundTrip([1, 2, 3])
        try roundTrip([1, 2, 3, 4])
    }

    func testUniformBlockCompressesWell() throws {
        let block = [UInt8](repeating: 0x55, count: 2000)
        try roundTrip(block)
        XCTAssertLessThan(LZO1X.compress(Data(block)).count, 64)
    }

    func testKnownLiteralStream() throws {
        // 一致のない短い入力は「17+長さ, 本体, 終端」になる。
        XCTAssertEqual(LZO1X.compress(Data([1, 2, 3, 4, 5])), Data([22, 1, 2, 3, 4, 5, 0x11, 0, 0]))
        XCTAssertEqual(try LZO1X.decompress(Data([22, 1, 2, 3, 4, 5, 0x11, 0, 0])), Data([1, 2, 3, 4, 5]))
    }

    func testPseudoRandomAndPatternedBlocks() throws {
        var state: UInt64 = 0x1234_5678_9ABC_DEF0
        func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        for round in 0..<200 {
            let length = 1 + Int(next() % 2000)
            var bytes = [UInt8]()
            bytes.reserveCapacity(length)
            switch round % 4 {
            case 0:
                // ほぼ乱数（圧縮できない）
                for _ in 0..<length { bytes.append(UInt8(truncatingIfNeeded: next())) }
            case 1:
                // ディザ画像に近い、少ない種類の値
                let choices: [UInt8] = [0x00, 0x55, 0xAA, 0xFF, 0x5A, 0x96]
                for _ in 0..<length { bytes.append(choices[Int(next() % UInt64(choices.count))]) }
            case 2:
                // 長い繰り返しと短い乱れ
                while bytes.count < length {
                    let run = 1 + Int(next() % 700)
                    let value = UInt8(truncatingIfNeeded: next())
                    bytes.append(contentsOf: [UInt8](repeating: value, count: min(run, length - bytes.count)))
                    if bytes.count < length { bytes.append(UInt8(truncatingIfNeeded: next())) }
                }
            default:
                // 周期パターン（遠い位置との一致）
                let period = 2 + Int(next() % 1500)
                let seed = (0..<period).map { _ in UInt8(truncatingIfNeeded: next()) }
                for i in 0..<length { bytes.append(seed[i % period]) }
            }
            try roundTrip(bytes)
        }
    }
}

final class PanelInfoTests: XCTestCase {
    func testParsesHuaweiStyleInfo() throws {
        let tlv = Data(hex: "A007F0C72006000228 A10700120030FFFFFF B10101 C00400000001 C10404A1B2C3 D10701000000000000")!
        let info = PanelInfo(tlv: tlv)
        XCTAssertEqual(info.tags, [0xA0, 0xA1, 0xB1, 0xC0, 0xC1, 0xD1])
        XCTAssertEqual(info.bitDimension, 1536)
        XCTAssertEqual(info.pixelDimension, 552)
        XCTAssertEqual(info.uid, Data(hex: "04A1B2C3"))
        XCTAssertEqual(info.supportsCompression, true)

        let layout = try PanelLayout(info: info)
        XCTAssertEqual(layout.colorMode, .fourColor)
        XCTAssertEqual(layout.nativeWidth, 552)
        XCTAssertEqual(layout.nativeHeight, 768)
        XCTAssertEqual(layout.scanMode, .vertical)
        XCTAssertEqual(layout.frameByteCount, 105_984)
    }

    func testExpectedElecomGeometry() throws {
        // 480×800・4色なら A0 は「1600ビット × 480」になるはず。
        let info = PanelInfo(tlv: Data(hex: "A0070007000640 01E0 A10701000000000000")!)
        let layout = try PanelLayout(info: info)
        XCTAssertEqual(layout.nativeWidth, 480)
        XCTAssertEqual(layout.nativeHeight, 800)
        XCTAssertEqual(layout.scanMode, .horizontal)
        XCTAssertEqual(layout.frameByteCount, 96_000)
        XCTAssertEqual(PanelLayout.nominal.frameByteCount, 96_000)
    }

    func testOverridesAndErrors() throws {
        let info = PanelInfo(tlv: Data(hex: "A00700010001900130 A10701000000000000")!)
        let bw = try PanelLayout(info: info)
        XCTAssertEqual(bw.colorMode, .blackWhite)
        XCTAssertEqual([bw.nativeWidth, bw.nativeHeight], [304, 400])

        var overrides = LayoutOverrides()
        overrides.colorMode = .fourColor
        overrides.scanMode = .vertical
        let forced = try PanelLayout(info: info, overrides: overrides)
        XCTAssertEqual([forced.nativeWidth, forced.nativeHeight], [304, 200])
        XCTAssertEqual(forced.scanMode, .vertical)

        // 1ラインが8ビット境界に揃わない形状は、誤った解釈の可能性が高いので受け付けない
        XCTAssertThrowsError(try PanelLayout(info: PanelInfo(tlv: Data(hex: "A0070001000190012C A10701000000000000")!)))

        XCTAssertThrowsError(try PanelLayout(info: PanelInfo(tlv: Data(hex: "C10401020304")!))) { error in
            XCTAssertEqual(error as? PanelLayout.LayoutError, .missingGeometry)
        }
        // 途中で切れた TLV は読めたところまでを使う
        XCTAssertEqual(PanelInfo(tlv: Data(hex: "C1020102 A007F0")!).tags, [0xC1])
    }
}

final class FramePackerTests: XCTestCase {
    func testHorizontalScanIsRowsRightToLeft() {
        // 8×8, 4色。左上だけ赤(3)、右上だけ黄(2)、ほかは白(1)。
        let layout = PanelLayout(colorMode: .fourColor, nativeWidth: 8, nativeHeight: 8, scanMode: .horizontal)
        var image = [UInt8](repeating: 1, count: 64)
        image[0] = 3
        image[7] = 2
        let frame = [UInt8](FramePacker.pack(portrait: image, layout: layout))
        XCTAssertEqual(frame.count, 16)
        // 1行目: 右端(黄)が先頭の上位2ビット、左端(赤)が2バイト目の下位2ビット
        XCTAssertEqual(frame[0], 0b10_01_01_01)
        XCTAssertEqual(frame[1], 0b01_01_01_11)
        XCTAssertEqual(frame[2], 0x55)
    }

    func testVerticalScanIsColumnsTopToBottom() {
        let layout = PanelLayout(colorMode: .fourColor, nativeWidth: 8, nativeHeight: 8, scanMode: .vertical)
        var image = [UInt8](repeating: 1, count: 64)
        image[0] = 3          // 左上
        image[7 * 8] = 0      // 左下
        image[7] = 2          // 右上
        let frame = [UInt8](FramePacker.pack(portrait: image, layout: layout))
        XCTAssertEqual(frame[0], 0b11_01_01_01)   // 1列目の上端
        XCTAssertEqual(frame[1], 0b01_01_01_00)   // 1列目の下端
        XCTAssertEqual(frame[14], 0b10_01_01_01)  // 最終列の上端
    }

    func testFlipsAndLandscapeNative() {
        var image = [UInt8](repeating: 1, count: 8 * 16)
        image[0] = 3 // 縦持ちで左上

        // 縦長パネル + 左右反転: 左上の赤は右上に移る
        let portrait = PanelLayout(colorMode: .fourColor, nativeWidth: 8, nativeHeight: 16, scanMode: .vertical)
        let flipped = [UInt8](FramePacker.pack(portrait: image, layout: portrait, flipHorizontal: true))
        XCTAssertEqual(flipped.count, 32)
        XCTAssertEqual(flipped[7 * 4], 0b11_01_01_01)
        XCTAssertEqual(flipped[0], 0x55)

        // 横長パネル: 縦持ちの左上は、時計回り90°でパネルの右上に来る
        let landscape = PanelLayout(colorMode: .fourColor, nativeWidth: 16, nativeHeight: 8, scanMode: .horizontal)
        let rotated = [UInt8](FramePacker.pack(portrait: image, layout: landscape))
        XCTAssertEqual(rotated.count, 32)
        XCTAssertEqual(rotated[0], 0b11_01_01_01)
        XCTAssertEqual(rotated.filter { $0 != 0x55 }.count, 1)
    }

    func testBlackWhitePacksEightPixelsPerByte() {
        let layout = PanelLayout(colorMode: .blackWhite, nativeWidth: 8, nativeHeight: 8, scanMode: .vertical)
        var image = [UInt8](repeating: 1, count: 64)
        image[0] = 0
        let frame = [UInt8](FramePacker.pack(portrait: image, layout: layout))
        XCTAssertEqual(frame.count, 8)
        XCTAssertEqual(frame[0], 0b0111_1111)
        XCTAssertEqual(frame[1], 0xFF)
    }
}

final class DitherTests: XCTestCase {
    func testPureColorsMapToTheirIndex() {
        let rgba: [UInt8] = [
            0, 0, 0, 255,
            255, 255, 255, 255,
            255, 225, 0, 255,
            205, 20, 20, 255
        ]
        var adjustments = ImageAdjustments()
        adjustments.contrast = 1
        adjustments.saturation = 1
        for method in DitherMethod.allCases {
            adjustments.method = method
            let out = Dither.quantize(rgba: rgba, width: 2, height: 2, palette: Palette.fourColor, adjustments: adjustments)
            XCTAssertEqual(out, [0, 1, 2, 3], "\(method)")
        }
    }

    func testMidGrayDithersToBlackAndWhiteMix() {
        let width = 32
        let height = 32
        var rgba = [UInt8]()
        for _ in 0..<(width * height) { rgba.append(contentsOf: [128, 128, 128, 255]) }
        var adjustments = ImageAdjustments()
        adjustments.contrast = 1
        adjustments.saturation = 1
        let out = Dither.quantize(rgba: rgba, width: width, height: height, palette: Palette.fourColor, adjustments: adjustments)
        let black = out.filter { $0 == 0 }.count
        let white = out.filter { $0 == 1 }.count
        XCTAssertEqual(black + white, out.count)
        XCTAssertGreaterThan(black, out.count / 3)
        XCTAssertGreaterThan(white, out.count / 3)
    }
}

final class UploadEncodingTests: XCTestCase {
    func testCompressedUploadFraming() throws {
        var state: UInt32 = 7
        let frame = Data((0..<4500).map { _ -> UInt8 in
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: state >> 24)
        })
        let blocks = try FMSC.compressedUpload(frame: frame)
        XCTAssertEqual(blocks.count, 3)

        var restored = Data()
        for (blockIndex, block) in blocks.enumerated() {
            var stream = Data()
            for (sub, packet) in block.packets.enumerated() {
                let bytes = [UInt8](packet)
                XCTAssertEqual(Array(bytes[0...2]), [0xF0, 0xD3, 0x00])
                XCTAssertEqual(bytes[3], sub == block.packets.count - 1 ? 1 : 0)
                XCTAssertEqual(Int(bytes[4]), bytes.count - 5)
                XCTAssertEqual(Int(bytes[5]), blockIndex)
                XCTAssertEqual(Int(bytes[6]), sub)
                XCTAssertLessThanOrEqual(bytes.count - 7, 250)
                stream.append(contentsOf: bytes[7...])
            }
            restored.append(try LZO1X.decompress(stream))
        }
        XCTAssertEqual(restored, frame)
    }

    func testRawUploadFraming() throws {
        let frame = Data([UInt8](repeating: 0xAB, count: 600))
        let blocks = try FMSC.rawUpload(frame: frame)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual([UInt8](blocks[2].packets[0].prefix(5)), [0xF0, 0xD2, 0x00, 0x02, 100])
        XCTAssertThrowsError(try FMSC.rawUpload(frame: Data(count: 64_001)))
    }

    func testFixedCommands() {
        XCTAssertEqual(FMSC.refresh(blocking: true).hexString, "F0D4850000")
        XCTAssertEqual(FMSC.refresh(blocking: false).hexString, "F0D4858000")
        XCTAssertEqual(FMSC.refresh(blocking: true, skipDetection: false).hexString, "F0D4050000")
        XCTAssertEqual(FMSC.refresh(blocking: true, powerOnDelayTenths: 20).hexString, "F0D4940000")
        XCTAssertEqual(FMSC.refresh(blocking: true, powerOnDelayTenths: 999).hexString, "F0D4FF0000")
        XCTAssertEqual(FMSC.verifyPIN(Data([1, 2, 3, 4, 5])).hexString, "00200001050102030405")
        XCTAssertEqual(FMSC.checkAccess.hexString, "F0D8000005000000000E")
    }
}

/// 基板のふりをするモック。
private final class MockBoard: APDUTransport {
    var infoTLV = Data(hex: "A0070007000040 0010 A10700000000000000 C10401020304 D10701000000000000")!
    var pinRequired = false
    var authenticated = false
    var acceptedPIN = Data([0x52, 0x65, 0x69, 0x99, 0x19])
    var refreshStatus: UInt16 = 0x9000
    var busyPolls = 2
    var sent: [Data] = []
    var streams: [Int: Data] = [:]
    var completedBlocks: [Int: Data] = [:]
    var refreshCount = 0
    var onSend: ((Data) -> Void)?
    /// この回数目の状態確認で、接続切れ（例外）を起こす
    var dropOnBusyPoll: Int?
    var busyPollCount = 0
    struct Dropped: Error {}

    func send(_ apdu: Data) async throws -> APDUResponse {
        sent.append(apdu)
        onSend?(apdu)
        let b = [UInt8](apdu)
        switch (b[0], b[1]) {
        case (0x00, 0xD1):
            return APDUResponse(data: infoTLV, sw: 0x9000)
        case (0xF0, 0xD8):
            return APDUResponse(data: Data(), sw: pinRequired && !authenticated ? 0x6985 : 0x9000)
        case (0x00, 0x20):
            authenticated = Data(b[5...]) == acceptedPIN
            return APDUResponse(data: Data(), sw: authenticated ? 0x9000 : 0x63C2)
        case (0xF0, 0xD3):
            let block = Int(b[5])
            if b[6] == 0 { streams[block] = Data() }
            streams[block, default: Data()].append(contentsOf: b[7...])
            if b[3] == 1 {
                guard let data = try? LZO1X.decompress(streams[block]!) else {
                    return APDUResponse(data: Data(), sw: 0x6992)
                }
                completedBlocks[block] = data
            }
            return APDUResponse(data: Data(), sw: 0x9000)
        case (0xF0, 0xD4):
            refreshCount += 1
            return APDUResponse(data: Data(), sw: refreshStatus)
        case (0xF0, 0xDE):
            busyPollCount += 1
            if busyPollCount == dropOnBusyPoll { throw Dropped() }
            if busyPolls > 0 {
                busyPolls -= 1
                return APDUResponse(data: Data([0x01]), sw: 0x9000)
            }
            return APDUResponse(data: Data([0x00]), sw: 0x9000)
        default:
            return APDUResponse(data: Data(), sw: 0x6D00)
        }
    }

    /// 受け取ったブロックをつなげた画像データ
    var storedFrame: Data {
        completedBlocks.keys.sorted().reduce(into: Data()) { $0.append(completedBlocks[$1]!) }
    }
}

final class WriteJobTests: XCTestCase {
    private func fastOptions() -> WriteOptions {
        var options = WriteOptions()
        options.chargeSeconds = 0
        return options
    }

    // モックの A0 は「64ビット(=32画素) × 16」の4色・縦スキャン → 16×32 画素
    private func checkerImage(_ layout: PanelLayout) -> [UInt8] {
        let count = layout.portraitWidth * layout.portraitHeight
        var image = [UInt8]()
        image.reserveCapacity(count)
        for i in 0..<count {
            let value: Int = (i * 7 + i / 5) % 4
            image.append(UInt8(value))
        }
        return image
    }

    func testWriteUploadsFrameThenRefreshes() async throws {
        let board = MockBoard()
        var seenLayout: PanelLayout?
        let job = WriteJob(kind: .write, options: fastOptions()) { layout in
            seenLayout = layout
            return self.checkerImage(layout)
        }
        let start = Date()
        let outcome = try await job.run(transport: board, connectedAt: start, sessionStartedAt: start) { _ in }
        XCTAssertEqual(outcome, .finished)
        XCTAssertEqual(seenLayout?.portraitWidth, 16)
        XCTAssertEqual(seenLayout?.portraitHeight, 32)
        let expected = FramePacker.pack(portrait: checkerImage(seenLayout!), layout: seenLayout!)
        XCTAssertEqual(board.storedFrame, expected)
        XCTAssertEqual(board.refreshCount, 1)
        XCTAssertTrue(board.sent.contains { $0.hexString == "F0D4850000" })
        // D4 の後も、描画が終わるまで状態確認を続けて給電を保つ
        XCTAssertEqual(board.sent.suffix(4).map { $0.hexString }, [String](repeating: "F0DE000001", count: 4))
        // パネル設定を書き換えるコマンド (DA/DB) は絶対に送らない
        XCTAssertFalse(board.sent.contains { $0[0] == 0xF0 && ($0[1] == 0xDA || $0[1] == 0xDB) })
    }

    func testReconnectsAndResumesWithoutResendingFinishedBlocks() async throws {
        let board = MockBoard()
        // 96×800 相当まで大きくして複数ブロックにする: 1600ビット × 96
        board.infoTLV = Data(hex: "A0070007000640 0060 A10700000000000000 C10401020304 D10701000000000000")!
        var clock = Date(timeIntervalSince1970: 1_000)
        let job = WriteJob(kind: .write, options: fastOptions()) { layout in
            var state: UInt32 = 99
            return (0..<(layout.portraitWidth * layout.portraitHeight)).map { _ -> UInt8 in
                state = state &* 1_664_525 &+ 1_013_904_223
                return UInt8((state >> 24) % 4)
            }
        }
        job.now = { clock }
        // 画像パケット1つにつき1秒かかることにする
        board.onSend = { apdu in
            if apdu[1] == 0xD3 { clock += 1 }
        }

        var outcomes: [WriteJob.Outcome] = []
        var sessionStart = clock
        var guardCount = 0
        while true {
            guardCount += 1
            XCTAssertLessThan(guardCount, 200)
            let outcome = try await job.run(transport: board, connectedAt: clock, sessionStartedAt: sessionStart) { _ in }
            outcomes.append(outcome)
            if outcome == .finished { break }
            if outcome == .newSession { sessionStart = clock }
        }
        XCTAssertTrue(outcomes.contains(.reconnect))
        XCTAssertTrue(outcomes.contains(.newSession))
        XCTAssertEqual(board.refreshCount, 1)
        XCTAssertEqual(board.storedFrame.count, 96 * 800 / 4)

        // 各パケットは一度しか送られていない
        let imagePackets = board.sent.filter { $0[1] == 0xD3 }
        XCTAssertEqual(Set(imagePackets).count, imagePackets.count)
        XCTAssertEqual(imagePackets.count, job.blocks.reduce(0) { $0 + $1.packets.count })
    }

    func testPINIsOnlySentWhenConfigured() async throws {
        let board = MockBoard()
        board.pinRequired = true
        let start = Date()

        let refused = WriteJob(kind: .write, options: fastOptions()) { self.checkerImage($0) }
        do {
            _ = try await refused.run(transport: board, connectedAt: start, sessionStartedAt: start) { _ in }
            XCTFail("PIN 未設定なら止まるはず")
        } catch {
            XCTAssertEqual(error as? WriteError, .pinRequired)
        }
        XCTAssertFalse(board.sent.contains { $0[1] == 0x20 || $0[1] == 0xD3 || $0[1] == 0xD4 })

        var options = fastOptions()
        options.pinMode = .huawei
        let allowed = WriteJob(kind: .write, options: options) { self.checkerImage($0) }
        let outcome = try await allowed.run(transport: board, connectedAt: start, sessionStartedAt: start) { _ in }
        XCTAssertEqual(outcome, .finished)
        XCTAssertEqual(board.refreshCount, 1)
    }

    func testProbeNeverWrites() async throws {
        let board = MockBoard()
        let job = WriteJob(kind: .probe, options: fastOptions())
        let start = Date()
        let outcome = try await job.run(transport: board, connectedAt: start, sessionStartedAt: start) { _ in }
        XCTAssertEqual(outcome, .finished)
        XCTAssertEqual(board.sent.map { $0.hexString }, ["00D1000000", "F0D8000005000000000E", "F0DE000001"])
        XCTAssertEqual(job.layout?.portraitWidth, 16)
    }

    func testRefreshOnlyAndPollingMode() async throws {
        let board = MockBoard()
        var options = fastOptions()
        options.blockingRefresh = false
        let job = WriteJob(kind: .refreshOnly, options: options)
        job.sleep = { _ in }
        let start = Date()
        let outcome = try await job.run(transport: board, connectedAt: start, sessionStartedAt: start) { _ in }
        XCTAssertEqual(outcome, .finished)
        XCTAssertFalse(board.sent.contains { $0[1] == 0xD3 })
        XCTAssertTrue(board.sent.contains { $0.hexString == "F0D4858000" })
        XCTAssertEqual(board.sent.filter { $0[1] == 0xDE }.count, 4)
    }

    func testConnectionLossDuringRefreshReconnectsWithoutResendingRefresh() async throws {
        let board = MockBoard()
        board.busyPolls = 5
        board.dropOnBusyPoll = 3
        let job = WriteJob(kind: .write, options: fastOptions()) { self.checkerImage($0) }
        job.timing.maxRefreshReconnects = 1
        job.sleep = { _ in }
        let start = Date()
        let first = try await job.run(transport: board, connectedAt: start, sessionStartedAt: start) { _ in }
        XCTAssertEqual(first, .newSession)
        let second = try await job.run(transport: board, connectedAt: Date(), sessionStartedAt: start) { _ in }
        XCTAssertEqual(second, .finished)
        // 描画指示と画像は一度しか送らない
        XCTAssertEqual(board.refreshCount, 1)
        let imagePackets = board.sent.filter { $0[1] == 0xD3 }
        XCTAssertEqual(Set(imagePackets).count, imagePackets.count)
        XCTAssertEqual(job.refreshReconnects, 1)
    }

    func testReconnectsProactivelyDuringLongRefresh() async throws {
        let board = MockBoard()
        board.busyPolls = 30
        var clock = Date(timeIntervalSince1970: 5_000)
        let job = WriteJob(kind: .refreshOnly, options: fastOptions())
        job.now = { clock }
        job.timing.maxRefreshReconnects = 1
        job.sleep = { seconds in clock += 1 }
        var outcomes: [WriteJob.Outcome] = []
        while outcomes.last != .finished {
            XCTAssertLessThan(outcomes.count, 10)
            outcomes.append(try await job.run(transport: board, connectedAt: clock, sessionStartedAt: clock) { _ in })
        }
        XCTAssertEqual(outcomes, [.reconnect, .finished])
        XCTAssertEqual(board.refreshCount, 1)
    }

    func testLingersWhenConnectionDropsAfterTheOnlyReconnect() async throws {
        let board = MockBoard()
        board.busyPolls = 40
        board.dropOnBusyPoll = 20
        var clock = Date(timeIntervalSince1970: 9_000)
        let job = WriteJob(kind: .refreshOnly, options: fastOptions())
        job.now = { clock }
        job.timing.maxRefreshReconnects = 1
        job.sleep = { _ in clock += 1 }
        let sessionStart = clock
        let first = try await job.run(transport: board, connectedAt: clock, sessionStartedAt: sessionStart) { _ in }
        XCTAssertEqual(first, .reconnect)
        let second = try await job.run(transport: board, connectedAt: clock, sessionStartedAt: sessionStart) { _ in }
        XCTAssertEqual(second, .linger)
        XCTAssertTrue(job.refreshUnconfirmed)
        XCTAssertFalse(job.canResume)
        XCTAssertEqual(board.refreshCount, 1)
    }

    func testByDefaultRefreshIsNeverInterruptedByReconnecting() async throws {
        let board = MockBoard()
        board.busyPolls = 40
        board.dropOnBusyPoll = 18
        var clock = Date(timeIntervalSince1970: 7_000)
        let job = WriteJob(kind: .refreshOnly, options: fastOptions())
        job.now = { clock }
        job.sleep = { _ in clock += 1 }
        let outcome = try await job.run(transport: board, connectedAt: clock, sessionStartedAt: clock) { _ in }
        XCTAssertEqual(outcome, .linger)
        XCTAssertEqual(job.refreshReconnects, 0)
        XCTAssertEqual(board.refreshCount, 1)
    }

    func testErrorsAreReportedWithStatusWord() async throws {
        let board = MockBoard()
        board.refreshStatus = 0x68CA
        let job = WriteJob(kind: .write, options: fastOptions()) { self.checkerImage($0) }
        let start = Date()
        do {
            _ = try await job.run(transport: board, connectedAt: start, sessionStartedAt: start) { _ in }
            XCTFail("エラーになるはず")
        } catch {
            XCTAssertEqual(error as? WriteError, .status(step: "画面更新", sw: 0x68CA))
        }
        XCTAssertTrue(job.canResume)

        let other = MockBoard()
        other.infoTLV = Data(hex: "C10401020304")!
        let unsupported = WriteJob(kind: .write, options: fastOptions()) { self.checkerImage($0) }
        do {
            _ = try await unsupported.run(transport: other, connectedAt: start, sessionStartedAt: start) { _ in }
            XCTFail("エラーになるはず")
        } catch {
            guard case .notSupported = error as? WriteError else { return XCTFail("\(error)") }
        }
    }
}
