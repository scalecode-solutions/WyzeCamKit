import Foundation
import Connect
import SwiftProtobuf

/// Transport-level failures.
public enum WyzeCamTransportError: Error, Sendable, Equatable {
    /// No token, or the server said the token isn't good: signed out.
    case notAuthenticated
    /// The camera doesn't exist for this user (no access looks the same, on purpose).
    case notFound
    /// The camera or its home box is offline.
    case offline
    /// Too many open views for this user.
    case tooManyViews
    case rpc(code: String, message: String)
    case badResponse(String)
}

/// The kit's view of the server. A protocol so tests and previews can fake it.
public protocol WyzeCamTransport: Sendable {
    func listCameras() async throws -> [WyzeCamera]
    /// Trade an SDP offer for the server's answer (non-trickle).
    func watch(cameraID: UUID, offerSDP: String, quality: WyzeCamQuality) async throws -> WatchAnswer
    /// Hang up a view. Best effort: the server also notices a dropped connection.
    func stopWatching(sessionID: String) async

    // Owner tools.
    func updateCamera(id: UUID, name: String?, color: WyzeCamColor?) async throws -> WyzeCamera
    func listGrants(cameraID: UUID?) async throws -> [WyzeCamGrant]
    func createGrant(cameraID: UUID, granteeID: UUID, expiresAt: Date?) async throws -> WyzeCamGrant
    func revokeGrant(id: UUID) async throws
    /// The people the caller may share with.
    func listContacts() async throws -> [WyzeCamContact]
    func listAgents() async throws -> [WyzeCamAgent]
    func registerAgent(name: String) async throws -> RegisteredAgent
    func rotateAgentToken(id: UUID) async throws -> String
}

public extension WyzeCamTransport {
    /// Defaults for fakes that only cover viewing.
    func updateCamera(id: UUID, name: String?, color: WyzeCamColor?) async throws -> WyzeCamera {
        throw WyzeCamTransportError.badResponse("not supported")
    }
    func listGrants(cameraID: UUID?) async throws -> [WyzeCamGrant] { [] }
    func createGrant(cameraID: UUID, granteeID: UUID, expiresAt: Date?) async throws -> WyzeCamGrant {
        throw WyzeCamTransportError.badResponse("not supported")
    }
    func revokeGrant(id: UUID) async throws { throw WyzeCamTransportError.badResponse("not supported") }
    func listContacts() async throws -> [WyzeCamContact] { [] }
    func listAgents() async throws -> [WyzeCamAgent] { [] }
    func registerAgent(name: String) async throws -> RegisteredAgent {
        throw WyzeCamTransportError.badResponse("not supported")
    }
    func rotateAgentToken(id: UUID) async throws -> String {
        throw WyzeCamTransportError.badResponse("not supported")
    }
}

/// `WyzeCamTransport` over Connect/protobuf. Wraps the generated client and
/// injects the bearer token per call.
public struct ConnectWyzeCamTransport: WyzeCamTransport {
    private let client: Camera_V1_CameraServiceClient
    private let tokenProvider: @Sendable () async -> String?

    public init(baseURL: URL, tokenProvider: @escaping @Sendable () async -> String?) {
        let config = ProtocolClientConfig(host: baseURL.absoluteString, networkProtocol: .connect, codec: ProtoCodec())
        let proto = ProtocolClient(httpClient: URLSessionHTTPClient(), config: config)
        self.client = Camera_V1_CameraServiceClient(client: proto)
        self.tokenProvider = tokenProvider
    }

    // MARK: plumbing

    private func authHeaders() async throws -> Headers {
        // No token → fail locally rather than send a request the server can only reject.
        guard let tok = await tokenProvider() else { throw WyzeCamTransportError.notAuthenticated }
        return ["Authorization": ["Bearer \(tok)"]]
    }

    private func value<T>(_ r: ResponseMessage<T>) throws -> T {
        if let m = r.message { return m }
        if let e = r.error { throw Wire.error(code: e.code, message: e.message) }
        throw WyzeCamTransportError.badResponse("empty rpc response")
    }

    // MARK: viewing

    public func listCameras() async throws -> [WyzeCamera] {
        let r = try value(await client.listCameras(request: .init(), headers: try await authHeaders()))
        return try r.cameras.map(Wire.camera)
    }

    public func watch(cameraID: UUID, offerSDP: String, quality: WyzeCamQuality) async throws -> WatchAnswer {
        var req = Camera_V1_WatchRequest()
        req.cameraID = Wire.id(cameraID)
        req.offerSdp = offerSDP
        req.quality = quality == .sd ? .sd : .hd
        let r = try value(await client.watch(request: req, headers: try await authHeaders()))
        return Wire.answer(r)
    }

    public func stopWatching(sessionID: String) async {
        guard let headers = try? await authHeaders() else { return }
        var req = Camera_V1_StopWatchingRequest()
        req.sessionID = sessionID
        _ = await client.stopWatching(request: req, headers: headers)
    }

    // MARK: owner tools

    public func updateCamera(id: UUID, name: String?, color: WyzeCamColor?) async throws -> WyzeCamera {
        var req = Camera_V1_UpdateCameraRequest()
        req.cameraID = Wire.id(id)
        if let name { req.name = name }
        if let color { req.color = color.rawValue }
        let r = try value(await client.updateCamera(request: req, headers: try await authHeaders()))
        return try Wire.camera(r.camera)
    }

    public func listGrants(cameraID: UUID?) async throws -> [WyzeCamGrant] {
        var req = Camera_V1_ListGrantsRequest()
        if let cameraID { req.cameraID = Wire.id(cameraID) }
        let r = try value(await client.listGrants(request: req, headers: try await authHeaders()))
        return try r.grants.map(Wire.grant)
    }

    public func createGrant(cameraID: UUID, granteeID: UUID, expiresAt: Date?) async throws -> WyzeCamGrant {
        var req = Camera_V1_CreateGrantRequest()
        req.cameraID = Wire.id(cameraID)
        req.granteeID = Wire.id(granteeID)
        if let expiresAt { req.expiresMs = Wire.ms(expiresAt) }
        let r = try value(await client.createGrant(request: req, headers: try await authHeaders()))
        return try Wire.grant(r.grant)
    }

    public func revokeGrant(id: UUID) async throws {
        var req = Camera_V1_RevokeGrantRequest()
        req.grantID = Wire.id(id)
        _ = try value(await client.revokeGrant(request: req, headers: try await authHeaders()))
    }

    public func listContacts() async throws -> [WyzeCamContact] {
        let r = try value(await client.listContacts(request: .init(), headers: try await authHeaders()))
        return try r.contacts.map(Wire.contact)
    }

    public func listAgents() async throws -> [WyzeCamAgent] {
        let r = try value(await client.listAgents(request: .init(), headers: try await authHeaders()))
        return try r.agents.map(Wire.agent)
    }

    public func registerAgent(name: String) async throws -> RegisteredAgent {
        var req = Camera_V1_RegisterAgentRequest()
        req.name = name
        let r = try value(await client.registerAgent(request: req, headers: try await authHeaders()))
        return RegisteredAgent(agent: try Wire.agent(r.agent), token: r.token)
    }

    public func rotateAgentToken(id: UUID) async throws -> String {
        var req = Camera_V1_RotateAgentTokenRequest()
        req.agentID = Wire.id(id)
        return try value(await client.rotateAgentToken(request: req, headers: try await authHeaders())).token
    }
}

/// Proto ↔ model mapping, free of the network so tests can pin it.
enum Wire {
    static func id(_ u: UUID) -> String { u.uuidString.lowercased() }

    static func uuid(_ s: String) throws -> UUID {
        guard let u = UUID(uuidString: s) else { throw WyzeCamTransportError.badResponse("bad uuid \(s)") }
        return u
    }

    static func date(_ ms: Int64) -> Date? { ms > 0 ? Date(timeIntervalSince1970: Double(ms) / 1000) : nil }
    static func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }

    static func error(code: Code, message: String?) -> WyzeCamTransportError {
        switch code {
        case .unauthenticated: .notAuthenticated
        case .notFound, .permissionDenied: .notFound
        case .unavailable: .offline
        case .resourceExhausted: .tooManyViews
        default: .rpc(code: "\(code)", message: message ?? "rpc failed")
        }
    }

    static func camera(_ c: Camera_V1_Camera) throws -> WyzeCamera {
        // swift-protobuf renames has_sd to hasSd_p: "has…" clashes with its presence accessors.
        WyzeCamera(id: try uuid(c.id), name: c.name, color: WyzeCamColor(token: c.color), online: c.online,
                   owned: c.isOwner, hasSD: c.hasSd_p, agentID: UUID(uuidString: c.agentID), camKey: c.camKey)
    }

    static func grant(_ g: Camera_V1_Grant) throws -> WyzeCamGrant {
        WyzeCamGrant(id: try uuid(g.id), cameraID: try uuid(g.cameraID), granteeID: try uuid(g.granteeID),
                     granteeName: g.granteeName, createdAt: date(g.createdMs), expiresAt: date(g.expiresMs))
    }

    static func contact(_ c: Camera_V1_Contact) throws -> WyzeCamContact {
        WyzeCamContact(id: try uuid(c.userID), name: c.name,
                       avatar: c.avatar.isEmpty ? nil : Data(base64Encoded: c.avatar))
    }

    static func agent(_ a: Camera_V1_Agent) throws -> WyzeCamAgent {
        WyzeCamAgent(id: try uuid(a.id), name: a.name, online: a.online, version: a.version,
                     lastSeen: date(a.lastSeenMs), createdAt: date(a.createdMs))
    }

    static func answer(_ r: Camera_V1_WatchResponse) -> WatchAnswer {
        WatchAnswer(sessionID: r.sessionID, answerSDP: r.answerSdp,
                    iceServers: r.iceServers.map { .init(urls: $0.urls, username: $0.username, credential: $0.credential) },
                    width: Int(r.width), height: Int(r.height),
                    quality: r.quality == .sd ? .sd : .hd)
    }
}
