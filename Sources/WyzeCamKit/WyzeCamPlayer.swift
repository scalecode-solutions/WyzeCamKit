import Foundation
import Observation
@preconcurrency import WebRTC

/// Why a live view ended, as the server said on the events channel (or as the
/// player saw it).
public enum WyzeCamEndReason: String, Sendable, Equatable {
    /// The owner removed this user's access (or it expired).
    case revoked
    /// The camera's stream stopped (the camera dropped, or its home box did).
    case ended
    /// The camera's home box isn't connected.
    case offline
    /// The server is restarting.
    case server
    /// The connection itself failed or dropped.
    case connection

    /// Whether trying again could help. A revoked view stays ended.
    public var retryable: Bool { self != .revoked }

    public var message: String {
        switch self {
        case .revoked: "You no longer have access to this camera."
        case .ended: "The camera stopped streaming."
        case .offline: "The camera is offline."
        case .server: "The server is restarting."
        case .connection: "The connection dropped."
        }
    }

    init(event t: String) {
        self = WyzeCamEndReason(rawValue: t) ?? .ended
    }
}

/// One live view of one camera stream: its own WebRTC connection to the
/// server, video only, receive only. Built by the engine
/// (`WyzeCamEngine.openPlayer`), which suspends every player when it stops and
/// resumes them when it starts again, so a stopped engine holds no connection.
///
/// It never creates an audio track and never touches the audio session, so it
/// can't disturb a host's calls.
@MainActor
@Observable
public final class WyzeCamPlayer: Identifiable {
    public enum State: Sendable, Equatable {
        /// Not connected (not started yet, or the engine is stopped).
        case idle
        case connecting
        /// Pictures are arriving.
        case live
        /// Ended; `retrying` when the player will try again on its own.
        case ended(WyzeCamEndReason, retrying: Bool)
        case failed(String, retrying: Bool)
    }

    public nonisolated let id = UUID()
    public let cameraID: UUID
    /// What was asked for.
    public let requested: WyzeCamQuality
    public private(set) var state: State = .idle
    /// What the server is sending (SD falls back to HD on a camera without one).
    public private(set) var quality: WyzeCamQuality?
    /// Decoded picture size, once pictures arrive.
    public private(set) var videoSize: CGSize?
    /// Pictures per second over the last second.
    public private(set) var fps: Double = 0
    /// Offer → first picture, for the last connection.
    public private(set) var firstPictureAfter: Duration?

    /// The track the video view renders. Internal: hosts use `WyzeCamVideo`.
    private(set) var track: RTCVideoTrack?

    private let transport: any WyzeCamTransport
    /// TURN for the next connection (the engine's cache). Asked before the
    /// offer: non-trickle signaling can't add a relay afterwards.
    private let ice: @MainActor () async -> [IceServer]
    private var pc: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var delegate: Delegate?
    private var probe: FrameProbe?
    private var sessionID: String?
    private var wanted = false
    /// Bumped by every connect and hang-up: callbacks from an older connection are ignored.
    private var generation = 0
    private var retryTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var retryDelay: Duration = .seconds(2)
    /// Told when this view's access ended (the engine reloads the list then).
    var onRevoked: (@MainActor () -> Void)?

    static let maxRetryDelay: Duration = .seconds(30)
    /// No first picture this long after connecting: hang up and try again.
    static let firstPictureTimeout: Duration = .seconds(20)

    init(cameraID: UUID, quality: WyzeCamQuality, transport: any WyzeCamTransport,
         ice: @escaping @MainActor () async -> [IceServer] = { [] }) {
        self.cameraID = cameraID
        self.requested = quality
        self.transport = transport
        self.ice = ice
    }

    isolated deinit {
        retryTask?.cancel()
        statsTask?.cancel()
        hangUp(tellServer: true)
    }

    // MARK: lifecycle (the engine drives these)

    /// Connect, and keep trying until `suspend()` (retryable endings only).
    func resume() {
        guard !wanted else { return }
        wanted = true
        retryDelay = .seconds(2)
        connect()
    }

    /// Hang up and stay idle until `resume()`.
    func suspend() {
        wanted = false
        retryTask?.cancel()
        retryTask = nil
        hangUp(tellServer: true)
        state = .idle
    }

    /// Try again now (after a failure the user wants to retry by hand).
    public func retry() {
        guard wanted else { return }
        retryTask?.cancel()
        retryTask = nil
        retryDelay = .seconds(2)
        connect()
    }

    // MARK: connection

    private func connect() {
        hangUp(tellServer: true)
        generation += 1
        let gen = generation
        state = .connecting
        let t0 = ContinuousClock.now
        Task { [weak self] in
            guard let self else { return }
            let servers = await self.ice()
            guard gen == self.generation else { return } // hung up meanwhile
            self.build(gen: gen, since: t0, iceServers: servers)
        }
    }

    /// The ICE servers the last connection was built with (for tests).
    private(set) var builtWithICE: [IceServer] = []

    private func build(gen: Int, since t0: ContinuousClock.Instant, iceServers: [IceServer]) {
        builtWithICE = iceServers
        let config = RTCConfiguration()
        config.iceServers = iceServers.map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherContinually
        let delegate = Delegate()
        guard let pc = WebRTCFactory.shared.peerConnection(
            with: config, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
            delegate: delegate) else {
            fail("Couldn't start video", gen: gen)
            return
        }
        self.pc = pc
        self.delegate = delegate

        let tInit = RTCRtpTransceiverInit()
        tInit.direction = .recvOnly
        let transceiver = pc.addTransceiver(of: .video, init: tInit)
        // Events from the server ride a negotiated data channel, id 0.
        let dcConfig = RTCDataChannelConfiguration()
        dcConfig.isNegotiated = true
        dcConfig.channelId = 0
        let channel = pc.dataChannel(forLabel: "events", configuration: dcConfig)
        channel?.delegate = delegate
        self.channel = channel

        if let track = transceiver?.receiver.track as? RTCVideoTrack {
            let probe = FrameProbe { [weak self] size in
                Task { @MainActor in self?.firstPicture(size: size, gen: gen, since: t0) }
            }
            track.add(probe)
            self.probe = probe
            self.track = track
        }

        delegate.onState = { [weak self] s in
            Task { @MainActor in self?.connectionChanged(s, gen: gen) }
        }
        delegate.onEvent = { [weak self] t in
            Task { @MainActor in self?.serverEvent(t, gen: gen) }
        }

        Task { [weak self] in
            await self?.negotiate(pc, gen: gen)
        }
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            var last = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, gen == self.generation, let probe = self.probe else { return }
                let n = probe.frames
                self.fps = Double(n - last)
                last = n
                if self.state == .connecting, ContinuousClock.now - t0 > Self.firstPictureTimeout {
                    self.end(.connection, gen: gen)
                    return
                }
            }
        }
    }

    private func negotiate(_ pc: RTCPeerConnection, gen: Int) async {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        do {
            let offer = try await pc.offer(for: constraints)
            // No waiting on our own ICE candidates: the server's are fixed and
            // in its answer, and it learns ours from the connectivity checks.
            try await pc.setLocalDescription(offer)
            guard gen == generation else { return }
            let answer = try await transport.watch(cameraID: cameraID, offerSDP: offer.sdp, quality: requested)
            guard gen == generation else {
                await transport.stopWatching(sessionID: answer.sessionID) // hung up meanwhile
                return
            }
            sessionID = answer.sessionID
            quality = answer.quality
            if answer.width > 0 { videoSize = CGSize(width: answer.width, height: answer.height) }
            try await pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answer.answerSDP))
        } catch let e as WyzeCamTransportError {
            guard gen == generation else { return }
            switch e {
            case .offline: end(.offline, gen: gen)
            case .unreachable: fail("Can't reach the server", gen: gen)
            case .notFound: end(.revoked, gen: gen)
            case .tooManyViews, .limit: fail("Too many cameras open at once", gen: gen)
            case .notAuthenticated: fail("Not signed in", gen: gen)
            case .rpc(_, let m), .badResponse(let m), .invalid(let m): fail(m, gen: gen)
            }
        } catch {
            guard gen == generation else { return }
            fail("Couldn't connect", gen: gen)
        }
    }

    private func firstPicture(size: CGSize, gen: Int, since t0: ContinuousClock.Instant) {
        guard gen == generation else { return }
        if size.width > 0 { videoSize = size }
        if state == .connecting {
            state = .live
            firstPictureAfter = ContinuousClock.now - t0
            retryDelay = .seconds(2) // a good connection resets the backoff
        }
    }

    private func connectionChanged(_ s: RTCPeerConnectionState, gen: Int) {
        guard gen == generation else { return }
        if s == .failed || s == .closed { end(.connection, gen: gen) }
    }

    private func serverEvent(_ t: String, gen: Int) {
        guard gen == generation else { return }
        end(WyzeCamEndReason(event: t), gen: gen)
    }

    private func end(_ reason: WyzeCamEndReason, gen: Int) {
        guard gen == generation else { return }
        hangUp(tellServer: reason == .connection)
        let again = wanted && reason.retryable
        state = .ended(reason, retrying: again)
        if reason == .revoked { onRevoked?() }
        if again { scheduleRetry() }
    }

    private func fail(_ message: String, gen: Int) {
        guard gen == generation else { return }
        hangUp(tellServer: true)
        // Every failure retries with backoff, "Not signed in" too: the host's
        // token may come back (a refresh), and while it's missing the
        // transport fails locally without a request.
        let again = wanted
        state = .failed(message, retrying: again)
        if again { scheduleRetry() }
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, Self.maxRetryDelay)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.wanted else { return }
            self.connect()
        }
    }

    /// Close the connection. Bumps the generation, so nothing from it lands later.
    private func hangUp(tellServer: Bool) {
        generation += 1
        statsTask?.cancel()
        statsTask = nil
        if let probe, let track { track.remove(probe) }
        probe = nil
        track = nil
        channel?.delegate = nil
        channel?.close()
        channel = nil
        pc?.close()
        pc = nil
        delegate = nil
        fps = 0
        if tellServer, let sid = sessionID {
            let transport = self.transport
            Task { await transport.stopWatching(sessionID: sid) }
        }
        sessionID = nil
    }
}

// MARK: - WebRTC plumbing

/// One factory for the process (decoders via VideoToolbox). The kit makes no
/// audio tracks, so the factory's audio device is never started by it.
enum WebRTCFactory {
    nonisolated(unsafe) static let shared: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()
}

/// Delegate callbacks arrive on WebRTC's own threads; they only forward.
private final class Delegate: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
    var onState: (@Sendable (RTCPeerConnectionState) -> Void)?
    var onEvent: (@Sendable (String) -> Void)?

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        onState?(newState)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let t = ServerEvent.parse(buffer.data, binary: buffer.isBinary) else { return }
        onEvent?(t)
    }
}

/// The events channel's frames: `{"t":"revoked"|"ended"|"offline"|"server"}`.
/// Anything else (binary, not JSON, no string `t`, oversized) is ignored: the
/// channel only ever ends a view, so noise must not end one.
enum ServerEvent {
    static let maxFrame = 4096

    static func parse(_ data: Data, binary: Bool = false) -> String? {
        guard !binary, data.count <= maxFrame,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["t"] as? String, !t.isEmpty, t.count <= 32 else { return nil }
        return t
    }
}

/// Counts decoded pictures (for fps) and reports the first one. Called on
/// WebRTC's render thread.
private final class FrameProbe: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var size = CGSize.zero
    private let onFirst: @Sendable (CGSize) -> Void

    init(onFirst: @escaping @Sendable (CGSize) -> Void) { self.onFirst = onFirst }

    var frames: Int { lock.withLock { count } }

    func setSize(_ size: CGSize) {
        lock.withLock { self.size = size }
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        let first: Bool = lock.withLock {
            count += 1
            if size == .zero { size = CGSize(width: Int(frame.width), height: Int(frame.height)) }
            return count == 1
        }
        if first { onFirst(lock.withLock { size }) }
    }
}
