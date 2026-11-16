import CoreNFC
import Foundation

enum NFCWriterError: LocalizedError {
    case unavailable
    case cancelled
    case timedOut
    case tagLost(String)
    case unsupportedTag(String)
    case job(WriteError)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "この端末ではNFCの読み取りが使えません"
        case .cancelled:
            return "キャンセルしました"
        case .timedOut:
            return "時間切れになりました。ケースを当てる位置を変えて、もう一度試してください"
        case .tagLost(let detail):
            return "ケースとの通信が切れました。位置を合わせ直して、もう一度試してください\n(\(detail))"
        case .unsupportedTag(let detail):
            return "対応していない種類のNFCタグです (\(detail))"
        case .job(let error):
            return error.message
        case .other(let detail):
            return detail
        }
    }
}

/// Core NFC のタグを APDU の送受信口として包む。
private struct TagTransport: APDUTransport {
    let tag: NFCTag

    func send(_ apdu: Data) async throws -> APDUResponse {
        guard let command = NFCISO7816APDU(data: apdu) else {
            throw NFCWriterError.other("APDU を組み立てられませんでした: \(apdu.hexString)")
        }
        switch tag {
        case .iso7816(let iso):
            let (data, sw1, sw2) = try await iso.sendCommand(apdu: command)
            return APDUResponse(data: data, sw: (UInt16(sw1) << 8) | UInt16(sw2))
        case .miFare(let mifare):
            // AID の SELECT に応答しない ISO 14443-4 タグは MIFARE 系として渡されることがある。
            let (data, sw1, sw2) = try await mifare.sendMiFareISO7816Command(command)
            return APDUResponse(data: data, sw: (UInt16(sw1) << 8) | UInt16(sw2))
        default:
            throw NFCWriterError.unsupportedTag("ISO 14443-4 ではありません")
        }
    }
}

/// NFC の読み取りシートを1回開き、WriteJob を進める。
///
/// - `.reconnect` が返ったら同じシートのままタグを検出し直す。
/// - `.newSession` が返ったらシートを閉じて呼び出し元に知らせる（呼び出し元が開き直す）。
final class NFCWriter: NSObject, NFCTagReaderSessionDelegate {
    private let job: WriteJob
    private let startMessage: String
    private let doneMessage: String
    private let log: (String) -> Void

    private var session: NFCTagReaderSession?
    private var continuation: CheckedContinuation<WriteJob.Outcome, Error>?
    private var sessionStartedAt = Date()
    private let lock = NSLock()

    static var isAvailable: Bool { NFCTagReaderSession.readingAvailable }

    init(job: WriteJob, startMessage: String, doneMessage: String, log: @escaping (String) -> Void) {
        self.job = job
        self.startMessage = startMessage
        self.doneMessage = doneMessage
        self.log = log
    }

    /// 戻り値は `.finished` か `.newSession`。
    func run() async throws -> WriteJob.Outcome {
        guard NFCTagReaderSession.readingAvailable else { throw NFCWriterError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            guard let session = NFCTagReaderSession(pollingOption: [.iso14443], delegate: self, queue: nil) else {
                self.finish(.failure(NFCWriterError.unavailable))
                return
            }
            self.session = session
            self.sessionStartedAt = Date()
            session.alertMessage = self.startMessage
            session.begin()
        }
    }

    private func finish(_ result: Result<WriteJob.Outcome, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        sessionStartedAt = Date()
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        let mapped: NFCWriterError
        if let nfcError = error as? NFCReaderError {
            switch nfcError.code {
            case .readerSessionInvalidationErrorUserCanceled:
                mapped = .cancelled
            case .readerSessionInvalidationErrorSessionTimeout:
                mapped = .timedOut
            default:
                mapped = .other(nfcError.localizedDescription)
            }
        } else {
            mapped = .other(error.localizedDescription)
        }
        // 正常終了時は finish 済みなので、ここでの呼び出しは何もしない。
        finish(.failure(mapped))
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard tags.count == 1, let tag = tags.first else {
            session.alertMessage = "タグが複数見つかりました。ケースだけを当ててください"
            session.restartPolling()
            return
        }

        Task {
            do {
                switch tag {
                case .iso7816(let iso):
                    log("タグ検出: ISO7816 AID=\(iso.initialSelectedAID) UID=\(iso.identifier.hexString) ATS履歴=\(iso.historicalBytes?.hexString ?? "-")")
                case .miFare(let mifare):
                    log("タグ検出: MIFARE系(family=\(mifare.mifareFamily.rawValue)) UID=\(mifare.identifier.hexString)")
                case .feliCa:
                    throw NFCWriterError.unsupportedTag("FeliCa")
                case .iso15693:
                    throw NFCWriterError.unsupportedTag("ISO 15693")
                @unknown default:
                    throw NFCWriterError.unsupportedTag("不明")
                }

                try await session.connect(to: tag)
                let connectedAt = Date()
                let outcome = try await job.run(
                    transport: TagTransport(tag: tag),
                    connectedAt: connectedAt,
                    sessionStartedAt: sessionStartedAt
                ) { progress in
                    session.alertMessage = progress.message
                }

                switch outcome {
                case .finished:
                    session.alertMessage = doneMessage
                    finish(.success(.finished))
                    session.invalidate()
                case .reconnect:
                    session.restartPolling()
                case .linger:
                    session.alertMessage = "仕上げ中…あと少し、そのまま動かさないでください"
                    try? await Task.sleep(nanoseconds: 14_000_000_000)
                    session.alertMessage = "終了しました。画面を確認してください"
                    finish(.success(.finished))
                    session.invalidate()
                case .newSession:
                    session.alertMessage = "続きの準備中…そのまま動かさずにお待ちください"
                    finish(.success(.newSession))
                    session.invalidate()
                }
            } catch {
                let mapped: NFCWriterError
                if let writerError = error as? NFCWriterError {
                    mapped = writerError
                } else if let jobError = error as? WriteError {
                    mapped = .job(jobError)
                } else if let nfcError = error as? NFCReaderError {
                    mapped = .tagLost(nfcError.localizedDescription)
                } else {
                    mapped = .other(error.localizedDescription)
                }
                log("エラー: \(mapped.localizedDescription)")
                finish(.failure(mapped))
                session.invalidate(errorMessage: mapped.localizedDescription)
            }
        }
    }
}
