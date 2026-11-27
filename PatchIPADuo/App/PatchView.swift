import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main
struct PatchIPADuoApp: App {
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
    @State private var display = "full"
    @State private var phone = false
    @State private var inspect = false
    @State private var report: String?
    @State private var processing = false
    @State private var result: ExportItem?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Inspect only", isOn: $inspect)
                    if !inspect {
                        SwiftUI.Picker("Display", selection: $display) {
                            Text("Full · SDK 27.1+").tag("full")
                            Text("Reserved side · SDK 27.0").tag("reserved-side")
                        }
                        Toggle("Enable iPhone support", isOn: $phone)
                    }
                    Button { picker = .open } label: {
                        Label("Choose decrypted IPA", systemImage: "folder")
                    }
                    
                } footer: {
                    Text("Uses the upstream SDK and scene checks. Exported apps require re-signing.")
                }
                .disabled(processing)
                if processing { ProgressView("Processing IPA…") }
                if let report { Section("Inspection and patch log") { Text(report).textSelection(.enabled) } }
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
            .navigationTitle("Patch IPA Duo")
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
        report = nil
        processing = true
        if let result { try? FileManager.default.removeItem(at: result.url.deletingLastPathComponent()) }
        result = nil
        errorText = nil
        Task {
            defer { processing = false }
            do {
                let (mode, enablePhone, inspectOnly) = (display, phone, inspect)
                let patched = try await Task.detached(priority: .userInitiated) { try IPAPatcher.run(url, display: mode, enablePhone: enablePhone, inspect: inspectOnly) }.value
                report = patched.report
                result = patched.output.map { ExportItem(url: $0) }
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
