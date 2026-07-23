import SwiftUI

@main
struct OfflineWalkieTalkieApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var walkieTalkie = WalkieTalkie()
    @State private var wasInBackground = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(walkieTalkie)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                wasInBackground = true
            } else if newPhase == .active, wasInBackground {
                wasInBackground = false
                walkieTalkie = WalkieTalkie()
            }
        }
    }
}
