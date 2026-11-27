import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main
struct DuoPatchApp: App {
    var body: some Scene { WindowGroup { PatchView() } }
}

private struct ExportItem: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct PatchView: View {
    @State private var importing = false
    @State private var processing = false
    @State private var result: ExportItem?
    @State private var export: ExportItem?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Target SDK", value: "iOS 27.2")
                    Button { importing = true } label: {
                        Label("Choose decrypted IPA", systemImage: "folder")
                    }
                    .disabled(processing)
                } footer: {
                    Text("Updates the main executable and its Info.plist on this device. The exported IPA requires re-signing before installation.")
                }
                if processing { ProgressView("Patching IPA…") }
                if let result {
                    Section("Patched file") {
                        Text(result.url.lastPathComponent)
                        Button("Save to Files") { export = result }
                    }
                }
                if let errorText {
                    Section("Couldn’t patch IPA") { Text(errorText).textSelection(.enabled) }
                }
            }
            .navigationTitle("IPA SDK Patcher")
            .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .data]) { selection in
                switch selection {
                case .success(let url): start(url)
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError { errorText = error.localizedDescription }
                }
            }
            .sheet(item: $export) { item in ExportPicker(url: item.url) }
        }
    }

    @MainActor private func start(_ url: URL) {
        processing = true
        if let result { try? FileManager.default.removeItem(at: result.url.deletingLastPathComponent()) }
        result = nil
        errorText = nil
        Task {
            defer { processing = false }
            do {
                let patched = try await Task.detached(priority: .userInitiated) { try IPAPatcher.run(url) }.value
                result = ExportItem(url: patched)
            } catch { errorText = error.localizedDescription }
        }
    }
}

private struct ExportPicker: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}
