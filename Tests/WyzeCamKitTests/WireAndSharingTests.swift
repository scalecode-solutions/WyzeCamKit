import Foundation
import Testing
import Connect
@testable import WyzeCamKit

@Suite struct WireTests {
    @Test func cameraMapping() throws {
        var c = Camera_V1_Camera()
        c.id = "11111111-2222-4333-8444-555555555555"
        c.name = "Driveway"
        c.color = "teal"
        c.online = true
        c.isOwner = true
        c.hasSd_p = true
        c.agentID = "66666666-7777-4888-9999-aaaaaaaaaaaa"
        c.camKey = "driveway"
        let m = try Wire.camera(c)
        #expect(m.name == "Driveway" && m.color == .teal && m.online && m.owned && m.hasSD)
        #expect(m.agentID?.uuidString.lowercased() == "66666666-7777-4888-9999-aaaaaaaaaaaa")

        c.color = "red" // not in the palette
        c.agentID = ""  // a grantee doesn't get it
        c.hasSd_p = false
        let g = try Wire.camera(c)
        #expect(g.color == .standard && g.agentID == nil && !g.hasSD)

        c.id = "nope"
        #expect(throws: WyzeCamTransportError.self) { try Wire.camera(c) }
    }

    @Test func errorsMapToWhatTheUIShows() {
        #expect(Wire.error(code: .unauthenticated, message: nil) == .notAuthenticated)
        #expect(Wire.error(code: .notFound, message: nil) == .notFound)
        #expect(Wire.error(code: .unavailable, message: "camera offline") == .offline)
        #expect(Wire.error(code: .resourceExhausted, message: nil) == .limit("limit reached"))
        #expect(Wire.error(code: .internalError, message: "x") == .rpc(code: "internalError", message: "x"))
    }

    @Test func answerAndDates() {
        var r = Camera_V1_WatchResponse()
        r.sessionID = "sid"
        r.answerSdp = "v=0"
        r.width = 640
        r.height = 360
        r.quality = .sd
        var ice = Camera_V1_IceServer()
        ice.urls = ["turn:turn.example:3478"]
        ice.username = "u"
        ice.credential = "c"
        r.iceServers = [ice]
        let a = Wire.answer(r)
        #expect(a.quality == .sd && a.width == 640 && a.iceServers.first?.urls == ["turn:turn.example:3478"])
        r.quality = .unspecified
        #expect(Wire.answer(r).quality == .hd)

        #expect(Wire.date(0) == nil)
        let d = Date(timeIntervalSince1970: 1_800_000_000.123)
        #expect(Wire.ms(d) == 1_800_000_000_123)
        #expect(Wire.date(Wire.ms(d))!.timeIntervalSince1970 == 1_800_000_000.123)
        #expect(Wire.id(UUID(uuidString: "11111111-2222-4333-8444-555555555555")!) == "11111111-2222-4333-8444-555555555555")
    }
}

@Suite struct SharingTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let camID = UUID()

    func grant(_ who: UUID, expires: Date? = nil, name: String = "") -> WyzeCamGrant {
        WyzeCamGrant(id: UUID(), cameraID: camID, granteeID: who, granteeName: name, expiresAt: expires)
    }

    @Test func candidatesSkipOwnerAndActiveShares() {
        let casey = WyzeCamContact(id: UUID(), name: "casey")
        let amy = WyzeCamContact(id: UUID(), name: "Amy")
        let lapsed = WyzeCamContact(id: UUID(), name: "Bo")
        let selfContact = WyzeCamContact(id: me, name: "Me")
        let grants = [grant(casey.id), grant(lapsed.id, expires: now.addingTimeInterval(-60))]
        let out = WyzeCamSharing.candidates(contacts: [casey, amy, lapsed, selfContact], grants: grants, owner: me, now: now)
        #expect(out.map(\.name) == ["Amy", "Bo"], "owner and active share out; a lapsed share is offered again")
    }

    @Test func accessLinesAndNames() {
        #expect(WyzeCamSharing.accessLine(grant(UUID()), now: now) == "No end date")
        #expect(WyzeCamSharing.accessLine(grant(UUID(), expires: now.addingTimeInterval(3600)), now: now).hasPrefix("Until "))
        #expect(WyzeCamSharing.accessLine(grant(UUID(), expires: now.addingTimeInterval(-3600)), now: now).hasPrefix("Expired "))
        #expect(!WyzeCamSharing.isActive(grant(UUID(), expires: now), now: now), "ends at its end time")

        let who = UUID()
        let g = grant(who, name: "Casey (server)")
        #expect(WyzeCamSharing.displayName(for: g, contacts: [WyzeCamContact(id: who, name: "Casey")]) == "Casey")
        #expect(WyzeCamSharing.displayName(for: g, contacts: []) == "Casey (server)")
        #expect(WyzeCamSharing.displayName(for: grant(who), contacts: []) == "Someone")
    }

    @Test func agentLine() {
        #expect(WyzeCamSharing.agentLine(WyzeCamAgent(id: UUID(), name: "Box", online: true, version: "1.2")) == "Online · 1.2")
        #expect(WyzeCamSharing.agentLine(WyzeCamAgent(id: UUID(), name: "Box")) == "Never connected")
        #expect(WyzeCamSharing.agentLine(WyzeCamAgent(id: UUID(), name: "Box", lastSeen: now), now: now).hasPrefix("Last seen"))
    }

    // C25: an untouched name field follows a rename from elsewhere; an
    // edited one keeps the user's text (their Save is deliberate).
    @Test func nameFieldFollowsOutsideRenamesOnlyWhenUntouched() {
        #expect(WyzeCamSharing.followRename(field: "Porch", lastSynced: "Porch", server: "Front door") == "Front door")
        #expect(WyzeCamSharing.followRename(field: "Porch cam", lastSynced: "Porch", server: "Front door") == "Porch cam")
        #expect(WyzeCamSharing.followRename(field: "", lastSynced: "Porch", server: "Front door") == "",
                "a cleared field is an edit too")
    }

    // C22/C23: a token sheet can't be swiped away while its request is in
    // flight or once the token is shown; only after a failure.
    @Test func tokenSheetSwipeRules() {
        #expect(!WyzeCamSharing.tokenSheetSwipeable(token: nil, failed: false), "in flight")
        #expect(!WyzeCamSharing.tokenSheetSwipeable(token: "tok", failed: false), "shown: Done only")
        #expect(WyzeCamSharing.tokenSheetSwipeable(token: nil, failed: true), "failed: the old token still works")
    }
}
