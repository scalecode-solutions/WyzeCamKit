# WyzeCamKit

Swift client for **mvCamera**: the Connect transport for cameras and sharing,
a WebRTC player for live view, and the UI. The host supplies identity and a
token provider and never logs in through the kit. Same shape as GarageKit and
LushKit.

iOS 26, Swift 6 (strict concurrency). Depends on connect-swift,
swift-protobuf and [smc_webRTC](https://github.com/scalecode-solutions/smc_webRTC)
(a shared WebRTC binary, so a host that already links it never carries two).

## What a host does

```swift
import WyzeCamKit

// 1. Build it inert (no requests, no video, nothing on disk).
let config = WyzeCamConfig(
    baseURL: URL(string: "https://example.app")!,
    currentUserID: myUserID,
    tokenProvider: { await auth.accessToken() }       // the host's own token
)
let engine = WyzeCamEngine(config: config)

// 2. Show it inside the host's own NavigationStack.
NavigationStack {
    WyzeCamView(engine: engine)                        // the grid; tiles push the live view
        .navigationTitle("…")                          // the host's title
        .toolbar { NavigationLink { WyzeCamOwnerView(engine: engine) { } } label: { Image(systemName: "gearshape") } }
}
.onAppear { engine.start() }                           // 3. run only while on screen
.onDisappear { engine.stop() }
.onChange(of: scenePhase) { _, phase in                // 4. and only in the foreground
    if phase == .background { engine.stop() } else if phase == .active { engine.start() }
}

// 5. Sign-out.
engine.wipeLocalStore()
```

### The rules behind that

- **Silent unless it's on screen.** A stopped engine makes no requests and
  holds no video connection, and nothing at home streams. On a day nobody
  opens the screen, the server never hears from the phone.
- **Video streams only while it's visible.** Grid tiles use each camera's SD
  substream and run only while the grid is on screen; opening a camera pushes
  `WyzeCamLiveView` (HD) and hangs the tiles up, so the home box sends one
  stream, not one per camera plus one.
- **The engine owns every player.** Views open players through
  `engine.openPlayer` and close them with `engine.closePlayer`. `stop()` hangs
  every one up; `start()` reconnects the ones still open. A host can drive the
  engine with a ref-counted owner (an app-wide session object) instead of
  view callbacks, because a pushed screen must not stop it.
- **Video only, receive only.** The kit never creates an audio track or touches
  the audio session, so it can't disturb a host's calls.
- **Nothing on the phone.** No database, no defaults, no pictures saved.
  `wipeLocalStore()` forgets what the account loaded.
- **Screens live in the host's navigation.** `WyzeCamView`, `WyzeCamLiveView`,
  `WyzeCamOwnerView` and `WyzeCamProfileView` are pushed content; sheets are
  used only for short tasks (share, add a home box). The kit never sets the
  host's title; its own pushed screens set theirs.
- **Wording** on the empty grid comes from `WyzeCamAppearance` (neutral defaults).
- **People** (names and avatars for sharing) come from mvCamera's contact list,
  which is the host's social graph projected by the server, the same way
  GarageKit and LushKit get them.

## Live view

`WyzeCamPlayer` is one WebRTC connection to the server for one camera stream:

- **Non-trickle offer → answer** over the `Watch` RPC. The server's
  candidates are fixed and in its answer; the client doesn't wait for its own
  (the server learns them from the connectivity checks).
- **TURN before the offer.** Relay credentials come from the `IceServers` RPC
  and go into the connection's configuration when it's built (a relay can't
  be added later without trickle). The engine caches them until 10 minutes
  before they expire; if they can't be fetched, the view goes ahead on direct
  paths only.
- **Server events** arrive on a negotiated data channel (id 0, `events`):
  `revoked`, `ended`, `offline`, `server`. Only well-formed text frames count;
  noise never ends a view.
- **Retries on its own** with backoff (2 s doubling to 30 s) after an ending
  that may pass (offline, stream ended, connection dropped, too many views,
  can't reach the server, not signed in: the host's token may come back).
  A revoked view never retries, and the engine reloads the list at once so the
  camera disappears.
- An answer that arrives after the view was hung up is stopped on the server,
  never played.
- `state`, `quality` (SD falls back to HD on a camera without one),
  `videoSize`, `fps` and `firstPictureAfter` are observable.

## Owner tools

`WyzeCamOwnerView` (push it; show its entry point to owners) lists your
cameras, cameras shared with you, and your **home boxes** (the computer at
home running `mvcam-agent`). Each camera opens `WyzeCamProfileView`: name,
color (GarageKit's palette), who can watch it (swipe to stop sharing,
**Share…** with an optional end date), and its key in the home box's config.
**Add a home box** registers one and shows its token once; a home box's page
makes a new token (the old one stops at once).

## WyzeCamLab

`Demo/WyzeCamLab` is the host used for development: the same wiring as above,
real mvServer login through MvAuth, a Production / Local picker.

- **Simulator:** choose Local; the app reaches the Mac's local stack on
  `localhost` (mvServer 6170, mvCamera 6096, WebRTC 8189).
- **Real phone against the local stack:** choose Local and enter the Mac's
  network name. The Mac must publish mvServer's and mvCamera's ports on the
  network, and mvCamera's WebRTC port with its public address set to the Mac's
  LAN address (`CAMERA_BIND`, `WEBRTC_BIND`, `WEBRTC_PUBLIC_IPS`).
- **Automation (Debug builds):** `WYZECAMLAB_USER` + `WYZECAMLAB_TOKEN` skip
  the login screen with a token from mvCamera's `cmd/minttoken`;
  `WYZECAMLAB_OPEN=<camera id>` opens that camera's live view, and
  `WYZECAMLAB_OPEN=owner` the owner screen:
  `SIMCTL_CHILD_WYZECAMLAB_USER=… SIMCTL_CHILD_WYZECAMLAB_TOKEN=… xcrun simctl launch <sim> dev.scalecode.WyzeCamLab`.

Regenerate the project after changing `Demo/project.yml`: `cd Demo && xcodegen generate`.

## Tests

```sh
xcodebuild test -scheme WyzeCamKit -destination 'platform=iOS Simulator,name=<a simulator>'
```

Happy paths and an adversarial suite: late and garbage answers from the
server, retry backoff, a refresh landing after stop, lifecycle abuse, strict
event frames, malformed responses. Player tests run real WebRTC offer
creation against a fake transport.

## Generated code

`Sources/WyzeCamKit/Generated` comes from mvCamera's protos:
`buf generate --template buf.gen.swift.yaml` (run in `../mvCamera`). Note:
swift-protobuf names the proto field `has_sd` `hasSd_p` (names starting with
`has` clash with its presence accessors).
