import SwiftUI

enum UploadState: Equatable {
    case notConfigured
    case idle
    case uploading
    case uploaded(Date)
    case failed(String)
}

/// 智慧掃描結果：判斷出的情境、依樣板產生的 JSON，以及上傳狀態。
struct SmartResultPanel: View {
    let model: SmartScanModel
    let templates: [ScanTemplate]
    let uploadState: UploadState
    var onRerun: (ScanTemplate?) -> Void
    var onCopy: (String) -> Void
    var onUpload: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                classificationCard
                jsonCard
                uploadCard
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
    }

    // MARK: - 情境

    private var classificationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(title: "情境", systemImage: "square.stack.3d.up", trailing: providerText)

            switch model.phase {
            case .idle, .classifying:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在判斷情境…")
                        .foregroundStyle(.secondary)
                }
            case let .extracting(template, classification):
                templateSummary(template, classification: classification)
            case let .finished(outcome):
                templateSummary(outcome.template, classification: outcome.classification)
                if !outcome.notes.isEmpty {
                    Text(outcome.notes.joined(separator: "\n"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Menu {
                ForEach(templates) { template in
                    Button(template.name) { onRerun(template) }
                }
                Divider()
                Button("重新自動判斷", systemImage: "wand.and.stars") { onRerun(nil) }
            } label: {
                Label("更換情境", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.medium))
            }
            .disabled(model.isRunning)
        }
        .card()
    }

    private func templateSummary(_ template: ScanTemplate, classification: Classification) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(template.name)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text(template.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if let confidence = classification.confidence {
                ConfidenceGauge(value: confidence)
            }
        }
    }

    private var providerText: String? {
        switch model.phase {
        case let .extracting(_, classification): return classification.provider.displayName
        case let .finished(outcome): return outcome.classification.provider.displayName
        case .idle, .classifying: return nil
        }
    }

    // MARK: - JSON

    @ViewBuilder
    private var jsonCard: some View {
        switch model.phase {
        case .idle, .classifying:
            EmptyView()
        case .extracting:
            VStack(alignment: .leading, spacing: 14) {
                CardHeader(title: "JSON", systemImage: "curlybraces")
                HStack(spacing: 10) {
                    ProgressView()
                    if let progress = model.pageProgress, progress.total > 1 {
                        Text("Apple Intelligence 正在分析第 \(progress.current)／\(progress.total) 頁…")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Apple Intelligence 正在依樣板產生資料…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .card()
        case let .finished(outcome):
            if let data = outcome.data {
                let json = data.prettyPrinted()
                VStack(alignment: .leading, spacing: 14) {
                    CardHeader(title: "JSON", systemImage: "curlybraces", trailing: "\(filledFieldCount(data)) 個欄位有值")
                    JSONBlock(json: json)
                    HStack(spacing: 12) {
                        Button {
                            onCopy(json)
                        } label: {
                            Label("複製", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        ShareLink(item: json) {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                    }
                    .font(.subheadline.weight(.medium))
                }
                .card()
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(title: "JSON", systemImage: "curlybraces")
                    Label(outcome.extractionError ?? "無法產生 JSON", systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                    Text("辨識文字仍會保存；上傳到伺服器後，也可以由接入的 harness 透過 MCP 產生並回寫 JSON。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    NavigationLink {
                        AIDiagnosticsView()
                    } label: {
                        Label("查看 Apple Intelligence 診斷", systemImage: "stethoscope")
                            .font(.subheadline.weight(.medium))
                    }
                }
                .card()
            }
        }
    }

    private func filledFieldCount(_ value: JSONValue) -> Int {
        switch value {
        case .null: return 0
        case .object(let members): return members.reduce(0) { $0 + filledFieldCount($1.value) }
        case .array(let elements): return elements.isEmpty ? 0 : elements.reduce(0) { $0 + filledFieldCount($1) }
        case .string(let text): return text.isEmpty ? 0 : 1
        case .number, .bool: return 1
        }
    }

    // MARK: - 上傳

    @ViewBuilder
    private var uploadCard: some View {
        if uploadState != .notConfigured {
            HStack(spacing: 12) {
                switch uploadState {
                case .notConfigured, .idle:
                    Label("尚未上傳", systemImage: "icloud")
                        .foregroundStyle(.secondary)
                case .uploading:
                    ProgressView()
                    Text("上傳中…")
                        .foregroundStyle(.secondary)
                case .uploaded(let date):
                    Label("已上傳 \(date.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.icloud")
                        .foregroundStyle(.green)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.icloud")
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if uploadState != .uploading {
                    Button("上傳", action: onUpload)
                        .buttonStyle(.bordered)
                        .disabled(model.isRunning)
                }
            }
            .font(.subheadline)
            .card()
        }
    }
}
