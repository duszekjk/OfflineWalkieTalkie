import SwiftUI

@main
struct OfflineWalkieTalkieApp: App {
    @StateObject private var walkieTalkie = WalkieTalkie()
    @StateObject private var chat = ChatManager()

    var body: some Scene {
        WindowGroup {
            Group {
                if chat.appMode == .chat {
                    ChatView()
                } else {
                    ContentView()
                }
            }
            .environmentObject(walkieTalkie)
            .environmentObject(chat)
            .onChange(of: chat.appMode) { _, mode in
                walkieTalkie.isTalking = false
                walkieTalkie.callActive = false

                if mode == .walkieTalkie {
                    walkieTalkie.mode = .walkieTalkie
                } else if mode == .call {
                    walkieTalkie.mode = .call
                }
            }
        }
    }
}
