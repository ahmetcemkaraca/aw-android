import SwiftUI

@main
struct PeakActivityCompanionApp: App {
    @StateObject private var store = CompanionStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
        }
    }
}
