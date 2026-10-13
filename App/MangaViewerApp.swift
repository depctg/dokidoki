import SwiftUI
import MangaCore

@main struct MangaViewerApp: App {
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 320, minHeight: 420)
                .task { await model.start() }
        }
        .defaultSize(width: 1100, height: 800)
        #if os(macOS)
        Settings { SettingsView(model: model).frame(width: 550, height: 500) }
        #endif
    }
}
