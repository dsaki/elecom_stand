import PhotosUI
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pickedItem: PhotosPickerItem?
    @State private var showSettings = false
    @State private var confirmWhite = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    PreviewCard()
                        .frame(maxWidth: 300)

                    PhotosPicker(selection: $pickedItem, matching: .images) {
                        Label(model.source == nil ? "写真を選ぶ" : "別の写真を選ぶ", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    if model.source != nil {
                        AdjustmentPanel()
                    }

                    Button {
                        model.writePhoto()
                    } label: {
                        Label("ケースに書き込む", systemImage: "wave.3.right")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.source == nil || model.isBusy || !model.nfcAvailable)

                    StatusPanel()

                    if !model.nfcAvailable {
                        Text("この端末ではNFCの読み取りが使えないため、書き込みはできません。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("電子ペーパーケース")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            model.writeTestPattern()
                        } label: {
                            Label("テスト画像を書き込む", systemImage: "square.grid.2x2")
                        }
                        Button {
                            model.refreshOnly()
                        } label: {
                            Label("再描画だけ行う", systemImage: "arrow.clockwise")
                        }
                        Button {
                            model.probe()
                        } label: {
                            Label("ケースの情報を読み取る", systemImage: "info.circle")
                        }
                        Button {
                            model.scanTagType()
                        } label: {
                            Label("タグの種類を調べる（診断）", systemImage: "dot.radiowaves.left.and.right")
                        }
                        Button(role: .destructive) {
                            confirmWhite = true
                        } label: {
                            Label("白で消去", systemImage: "eraser")
                        }
                    } label: {
                        Label("その他の操作", systemImage: "ellipsis.circle")
                    }
                    .disabled(model.isBusy || !model.nfcAvailable)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("設定", systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(model)
            }
            .confirmationDialog("ケースの表示を真っ白にしますか？", isPresented: $confirmWhite, titleVisibility: .visible) {
                Button("白で消去", role: .destructive) { model.writeWhite() }
                Button("やめる", role: .cancel) {}
            }
            .onChange(of: pickedItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        model.setPhoto(image)
                    }
                }
            }
        }
    }
}

/// ケースに表示される見た目のプレビュー。ドラッグで位置、ピンチで大きさを調整できる。
private struct PreviewCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var dragStart: ImageRenderer.Placement?
    @State private var zoomStart: CGFloat?

    var body: some View {
        let layout = model.layout
        GeometryReader { proxy in
            ZStack {
                Color(red: 0.91, green: 0.91, blue: 0.89)
                if let preview = model.preview {
                    Image(uiImage: preview)
                        .interpolation(.none)
                        .resizable()
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "photo")
                            .font(.system(size: 40))
                        Text("写真を選ぶと\nここに仕上がりが表示されます")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(Color.black.opacity(0.45))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        guard model.source != nil else { return }
                        let start = dragStart ?? model.placement
                        dragStart = start
                        var next = model.placement
                        next.offsetX = min(1.5, max(-1.5, start.offsetX + value.translation.width / proxy.size.width))
                        next.offsetY = min(1.5, max(-1.5, start.offsetY + value.translation.height / proxy.size.height))
                        model.placement = next
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { scale in
                        guard model.source != nil else { return }
                        let start = zoomStart ?? model.placement.zoom
                        zoomStart = start
                        model.placement.zoom = min(5, max(1, start * scale))
                    }
                    .onEnded { _ in zoomStart = nil }
            )
        }
        .aspectRatio(CGFloat(layout.portraitWidth) / CGFloat(layout.portraitHeight), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.4)))
        .accessibilityLabel("仕上がりのプレビュー")
    }
}

private struct AdjustmentPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ドラッグで位置、ピンチで大きさを変えられます")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Picker("仕上げ", selection: $model.settings.adjustments.method) {
                ForEach(DitherMethod.allCases) { method in
                    Text(method.label).tag(method)
                }
            }
            .pickerStyle(.segmented)

            slider("明るさ", value: $model.settings.adjustments.brightness, range: -0.5...0.5)
            slider("コントラスト", value: $model.settings.adjustments.contrast, range: 0.5...1.8)
            slider("あざやかさ", value: $model.settings.adjustments.saturation, range: 0...2)

            HStack {
                Button("位置を戻す") {
                    model.placement = ImageRenderer.Placement()
                }
                Spacer()
                Button("色合いを戻す") {
                    let method = model.settings.adjustments.method
                    model.settings.adjustments = ImageAdjustments()
                    model.settings.adjustments.method = method
                }
            }
            .font(.footnote)
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .frame(width: 96, alignment: .leading)
            Slider(value: value, in: range)
                .accessibilityLabel(title)
        }
    }
}

private struct StatusPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.isBusy {
            HStack(spacing: 10) {
                ProgressView()
                Text("NFCで通信中…")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } else if let status = model.statusText {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text(status)
                        .font(.subheadline)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: model.statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(model.statusIsError ? Color.orange : Color.green)
                }
                if model.canResume {
                    Button {
                        model.resume()
                    } label: {
                        Label("続きから再開", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
