import Foundation

/// Which backend WyzeCamLab talks to. Auth goes to mvServer (WebSocket via
/// MvAuth); camera calls go to mvCamera (Connect, plus WebRTC for video, via
/// WyzeCamKit). Same credentials, two services. Develop against **Local**
/// (mvServer + mvCamera in local Docker).
enum LabServer: String, CaseIterable, Identifiable, Sendable {
    case production = "Production"
    case local = "Local"

    var id: String { rawValue }

    /// Where the local stack lives. "localhost" on a simulator; on a real phone,
    /// the Mac's name on the network (e.g. "My-Mac.local"), set on the login
    /// screen. The Mac must publish mvServer's and mvCamera's ports (and the
    /// WebRTC port) on the network for that.
    static var localHost: String {
        get {
            let h = UserDefaults.standard.string(forKey: "WyzeCamLab.localHost")?.trimmingCharacters(in: .whitespaces) ?? ""
            return h.isEmpty ? "localhost" : h
        }
        set { UserDefaults.standard.set(newValue, forKey: "WyzeCamLab.localHost") }
    }

    /// mvServer WebSocket endpoint MvAuth logs in against.
    var authWS: URL {
        switch self {
        case .production: URL(string: "wss://api.mvchat.app/v0/ws")!
        case .local:      URL(string: "ws://\(Self.localHost):6170/v0/ws") ?? URL(string: "ws://localhost:6170/v0/ws")!
        }
    }

    /// mvCamera base URL WyzeCamKit talks to.
    var cameraBaseURL: URL {
        switch self {
        case .production: URL(string: "https://cam.mvchat.app")!
        case .local:      URL(string: "http://\(Self.localHost):6096") ?? URL(string: "http://localhost:6096")!
        }
    }
}
