import SwiftUI
@preconcurrency import WebRTC

/// A player's picture. Black until pictures arrive; `fill` crops to the frame
/// (grid tiles), otherwise the whole picture shows (the live view).
public struct WyzeCamVideo: View {
    let player: WyzeCamPlayer
    var fill: Bool

    public init(player: WyzeCamPlayer, fill: Bool = false) {
        self.player = player
        self.fill = fill
    }

    public var body: some View {
        VideoSurface(track: player.track, fill: fill)
            // Not `.background(.black)`: a style background reaches into the
            // safe areas and paints the host's navigation bar black.
            .background(.black, ignoresSafeAreaEdges: [])
    }
}

/// RTCMTLVideoView in SwiftUI (receive-only).
struct VideoSurface: UIViewRepresentable {
    let track: RTCVideoTrack?
    var fill: Bool

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = fill ? .scaleAspectFill : .scaleAspectFit
        view.clipsToBounds = true
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        view.videoContentMode = fill ? .scaleAspectFill : .scaleAspectFit
        let old = context.coordinator.track
        if old !== track {
            old?.remove(view)
            track?.add(view)
            context.coordinator.track = track
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.track?.remove(view)
        coordinator.track = nil
    }

    final class Coordinator {
        var track: RTCVideoTrack?
    }
}
