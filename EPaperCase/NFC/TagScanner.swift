import CoreNFC
import Foundation

/// どんな種類の NFC タグとして見えているかを調べるだけの診断（書き込みは一切しない）。
final class TagScanner: NSObject, NFCTagReaderSessionDelegate {
    private var session: NFCTagReaderSession?
    private var continuation: CheckedContinuation<String, Error>?
    private let lock = NSLock()

    func run() async throws -> String {
        guard NFCTagReaderSession.readingAvailable else { throw NFCWriterError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            guard let session = NFCTagReaderSession(pollingOption: [.iso14443, .iso15693], delegate: self, queue: nil) else {
                self.finish(.failure(NFCWriterError.unavailable))
                return
            }
            self.session = session
            session.alertMessage = "ケースの背面をスマホ上部に当て、ゆっくり位置をずらしてください"
            session.begin()
        }
    }

    private func finish(_ result: Result<String, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        if let nfcError = error as? NFCReaderError {
            switch nfcError.code {
            case .readerSessionInvalidationErrorUserCanceled:
                finish(.failure(NFCWriterError.cancelled))
            case .readerSessionInvalidationErrorSessionTimeout:
                finish(.failure(NFCWriterError.other("60秒以内にタグを検出できませんでした")))
            default:
                finish(.failure(NFCWriterError.other(nfcError.localizedDescription)))
            }
        } else {
            finish(.failure(NFCWriterError.other(error.localizedDescription)))
        }
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        var lines: [String] = []
        for tag in tags {
            switch tag {
            case .iso7816(let iso):
                lines.append("ISO7816 (ISO-DEP) AID=\(iso.initialSelectedAID) UID=\(iso.identifier.hexString) 履歴=\(iso.historicalBytes?.hexString ?? "-") アプリ=\(iso.applicationData?.hexString ?? "-")")
            case .miFare(let mifare):
                let family: String
                switch mifare.mifareFamily {
                case .ultralight: family = "Ultralight/NTAG"
                case .plus: family = "Plus"
                case .desfire: family = "DESFire"
                default: family = "不明(AID不一致のISO-DEPの可能性)"
                }
                lines.append("MIFARE系 family=\(family) UID=\(mifare.identifier.hexString) 履歴=\(mifare.historicalBytes?.hexString ?? "-")")
            case .iso15693(let v):
                lines.append("ISO15693 UID=\(v.identifier.hexString) メーカーコード=\(v.icManufacturerCode)")
            case .feliCa(let felica):
                lines.append("FeliCa IDm=\(felica.currentIDm.hexString) システムコード=\(felica.currentSystemCode.hexString)")
            @unknown default:
                lines.append("不明な種類のタグ")
            }
        }
        let summary = lines.joined(separator: "\n")
        session.alertMessage = "タグを検出しました"
        finish(.success(summary))
        session.invalidate()
    }
}
