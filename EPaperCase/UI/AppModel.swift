import SwiftUI
import UIKit

struct AppSettings: Equatable, Codable {
    var options = WriteOptions()
    var adjustments = ImageAdjustments()
    /// 最後にケースから読み取れたレイアウト（プレビューの寸法合わせ用）
    var lastLayout: PanelLayout?

    private static let key = "settings.v4"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = AppSettings.load() {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            if settings.adjustments != oldValue.adjustments || settings.lastLayout != oldValue.lastLayout {
                schedulePreview()
            }
        }
    }
    @Published var placement = ImageRenderer.Placement() {
        didSet { if placement != oldValue { schedulePreview() } }
    }
    @Published private(set) var source: CGImage?
    @Published private(set) var preview: UIImage?
    @Published private(set) var isBusy = false
    @Published private(set) var statusText: String?
    @Published private(set) var statusIsError = false
    @Published private(set) var canResume = false
    @Published private(set) var logLines: [String] = []

    private var previewTask: Task<Void, Never>?
    private var pendingJob: WriteJob?
    private var pendingDoneMessage = ""

    /// プレビューや変換に使うレイアウト。未読み取りなら公称値 (480×800・4色)。
    var layout: PanelLayout { settings.lastLayout ?? .nominal }

    var nfcAvailable: Bool { NFCWriter.isAvailable }

    // MARK: - 画像

    func setPhoto(_ image: UIImage) {
        source = ImageRenderer.normalized(image)
        placement = ImageRenderer.Placement()
        schedulePreview()
    }

    private func schedulePreview() {
        previewTask?.cancel()
        guard let source else {
            preview = nil
            return
        }
        let layout = self.layout
        let placement = self.placement
        let adjustments = self.settings.adjustments
        previewTask = Task {
            let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                let indices = ImageRenderer.indices(from: source, layout: layout, placement: placement, adjustments: adjustments)
                return ImageRenderer.preview(indices: indices, width: layout.portraitWidth, height: layout.portraitHeight)
            }.value
            if !Task.isCancelled {
                self.preview = image
            }
        }
    }

    // MARK: - ログ

    func appendLog(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        logLines.append("\(formatter.string(from: Date())) \(line)")
        if logLines.count > 600 {
            logLines.removeFirst(logLines.count - 600)
        }
    }

    var logText: String { logLines.joined(separator: "\n") }

    func clearLog() { logLines.removeAll() }

    // MARK: - NFC 操作

    func writePhoto() {
        guard let source else { return }
        let placement = self.placement
        let adjustments = self.settings.adjustments
        start(
            WriteJob(kind: .write, options: settings.options) { layout in
                ImageRenderer.indices(from: source, layout: layout, placement: placement, adjustments: adjustments)
            },
            title: "写真の書き込み",
            doneMessage: "書き込みが完了しました"
        )
    }

    func writeTestPattern() {
        start(
            WriteJob(kind: .write, options: settings.options) { layout in
                ImageRenderer.testPatternIndices(layout: layout)
            },
            title: "テスト画像の書き込み",
            doneMessage: "テスト画像を書き込みました"
        )
    }

    func writeWhite() {
        start(
            WriteJob(kind: .write, options: settings.options) { layout in
                [UInt8](repeating: 1, count: layout.portraitWidth * layout.portraitHeight)
            },
            title: "白で消去",
            doneMessage: "白で消去しました"
        )
    }

    func refreshOnly() {
        start(WriteJob(kind: .refreshOnly, options: settings.options), title: "再描画", doneMessage: "再描画が完了しました")
    }

    func probe() {
        start(WriteJob(kind: .probe, options: settings.options), title: "ケース情報の読み取り", doneMessage: "ケースの情報を読み取りました")
    }

    /// タグの種類を調べるだけの診断。
    func scanTagType() {
        guard !isBusy else { return }
        appendLog("―― タグの種類を調べる ――")
        isBusy = true
        canResume = false
        statusText = nil
        statusIsError = false
        Task {
            defer { isBusy = false }
            do {
                let result = try await TagScanner().run()
                appendLog(result)
                statusText = "タグを検出しました\n\(result)"
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                appendLog("失敗: \(message)")
                statusText = message
                statusIsError = true
            }
        }
    }

    func resume() {
        guard let job = pendingJob, job.canResume else { return }
        appendLog("―― 続きから再開 ――")
        execute(job, doneMessage: pendingDoneMessage)
    }

    private func start(_ job: WriteJob, title: String, doneMessage: String) {
        guard !isBusy else { return }
        appendLog("―― \(title) ――")
        job.log = { [weak self] line in
            Task { @MainActor in self?.appendLog(line) }
        }
        pendingJob = job
        pendingDoneMessage = doneMessage
        execute(job, doneMessage: doneMessage)
    }

    private func execute(_ job: WriteJob, doneMessage: String) {
        guard !isBusy else { return }
        isBusy = true
        canResume = false
        statusText = nil
        statusIsError = false

        Task {
            defer { isBusy = false }
            do {
                var first = true
                while true {
                    let writer = NFCWriter(
                        job: job,
                        startMessage: first
                            ? "ケースの内側（スマホを入れる面）をスマホ背面の上部に重ねてください"
                            : "続きを行います。そのまま動かさないでください",
                        doneMessage: doneMessage,
                        log: { [weak self] line in
                            Task { @MainActor in self?.appendLog(line) }
                        }
                    )
                    let outcome = try await writer.run()
                    if outcome == .finished { break }
                    // 読み取りシートが閉じきるのを待ってから開き直す。
                    first = false
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                }
                if let detected = job.layout {
                    settings.lastLayout = detected
                }
                statusText = job.refreshUnconfirmed
                    ? "描画の完了を確認できないまま終了しました。画面を確認し、乱れていれば「再描画だけ行う」を試してください"
                    : doneMessage
                statusIsError = job.refreshUnconfirmed
                if job.kind == .probe, let info = job.info {
                    statusText = "\(doneMessage)\n\(job.layout?.summary ?? "形状不明")\n\(info.dump)"
                }
                pendingJob = nil
            } catch {
                if let detected = job.layout {
                    settings.lastLayout = detected
                }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                appendLog("失敗: \(message)")
                statusText = message
                statusIsError = true
                canResume = job.canResume
            }
        }
    }
}
