import SwiftUI
import MangaCore

@main struct MangaViewerApp: App {
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 320, minHeight: 420)
                .task { await model.start() }
                #if os(visionOS)
                .controlSize(.large)
                .environment(\.defaultMinListRowHeight, 56)
                #endif
        }
        .defaultSize(width: 1100, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open URL…") { model.section = .browse; model.path = []; model.openURLRequest += 1 }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
        #if os(macOS)
        Settings {
            SettingsView(model: model).frame(width: 550, height: 500)
                .alert("MangaViewer", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                    Button("OK") { model.error = nil }
                } message: { Text(model.error ?? "") }
        }
        #endif
    }
}
