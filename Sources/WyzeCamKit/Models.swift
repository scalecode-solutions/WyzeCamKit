import Foundation

/// A camera the user may watch: their own, or one shared with them.
public struct WyzeCamera: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public var name: String
    public var color: WyzeCamColor
    /// Its home box is connected and last saw the camera.
    public var online: Bool
    public var owned: Bool
    /// It has an SD substream (grids use it; the live view uses HD).
    public var hasSD: Bool
    /// Owner only: the home box it hangs off, and its key in that box's config.
    public var agentID: UUID?
    public var camKey: String

    public init(id: UUID, name: String, color: WyzeCamColor = .standard, online: Bool = false,
                owned: Bool = false, hasSD: Bool = false, agentID: UUID? = nil, camKey: String = "") {
        self.id = id
        self.name = name
        self.color = color
        self.online = online
        self.owned = owned
        self.hasSD = hasSD
        self.agentID = agentID
        self.camKey = camKey
    }
}

/// A camera's color, from the server's palette (shared with GarageKit: no red
/// or orange, they mean trouble).
public enum WyzeCamColor: String, CaseIterable, Sendable, Hashable {
    case standard = ""
    case cyan, sky, blue, indigo, purple, pink, teal, mint, yellow, brown

    public init(token: String) { self = WyzeCamColor(rawValue: token) ?? .standard }

    /// The ones an owner picks from (`.standard` is "no choice": it looks cyan).
    public static var palette: [WyzeCamColor] { allCases.filter { $0 != .standard } }

    public var label: String {
        switch self {
        case .standard: "Default"
        default: rawValue.capitalized
        }
    }
}

/// Which of a camera's streams to watch.
public enum WyzeCamQuality: String, Sendable, Hashable, CaseIterable {
    /// The main stream (Wyze v4: 2560x1440).
    case hd
    /// The substream (Wyze v4: 640x360, a fraction of the bandwidth).
    case sd

    public var label: String { rawValue.uppercased() }
}

/// Someone a camera is shared with.
public struct WyzeCamGrant: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let cameraID: UUID
    public let granteeID: UUID
    /// The name the server knew them by when it answered (may be empty).
    public let granteeName: String
    public let createdAt: Date?
    /// nil = until the owner removes it.
    public let expiresAt: Date?

    public init(id: UUID, cameraID: UUID, granteeID: UUID, granteeName: String = "",
                createdAt: Date? = nil, expiresAt: Date? = nil) {
        self.id = id
        self.cameraID = cameraID
        self.granteeID = granteeID
        self.granteeName = granteeName
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

/// A person the owner may share with (the host's social graph, projected by
/// the server).
public struct WyzeCamContact: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let name: String
    public let avatar: Data?

    public init(id: UUID, name: String, avatar: Data? = nil) {
        self.id = id
        self.name = name
        self.avatar = avatar
    }
}

/// A home box (mvcam-agent) the owner registered.
public struct WyzeCamAgent: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let name: String
    public let online: Bool
    public let version: String
    public let lastSeen: Date?
    public let createdAt: Date?

    public init(id: UUID, name: String, online: Bool = false, version: String = "",
                lastSeen: Date? = nil, createdAt: Date? = nil) {
        self.id = id
        self.name = name
        self.online = online
        self.version = version
        self.lastSeen = lastSeen
        self.createdAt = createdAt
    }
}

/// A home box just registered, with its token (shown once).
public struct RegisteredAgent: Sendable, Equatable {
    public let agent: WyzeCamAgent
    public let token: String
}

/// What `watch` gets back: the server's half of the WebRTC handshake.
public struct WatchAnswer: Sendable, Equatable {
    public struct IceServer: Sendable, Equatable {
        public let urls: [String]
        public let username: String
        public let credential: String
    }
    public let sessionID: String
    public let answerSDP: String
    public let iceServers: [IceServer]
    /// 0 until the camera has streamed since the server started.
    public let width: Int
    public let height: Int
    /// What's actually being sent (SD falls back to HD on a camera without one).
    public let quality: WyzeCamQuality
}
