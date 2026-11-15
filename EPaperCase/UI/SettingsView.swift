import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("左右を反転", isOn: $model.settings.options.overrides.flipHorizontal)
                    Toggle("上下を反転", isOn: $model.settings.options.overrides.flipVertical)
                } header: {
                    Text("表示の向き")
                } footer: {
                    Text("メニューの「テスト画像を書き込む」で確認し、左上が黒・右上が赤・左下が黄になるように切り替えてください。上下左右とも逆なら両方オンにします。")
                }

                Section {
                    Picker("データの並び", selection: $model.settings.options.overrides.scanMode) {
                        Text("自動").tag(ScanMode?.none)
                        Text("縦スキャン").tag(ScanMode?.some(.vertical))
                        Text("横スキャン").tag(ScanMode?.some(.horizontal))
                    }
                    Picker("色数", selection: $model.settings.options.overrides.colorMode) {
                        Text("自動").tag(ColorMode?.none)
                        Text("4色").tag(ColorMode?.some(.fourColor))
                        Text("白黒").tag(ColorMode?.some(.blackWhite))
                    }
                    Toggle("描画指示: 応答を待つ (P2=00)", isOn: $model.settings.options.blockingRefresh)
                    Toggle("描画指示: 検出を省略", isOn: $model.settings.options.skipDetection)
                    Stepper(
                        "描画前の給電待ち: \(String(format: "%.1f", model.settings.options.chargeSeconds)) 秒",
                        value: $model.settings.options.chargeSeconds,
                        in: 0...8,
                        step: 0.5
                    )
                    Stepper(
                        "基板側の電源投入待ち: \(String(format: "%.1f", Double(model.settings.options.powerOnDelayTenths) / 10)) 秒",
                        value: $model.settings.options.powerOnDelayTenths,
                        in: 0...100,
                        step: 5
                    )
                } header: {
                    Text("詳細（通常は変更不要）")
                } footer: {
                    Text("テスト画像が縞模様や砂嵐になる場合は「データの並び」を切り替えてください。現在の判定: \(model.settings.lastLayout?.summary ?? "未読み取り（480×800・4色と仮定）")")
                }

                Section {
                    Picker("PIN", selection: $model.settings.options.pinMode) {
                        ForEach(PINMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    if model.settings.options.pinMode == .custom {
                        TextField("16進数（例: 0102030405）", text: $model.settings.options.customPINHex)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                    }
                } header: {
                    Text("認証")
                } footer: {
                    Text("ケースが認証を要求したときだけ使われます。間違ったPINを何度も送るとケースがロックされるおそれがあるため、「PIN認証が必要」と表示された場合以外は変更しないでください。")
                }

                Section("診断") {
                    NavigationLink("通信ログ") {
                        LogView()
                    }
                }

                Section("このアプリについて") {
                    Text("NFCで書き換える電子ペーパー付きスマホケース用の非公式アプリです。メーカーのサポート対象外のため、自己責任でご利用ください。ケース内部の画面設定を書き換える操作は行いません。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }
}

private struct LogView: View {
    @EnvironmentObject private var model: AppModel
    @State private var copied = false

    var body: some View {
        ScrollView {
            Text(model.logLines.isEmpty ? "まだ記録がありません" : model.logText)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("通信ログ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(copied ? "コピー済み" : "コピー") {
                    UIPasteboard.general.string = model.logText
                    copied = true
                }
                .disabled(model.logLines.isEmpty)
                Button("消去", role: .destructive) {
                    model.clearLog()
                    copied = false
                }
                .disabled(model.logLines.isEmpty)
            }
        }
    }
}
