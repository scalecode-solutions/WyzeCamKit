import Foundation
import Testing
import WyzeCamKit

// Shared by the kit's test targets: a fake server, a wait helper, and a
// camera maker. Public API only, so neither target needs the other.

/// A server stand-in that records what the kit asked for.
public actor FakeTransport: WyzeCamTransport {
    public var cameras: [WyzeCamera] = []
    public var listError: WyzeCamTransportError?
    public var watchError: WyzeCamTransportError = .offline
    /// When set, watch answers with this (after `watchDelay`) instead of failing.
    public var watchAnswer: WatchAnswer?
    public var watchDelay: Duration = .zero
    public var listDelay: Duration = .zero
    public var ice: IceConfig = .none
    public var iceError: WyzeCamTransportError?
    public private(set) var iceCalls = 0
    /// Every call, in order ("ice", "watch", "list").
    public private(set) var calls: [String] = []
    public private(set) var listCalls = 0
    public private(set) var watchCalls: [(UUID, WyzeCamQuality, String)] = []
    /// When each watch arrived (backoff tests read the gaps).
    public private(set) var watchTimes: [ContinuousClock.Instant] = []
    public private(set) var stopped: [String] = []

    public init(cameras: [WyzeCamera] = []) { self.cameras = cameras }

    public func set(cameras: [WyzeCamera]) { self.cameras = cameras }
    public func set(listError: WyzeCamTransportError?) { self.listError = listError }
    public func set(watchError: WyzeCamTransportError) { self.watchError = watchError }
    public func set(answer: WatchAnswer?, delay: Duration = .zero) { watchAnswer = answer; watchDelay = delay }
    public func set(listDelay: Duration) { self.listDelay = listDelay }
    public func set(ice: IceConfig, error: WyzeCamTransportError? = nil) { self.ice = ice; iceError = error }

    public func iceServers() async throws -> IceConfig {
        iceCalls += 1
        calls.append("ice")
        if let iceError { throw iceError }
        return ice
    }

    public func listCameras() async throws -> [WyzeCamera] {
        listCalls += 1
        if listDelay > .zero { try? await Task.sleep(for: listDelay) }
        if let listError { throw listError }
        return cameras
    }

    public func watch(cameraID: UUID, offerSDP: String, quality: WyzeCamQuality) async throws -> WatchAnswer {
        watchCalls.append((cameraID, quality, offerSDP))
        watchTimes.append(.now)
        calls.append("watch")
        if watchDelay > .zero { try? await Task.sleep(for: watchDelay) }
        if let watchAnswer { return watchAnswer }
        throw watchError
    }

    public func stopWatching(sessionID: String) async { stopped.append(sessionID) }
}

/// Waits for something that should happen. The limit is generous on
/// purpose: it only matters when the thing never happens, and a busy machine
/// (a parallel run beside other builds) can take seconds for what's normally
/// a tenth of one.
@MainActor
public func eventually(_ what: String, timeout: Duration = .seconds(20), _ cond: @MainActor () async -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await cond() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("timed out waiting for \(what)")
}

public let me = UUID()

public func cam(_ name: String, owned: Bool = true, online: Bool = true, sd: Bool = true) -> WyzeCamera {
    WyzeCamera(id: UUID(), name: name, online: online, owned: owned, hasSD: sd, camKey: name.lowercased())
}
