import AppKit
import SwiftUI

@MainActor
final class ScenePickerState: ObservableObject {
    let scenes: [Scene]
    let disk: LibraryDisk
    @Published var focusedID: String
    let select: (Scene) -> Void
    let dismiss: () -> Void

    init(model: AppModel, dismiss: @escaping () -> Void) {
        scenes = model.state.scenes
        disk = model.disk
        focusedID = model.selected?.id ?? scenes.first?.id ?? ""
        select = { [weak model] scene in model?.choose(scene) }
        self.dismiss = dismiss
    }
    func move(_ offset: Int) {
        guard !scenes.isEmpty else { return }
        let index = scenes.firstIndex { $0.id == focusedID } ?? 0
        focusedID = scenes[(index + offset + scenes.count) % scenes.count].id
    }
    func commit() {
        guard let scene = scenes.first(where: { $0.id == focusedID }) else { return }
        dismiss()
        select(scene)
    }
}

final class ScenePickerPanel: NSPanel {
    var pickerState: ScenePickerState?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: pickerState?.move(-1)
        case 124: pickerState?.move(1)
        case 36, 76: pickerState?.commit()
        case 53: pickerState?.dismiss()
        default: super.keyDown(with: event)
        }
    }
    override func cancelOperation(_ sender: Any?) { pickerState?.dismiss() }
}

struct ScenePickerView: View {
    @ObservedObject var picker: ScenePickerState
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Choose your scene").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("← → browse   ↵ play   esc close").font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(.horizontal, 20)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(picker.scenes) { scene in
                            Button {
                                picker.focusedID = scene.id
                                picker.commit()
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    SceneThumbnail(url: picker.disk.still(scene), pixelSize: 600)
                                        .frame(width: 232, height: 130.5).clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .overlay(RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(picker.focusedID == scene.id ? Color.orange : Color.white.opacity(0.12), lineWidth: picker.focusedID == scene.id ? 3 : 1))
                                    Text(scene.name.replacingOccurrences(of: "-", with: " ").capitalized)
                                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        .foregroundStyle(picker.focusedID == scene.id ? .primary : .secondary)
                                }.frame(width: 232)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(scene.name)
                            .accessibilityValue(picker.focusedID == scene.id ? "Highlighted" : "")
                            .id(scene.id)
                        }
                    }.padding(.horizontal, 20).padding(.vertical, 3)
                }
                .onAppear { proxy.scrollTo(picker.focusedID, anchor: .center) }
                .onChange(of: picker.focusedID) { _, id in
                    withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .padding(.vertical, 18)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
    }
}
