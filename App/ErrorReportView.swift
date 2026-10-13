import SwiftUI
import UniformTypeIdentifiers
import MangaCore

private struct ErrorReportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct ErrorReportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [ErrorDiagnostics.Entry] = []
    @State private var loading = true
    @State private var error: String?
    @State private var exportError: String?
    @State private var exporting = false
    private var report: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        return [String(localized: "MangaViewer error report"), "MangaViewer \(version) (\(build))", system, ""]
            .joined(separator: "\n") + entries.map { "\($0.date.ISO8601Format()) \($0.message)" }.joined(separator: "\n")
    }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Up to 200 errors from this app session, within the last 24 hours. Reports are shared only when you choose.")
                    .font(.callout).foregroundStyle(.secondary)
                if loading { ProgressView("Reading error log…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let error {
                    ContentUnavailableView("Could not read error report", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if entries.isEmpty {
                    ContentUnavailableView("No errors recorded", systemImage: "checkmark.circle", description: Text("Errors may take a moment to appear. Refresh to check again."))
                } else {
                    HStack {
                        ShareLink(item: report) { Label("Share report", systemImage: "square.and.arrow.up") }
                        Button("Export report", systemImage: "square.and.arrow.down") { exporting = true }
                    }
                    ScrollView {
                        Text(report).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("diagnostics.report")
                    }
                }
            }
            .padding()
            .navigationTitle("Error report")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }.disabled(loading)
                }
            }
        }
        .frame(minWidth: 300, idealWidth: 620, minHeight: 420)
        .task { await refresh() }
        .alert("Could not export report", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: { Text(exportError ?? "") }
        .fileExporter(isPresented: $exporting, document: ErrorReportDocument(text: report), contentType: .plainText, defaultFilename: "MangaViewer-errors") { result in
            if case .failure(let failure) = result {
                ErrorDiagnostics.record(failure, operation: .exportReport)
                exportError = failure.localizedDescription
            }
        }
    }
    private func refresh() async {
        loading = true; error = nil
        defer { loading = false }
        do { entries = try await ErrorDiagnostics.entries() }
        catch {
            ErrorDiagnostics.record(error, operation: .readReport)
            self.error = error.localizedDescription
        }
    }
}
