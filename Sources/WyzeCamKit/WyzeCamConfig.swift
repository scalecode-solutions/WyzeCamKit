import Foundation

/// Everything WyzeCamKit needs from the host. The token provider is `@Sendable` +
/// `async` so the host can hand over its current mvServer access token
/// (auto-refreshed) from its own actor. WyzeCamKit never logs anyone in.
public struct WyzeCamConfig: Sendable {
    /// mvCamera base URL (Connect), e.g. `https://cam.example.app`.
    public let baseURL: URL
    /// The signed-in user (mvServer UUID).
    public let currentUserID: UUID
    public let tokenProvider: @Sendable () async -> String?
    /// How often the camera list (names, online dots) is refreshed while the
    /// engine runs. Nothing is fetched while it's stopped.
    public let refreshInterval: Duration

    public init(baseURL: URL,
                currentUserID: UUID,
                tokenProvider: @escaping @Sendable () async -> String?,
                refreshInterval: Duration = .seconds(15)) {
        self.baseURL = baseURL
        self.currentUserID = currentUserID
        self.tokenProvider = tokenProvider
        self.refreshInterval = refreshInterval
    }

    /// The live transport — Connect/protobuf against mvCamera.
    public var transport: any WyzeCamTransport {
        ConnectWyzeCamTransport(baseURL: baseURL, tokenProvider: tokenProvider)
    }
}
