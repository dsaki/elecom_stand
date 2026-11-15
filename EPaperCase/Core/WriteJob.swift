import Foundation

struct APDUResponse: Equatable {
    var data: Data
    var sw: UInt16

    var isOK: Bool { sw == 0x9000 }
}

/// NFC タグとの1往復。実機では Core NFC、テストではモックが実装する。
protocol APDUTransport {
    func send(_ apdu: Data) async throws -> APDUResponse
}

enum PINMode: String, Codable, CaseIterable, Identifiable {
    case never
    case badge
    case huawei
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .never: return "送らない（推奨）"
        case .badge: return "既知のPIN A（名札タイプ）"
        case .huawei: return "既知のPIN B（Huawei用ケース）"
        case .custom: return "自分で入力"
        }
    }
}

struct WriteOptions: Equatable, Codable {
    var overrides = LayoutOverrides()
    var pinMode: PINMode = .never
    var customPINHex = ""
    /// true: 描画完了まで応答を待つ D4。false: 非同期 D4 + 状態ポーリング。
    var blockingRefresh = true
    /// D4 の P1 最上位ビット（検出の省略）。
    var skipDetection = true
    /// 描画指示から実際にパネルの電源を入れるまで基板に待たせる時間（100ms 単位）。
    var powerOnDelayTenths = 20
    /// タグに接続してから描画指示を送るまで、給電だけして待つ秒数。
    var chargeSeconds: Double = 2.5

    var pin: Data? {
        switch pinMode {
        case .never: return nil
        case .badge: return Data([0x20, 0x09, 0x12, 0x10])
        case .huawei: return Data([0x52, 0x65, 0x69, 0x99, 0x19])
        case .custom:
            guard let data = Data(hex: customPINHex), (1...16).contains(data.count) else { return nil }
            return data
        }
    }
}

enum WriteError: Error, Equatable {
    case status(step: String, sw: UInt16)
    case notSupported(String)
    case differentTag
    case pinRequired
    case layoutChanged
    case refreshNotConfirmed

    var message: String {
        switch self {
        case .status(let step, let sw):
            return "\(step)でエラー: \(FMSC.statusMessage(sw)) (SW=\(sw.hexString))"
        case .notSupported(let reason):
            return "このケースには対応できませんでした: \(reason)"
        case .differentTag:
            return "途中で別のケース（タグ）を検出しました"
        case .pinRequired:
            return "ケースがPIN認証を要求しています。設定の「PIN」を確認してください"
        case .layoutChanged:
            return "途中でケースの画面設定が変わりました。最初からやり直してください"
        case .refreshNotConfirmed:
            return "画面の更新完了を確認できませんでした。表示を目で確認してください"
        }
    }
}

/// 1回の操作（情報読み取り / 画像書き込み / 再描画のみ）。
///
/// iOS の Core NFC はタグとの接続を約20秒、セッション全体を60秒で打ち切るため、
/// 途中で「つなぎ直し」や「セッションの張り直し」をして続きから再開できるように
/// 進み具合をこのオブジェクトが覚えておく。
final class WriteJob {
    enum Kind: Equatable {
        case probe
        case write
        case refreshOnly
    }

    enum Outcome: Equatable {
        case finished
        /// 同じセッションのままタグに接続し直して run を呼び直す
        case reconnect
        /// NFC セッションを開き直して run を呼び直す
        case newSession
    }

    struct Progress: Equatable {
        var message: String
        var fraction: Double?
    }

    struct Timing {
        /// 接続からこの秒数を超えたら、次のブロックの前につなぎ直す
        var reconnectAfter: TimeInterval = 12
        /// セッション開始からこの秒数を超えたら、転送の途中でセッションを張り直す
        var newSessionAfterDuringUpload: TimeInterval = 42
        /// セッション開始からこの秒数を超えていたら、描画の前にセッションを張り直す
        var newSessionBeforeRefresh: TimeInterval = 25
        /// 接続からこの秒数を超えていたら、描画の前につなぎ直す
        var reconnectBeforeRefresh: TimeInterval = 6
        var pollInterval: TimeInterval = 0.4
        var pollTimeout: TimeInterval = 50
        /// 描画待ち中に接続が切れたとき、つなぎ直して待ち続ける回数の上限
        var maxRefreshReconnects = 3
    }

    let kind: Kind
    let options: WriteOptions
    var timing = Timing()
    var now: () -> Date = { Date() }
    var sleep: (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    var log: (String) -> Void = { _ in }

    /// レイアウトが分かった時点で呼ばれ、縦持ちの見た目どおりの色番号配列を返す。
    private let makeImage: ((PanelLayout) throws -> [UInt8])?

    private(set) var info: PanelInfo?
    private(set) var layout: PanelLayout?
    private(set) var blocks: [FMSC.UploadBlock] = []
    private(set) var nextBlock = 0
    private(set) var uploadDone = false
    private(set) var finished = false
    /// 描画指示 (D4) を送った時刻。送信済みなら、つなぎ直しても D4 は送り直さない。
    private(set) var refreshStartedAt: Date?
    private(set) var refreshSeenBusy = false
    private(set) var refreshReconnects = 0

    init(kind: Kind, options: WriteOptions, makeImage: ((PanelLayout) throws -> [UInt8])? = nil) {
        self.kind = kind
        self.options = options
        self.makeImage = makeImage
    }

    /// 途中まで進んでいて、続きから再開できるか。
    var canResume: Bool {
        !finished && kind != .probe && layout != nil
    }

    private func exchange(_ transport: APDUTransport, _ step: String, _ apdu: Data, logged: Bool = true) async throws -> APDUResponse {
        let response = try await transport.send(apdu)
        if logged || !response.isOK {
            let shown = apdu.count > 24 ? apdu.prefix(8).hexString + "…(\(apdu.count)B)" : apdu.hexString
            log("\(step) > \(shown) < \(response.data.prefix(64).hexString) SW=\(response.sw.hexString)")
        }
        return response
    }

    private func requireOK(_ response: APDUResponse, _ step: String) throws {
        guard response.isOK else { throw WriteError.status(step: step, sw: response.sw) }
    }

    /// タグに接続するたびに呼ぶ。
    /// - Parameters:
    ///   - connectedAt: 今回タグに接続した時刻
    ///   - sessionStartedAt: NFC セッション（読み取りシート）を開いた時刻
    func run(
        transport: APDUTransport,
        connectedAt: Date,
        sessionStartedAt: Date,
        progress: (Progress) -> Void
    ) async throws -> Outcome {
        // 1. 基板情報。つなぎ直しのたびに同じケースかどうかも確かめる。
        progress(Progress(message: "ケースの情報を読み取り中…", fraction: nil))
        let infoResponse = try await exchange(transport, "情報読み取り(D1)", FMSC.readInfo)
        guard infoResponse.isOK else {
            if [0x6D00, 0x6E00, 0x6A82, 0x6A86].contains(infoResponse.sw) {
                throw WriteError.notSupported("情報読み取りコマンドに応答しません (SW=\(infoResponse.sw.hexString))。想定と異なる通信方式のようです")
            }
            throw WriteError.status(step: "情報読み取り", sw: infoResponse.sw)
        }
        let current = PanelInfo(tlv: infoResponse.data)
        if let previous = info {
            if previous.uid != current.uid { throw WriteError.differentTag }
            if previous.fields[0xA0] != current.fields[0xA0] || previous.fields[0xA1] != current.fields[0xA1] {
                throw WriteError.layoutChanged
            }
        } else {
            info = current
            log("基板情報: \(current.dump)")
        }

        if kind == .probe {
            // 読むだけのコマンドで追加情報を集める（書き込みは一切しない）。
            _ = try await exchange(transport, "アクセス確認(D8)", FMSC.checkAccess)
            _ = try await exchange(transport, "状態確認(DE)", FMSC.busyStatus)
            if let detected = try? PanelLayout(info: current, overrides: options.overrides) {
                layout = detected
                log("判定: \(detected.summary) / データ \(detected.frameByteCount) バイト")
            } else {
                log("判定: パネル形状を読み取れませんでした")
            }
            finished = true
            return .finished
        }

        // 2. レイアウト決定と画像データの準備（初回のみ）
        if layout == nil {
            let detected: PanelLayout
            do {
                detected = try PanelLayout(info: current, overrides: options.overrides)
            } catch PanelLayout.LayoutError.missingGeometry {
                throw WriteError.notSupported("パネル形状の情報 (A0) がありません")
            } catch PanelLayout.LayoutError.implausible(let reason) {
                throw WriteError.notSupported(reason)
            }
            log("判定: \(detected.summary) / データ \(detected.frameByteCount) バイト")

            if kind == .write, let makeImage {
                progress(Progress(message: "画像を変換中…", fraction: nil))
                let portrait = try makeImage(detected)
                let frame = FramePacker.pack(
                    portrait: portrait,
                    layout: detected,
                    flipHorizontal: options.overrides.flipHorizontal,
                    flipVertical: options.overrides.flipVertical
                )
                if current.supportsCompression == false {
                    guard frame.count <= FMSC.packetStride * 256 else {
                        throw WriteError.notSupported("圧縮転送に非対応の基板で、画像が大きすぎます")
                    }
                    blocks = try FMSC.rawUpload(frame: frame)
                } else {
                    blocks = try FMSC.compressedUpload(frame: frame)
                }
                let packetCount = blocks.reduce(0) { $0 + $1.packets.count }
                log("転送計画: \(blocks.count) ブロック / \(packetCount) パケット")
            }
            layout = detected
        }

        // 3. アクセス権。認証状態はつなぎ直すと失われるので毎回確認する。
        let access = try await exchange(transport, "アクセス確認(D8)", FMSC.checkAccess, logged: nextBlock == 0)
        if access.sw == 0x6985 {
            guard let pin = options.pin else { throw WriteError.pinRequired }
            let verify = try await transport.send(FMSC.verifyPIN(pin))
            log("PIN認証 SW=\(verify.sw.hexString)")
            try requireOK(verify, "PIN認証")
            try requireOK(try await exchange(transport, "アクセス再確認(D8)", FMSC.checkAccess), "アクセス確認")
        } else if !access.isOK {
            // D8 自体に対応しない基板もあるので、ここでは止めずに先へ進む。
            log("アクセス確認は 9000 以外でしたが続行します")
        }

        // 4. 画像転送
        if kind == .write && !uploadDone {
            while nextBlock < blocks.count {
                let time = now()
                if time.timeIntervalSince(sessionStartedAt) > timing.newSessionAfterDuringUpload {
                    log("セッションの制限時間が近いので張り直します (ブロック \(nextBlock)/\(blocks.count))")
                    return .newSession
                }
                if time.timeIntervalSince(connectedAt) > timing.reconnectAfter {
                    log("接続の制限時間が近いのでつなぎ直します (ブロック \(nextBlock)/\(blocks.count))")
                    return .reconnect
                }
                progress(Progress(
                    message: "画像を転送中… \(nextBlock * 100 / blocks.count)%\nスマホとケースを動かさないでください",
                    fraction: Double(nextBlock) / Double(blocks.count)
                ))
                for packet in blocks[nextBlock].packets {
                    let response = try await exchange(transport, "画像転送 ブロック\(nextBlock)", packet, logged: false)
                    try requireOK(response, "画像転送")
                }
                nextBlock += 1
            }
            uploadDone = true
            log("画像転送が完了しました")
        }

        // 5. 画面更新。4色パネルは時間がかかるので、接続し直して持ち時間を確保する。
        let refreshMessage = "画面を更新中…（30秒ほど）\n終わるまでスマホとケースを動かさないでください"
        if refreshStartedAt == nil {
            let time = now()
            if time.timeIntervalSince(sessionStartedAt) > timing.newSessionBeforeRefresh {
                log("画面更新の前にセッションを張り直します")
                return .newSession
            }
            if time.timeIntervalSince(connectedAt) > timing.reconnectBeforeRefresh {
                log("画面更新の前につなぎ直します")
                return .reconnect
            }

            // 描画の開始時はパネルの昇圧で大きな電力を使う。接続直後に指示すると電圧が落ちて
            // 基板がリセットされるので、先に少し給電してから始める。
            let charged = now().timeIntervalSince(connectedAt)
            if charged < options.chargeSeconds {
                progress(Progress(message: "ケースに給電中…\nそのまま動かさないでください", fraction: 1))
                await sleep(options.chargeSeconds - charged)
            }

            progress(Progress(message: refreshMessage, fraction: 1))
            let command = FMSC.refresh(
                blocking: options.blockingRefresh,
                skipDetection: options.skipDetection,
                powerOnDelayTenths: options.powerOnDelayTenths
            )
            let refresh = try await exchange(transport, "画面更新(D4)", command)
            try requireOK(refresh, "画面更新")
            refreshStartedAt = now()
        } else {
            progress(Progress(message: refreshMessage, fraction: 1))
            log("描画の途中でつなぎ直しました。状態確認を続けます")
        }
        let started = refreshStartedAt ?? now()

        // D4 が成功を返しても、パネルはまだ描画中。描画中に電波を止めると前の絵が残ったまま
        // 中断されるので、待機中に戻るまで通信を続けて給電を保つ。
        // iOS はタグとの接続を約20秒で切るため、切れたら同じ読み取りシートのままつなぎ直す。
        var idleCount = 0
        var firstPoll = true
        while true {
            await sleep(timing.pollInterval)
            let state: APDUResponse
            do {
                state = try await exchange(transport, "状態確認(DE)", FMSC.busyStatus, logged: firstPoll)
            } catch {
                guard refreshReconnects < timing.maxRefreshReconnects else { throw error }
                refreshReconnects += 1
                log("描画待ち中に接続が切れました (描画開始から \(String(format: "%.1f", now().timeIntervalSince(started))) 秒)。つなぎ直します")
                return .reconnect
            }
            firstPoll = false
            guard state.isOK else {
                if options.blockingRefresh {
                    log("状態確認に対応していないため、描画待ちを打ち切ります")
                    break
                }
                throw WriteError.status(step: "状態確認", sw: state.sw)
            }
            if state.data.first == 0x01 {
                if !refreshSeenBusy { log("パネルが描画中です。完了を待ちます") }
                refreshSeenBusy = true
                idleCount = 0
            } else {
                idleCount += 1
                if idleCount >= 2 && (refreshSeenBusy || options.blockingRefresh) { break }
                if idleCount >= 8 { throw WriteError.refreshNotConfirmed }
            }
            if now().timeIntervalSince(started) > timing.pollTimeout {
                throw WriteError.status(step: "画面更新待ち", sw: 0x68CB)
            }
        }
        log("描画待ち \(String(format: "%.1f", now().timeIntervalSince(started))) 秒 (描画中を確認: \(refreshSeenBusy ? "はい" : "いいえ") / つなぎ直し: \(refreshReconnects) 回)")

        log("画面更新が完了しました")
        finished = true
        return .finished
    }
}
