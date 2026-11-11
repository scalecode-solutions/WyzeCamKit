/// The kit's wording, chosen by the host. The kit ships neutral defaults
/// (WyzeCamLab); a host can pass its own.
public struct WyzeCamAppearance: Sendable {
    /// Shown when the user has no cameras at all.
    public var emptyTitle: String
    public var emptyMessage: String

    public init(emptyTitle: String = "No cameras",
                emptyMessage: String = "Cameras you own or that are shared with you show up here.") {
        self.emptyTitle = emptyTitle
        self.emptyMessage = emptyMessage
    }

    public static let standard = WyzeCamAppearance()
}
