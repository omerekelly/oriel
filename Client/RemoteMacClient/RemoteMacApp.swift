import SwiftUI

@main
struct RemoteMacApp: App {
    @StateObject private var session = ClientSession()

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
                .preferredColorScheme(.dark)
                .persistentSystemOverlays(.hidden)
        }
    }
}

struct RootView: View {
    @ObservedObject var session: ClientSession

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if session.state == .connected {
                SessionView(session: session)
                    .transition(.opacity)
            } else {
                ConnectView(session: session)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session.state)
        .onAppear {
            // Dev affordance: `simctl launch ... -autoconnect` skips the connect
            // screen so the stream can be exercised without tapping.
            guard ProcessInfo.processInfo.arguments.contains("-autoconnect") else { return }
            let defaults = UserDefaults.standard
            let host = defaults.string(forKey: "lastHost") ?? "100.78.170.16"
            let port = UInt16(defaults.string(forKey: "lastPort") ?? "") ?? ProtocolLimits.defaultPort
            let token = defaults.string(forKey: "pairingCode") ?? ""
            session.connect(host: host, port: port, token: token)
        }
    }
}
