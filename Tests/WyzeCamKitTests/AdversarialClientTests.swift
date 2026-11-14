import Foundation
import Testing
@testable import WyzeCamKit
import WyzeCamKitTestSupport

/// The client against a server (or network) that misbehaves: late, hostile,
/// malformed, or simply gone. Each test names the attack it pins.
@MainActor
@Suite struct AdversarialClientTests {
    func engine(_ t: FakeTransport, interval: Duration = .seconds(60)) -> WyzeCamEngine {
        WyzeCamEngine(config: WyzeCamConfig(baseURL: URL(string: "http://localhost:1")!, currentUserID: me,
                                            tokenProvider: { "t" }, refreshInterval: interval),
                      transport: t)
    }

    func answer(_ sid: String, sdp: String = "v=0\r\ngarbage", quality: WyzeCamQuality = .hd) -> WatchAnswer {
        WatchAnswer(sessionID: sid, answerSDP: sdp, iceServers: [], width: 0, height: 0, quality: quality)
    }

    // A session the server opened must never be left behind: an answer that
    // lands after the view was hung up is stopped on the server, and the
    // player stays idle.
    @Test func lateAnswerIsHungUpNotPlayed() async throws {
        let t = FakeTransport()
        await t.set(answer: answer("late-session"), delay: .milliseconds(400))
        let e = engine(t)
        e.start()
        let p = e.openPlayer(cameraID: UUID(), quality: .hd)
        await eventually("watch sent") { await !t.watchCalls.isEmpty }
        e.stop() // the user leaves before the server answers
        await eventually("late session stopped on the server") { await t.stopped.contains("late-session") }
        #expect(p.state == .idle)
        try await Task.sleep(for: .seconds(3))
        #expect(await t.watchCalls.count == 1, "a hung-up player must not reconnect")
    }

    // A server (or a man in the middle) answering with garbage SDP: the
    // player fails, tells the server to drop the session, and backs off.
    @Test func garbageAnswerFailsCleanly() async throws {
        let t = FakeTransport()
        await t.set(answer: answer("bad-sdp", sdp: "this is not sdp"))
        let e = engine(t)
        e.start()
        let p = e.openPlayer(cameraID: UUID(), quality: .hd)
        await eventually("failed") {
            if case .failed(_, let retrying) = p.state { return retrying }
            return false
        }
        await eventually("bad session stopped") { await t.stopped.contains("bad-sdp") }
        e.stop()
    }

    // An always-offline camera must not be hammered: the retry backs off
    // (2 s, 4 s, …, 30 s cap). Read as gaps between tries, not tries per
    // window: a busy machine only stretches gaps, so this can't flake, and a
    // missing or shrinking backoff still fails.
    @Test func retriesBackOff() async throws {
        let t = FakeTransport() // watch always answers .offline
        let e = engine(t)
        e.start()
        let p = e.openPlayer(cameraID: UUID(), quality: .sd)
        await eventually("three tries", timeout: .seconds(30)) { await t.watchCalls.count >= 3 }
        let times = await t.watchTimes
        guard times.count >= 3 else { return } // eventually already recorded the failure
        let gap1 = times[1] - times[0], gap2 = times[2] - times[1]
        #expect(gap1 >= .milliseconds(1900), "first retry after \(gap1), want about 2 s")
        #expect(gap2 >= .milliseconds(3900), "second retry after \(gap2), want about 4 s")
        #expect(gap2 > gap1, "the backoff grows")
        e.closePlayer(p)
        let after = await t.watchCalls.count
        try await Task.sleep(for: .seconds(3))
        #expect(await t.watchCalls.count == after, "a closed player never tries again")
        e.stop()
    }

    // C20: signed out mid-session. The player keeps trying with backoff (so
    // it recovers on its own when the host's token comes back), never in a
    // tight loop.
    @Test func notSignedInBacksOffAndRecovers() async throws {
        let t = FakeTransport()
        await t.set(watchError: .notAuthenticated)
        let e = engine(t)
        e.start()
        let p = e.openPlayer(cameraID: UUID(), quality: .hd)
        await eventually("failed") { p.state == .failed("Not signed in", retrying: true) }
        try await Task.sleep(for: .milliseconds(1500))
        #expect(await t.watchCalls.count == 1, "no tight loop while signed out")
        await t.set(watchError: .offline) // signed back in: the camera is merely offline now
        await eventually("recovered past auth", timeout: .seconds(6)) { p.state == .ended(.offline, retrying: true) }
        e.stop()
    }

    // Too many open views (the server's cap): a clear message, and a retry
    // later rather than a tight loop.
    @Test func tooManyViewsBacksOff() async throws {
        let t = FakeTransport()
        await t.set(watchError: .tooManyViews)
        let e = engine(t)
        e.start()
        let p = e.openPlayer(cameraID: UUID(), quality: .hd)
        await eventually("failed") { p.state == .failed("Too many cameras open at once", retrying: true) }
        e.stop()
    }

    // A refresh still in flight when the engine stops (sign-out, leaving the
    // screen) must not write its result afterwards.
    @Test func stopDuringRefreshWritesNothing() async throws {
        let t = FakeTransport(cameras: [cam("Porch")])
        await t.set(listDelay: .milliseconds(300))
        let e = engine(t)
        e.start()
        await eventually("list in flight") { await t.listCalls == 1 }
        e.wipeLocalStore()
        try await Task.sleep(for: .milliseconds(500))
        #expect(e.cameras.isEmpty, "a stale answer leaked past wipeLocalStore")
        #expect(e.status == .idle)
    }

    // Lifecycle calls in odd orders and repeats don't crash or double up.
    @Test func lifecycleAbuse() async throws {
        let t = FakeTransport(cameras: [cam("Porch")])
        let e = engine(t, interval: .milliseconds(100))
        e.stop() // before start
        e.start(); e.start(); e.start() // idempotent: one refresh loop
        try await Task.sleep(for: .milliseconds(350))
        let calls = await t.listCalls
        #expect(calls <= 5, "\(calls) refreshes in 350 ms at 100 ms: more than one loop is running")
        let p = e.openPlayer(cameraID: UUID(), quality: .sd)
        e.closePlayer(p)
        e.closePlayer(p) // twice
        p.retry() // on a closed player: nothing
        e.wipeLocalStore()
        e.wipeLocalStore()
        e.stop()
        #expect(e.openPlayerCount == 0)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await t.watchCalls.isEmpty, "a closed player connected anyway")
    }

    // The events channel: only well-formed text frames count. Noise must not
    // end a view; an unknown kind from the server reads as "ended".
    @Test func eventFramesAreStrict() {
        let ok = { (s: String) in ServerEvent.parse(Data(s.utf8)) }
        #expect(ok(#"{"t":"revoked"}"#) == "revoked")
        #expect(ok(#"{"t":"offline","reason":"x"}"#) == "offline")
        #expect(ok("not json") == nil)
        #expect(ok(#"{"t":5}"#) == nil)
        #expect(ok(#"{"t":""}"#) == nil)
        #expect(ok(#"["t","revoked"]"#) == nil)
        #expect(ok(#"{"type":"revoked"}"#) == nil)
        #expect(ServerEvent.parse(Data(#"{"t":"revoked"}"#.utf8), binary: true) == nil)
        let huge = #"{"t":"ended","pad":""# + String(repeating: "x", count: 5000) + #""}"#
        #expect(ok(huge) == nil)
        #expect(ok(#"{"t":""# + String(repeating: "a", count: 40) + #""}"#) == nil)
        #expect(WyzeCamEndReason(event: "something-new") == .ended)
        #expect(WyzeCamEndReason(event: "revoked") == .revoked && !WyzeCamEndReason.revoked.retryable)
    }

    // Every response type refuses malformed ids instead of inventing objects.
    @Test func malformedResponsesAreRefused() {
        var g = Camera_V1_Grant()
        g.id = UUID().uuidString; g.cameraID = "x"; g.granteeID = UUID().uuidString
        #expect(throws: WyzeCamTransportError.self) { try Wire.grant(g) }
        var c = Camera_V1_Contact()
        c.userID = "../etc"; c.name = "x"
        #expect(throws: WyzeCamTransportError.self) { try Wire.contact(c) }
        var a = Camera_V1_Agent()
        a.id = ""
        #expect(throws: WyzeCamTransportError.self) { try Wire.agent(a) }

        // A bad avatar is no avatar, not a crash; odd times are no time.
        c.userID = UUID().uuidString
        c.avatar = "%%%not base64%%%"
        #expect(try! Wire.contact(c).avatar == nil)
        #expect(Wire.date(-5) == nil)
        g.cameraID = UUID().uuidString
        g.expiresMs = -1
        #expect(try! Wire.grant(g).expiresAt == nil)
    }

    // C18: TURN is fetched BEFORE the offer and goes into the connection's
    // configuration; one fetch serves later players until it nears expiry.
    @Test func turnComesBeforeTheOffer() async throws {
        let t = FakeTransport()
        let relay = IceServer(urls: ["turn:turn.example:3478"], username: "u", credential: "c")
        await t.set(ice: IceConfig(servers: [relay], expiresAt: Date().addingTimeInterval(24 * 3600)))
        let e = engine(t)
        e.start()
        let p = e.openPlayer(cameraID: UUID(), quality: .hd)
        await eventually("watch") { await !t.watchCalls.isEmpty }
        let order = await t.calls.filter { $0 != "list" }
        #expect(order.prefix(2) == ["ice", "watch"], "TURN must be known before the offer: \(order)")
        #expect(p.builtWithICE == [relay], "the relay must be in the connection's configuration")
        let q = e.openPlayer(cameraID: UUID(), quality: .sd)
        await eventually("second watch") { await t.watchCalls.count >= 2 }
        #expect(await t.iceCalls == 1, "cached credentials are reused")
        #expect(q.builtWithICE == [relay])
        e.stop()
    }

    // Credentials close to expiry are fetched again; a TURN outage never
    // blocks a view (direct paths only).
    @Test func turnNearExpiryRefetchesAndOutageStillConnects() async throws {
        let t = FakeTransport()
        let relay = IceServer(urls: ["turn:t"], username: "u", credential: "c")
        await t.set(ice: IceConfig(servers: [relay], expiresAt: Date().addingTimeInterval(60))) // inside the margin
        let e = engine(t)
        e.start()
        _ = await e.iceServers()
        _ = await e.iceServers()
        #expect(await t.iceCalls == 2, "credentials inside the expiry margin must be refetched")

        let t2 = FakeTransport()
        await t2.set(ice: .none, error: .unreachable)
        let e2 = engine(t2)
        e2.start()
        let p = e2.openPlayer(cameraID: UUID(), quality: .hd)
        await eventually("watch despite the TURN outage") { await !t2.watchCalls.isEmpty }
        #expect(p.builtWithICE.isEmpty)
        e.stop(); e2.stop()
    }

    // C21: a host dropping a running engine frees it now, not after the
    // refresh loop's sleep (which would keep players up meanwhile).
    @Test func droppedEngineIsFreedPromptly() async throws {
        let t = FakeTransport(cameras: [cam("Porch")])
        var e: WyzeCamEngine? = engine(t, interval: .seconds(60))
        weak let weakEngine = e
        e?.start()
        await eventually("ready") { e?.status == .ready }
        e = nil
        await eventually("engine freed", timeout: .seconds(2)) { weakEngine == nil }
    }

    // C19: only the server's "camera offline" means offline; a proxy or the
    // network answering Unavailable is "can't reach the server".
    @Test func unavailableIsOfflineOnlyWhenTheServerSaysSo() {
        #expect(Wire.error(code: .unavailable, message: "camera offline") == .offline)
        #expect(Wire.error(code: .unavailable, message: "upstream connect error") == .unreachable)
        #expect(Wire.error(code: .unavailable, message: nil) == .unreachable)
        #expect(WyzeCamEngine.describe(WyzeCamTransportError.unreachable) == "Can't reach the server")
    }
}
