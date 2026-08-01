import SwiftUI

@main
struct HopBoardApp: App {
    @StateObject private var session = SessionManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
                .onOpenURL { url in
                    guard url.scheme == "hopboard" else { return }
                    // hopboard://session/start — the keyboard's deep link.
                    if url.host == "session", url.lastPathComponent == "start" {
                        Task { await session.startSession() }
                    }
                    // hopboard://settings — the keyboard's gear key.
                    if url.host == "settings" {
                        session.showSettings = true
                    }
                }
                .task {
                    // Dev hooks for driving the sim without UI taps
                    // (launched via SIMCTL_CHILD_FLOW_AUTO*, like hop-ios).
                    let env = ProcessInfo.processInfo.environment
                    guard env["FLOW_AUTOSTART"] == "1" || env["FLOW_AUTOTEST"] == "1" else { return }
                    await session.startSession()
                    if env["FLOW_AUTOTEST"] == "1", session.state == .ready {
                        session.beginSegment()
                        try? await Task.sleep(for: .seconds(2))
                        session.finishSegment()
                    }
                }
        }
    }
}
