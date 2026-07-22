import SwiftUI

@main
struct OfflineWalkieTalkieApp: App {
    @StateObject private var walkieTalkie = WalkieTalkie()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(walkieTalkie)
        }
    }
}
