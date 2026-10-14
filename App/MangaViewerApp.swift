import SwiftUI
import MangaCore

@main struct MangaViewerApp: App {
    @State private var model = AppModel()
    var body: some Scene {
        mainWindow
        .defaultSize(width: 1100, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open URL…") { model.collapseReader(); model.section = .browse; model.path = []; model.openURLRequest += 1 }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
        #if os(macOS)
        Settings {
            SettingsView(model: model).frame(width: 550, height: 500)
                .alert(Text(verbatim: AppInfo.name), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                    Button("OK") { model.error = nil }
                } message: { Text(model.error ?? "") }
        }
        #endif
    }
    @SceneBuilder private var mainWindow: some Scene {
        #if os(iOS)
        WindowGroup { content }
        #else
        Window(Text(verbatim: AppInfo.name), id: "main") { content }
        #endif
    }
    private var content: some View {
        RootView(model: model)
            .frame(minWidth: 320, minHeight: 420)
            .task { await model.start() }
            #if os(visionOS)
            .controlSize(.large)
            .environment(\.defaultMinListRowHeight, 56)
            #endif
    }
}
