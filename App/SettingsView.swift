import SwiftUI
import UniformTypeIdentifiers
import MangaCore

struct RuleDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw ReaderError.invalidRule("Cannot read the JSON file.") }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var importing = false
    @State private var exporting = false
    @State private var exportDocument = RuleDocument()
    @State private var filename = "site-rule"
    @State private var pendingRule: SiteRule?
    @State private var sharingRule: SiteRule?
    @State private var pendingExport: SiteRule?
    @State private var diskBytes = 0
    @State private var status: String?
    var body: some View {
        List {
            Section("Reader defaults") {
                Picker("Mode", selection: $model.preferences.mode) { ForEach(ReadingMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Picker("Direction", selection: $model.preferences.direction) { ForEach(ReadingDirection.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Toggle("Trim blank margins", isOn: $model.preferences.trimMargins)
                Toggle("Detect spreads", isOn: $model.preferences.detectSpreads)
                Toggle("Facing pages in wide windows", isOn: $model.preferences.facingPages)
            }
            Section {
                ForEach(model.rules) { rule in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(rule.name).font(.headline)
                                Text("Version \(rule.version)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Menu {
                                Button("Export JSON", systemImage: "square.and.arrow.up") { export(rule) }
                                Button("Share QR", systemImage: "qrcode") { sharingRule = rule }
                                Button("Remove rule", systemImage: "trash", role: .destructive) { Task { await remove(rule) } }
                            } label: { Label("Rule actions", systemImage: "ellipsis.circle").labelStyle(.iconOnly) }
                            .accessibilityLabel("Actions for \(rule.name)")
                        }
                    }.padding(.vertical, 4)
                    .accessibilityIdentifier("rules.item.\(rule.id)")
                }.onMove(perform: model.moveRules)
                Button("Import JSON rule", systemImage: "square.and.arrow.down") { importing = true }
                Button("Restore bundled rules", systemImage: "arrow.counterclockwise") { Task { await restoreRules() } }
            } header: { Text("Site rules") } footer: { Text("Drag to reorder. The first site opens in Browse. Removing a rule keeps reading history and saved titles.") }
            Section {
                LabeledContent("Image cache", value: ByteCountFormatter.string(fromByteCount: Int64(diskBytes), countStyle: .file))
                Button("Clear image cache", systemImage: "photo.badge.arrow.down") {
                    Task { await model.repository?.clearImages(); diskBytes = await model.repository?.imageCacheUsage() ?? 0; status = "Image cache cleared." }
                }
                Button("Clear content cache", systemImage: "trash") {
                    Task {
                        do { try await model.repository?.clearContent(); status = "Content cache cleared. Reading progress and saved manga are kept." }
                        catch { model.error = error.localizedDescription }
                    }
                }
            } header: { Text("Storage") } footer: { Text("Images use up to 256 MiB on disk. Reading history, preferences, and saved titles survive cache clearing.") }
            if let status { Section { Text(status).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently) } }
            Section("About") { Text("MangaViewer 1.0"); Text("Native reading for iPhone, iPad, Mac, and Apple Vision Pro.").foregroundStyle(.secondary) }
        }
        .navigationTitle("Settings")
        #if !os(macOS)
        .listStyle(.insetGrouped)
        .toolbar { ToolbarItem(placement: .primaryAction) { EditButton() } }
        #endif
        .disabled(model.repository == nil)
        .task { diskBytes = await model.repository?.imageCacheUsage() ?? 0 }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                pendingRule = try SiteRule.decode(file.read(upToCount: 128 * 1024 + 1) ?? Data())
            } catch { model.error = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: filename) { result in
            switch result { case .success: status = "Rule exported."; case .failure(let error): model.error = error.localizedDescription }
        }
        .sheet(item: $pendingRule) { rule in
            NavigationStack {
                List {
                    Section { Text(rule.name).font(.title2); Text("Version \(rule.version)") }
                    Section("Allowed hosts") { ForEach(rule.allowedHosts, id: \.self) { Text($0) } }
                    Section { Text("Installing this rule allows requests to these hosts. The rule is data only and cannot provide scripts or credentials.") }
                }
                .navigationTitle("Import rule")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { pendingRule = nil } }
                    ToolbarItem(placement: .confirmationAction) { Button("Install") { Task { await install(rule) } } }
                }
            }.frame(minWidth: 300, idealWidth: 480, minHeight: 380)
        }
        .sheet(item: $sharingRule, onDismiss: {
            if let rule = pendingExport { pendingExport = nil; export(rule) }
        }) { rule in
            RuleQRView(rule: rule) { pendingExport = rule; sharingRule = nil }
        }
    }
    private func export(_ rule: SiteRule) {
        do { exportDocument = RuleDocument(data: try rule.exported()); filename = rule.id; exporting = true }
        catch { model.error = error.localizedDescription }
    }
    private func install(_ rule: SiteRule) async {
        do {
            try await model.repository?.install(rule); model.rules = try model.store?.rules() ?? []
            pendingRule = nil; status = "Installed \(rule.name)."
        } catch { model.error = error.localizedDescription; pendingRule = nil }
    }
    private func remove(_ rule: SiteRule) async {
        do { try await model.repository?.removeRule(rule.id); model.rules = try model.store?.rules() ?? [] }
        catch { model.error = error.localizedDescription }
    }
    private func restoreRules() async {
        do {
            for rule in try DemoContent.bundledRules() {
                if let installed = model.rules.first(where: { $0.id == rule.id }), installed.version >= rule.version { continue }
                try await model.repository?.install(rule)
            }
            model.rules = try model.store?.rules() ?? []; status = "Bundled rules restored."
        } catch { model.error = error.localizedDescription }
    }
}

private struct RuleQRView: View {
    let rule: SiteRule
    let export: () -> Void
    @State private var qr: CGImage?
    @State private var message = "Preparing QR code…"
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text(rule.name).font(.title2)
                    if let qr {
                        let image = Image(decorative: qr, scale: 1)
                        image.resizable().interpolation(.none).scaledToFit().frame(maxWidth: 360).accessibilityLabel("QR code containing the site rule JSON")
                        ShareLink(item: image, preview: SharePreview(rule.name, image: image)) { Label("Share QR image", systemImage: "square.and.arrow.up") }
                    } else { Text(message).multilineTextAlignment(.center) }
                    Button("Export JSON file", action: export).buttonStyle(.borderedProminent)
                }.padding(24)
            }.navigationTitle("Share rule")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .frame(minWidth: 300, idealWidth: 460, minHeight: 420)
        .task {
            do {
                qr = try RuleExchange.qrImage(for: rule)
                if qr == nil { message = "This rule is too large for a reliable single QR code (\(RuleExchange.qrByteLimit) UTF-8 bytes). Use JSON file export." }
            } catch { message = error.localizedDescription }
        }
    }
}
