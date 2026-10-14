import SwiftUI

@main
struct PeakActivityCompanionApp: App {
    @StateObject private var store = CompanionStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .onChange(of: scenePhase) { phase in
                    if phase == .active { store.load() } else { store.suspendLocalSync() }
                }
        }
    }
}
