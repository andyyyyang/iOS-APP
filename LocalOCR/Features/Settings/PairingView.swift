import SwiftUI
import VisionKit

/// 與 Obsidian 配對：掃描 QR Code 或輸入配對碼（由 Obsidian 的 LocalOCR 外掛「配對 iPhone／iPad」產生）。
struct PairingView: View {
    /// 從 localocr://pair 連結開啟時直接配對。
    var link: PairingClient.Link?

    @Environment(\.dismiss) private var dismiss
    @State private var serverText = PairingClient.defaultServer.absoluteString
    @State private var code = ""
    @State private var showsScanner = false
    @State private var phase: Phase = .idle

    enum Phase: Equatable {
        case idle
        case pairing
        case paired(String)
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                Text("在 Obsidian 執行「配對 iPhone／iPad」")
                    .font(.subheadline)
            }

            Section {
                Button {
                    showsScanner = true
                } label: {
                    Label("掃描 QR Code", systemImage: "qrcode.viewfinder")
                }
                .disabled(!DataScannerViewController.isSupported || phase == .pairing)
            }

            Section {
                TextField("XXXX-XXXX", text: $code)
                    .font(.title3.monospaced())
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .onChange(of: code) { _, newValue in
                        let normalized = PairingClient.normalizeCode(newValue)
                        if normalized.count == 9, normalized != newValue { code = normalized }
                    }
                Button {
                    Task { await pairWithCode() }
                } label: {
                    HStack {
                        Text("配對")
                        Spacer()
                        if phase == .pairing { ProgressView() }
                    }
                }
                .disabled(PairingClient.normalizeCode(code).count != 9 || phase == .pairing)
            } header: {
                Text("或輸入配對碼")
            }

            switch phase {
            case .paired(let message):
                Section {
                    Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("完成") { dismiss() }
                }
            case .failed(let message):
                Section {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            default:
                EmptyView()
            }

            Section {
                TextField("伺服器網址", text: $serverText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                NavigationLink("手動設定") {
                    ServerSettingsView()
                }
            } header: {
                Text("進階")
            }
        }
        .canvasList()
        .navigationTitle("與 Obsidian 配對")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("關閉") { dismiss() }
            }
        }
        .fullScreenCover(isPresented: $showsScanner) {
            PairingScanner { link in
                showsScanner = false
                Task { await pair(link) }
            } onCancel: {
                showsScanner = false
            }
            .ignoresSafeArea()
        }
        .task {
            if let link, phase == .idle { await pair(link) }
        }
    }

    private func pairWithCode() async {
        guard let server = ServerSettings.normalizedURL(serverText) else {
            phase = .failed("伺服器網址不正確")
            return
        }
        await pair(PairingClient.Link(server: server, code: PairingClient.normalizeCode(code)))
    }

    private func pair(_ link: PairingClient.Link) async {
        phase = .pairing
        do {
            let result = try await PairingClient.claim(link)
            PairingClient.apply(result, server: link.server)
            let vault = result.vaultName.map { "「\($0)」" } ?? ""
            phase = .paired("已與 Obsidian \(vault)配對")
            await VaultSyncCenter.shared.syncNow()
            await NotesStore.shared.reload()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// 掃描配對 QR Code（VisionKit 即時辨識條碼）。
private struct PairingScanner: UIViewControllerRepresentable {
    var onFound: (PairingClient.Link) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        scanner.navigationItem.title = "掃描配對 QR Code"
        scanner.navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel,
            primaryAction: UIAction { _ in context.coordinator.parent.onCancel() }
        )
        return UINavigationController(rootViewController: scanner)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {
        context.coordinator.parent = self
        if let scanner = controller.viewControllers.first as? DataScannerViewController, !scanner.isScanning {
            try? scanner.startScanning()
        }
    }

    static func dismantleUIViewController(_ controller: UINavigationController, coordinator: Coordinator) {
        (controller.viewControllers.first as? DataScannerViewController)?.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var parent: PairingScanner
        private var didFind = false

        init(parent: PairingScanner) {
            self.parent = parent
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !didFind else { return }
            for item in addedItems {
                guard case .barcode(let barcode) = item,
                      let payload = barcode.payloadStringValue,
                      let url = URL(string: payload),
                      let link = PairingClient.parse(url) else { continue }
                didFind = true
                dataScanner.stopScanning()
                parent.onFound(link)
                return
            }
        }
    }
}
