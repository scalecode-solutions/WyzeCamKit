import Foundation
import Testing
@testable import WyzeCamKit
import WyzeCamKitTestSupport

@MainActor
@Suite struct EngineTests {
    func engine(_ t: FakeTransport, interval: Duration = .seconds(60)) -> WyzeCamEngine {
        WyzeCamEngine(config: WyzeCamConfig(baseURL: URL(string: "http://localhost:1")!, currentUserID: me,
                                            tokenProvider: { "t" }, refreshInterval: interval),
                      transport: t)
    }

    @Test func initIsInert() async throws {
        let t = FakeTransport(cameras: [cam("Porch")])
        let e = engine(t)
        let p = e.openPlayer(cameraID: UUID(), quality: .sd) // a view opened before start
        try await Task.sleep(for: .milliseconds(200))
        #expect(await t.listCalls == 0)
        #expect(await t.watchCalls.isEmpty)
        #expect(p.state == .idle)
        #expect(!e.isRunning && e.cameras.isEmpty)
    }

    @Test func startLoadsSortedAndStopGoesQuiet() async throws {
        let t = FakeTransport(cameras: [cam("Zed"), cam("Shared", owned: false), cam("Alpha")])
        let e = engine(t, interval: .milliseconds(50))
        e.start()
        await eventually("cameras") { e.status == .ready }
        #expect(e.cameras.map(\.name) == ["Alpha", "Zed", "Shared"]) // owned first, then by name
        await eventually("a refresh on the timer") { await t.listCalls >= 2 }
        e.stop()
        let after = await t.listCalls
        try await Task.sleep(for: .milliseconds(250))
        #expect(await t.listCalls == after, "a stopped engine must not keep asking")
        #expect(!e.isRunning)
    }

    @Test func signedOutAndFailuresKeepTheLastList() async throws {
        let t = FakeTransport(cameras: [cam("Porch")])
        let e = engine(t)
        e.start()
        await eventually("ready") { e.status == .ready }
        await t.set(listError: .rpc(code: "internal", message: "boom"))
        await e.refresh()
        #expect(e.status == .failed("boom"))
        #expect(e.cameras.count == 1, "a failed refresh keeps what was shown")
        await t.set(listError: .notAuthenticated)
        await e.refresh()
        #expect(e.status == .signedOut)
        e.stop()
    }

    @Test func playersFollowTheEngine() async throws {
        let t = FakeTransport()
        let e = engine(t)
        let c = UUID()
        let p = e.openPlayer(cameraID: c, quality: .sd)
        e.start()
        // It really makes an offer (WebRTC), sends it with the quality asked for,
        // and the server's "offline" ends it with a retry pending.
        await eventually("watch") { await !t.watchCalls.isEmpty }
        let call = try #require(await t.watchCalls.first)
        #expect(call.0 == c && call.1 == .sd && call.2.hasPrefix("v=0"))
        #expect(call.2.contains("m=video"), "the offer must ask for video")
        await eventually("ended offline") { p.state == .ended(.offline, retrying: true) }

        e.stop()
        #expect(p.state == .idle, "stop hangs every player up")
        let calls = await t.watchCalls.count
        try await Task.sleep(for: .seconds(3)) // past the first retry delay
        #expect(await t.watchCalls.count == calls, "a stopped engine's players don't retry")

        e.start() // back in front: still-open players reconnect
        await eventually("reconnect") { await t.watchCalls.count > calls }
        e.closePlayer(p)
        #expect(e.openPlayerCount == 0)
        e.stop()
    }

    @Test func revokedDoesNotRetry() async throws {
        let t = FakeTransport()
        await t.set(watchError: .notFound)
        let e = engine(t)
        e.start()
        let p = e.openPlayer(cameraID: UUID(), quality: .hd)
        let lists = await t.listCalls
        await eventually("revoked") { p.state == .ended(.revoked, retrying: false) }
        await eventually("the list reloads at once") { await t.listCalls > lists }
        let calls = await t.watchCalls.count
        try await Task.sleep(for: .seconds(3))
        #expect(await t.watchCalls.count == calls)
        e.stop()
    }

    @Test func wipeForgetsEverything() async throws {
        let t = FakeTransport(cameras: [cam("Porch")])
        let e = engine(t)
        e.start()
        await eventually("ready") { e.status == .ready }
        _ = e.openPlayer(cameraID: UUID(), quality: .sd)
        e.wipeLocalStore()
        #expect(e.cameras.isEmpty && e.openPlayerCount == 0 && !e.isRunning && e.status == .idle)
    }
}
