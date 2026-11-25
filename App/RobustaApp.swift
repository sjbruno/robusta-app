import RobustaCore
import SwiftUI

@main
struct RobustaApp: App {
    @State private var store: AppStore

    init() {
        let store = AppStore()
        _store = State(initialValue: store)
        #if DEBUG
        Snapshot.runIfRequested()
        LiveSnapshot.scheduleIfRequested(store: store)
        LiveSnapshot.scheduleSettingsIfRequested()
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            MainView(store: store, initialTab: store.startTab)
        } label: {
            // Grão de café em PDF vetorial, modo template (Tools/make-icon.swift).
            Image(DS.menuBarImage).accessibilityLabel("Robusta")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
        }
    }
}
