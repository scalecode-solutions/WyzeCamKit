import SwiftUI

/// One camera, live, in HD. Pushed by `WyzeCamView` (or by a host that links
/// straight to a camera); reads the camera from the engine by id. The stream
/// runs while this screen is on screen and the engine runs.
public struct WyzeCamLiveView: View {
    let engine: WyzeCamEngine
    let cameraID: UUID

    public init(engine: WyzeCamEngine, cameraID: UUID) {
        self.engine = engine
        self.cameraID = cameraID
        self.hostQuality = nil
    }

    /// The same, with the host owning the quality (to remember a preference,
    /// say). The picker writes it; a change from the host switches the stream
    /// just the same.
    public init(engine: WyzeCamEngine, cameraID: UUID, quality: Binding<WyzeCamQuality>) {
        self.engine = engine
        self.cameraID = cameraID
        self.hostQuality = quality
    }

    private let hostQuality: Binding<WyzeCamQuality>?
    @State private var player: WyzeCamPlayer?
    @State private var ownQuality: WyzeCamQuality = .hd
    private var quality: WyzeCamQuality { hostQuality?.wrappedValue ?? ownQuality }
    private var qualityBinding: Binding<WyzeCamQuality> { hostQuality ?? $ownQuality }
    @State private var fill = false
    @State private var showInfo = false

    private var camera: WyzeCamera? { engine.camera(cameraID) }

    public var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Rectangle().fill(.black)
                if let player {
                    WyzeCamVideo(player: player, fill: fill)
                    PlayerStatus(player: player)
                }
            }
            .aspectRatio(fill ? 3 / 4 : 16 / 9, contentMode: .fit)
            .onTapGesture(count: 2) { withAnimation(.snappy) { fill.toggle() } }
            .accessibilityAction(named: fill ? "Show whole picture" : "Zoom to fill") { fill.toggle() }

            controls
                .padding(16)
            Spacer(minLength: 0)
        }
        .navigationTitle(camera?.name ?? "Camera")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let camera, camera.owned {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        WyzeCamProfileView(engine: engine, cameraID: camera.id)
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Camera settings")
                }
            }
        }
        .onAppear { open() }
        .onDisappear { close() }
        .onChange(of: quality) { close(); open() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if camera?.hasSD == true {
                    Picker("Quality", selection: qualityBinding) {
                        ForEach(WyzeCamQuality.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 140)
                }
                Spacer()
                Button {
                    withAnimation(.snappy) { fill.toggle() }
                } label: {
                    Image(systemName: fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(fill ? "Show whole picture" : "Zoom to fill")
            }
            if let player {
                Text(statsLine(player))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if camera?.online == false {
                Label("This camera is offline.", systemImage: "video.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statsLine(_ p: WyzeCamPlayer) -> String {
        var parts: [String] = []
        if let q = p.quality { parts.append(q.label) }
        if let s = p.videoSize { parts.append("\(Int(s.width))×\(Int(s.height))") }
        if p.state == .live { parts.append("\(Int(p.fps.rounded())) fps") }
        if let t = p.firstPictureAfter {
            parts.append("first picture \(t.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))")
        }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    private func open() {
        guard player == nil else { return }
        player = engine.openPlayer(cameraID: cameraID, quality: quality)
    }

    private func close() {
        if let player { engine.closePlayer(player) }
        player = nil
    }
}
