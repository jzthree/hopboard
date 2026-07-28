import SwiftUI

@main
struct FlowBoardApp: App {
    @StateObject private var session = SessionManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
                .onOpenURL { url in
                    guard url.scheme == "flowboard" else { return }
                    // flowboard://session/start — the keyboard's deep link.
                    if url.host == "session", url.lastPathComponent == "start" {
                        Task { await session.startSession() }
                    }
                }
        }
    }
}
