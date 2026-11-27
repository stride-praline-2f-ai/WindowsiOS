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

private enum Picker: Identifiable {
    case open
    case save(URL)

    var id: String {
        switch self {
        case .open: return "open"
        case .save(let url): return url.absoluteString
        }
    }
}

private struct PatchView: View {
    @State private var picker: Picker?
    @State private var processing = false
    @State private var result: ExportItem?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Target SDK", value: "iOS 27.2")
                    Button { picker = .open } label: {
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
                        Button("Save to Files") { picker = .save(result.url) }
                    }
                }
                if let errorText {
                    Section("Couldn’t patch IPA") { Text(errorText).textSelection(.enabled) }
                }
            }
            .navigationTitle("IPA SDK Patcher")
            .sheet(item: $picker) { action in
                switch action {
                case .open:
                    ImportPicker { url in
                        picker = nil
                        if let url { start(url) }
                    }
                case .save(let url):
                    ExportPicker(url: url)
                }
            }
        }
    }

    @MainActor private func start(_ url: URL) {
        guard url.pathExtension.lowercased() == "ipa" else {
            errorText = "Choose a file with the .ipa extension."
            return
        }
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

private struct ImportPicker: UIViewControllerRepresentable {
    let finish: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(finish) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Providers may identify the same IPA as an archive or as generic data.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let finish: (URL?) -> Void
        init(_ finish: @escaping (URL?) -> Void) { self.finish = finish }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finish(nil)
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
