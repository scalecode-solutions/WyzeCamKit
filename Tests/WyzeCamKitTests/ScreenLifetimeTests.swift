import Foundation
import SwiftUI
import Testing
import UIKit
@testable import WyzeCamKit

/// The kit's screens, hosted for real (a window, SwiftUI's own appear and
/// disappear), against a fake server: every screen's players live exactly
/// as long as the screen, follow the camera list under it, and leave
/// nothing connecting behind.

/// What's on screen, switched the way a host's navigation would.
@MainActor @Observable final class Stage {
    enum Screen: Equatable { case none, grid, live(UUID) }
    var screen: Screen = .none
    /// Cameras pushed over the grid (what tapping a tile does).
    var path: [UUID] = []
    /// The live view's quality, owned here (what the picker writes).
    var quality: WyzeCamQuality = .hd
}

struct StageView: View {
    let engine: WyzeCamEngine
    let stage: Stage

    var body: some View {
        switch stage.screen {
        case .none: Color.clear
        case .grid:
            NavigationStack(path: Bindable(stage).path) {
                WyzeCamView(engine: engine)
                    .navigationDestination(for: UUID.self) { WyzeCamLiveView(engine: engine, cameraID: $0) }
            }
        case .live(let id):
            NavigationStack { WyzeCamLiveView(engine: engine, cameraID: id, quality: Bindable(stage).quality) }
        }
    }
}

@MainActor final class Host {
    let window: UIWindow
    let stage = Stage()

    init(engine: WyzeCamEngine, size: CGSize = CGSize(width: 390, height: 844)) {
        window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = UIHostingController(rootView: StageView(engine: engine, stage: stage))
        window.makeKeyAndVisible()
    }

    func show(_ s: Stage.Screen) async {
        stage.screen = s
        await settle()
    }

    /// Let SwiftUI run its updates (appear/disappear land on later turns).
    func settle(_ turns: Int = 6) async {
        for _ in 0..<turns {
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
    }
}

@MainActor
@Suite(.serialized) struct ScreenLifetimeTests {
    func engine(_ t: FakeTransport) -> WyzeCamEngine {
        WyzeCamEngine(config: WyzeCamConfig(baseURL: URL(string: "http://localhost:1")!, currentUserID: me,
                                            tokenProvider: { "t" }, refreshInterval: .seconds(60)),
                      transport: t)
    }

    /// No new connection attempts over a stretch longer than the first retry (2 s).
    func quiet(_ t: FakeTransport, _ what: String) async throws {
        let before = await t.watchCalls.count
        try await Task.sleep(for: .seconds(2.5))
        #expect(await t.watchCalls.count == before, "\(what): something kept connecting")
    }

    // The grid opens one SD player per tile that can show a picture (online,
    // with SD), none for the rest, and leaving the grid closes every one.
    @Test func gridTilesLiveExactlyAsLongAsTheGrid() async throws {
        let live = [cam("A"), cam("B"), cam("C")]
        let t = FakeTransport(cameras: live + [cam("Dark", online: false), cam("NoSD", sd: false)])
        let e = engine(t)
        e.start()
        await eventually("listed") { e.cameras.count == 5 }
        let host = Host(engine: e)
        defer { host.close() }

        await host.show(.grid)
        await eventually("three tiles streaming") { e.openPlayerCount == 3 }
        await eventually("each asked for once, in SD") { await t.watchCalls.count >= 3 }
        let asked = await t.watchCalls
        #expect(Set(asked.map(\.0)) == Set(live.map(\.id)), "only online SD cameras")
        #expect(asked.allSatisfy { $0.1 == .sd })

        await host.show(.none)
        await eventually("all closed") { e.openPlayerCount == 0 }
        try await quiet(t, "after leaving the grid")
        e.stop()
    }

    // The list moves under a grid that's on screen: a camera going offline,
    // being revoked, coming back, or a new one. Players follow, one per
    // tile, never two.
    @Test func tilesFollowTheListUnderThem() async throws {
        let a = cam("A"), b = cam("B")
        let t = FakeTransport(cameras: [a, b])
        let e = engine(t)
        e.start()
        await eventually("listed") { e.cameras.count == 2 }
        let host = Host(engine: e)
        defer { host.close() }
        await host.show(.grid)
        await eventually("two tiles") { e.openPlayerCount == 2 }

        var offB = b
        offB.online = false
        await t.set(cameras: [a, offB])
        await e.refresh()
        await host.settle()
        await eventually("B offline: its player closes") { e.openPlayerCount == 1 }

        await t.set(cameras: [a])       // B revoked
        await e.refresh()
        await host.settle()
        #expect(e.openPlayerCount == 1)

        let c = cam("C")
        await t.set(cameras: [a, b, c]) // B back, C new
        await e.refresh()
        await host.settle()
        await eventually("three tiles") { e.openPlayerCount == 3 }

        await t.set(cameras: [])        // everything revoked
        await e.refresh()
        await host.settle()
        await eventually("none") { e.openPlayerCount == 0 }
        try await quiet(t, "with no cameras listed")
        e.stop()
    }

    // The live view: one HD player while it's up, a quality switch replaces
    // it (never two at once), and leaving closes it.
    @Test func liveViewOnePlayerAndQualitySwitchReplacesIt() async throws {
        let porch = cam("Porch")
        let t = FakeTransport(cameras: [porch])
        let e = engine(t)
        e.start()
        await eventually("listed") { e.cameras.count == 1 }
        let host = Host(engine: e)
        defer { host.close() }

        await host.show(.live(porch.id))
        await eventually("one HD player") { e.openPlayerCount == 1 }
        await eventually("asked for HD") { await t.watchCalls.first?.1 == .hd }

        host.stage.quality = .sd        // what picking SD writes
        await host.settle(10)
        await eventually("switched to SD") { await t.watchCalls.contains { $0.1 == .sd } }
        #expect(e.openPlayerCount == 1, "the HD player was replaced, not kept")

        await host.show(.none)
        await eventually("closed") { e.openPlayerCount == 0 }
        try await quiet(t, "after leaving the live view")
        e.stop()
    }

    // Opening a camera from the grid hangs the tiles up: the home box sends
    // the one HD stream, not every tile's SD stream as well.
    @Test func openingACameraHangsUpTheTiles() async throws {
        let porch = cam("Porch"), yard = cam("Yard"), side = cam("Side")
        let t = FakeTransport(cameras: [porch, yard, side])
        let e = engine(t)
        e.start()
        await eventually("listed") { e.cameras.count == 3 }
        let host = Host(engine: e)
        defer { host.close() }
        await host.show(.grid)
        await eventually("three tiles") { e.openPlayerCount == 3 }

        host.stage.path = [porch.id]   // what tapping the Porch tile pushes
        await host.settle(10)
        await eventually("only the live view's player") { e.openPlayerCount == 1 }
        await eventually("which is Porch in HD") { await t.watchCalls.last.map { $0.0 == porch.id && $0.1 == .hd } ?? false }

        host.stage.path = []           // back
        await host.settle(10)
        await eventually("tiles again") { e.openPlayerCount == 3 }
        await host.show(.none)
        await eventually("all closed") { e.openPlayerCount == 0 }
        e.stop()
    }

    // The host stops the engine with screens up (app to background): the
    // players stay open but quiet, with no connection attempts; start brings
    // them back.
    @Test func engineStopUnderAScreenGoesQuietThenResumes() async throws {
        let t = FakeTransport(cameras: [cam("A"), cam("B")])
        let e = engine(t)
        e.start()
        await eventually("listed") { e.cameras.count == 2 }
        let host = Host(engine: e)
        defer { host.close() }
        await host.show(.grid)
        await eventually("two tiles") { e.openPlayerCount == 2 }

        e.stop()
        try await quiet(t, "while stopped")
        let calls = await t.watchCalls.count
        e.start()
        await eventually("reconnected") { await t.watchCalls.count >= calls + 2 }
        #expect(e.openPlayerCount == 2, "no duplicate players on resume")
        await host.show(.none)
        await eventually("closed") { e.openPlayerCount == 0 }
        e.stop()
    }

    // Thrashing the screens (fast back and forth, a host glitching) leaves
    // exactly what's on screen at the end: nothing leaked, nothing doubled.
    @Test func thrashingScreensLeaksNothing() async throws {
        let a = cam("A"), b = cam("B")
        let t = FakeTransport(cameras: [a, b])
        let e = engine(t)
        e.start()
        await eventually("listed") { e.cameras.count == 2 }
        let host = Host(engine: e)
        defer { host.close() }
        let screens: [Stage.Screen] = [.grid, .none, .live(a.id), .grid, .live(b.id), .none]
        var appeared = 0
        for i in 0..<40 {
            host.stage.screen = screens[i % screens.count]
            // Mostly faster than a screen can finish appearing, sometimes
            // long enough that it does (so its players really open).
            await host.settle(i % 5 == 0 ? 6 : i % 3)
            appeared = max(appeared, e.openPlayerCount)
        }
        #expect(appeared > 0, "some screens got far enough to open players")
        await host.show(.none)
        await eventually("nothing open") { e.openPlayerCount == 0 }
        try await quiet(t, "after thrashing")
        await host.show(.grid)
        await eventually("exactly the grid's two") { e.openPlayerCount == 2 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(e.openPlayerCount == 2)
        await host.show(.none)
        await eventually("closed") { e.openPlayerCount == 0 }
        e.stop()
    }

    // Sign-out with the grid up: the list empties, every tile goes, and
    // nothing keeps connecting for the old account.
    @Test func signOutUnderTheGrid() async throws {
        let t = FakeTransport(cameras: [cam("A"), cam("B")])
        let e = engine(t)
        e.start()
        await eventually("listed") { e.cameras.count == 2 }
        let host = Host(engine: e)
        defer { host.close() }
        await host.show(.grid)
        await eventually("two tiles") { e.openPlayerCount == 2 }
        e.wipeLocalStore()
        await host.settle()
        #expect(e.openPlayerCount == 0 && e.cameras.isEmpty)
        try await quiet(t, "after sign-out")
    }

    // Revoked while the live view is up: the view says so, stays put, and
    // doesn't try again; the camera has left the list.
    @Test func revokedUnderTheLiveView() async throws {
        let theirs = cam("Theirs", owned: false)
        let t = FakeTransport(cameras: [theirs])
        let e = engine(t)
        e.start()
        await eventually("listed") { e.cameras.count == 1 }
        await t.set(cameras: [])
        await t.set(watchError: .notFound)
        let host = Host(engine: e)
        defer { host.close() }
        await host.show(.live(theirs.id))
        await eventually("gone from the list") { e.cameras.isEmpty }
        #expect(e.openPlayerCount == 1, "the screen is still up, with its ended player")
        try await quiet(t, "after the revoke")
        await host.show(.none)
        await eventually("closed") { e.openPlayerCount == 0 }
        e.stop()
    }

    // A screen-sized grid of many cameras streams only what's on screen,
    // never more than the server lets one person open (12).
    @Test func aBigGridStaysUnderTheServersCap() async throws {
        let many = (1...32).map { cam(String(format: "Cam %02d", $0)) }
        let t = FakeTransport(cameras: many)
        let e = engine(t)
        e.start()
        await eventually("listed") { e.cameras.count == 32 }
        let host = Host(engine: e)
        defer { host.close() }
        await host.show(.grid)
        await eventually("some tiles") { e.openPlayerCount > 0 }
        await host.settle(10)
        #expect(e.openPlayerCount <= 12, "\(e.openPlayerCount) players for one phone screen")
        await host.show(.none)
        await eventually("closed") { e.openPlayerCount == 0 }
        e.stop()
    }
}
