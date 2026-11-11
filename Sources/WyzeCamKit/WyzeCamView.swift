import SwiftUI

/// The camera grid: every camera the user may watch, each online one as a
/// live SD tile. Tapping a tile pushes `WyzeCamLiveView` (HD) in the host's
/// navigation stack. The kit never sets the host's title.
///
/// Tiles stream only while they're on screen: pushing the live view over the
/// grid hangs the tiles up, so the home box sends one stream, not N + 1.
public struct WyzeCamView: View {
    let engine: WyzeCamEngine
    let appearance: WyzeCamAppearance

    public init(engine: WyzeCamEngine, appearance: WyzeCamAppearance = .standard) {
        self.engine = engine
        self.appearance = appearance
    }

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    public var body: some View {
        Group {
            if engine.cameras.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(engine.cameras) { cam in
                            NavigationLink {
                                WyzeCamLiveView(engine: engine, cameraID: cam.id)
                            } label: {
                                WyzeCamTile(engine: engine, camera: cam)
                            }
                            .buttonStyle(.plain)
                            .disabled(!cam.online)
                        }
                    }
                    .padding(16)
                    if case .failed(let message) = engine.status {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 16)
                    }
                }
                .refreshable { await engine.refresh() }
            }
        }
    }

    @ViewBuilder private var empty: some View {
        switch engine.status {
        case .idle, .loading:
            ProgressView()
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't load cameras", systemImage: "video.slash")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await engine.refresh() } }
            }
        case .signedOut:
            ContentUnavailableView("Not signed in", systemImage: "person.crop.circle.badge.exclamationmark")
        case .ready:
            ContentUnavailableView(appearance.emptyTitle, systemImage: "video",
                                   description: Text(appearance.emptyMessage))
        }
    }
}

/// One camera in the grid: its SD picture when it's online and has one, its
/// name, and its state.
struct WyzeCamTile: View {
    let engine: WyzeCamEngine
    let camera: WyzeCamera

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(.black)
                if camera.online && camera.hasSD {
                    TilePicture(engine: engine, cameraID: camera.id)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: camera.online ? "play.circle" : "video.slash")
                            .font(.title2)
                        Text(camera.online ? "Tap to watch" : "Offline")
                            .font(.caption)
                    }
                    .foregroundStyle(.white.opacity(0.6))
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))

            HStack(spacing: 6) {
                Circle()
                    .fill(camera.online ? AnyShapeStyle(CameraTint(color: camera.color)) : AnyShapeStyle(.gray))
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(camera.online ? "Online" : "Offline")
                Text(camera.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if !camera.owned {
                    Image(systemName: "person.2.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Shared with you")
                }
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        // Combine the children's own labels (name, online, "Shared with you",
        // and the stream's state or error) rather than replacing them.
        .accessibilityElement(children: .combine)
        .accessibilityHint(camera.online ? "Opens the live view" : "")
    }
}

/// The live SD picture inside a tile. Exists only while the tile shows an
/// online camera, so appearing and disappearing are exactly the stream's life.
private struct TilePicture: View {
    let engine: WyzeCamEngine
    let cameraID: UUID
    @State private var player: WyzeCamPlayer?

    var body: some View {
        ZStack {
            if let player {
                WyzeCamVideo(player: player, fill: true)
                PlayerStatus(player: player, compact: true)
            }
        }
        .onAppear {
            if player == nil { player = engine.openPlayer(cameraID: cameraID, quality: .sd) }
        }
        .onDisappear {
            if let player { engine.closePlayer(player) }
            player = nil
        }
    }
}

/// What a player is doing, laid over its picture: nothing while it's live.
struct PlayerStatus: View {
    let player: WyzeCamPlayer
    var compact = false

    var body: some View {
        switch player.state {
        case .live:
            EmptyView()
        case .idle, .connecting:
            ProgressView().tint(.white)
        case .ended(let reason, let retrying):
            note(reason == .revoked ? "lock.fill" : "video.slash", reason.message, retrying: retrying)
        case .failed(let message, let retrying):
            note("exclamationmark.triangle", message, retrying: retrying)
        }
    }

    /// A revoked view can't come back by trying again.
    private var isRevoked: Bool {
        if case .ended(.revoked, _) = player.state { return true }
        return false
    }

    private func note(_ symbol: String, _ text: String, retrying: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(compact ? .title3 : .title)
            Text(text)
                .font(compact ? .caption2 : .callout)
                .multilineTextAlignment(.center)
            if retrying {
                Text("Trying again…").font(compact ? .caption2 : .caption).opacity(0.7)
            } else if !compact && !isRevoked {
                Button("Try again") { player.retry() }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
        }
        .foregroundStyle(.white)
        .padding(compact ? 6 : 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Readable over whatever picture was last on screen.
        .background(.black.opacity(0.55), ignoresSafeAreaEdges: [])
    }
}
