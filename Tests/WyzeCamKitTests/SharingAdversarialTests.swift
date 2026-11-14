import Foundation
import Testing
@testable import WyzeCamKit
import WyzeCamKitTestSupport

/// Sharing from the client's side, attacked: what the owner is told when a
/// share can't be made, which people are offered, which end dates go out,
/// and what a revoke does to someone watching.
@MainActor
@Suite struct SharingAdversarialTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let camID = UUID()

    func grant(_ who: UUID, expires: Date? = nil, name: String = "") -> WyzeCamGrant {
        WyzeCamGrant(id: UUID(), cameraID: camID, granteeID: who, granteeName: name, expiresAt: expires)
    }

    func engine(_ t: FakeTransport) -> WyzeCamEngine {
        WyzeCamEngine(config: WyzeCamConfig(baseURL: URL(string: "http://localhost:1")!, currentUserID: me,
                                            tokenProvider: { "t" }, refreshInterval: .seconds(60)),
                      transport: t)
    }

    // Every cap the server has answers ResourceExhausted. Only on Watch does
    // that mean "too many cameras open"; a full share list or too many home
    // boxes must say so, in the server's words.
    @Test func capsAreNamedForWhatTheyAre() {
        #expect(Wire.error(code: .resourceExhausted, message: "too many shares on this camera") == .limit("too many shares on this camera"))
        #expect(WyzeCamEngine.describe(WyzeCamTransportError.limit("too many shares on this camera")) == "Too many shares on this camera.")
        #expect(WyzeCamEngine.describe(WyzeCamTransportError.limit("too many home boxes")) == "Too many home boxes.")
        #expect(!WyzeCamEngine.describe(WyzeCamTransportError.limit("too many shares on this camera")).contains("cameras open"))
        #expect(Wire.error(code: .resourceExhausted, message: nil) == .limit("limit reached"))
        #expect(Wire.error(code: .invalidArgument, message: "expiry is in the past") == .invalid("expiry is in the past"))
        #expect(WyzeCamEngine.describe(WyzeCamTransportError.invalid("")) == "Something went wrong.")
        #expect(WyzeCamEngine.describe(WyzeCamTransportError.invalid("  name is blank.  ")) == "Name is blank.")
    }

    // A view refused by a cap still reads as too many open views, whichever
    // way the error arrives.
    @Test func aCapOnWatchIsTooManyViews() async throws {
        let t = FakeTransport()
        await t.set(watchError: .limit("too many open views"))
        let e = engine(t)
        e.start()
        let p = e.openPlayer(cameraID: UUID(), quality: .hd)
        await eventually("failed") { p.state == .failed("Too many cameras open at once", retrying: true) }
        e.stop()
    }

    // What the owner reads when a share fails: the real reason, not always
    // "they may not be able to see you".
    @Test func shareFailuresSayWhy() {
        #expect(WyzeCamSharing.shareFailure(WyzeCamTransportError.notFound, name: "Amy")
                == "Couldn't share with Amy. They may not be able to see you yet.")
        #expect(WyzeCamSharing.shareFailure(WyzeCamTransportError.limit("too many shares on this camera"), name: "Amy")
                == "This camera is shared with as many people as it can be. Remove someone first.")
        #expect(WyzeCamSharing.shareFailure(WyzeCamTransportError.invalid("expiry is in the past"), name: "Amy")
                == "Couldn't share with Amy: Expiry is in the past.")
        #expect(WyzeCamSharing.shareFailure(WyzeCamTransportError.unreachable, name: "Amy")
                == "Couldn't share with Amy: Can't reach the server")
        #expect(WyzeCamSharing.shareFailure(URLError(.notConnectedToInternet), name: "Amy")
                == "Couldn't share with Amy: Can't reach the server")
    }

    // End dates: none is fine; one that has passed (the sheet sat open) or
    // one past the server's reach is caught before it's sent; the picker
    // can't offer one the server would refuse.
    @Test func endDatesAreCheckedBeforeSending() {
        #expect(WyzeCamSharing.endProblem(nil, now: now) == nil)
        #expect(WyzeCamSharing.endProblem(now.addingTimeInterval(3600), now: now) == nil)
        #expect(WyzeCamSharing.endProblem(now, now: now) != nil, "an end of right now has passed")
        #expect(WyzeCamSharing.endProblem(now.addingTimeInterval(-1), now: now) != nil)
        #expect(WyzeCamSharing.endProblem(now.addingTimeInterval(WyzeCamSharing.maxShareSpan + 1), now: now) != nil)
        #expect(WyzeCamSharing.endProblem(.distantFuture, now: now) != nil)
        let range = WyzeCamSharing.endRange(now: now)
        #expect(range.lowerBound == now)
        let serverLimit: TimeInterval = 10 * 365 * 24 * 3600
        #expect(range.upperBound.timeIntervalSince(now) < serverLimit, "the picker stays inside the server's ten years")
        #expect(WyzeCamSharing.endProblem(range.upperBound, now: now) == nil, "the picker's last date is sendable")
    }

    // The people offered: never the owner, never someone already watching,
    // never one person twice (a duplicated contact would be two rows with
    // one id), and two people with one name are both kept.
    @Test func candidatesSurviveAMessyContactList() {
        let amy = WyzeCamContact(id: UUID(), name: "Amy")
        let amy2 = WyzeCamContact(id: UUID(), name: "Amy")
        let bo = WyzeCamContact(id: UUID(), name: "Bo")
        let edge = WyzeCamContact(id: UUID(), name: "Edge")
        let owner = WyzeCamContact(id: me, name: "Me")
        let grants = [grant(bo.id), grant(edge.id, expires: now), grant(UUID())] // a share for someone not in contacts
        let out = WyzeCamSharing.candidates(contacts: [amy, owner, amy, amy2, bo, owner, edge], grants: grants, owner: me, now: now)
        #expect(out.count == 3)
        #expect(Set(out.map(\.id)) == [amy.id, amy2.id, edge.id], "share ending exactly now is offered again")
        #expect(Set(out.map(\.id)).count == out.count, "no duplicates")
        #expect(WyzeCamSharing.candidates(contacts: [], grants: grants, owner: me, now: now).isEmpty)
    }

    // A share is active up to, not including, its end; names fall back
    // cleanly when the server or contacts have nothing useful.
    @Test func boundariesAndNames() {
        #expect(WyzeCamSharing.isActive(grant(UUID(), expires: now.addingTimeInterval(0.001)), now: now))
        #expect(!WyzeCamSharing.isActive(grant(UUID(), expires: now), now: now))
        #expect(!WyzeCamSharing.isActive(grant(UUID(), expires: .distantPast), now: now))
        #expect(WyzeCamSharing.isActive(grant(UUID()), now: .distantFuture), "no end date never ends")

        let who = UUID()
        #expect(WyzeCamSharing.displayName(for: grant(who, name: "   \n"), contacts: []) == "Someone")
        #expect(WyzeCamSharing.displayName(for: grant(who, name: "Casey"), contacts: [WyzeCamContact(id: who, name: "")]) == "Casey",
                "a contact with no name doesn't blank a known one")
        #expect(WyzeCamSharing.displayName(for: grant(who, name: "Casey"), contacts: [WyzeCamContact(id: UUID(), name: "Other")]) == "Casey",
                "someone else's contact isn't used")
    }

    // Shares off the wire: garbage ids are refused, and missing or negative
    // times mean "none", never 1970.
    @Test func grantsOffTheWire() throws {
        var g = Camera_V1_Grant()
        g.id = UUID().uuidString
        g.cameraID = UUID().uuidString
        g.granteeID = UUID().uuidString
        g.expiresMs = -5
        g.createdMs = 0
        let m = try Wire.grant(g)
        #expect(m.expiresAt == nil && m.createdAt == nil)
        for bad in ["", "x", "' OR 1=1 --"] {
            var b = g
            b.granteeID = bad
            #expect(throws: WyzeCamTransportError.self) { try Wire.grant(b) }
        }
    }

    // Revoked while watching: the view ends for good, and the camera leaves
    // the list at once (not at the next refresh, a minute away here).
    @Test func revokedWhileWatchingLeavesTheList() async throws {
        let shared = cam("Their porch", owned: false)
        let t = FakeTransport(cameras: [shared])
        let e = engine(t)
        e.start()
        await eventually("listed") { e.cameras.count == 1 }
        await t.set(cameras: [])            // the owner revoked
        await t.set(watchError: .notFound)  // and the server now says NotFound
        let p = e.openPlayer(cameraID: shared.id, quality: .sd)
        await eventually("revoked") { p.state == .ended(.revoked, retrying: false) }
        await eventually("gone from the list") { e.cameras.isEmpty }
        e.closePlayer(p)
        e.stop()
    }
}
