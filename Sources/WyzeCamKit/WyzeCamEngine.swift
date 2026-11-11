import Foundation
import Observation

/// The kit coordinator. Hosts build it inert, `start()` it when the kit's
/// screen comes on and `stop()` it when the screen goes or the app leaves the
/// foreground, and call `wipeLocalStore()` on sign-out. Stopped, it makes no
/// requests and holds no video connection: on a day nobody opens the screen,
/// the server never hears from this phone, and no camera at home streams.
///
/// Live video comes from players the views open through the engine
/// (`openPlayer` / `closePlayer`). The engine owns them: `stop()` hangs every
/// one up, `start()` reconnects the ones still open.
@MainActor
@Observable
public final class WyzeCamEngine {
    public enum Status: Sendable, Equatable {
        case idle
        case loading
        case ready
        /// The last refresh failed; the list shown is the last good one.
        case failed(String)
        case signedOut
    }

    // MARK: observable state

    /// Every camera the user may watch (own + shared), owned first then by name.
    public private(set) var cameras: [WyzeCamera] = []
    public private(set) var status: Status = .idle
    /// True between `start()` and `stop()`.
    public private(set) var isRunning = false

    public let config: WyzeCamConfig
    private let transport: any WyzeCamTransport
    private var players: [UUID: WyzeCamPlayer] = [:]
    private var iceCache: IceConfig?
    /// TURN credentials are refetched this long before they expire.
    static let iceMargin: TimeInterval = 600
    private var refreshTask: Task<Void, Never>?
    /// Bumped by stop(): work started before it must not write after it.
    private var generation = 0

    public init(config: WyzeCamConfig, transport: (any WyzeCamTransport)? = nil) {
        self.config = config
        self.transport = transport ?? config.transport
    }

    isolated deinit {
        refreshTask?.cancel()
        players.values.forEach { $0.suspend() }
    }

    // MARK: lifecycle

    /// Load the cameras, keep them fresh, and connect the open players. Idempotent.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        let gen = generation
        let interval = config.refreshInterval
        players.values.forEach { $0.resume() }
        // No strong self across the sleep: a host that drops a running
        // engine gets its deinit (and every player hung up) right away.
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { // the strong reference ends with this scope, before the sleep
                    guard let engine = self, gen == engine.generation else { return }
                    await engine.refresh()
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Stop all work and hang up every player. Safe to call repeatedly.
    public func stop() {
        generation += 1
        isRunning = false
        refreshTask?.cancel()
        refreshTask = nil
        players.values.forEach { $0.suspend() }
        if status == .loading { status = .idle }
    }

    /// Sign-out: stop, and forget everything this account loaded. The kit
    /// writes nothing on the phone (no database, no defaults, no pictures), so
    /// there is nothing on disk to remove.
    public func wipeLocalStore() {
        stop()
        players = [:]
        cameras = []
        iceCache = nil
        status = .idle
    }

    /// Reload the camera list now.
    public func refresh() async {
        let gen = generation
        if cameras.isEmpty, status != .ready { status = .loading }
        do {
            let list = try await transport.listCameras()
            guard gen == generation else { return }
            cameras = Self.sorted(list)
            status = .ready
        } catch WyzeCamTransportError.notAuthenticated {
            guard gen == generation else { return }
            status = .signedOut
        } catch {
            guard gen == generation else { return }
            status = .failed(Self.describe(error))
        }
    }

    public func camera(_ id: UUID) -> WyzeCamera? { cameras.first { $0.id == id } }

    /// Owned first, then by name.
    static func sorted(_ list: [WyzeCamera]) -> [WyzeCamera] {
        list.sorted {
            if $0.owned != $1.owned { return $0.owned }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: players

    /// A live view of `cameraID`. It connects now if the engine runs (else on
    /// `start()`), and keeps trying on its own until `closePlayer`. Pair every
    /// open with a close; the kit's views do.
    public func openPlayer(cameraID: UUID, quality: WyzeCamQuality) -> WyzeCamPlayer {
        let p = WyzeCamPlayer(cameraID: cameraID, quality: quality, transport: transport,
                              ice: { [weak self] in await self?.iceServers() ?? [] })
        // Access gone: the camera should leave the list now, not at the next tick.
        p.onRevoked = { [weak self] in
            guard let self, self.isRunning else { return }
            Task { await self.refresh() }
        }
        players[p.id] = p
        if isRunning { p.resume() }
        return p
    }

    /// Hang up and forget a player.
    public func closePlayer(_ player: WyzeCamPlayer) {
        player.suspend()
        players.removeValue(forKey: player.id)
    }

    /// TURN for the next connection: cached until shortly before it expires.
    /// A failure to fetch means direct paths only, never a failed view.
    func iceServers() async -> [IceServer] {
        if let c = iceCache, let exp = c.expiresAt, exp.timeIntervalSinceNow > Self.iceMargin {
            return c.servers
        }
        if let c = iceCache, c.servers.isEmpty, c.expiresAt == nil { return [] } // the server has none
        let gen = generation
        guard let fresh = try? await transport.iceServers() else { return iceCache?.servers ?? [] }
        if gen == generation { iceCache = fresh }
        return fresh.servers
    }

    /// Open players (for tests and the Lab).
    public var openPlayerCount: Int { players.count }

    // MARK: owner tools

    public func rename(_ camera: WyzeCamera, to name: String) async throws {
        let updated = try await transport.updateCamera(id: camera.id, name: name, color: nil)
        replace(updated)
    }

    public func setColor(_ color: WyzeCamColor, of camera: WyzeCamera) async throws {
        let updated = try await transport.updateCamera(id: camera.id, name: nil, color: color)
        replace(updated)
    }

    /// Shares on one camera, or on every camera the user owns (nil).
    public func grants(for cameraID: UUID?) async throws -> [WyzeCamGrant] {
        try await transport.listGrants(cameraID: cameraID)
    }

    public func share(_ cameraID: UUID, with contact: WyzeCamContact, until: Date?) async throws -> WyzeCamGrant {
        try await transport.createGrant(cameraID: cameraID, granteeID: contact.id, expiresAt: until)
    }

    /// Ends the share and any view it allowed, now.
    public func revoke(_ grant: WyzeCamGrant) async throws {
        try await transport.revokeGrant(id: grant.id)
    }

    public func contacts() async throws -> [WyzeCamContact] {
        try await transport.listContacts()
    }

    public func agents() async throws -> [WyzeCamAgent] {
        try await transport.listAgents()
    }

    /// Register a new home box. The token is shown once; it goes in the box's config.
    public func registerAgent(name: String) async throws -> RegisteredAgent {
        try await transport.registerAgent(name: name)
    }

    /// A new token for a home box. The old one stops working at once.
    public func rotateToken(of agent: WyzeCamAgent) async throws -> String {
        try await transport.rotateAgentToken(id: agent.id)
    }

    private func replace(_ camera: WyzeCamera) {
        guard let i = cameras.firstIndex(where: { $0.id == camera.id }) else { return }
        cameras[i] = camera
        cameras = Self.sorted(cameras)
    }

    nonisolated static func describe(_ error: Error) -> String {
        switch error as? WyzeCamTransportError {
        case .notAuthenticated: "Not signed in"
        case .offline: "Offline"
        case .unreachable: "Can't reach the server"
        case .notFound: "Not found"
        case .tooManyViews: "Too many cameras open at once"
        case .limit(let m), .invalid(let m): WyzeCamSharing.sentence(m)
        case .rpc(_, let m), .badResponse(let m): m
        case nil: (error as? URLError) != nil ? "Can't reach the server" : error.localizedDescription
        }
    }
}
