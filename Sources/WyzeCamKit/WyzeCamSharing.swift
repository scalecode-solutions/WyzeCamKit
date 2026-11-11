import Foundation

/// The owner screen's rules, kept free of UI so tests can pin them (the
/// GarageSharing twin).
public enum WyzeCamSharing {
    /// Whether a share still lets them watch. The server keeps listing shares
    /// past their end date (so they stay removable); they just stop working.
    public static func isActive(_ grant: WyzeCamGrant, now: Date = .now) -> Bool {
        grant.expiresAt.map { $0 > now } ?? true
    }

    /// The line under a person: when their access ends, or that it has.
    public static func accessLine(_ grant: WyzeCamGrant, now: Date = .now) -> String {
        guard let end = grant.expiresAt else { return "No end date" }
        let when = end.formatted(date: .abbreviated, time: .shortened)
        return isActive(grant, now: now) ? "Until \(when)" : "Expired \(when)"
    }

    /// People who may be offered for a camera: the contacts minus the owner
    /// and anyone with a share that still works, sorted by name. Someone whose
    /// share ran out is offered again (sharing again renews it).
    public static func candidates(contacts: [WyzeCamContact], grants: [WyzeCamGrant], owner: UUID,
                                  now: Date = .now) -> [WyzeCamContact] {
        let granted = Set(grants.filter { isActive($0, now: now) }.map(\.granteeID))
        var seen = Set<UUID>() // a contact listed twice would be two rows with one id
        return contacts
            .filter { $0.id != owner && !granted.contains($0.id) && seen.insert($0.id).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The furthest a share's end date may be set. The server refuses past
    /// ten years; a day short of that leaves room for clocks that disagree.
    public static let maxShareSpan: TimeInterval = (10 * 365 - 1) * 24 * 3600

    /// The end dates the share sheet offers.
    public static func endRange(now: Date = .now) -> ClosedRange<Date> {
        now...now.addingTimeInterval(maxShareSpan)
    }

    /// What's wrong with an end date before it's sent, or nil when it's fine
    /// (no end date is always fine). The sheet can sit open past the time
    /// that was picked.
    public static func endProblem(_ end: Date?, now: Date = .now) -> String? {
        guard let end else { return nil }
        if end <= now { return "That end time has passed. Pick a later one." }
        if end > now.addingTimeInterval(maxShareSpan) { return "Pick an end date within ten years, or no end date." }
        return nil
    }

    /// Why a share didn't go through, in words for the owner.
    public static func shareFailure(_ error: Error, name: String) -> String {
        switch error as? WyzeCamTransportError {
        case .notFound: "Couldn't share with \(name). They may not be able to see you yet."
        case .limit: "This camera is shared with as many people as it can be. Remove someone first."
        default: "Couldn't share with \(name): \(WyzeCamEngine.describe(error))"
        }
    }

    /// The server's lower-case words as a sentence.
    static func sentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first else { return "Something went wrong." }
        let body = first.uppercased() + t.dropFirst()
        return body.hasSuffix(".") ? body : body + "."
    }

    /// How to show who a share is for: the contact's current name, else the
    /// name the server sent, else a neutral word.
    public static func displayName(for grant: WyzeCamGrant, contacts: [WyzeCamContact]) -> String {
        if let c = contacts.first(where: { $0.id == grant.granteeID }), !c.name.isEmpty { return c.name }
        let name = grant.granteeName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Someone" : name
    }

    /// The name field after the server's name changed (a rename from another
    /// phone): it follows only if the user hasn't edited it since it was
    /// last filled, so an untouched field never offers to "save" the old name.
    public static func followRename(field: String, lastSynced: String, server: String) -> String {
        field == lastSynced ? server : field
    }

    /// Whether a token sheet may be dismissed: not while the request is in
    /// flight (the token would land nowhere) and not by a swipe once it's
    /// shown (only Done, after it's been seen). An error leaves the old
    /// token working, so that sheet may go.
    public static func tokenSheetSwipeable(token: String?, failed: Bool) -> Bool {
        token == nil && failed
    }

    /// The line under a home box: online, or when it was last seen.
    public static func agentLine(_ agent: WyzeCamAgent, now: Date = .now) -> String {
        let version = agent.version.isEmpty ? "" : " · \(agent.version)"
        if agent.online { return "Online\(version)" }
        guard let seen = agent.lastSeen else { return "Never connected" }
        return "Last seen \(seen.formatted(.relative(presentation: .named, unitsStyle: .wide)))\(version)"
    }
}
