import SwiftUI

/// 選擇辨識語言並調整優先順序。可選語言清單由 Vision 依目前辨識模式提供。
struct LanguageSelectionView: View {
    @Binding var languagesRaw: String
    let level: RecognitionLevel

    @State private var supported: [String] = []

    private var selected: [String] {
        OCRSettings.decode(languagesRaw)
    }

    private var available: [String] {
        supported.filter { !selected.contains($0) }
    }

    private var hasUnsupportedSelection: Bool {
        !supported.isEmpty && selected.contains { !supported.contains($0) }
    }

    var body: some View {
        List {
            Section {
                if selected.isEmpty {
                    Text("未選擇，將使用系統預設語言")
                        .foregroundStyle(.secondary)
                }
                ForEach(selected, id: \.self) { identifier in
                    LanguageRow(identifier: identifier, isSupported: supported.isEmpty || supported.contains(identifier))
                }
                .onMove(perform: move)
                .onDelete(perform: remove)
            } header: {
                Text("已選擇（依優先順序）")
            } footer: {
                if hasUnsupportedSelection {
                    Text("標示警告的語言在「\(level.displayName)」模式下不支援，辨識時會略過。")
                }
            }

            Section("可加入的語言") {
                ForEach(available, id: \.self) { identifier in
                    Button {
                        languagesRaw = OCRSettings.encode(selected + [identifier])
                    } label: {
                        HStack {
                            LanguageRow(identifier: identifier, isSupported: true)
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Section {
                Button("重設為預設值") {
                    languagesRaw = OCRSettings.encode(OCRSettings.defaultLanguages)
                }
            }
        }
        .navigationTitle("辨識語言")
        .toolbar { EditButton() }
        .task(id: level) {
            supported = OCRService.supportedLanguages(for: level)
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var languages = selected
        languages.move(fromOffsets: source, toOffset: destination)
        languagesRaw = OCRSettings.encode(languages)
    }

    private func remove(at offsets: IndexSet) {
        var languages = selected
        languages.remove(atOffsets: offsets)
        languagesRaw = OCRSettings.encode(languages)
    }
}

private struct LanguageRow: View {
    let identifier: String
    let isSupported: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(OCRSettings.displayName(for: identifier))
                Text(identifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !isSupported {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("目前模式不支援")
            }
        }
        .contentShape(Rectangle())
    }
}

#Preview {
    NavigationStack {
        LanguageSelectionView(languagesRaw: .constant("zh-Hant,en-US"), level: .accurate)
    }
}
