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
        return contacts
            .filter { $0.id != owner && !granted.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// How to show who a share is for: the contact's current name, else the
    /// name the server sent, else a neutral word.
    public static func displayName(for grant: WyzeCamGrant, contacts: [WyzeCamContact]) -> String {
        if let c = contacts.first(where: { $0.id == grant.granteeID }), !c.name.isEmpty { return c.name }
        let name = grant.granteeName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Someone" : name
    }

    /// The line under a home box: online, or when it was last seen.
    public static func agentLine(_ agent: WyzeCamAgent, now: Date = .now) -> String {
        let version = agent.version.isEmpty ? "" : " · \(agent.version)"
        if agent.online { return "Online\(version)" }
        guard let seen = agent.lastSeen else { return "Never connected" }
        return "Last seen \(seen.formatted(.relative(presentation: .named, unitsStyle: .wide)))\(version)"
    }
}
