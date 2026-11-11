import SwiftUI
import WyzeCamKit
import MvAuth

struct ContentView: View {
    @State private var auth = AuthModel()

    var body: some View {
        #if DEBUG
        // Automation: `WYZECAMLAB_USER` + `WYZECAMLAB_TOKEN` (a minted dev token)
        // skip the login screen, so a script can drive simulators without
        // anyone's password. Debug builds only.
        if let dev = DevSession.fromEnvironment {
            WyzeCamLabHost(userID: dev.userID, baseURL: dev.baseURL, serverName: "Local (dev token)",
                           tokenProvider: { dev.token }, signOut: {})
        } else {
            signedIn
        }
        #else
        signedIn
        #endif
    }

    @ViewBuilder private var signedIn: some View {
        switch auth.state {
        case .loggedIn(let profile):
            WyzeCamLabHost(userID: profile.userID, baseURL: auth.server.cameraBaseURL, serverName: auth.server.rawValue,
                           tokenProvider: { [auth] in await auth.accessToken() }, signOut: { [auth] in auth.logOut() })
                .id(profile.userID) // a fresh engine per identity
        default:
            LoginView(auth: auth)
        }
    }
}

#if DEBUG
struct DevSession: Sendable {
    let userID: String
    let token: String
    let baseURL: URL

    static var fromEnvironment: DevSession? {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["WYZECAMLAB_USER"], UUID(uuidString: user) != nil,
              let token = env["WYZECAMLAB_TOKEN"], !token.isEmpty else { return nil }
        let base = env["WYZECAMLAB_URL"].flatMap(URL.init(string:)) ?? LabServer.local.cameraBaseURL
        return DevSession(userID: user, token: token, baseURL: base)
    }
}
#endif

/// The dev host, shaped like a production one: the engine is built inert with
/// the Lab's token provider, runs only while this screen is up and the app is
/// in front, and is wiped on sign-out.
struct WyzeCamLabHost: View {
    let userID: String
    let serverName: String
    let signOut: @MainActor () -> Void
    @State private var engine: WyzeCamEngine
    @Environment(\.scenePhase) private var scenePhase

    init(userID: String, baseURL: URL, serverName: String,
         tokenProvider: @escaping @Sendable () async -> String?, signOut: @escaping @MainActor () -> Void) {
        self.userID = userID
        self.serverName = serverName
        self.signOut = signOut
        let config = WyzeCamConfig(
            baseURL: baseURL,
            currentUserID: UUID(uuidString: userID) ?? UUID(),
            tokenProvider: tokenProvider
        )
        _engine = State(initialValue: WyzeCamEngine(config: config))
    }

    var body: some View {
        // Hosted the way a production host does it: the grid in a navigation
        // stack, the live view pushed by the kit, owner tools pushed from a
        // toolbar gear. (A production host shows the gear only to owners;
        // the Lab always does, so a fresh account can add its first home box.)
        NavigationStack {
            root
                .navigationTitle("Cameras")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            WyzeCamOwnerView(engine: engine) { accountSection }
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Manage cameras")
                    }
                }
        }
        // The NavigationStack stays in place while the kit pushes its screens,
        // so this lifetime (not a pushed screen's) is the engine's: one start
        // when the Lab comes up, one stop when it goes.
        .onAppear { engine.start() }
        .onDisappear { engine.stop() }
        // Silent unless it's on screen: in the background every video
        // connection closes and the home box stops streaming; coming back
        // reconnects the views still open.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: engine.start()
            case .background: engine.stop()
            default: break
            }
        }
    }

    /// The grid; or, for automation (Debug), `WYZECAMLAB_OPEN=<camera id>`
    /// opens that camera's live view and `WYZECAMLAB_OPEN=owner` the owner screen.
    @ViewBuilder private var root: some View {
        #if DEBUG
        let open = ProcessInfo.processInfo.environment["WYZECAMLAB_OPEN"] ?? ""
        if open == "owner" {
            WyzeCamOwnerView(engine: engine) { accountSection }
        } else if let id = UUID(uuidString: open) {
            WyzeCamLiveView(engine: engine, cameraID: id)
        } else {
            WyzeCamView(engine: engine)
        }
        #else
        WyzeCamView(engine: engine)
        #endif
    }

    /// WyzeCamLab's own rows, appended to the kit's owner screen.
    private var accountSection: some View {
        Section {
            LabeledContent("User ID") {
                Text(userID).font(.caption.monospaced()).textSelection(.enabled)
            }
            LabeledContent("Server", value: serverName)
            LabeledContent("Open video views", value: "\(engine.openPlayerCount)")
            Button("Sign out", role: .destructive) {
                engine.wipeLocalStore()
                signOut()
            }
        } header: {
            Text("Account")
        }
    }
}
