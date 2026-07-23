import SwiftUI

@main
struct OfflineWalkieTalkieApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var walkieTalkie: WalkieTalkie? = WalkieTalkie()
    @State private var chat = ChatManager()
    @State private var showingChat = false
    @State private var wasInBackground = false

    var body: some Scene {
        WindowGroup {
            if showingChat {
                ChatView {
                    walkieTalkie = WalkieTalkie()
                    showingChat = false
                }
                .environmentObject(chat)
            } else if let walkieTalkie {
                ContentView {
                    showingChat = true
                    self.walkieTalkie = nil
                }
                .environmentObject(walkieTalkie)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                wasInBackground = true
            } else if newPhase == .active, wasInBackground {
                wasInBackground = false
                if !showingChat {
                    walkieTalkie = WalkieTalkie()
                }
            }
        }
    }
}
