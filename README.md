# AeroDrop for macOS

Peer-to-peer file transfer between a Mac and an Android device over the local
network. No cloud, no account, no internet connection required — the two
devices find each other over Bonjour and talk directly over TLS 1.3.

This repository is the **macOS app only**. The Android counterpart is a separate
project; this side is useless without it.

<img src="docs/screenshot.png" alt="AeroDrop panel" width="480">

## Requirements

| | |
|---|---|
| macOS | 26.2 or later (deployment target) |
| Toolchain | Xcode 26+, Swift 5, C++20 |
| Dependencies | OpenSSL 3 (`brew install openssl@3`) |
| Network | Both devices on the same LAN, same subnet |
| Firewall | macOS will prompt to accept incoming connections on first launch |

The app is a **menu bar extra** — there is no Dock icon and no main window. Click
the antenna glyph in the menu bar to open the panel, or add the widget to your
desktop and Notification Center to send and monitor transfers without opening
anything at all. See [Widgets](#widgets) for what it can and can't do.

## Build

```bash
./xcode-setup.sh      # installs OpenSSL 3, generates AeroDrop.xcconfig
open AeroDrop.xcodeproj
```

Then in Xcode: select the project → target **AeroDrop** → *Info* →
*Configurations* → set **both** Debug and Release to the generated
`AeroDrop` xcconfig, then `⌘B`.

Or from the command line, once the xcconfig is wired up:

```bash
xcodebuild -scheme AeroDrop -configuration Debug build
```

The project has two targets. `AeroDropWidgets` (the widget extension) is built
automatically as a dependency of the app and embedded at
`AeroDrop.app/Contents/PlugIns/AeroDropWidgets.appex` — nothing to wire up. It
links no OpenSSL, so it needs no xcconfig; build it alone with
`-scheme AeroDropWidgets` if you want to iterate on the widget quickly.

> The script is a convenience, not a requirement. `project.pbxproj` already
> hardcodes the OpenSSL search paths, so `xcodebuild` works on a clean checkout
> without ever running it. Running it just refreshes them for your Homebrew
> prefix.
>
> The project uses a file-system-synchronized group, so new files under
> `AeroDrop/`, `AeroDropWidgets/` and `AeroDropShared/` are picked up
> automatically — there is no "add files to target" step. Note that
> `xcode-setup.sh` still prints the older manual instructions, and its
> suggested `MACOSX_DEPLOYMENT_TARGET = 13.0` is stale; the project itself is
> set to 26.2.

## Using it

1. Open AeroDrop on both devices. The Mac starts advertising `_aerodrop._tcp`
   on port **7770** immediately at launch.
2. Your Android device appears in the **Devices** sidebar and is selected for
   you. AeroDrop re-selects the device you used last, so after a relaunch it's
   already pointing at the right one; click another row to switch.
3. Drop one or more files onto the panel, or press `⌘O` to pick them.

Transfers are **serialized through a queue** — drop twenty files and they go one
at a time, each with its own progress, throughput and time remaining. You can
keep dropping files while a transfer is running, remove anything still waiting,
and clear finished items when you're done. Received files land in
`~/Downloads/AeroDrop`.

The panel is resizable (drag the corner, or the title bar to move it) and
remembers its size. It opens by itself on first launch so the app isn't
mysteriously invisible, then stays out of the way.

You can also skip the panel entirely: add the widget to your desktop or
Notification Center and drag files straight onto it.

### Sending and receiving look the same

Every visual decision about a transfer lives in two files, `TransferStyle.swift`
and `TransferMotion.swift`, and both directions run the same code path. The only
intended differences are the arrow (`arrow.up.to.line` / `arrow.down.to.line`)
and the verb — the tint, progress bar, ripples, row layout and summary treatment
are literally the same code. Direction is never signalled by colour, so the two
can't drift apart visually.

| | |
|---|---|
| Row layout | identical; a direction glyph on every row so inbound and outbound are distinguishable without reading text |
| Progress | one `WaveProgressBar` used for the queue, the row, and the status icon |
| Animations | rows slide in and out, the bar's waterline travels, completion gets a tint wash and a single bounce |
| Summary | the active transfer is described by the same three lines whichever way it is going |
| Menu bar | `TransferActivity` mirrors any in-flight transfer as a percentage, so closing the panel never hides it |

### The water metaphor

Transfers read as things landing in water. All of it is drawn with `Canvas` and
driven by `TimelineView(.animation)`, so it stays on the GPU.

- **Ripples** — three concentric rings expanding from the point of impact, with
  staggered starts so they chase each other outward, over a short soft bloom at
  the contact point. One ring would read as a loading spinner; three read as a
  splash. A transfer that starts fires the same ripple in both directions:
  `RippleStyle` has no per-direction case, and the only thing distinguishing
  inbound from outbound is the arrow and the verb in the row.
- **`WaveProgressBar`** — progress is water filling a vessel from the bottom, so
  the bar is a waterline rather than a filled rectangle. Two summed sines make
  the crest travel along the bar, which keeps moving even when a transfer stalls
  between progress callbacks. The status icon uses the same view with the glow
  suppressed, so the menu bar never blurs.
- **`WaterSurface`** — slow swells behind the idle drop zone, lifting in
  amplitude as a transfer picks up speed.

`RippleLayer` only mounts its timeline while a ripple is actually alive;
`TimelineView(.animation)` redraws every frame forever otherwise, which is the
wrong trade for an app that spends most of its life in the menu bar. Every view
in the file renders its settled state when the system asks for reduced motion.

The bar is `easeOut(0.22)` — long enough to smooth the 100 ms progress callbacks
into continuous motion, short enough not to lag a stall. An active transfer that
hasn't reported a fraction yet shows a moving highlight rather than sitting at
zero, which otherwise reads as broken.

Rows are appended in arrival order for both directions. Incoming transfers used
to be inserted at index 0 while outgoing appended, which meant the newest row was
at the top for one direction and the bottom for the other; the active row is now
scrolled into view instead of relying on position.

The menu bar indicator is deliberately direction-neutral — it shows a percentage,
not an arrow, because it only needs to say *busy*.

### Pairing

There is no pairing step. Each device generates its own self-signed
certificate on first launch; the SHA-256 fingerprint is shown in the panel
footer and can be copied with **Copy ID**. Compare it out of band if you want
to confirm you're talking to the device you think you are.

## How it works

```
Android device                          Mac
     │                                     │
     ├── Bonjour _aerodrop._tcp:7770 ──────┤   AeroDiscoveryBrowser (NetServiceBrowser)
     │                                     │   BonjourService      (BonjourBridge.mm)
     │                                     │
     ├── TLS 1.3 ─────────────────────────►┤   AeroServer         (CXX, OpenSSL)
     ├── 64-byte AERO header               │   ├─ magic "AERO", version, file size,
     └── raw payload ──────────────────────┤   │  filename (44B), Adler-32
                                           │   └─ 512 KiB chunks
```

Discovery is deliberately **resolve-only**. `NetServiceBrowser` is used purely
to turn an mDNS name into an IP address; no TCP connection is opened during
discovery. An early `NWConnection` probe during discovery was enough to make
Android's `SSLServerSocket` throw and leave the Mac waiting forever, so the
browser never touches the socket.

Both devices bind an IPv6 dual-stack socket, so IPv4-mapped addresses work
without a second listener. When a peer advertises an IPv6 link-local address
the `%en0` scope ID is preserved so the kernel can route it.

### Wire format

A fixed 64-byte header precedes the payload:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | magic `AERO` |
| 4 | 4 | version (`uint32`, currently 1) |
| 8 | 8 | file size (`uint64`) |
| 16 | 44 | filename, UTF-8, null-padded |
| 60 | 4 | Adler-32 of the filename bytes |

The remainder of the connection is the raw file, streamed in 512 KiB chunks
with a progress callback every ~100 ms.

## Security

- TLS 1.3 only — `SSL_CTX_set_min_proto_version(TLS1_3_VERSION)`, so anything
  older is refused outright.
- Traffic is encrypted in transit and never leaves the LAN.
- **Certificates are not verified.** `SSL_VERIFY_NONE` is set on both the
  server and client contexts; the self-signed certificate is accepted as-is.
  That makes the channel confidential but **not authenticated** — a device on
  the same network could in principle man-in-the-middle it. This is trust-on-
  first-use with no automatic pinning, which is why the fingerprint is surfaced
  in the UI for manual comparison. Adding real verification (pinning on first
  contact, or a PAKE) is the obvious next step and is not implemented.

## Layout

```
AeroDrop/
  AeroDropApp.swift        App entry point; installs the status item
  Core/
    AeroDiscoveryBrowser   NetServiceBrowser wrapper → @Published [AeroPeerInfo]
    AeroPeerInfo           Peer model; id is the mDNS instance name
    BonjourService         @MainActor wrapper over the C registration API
    BonjourBridge.{h,mm}   DNSServiceRegister plumbing
    BridgeServer.{h,mm}    ObjC++ singleton owning AeroServer; block-based API
  CXX/
    AeroServer.{h,cpp}     TLS listener, inbound receive, outbound send
    CertManager.{h,cpp}    On-demand RSA-4096 keygen + self-signed cert
  UI/
    RootView               Two-pane layout, banner, security footer
    PeerSidebar            List-based device sidebar
    DropTargetView         Idle / drag-target state
    TransferQueueView      Queue summary and per-item rows
    TransferViewModel      Serialization, discovery wiring, throughput
    TransferItem           Queue item model + ThroughputMeter
    TransferStyle          Shared send/receive presentation + animated bar
    TransferMotion         Ripples, wave progress bar, idle water surface
    TransferActivity       Transfer state mirrored into the menu bar
    StatusPanelController  NSStatusItem + resizable AeroPanel
    WidgetBridge           Shared-state writer, peer memory, drop hand-off
    Theme                  Colors, spacing, byte/duration formatting
```

SwiftUI for the UI, Objective-C++ as the bridge into the C++/OpenSSL
transport. There is no package manager dependency beyond OpenSSL; new files
under `AeroDrop/`, `AeroDropWidgets/` and `AeroDropShared/` join their targets
automatically.

```
AeroDropWidgets/             WidgetKit extension (see "Widgets" below)
  AeroDropWidget            One widget, three modes across four families
  Intents/                  Mode parameter + the drop hand-off
AeroDropShared/
  AeroWidgetState           Codable snapshot shared with the widget
```

### A note on throughput

`speed_mbps` in `AeroServer.h` is never assigned and is always `0.0`; the one
code path that did compute a rate reported MB/s, not Mbps. Rather than change
the transport, the UI derives throughput in Swift from byte deltas between
progress callbacks (`ThroughputMeter`), smoothed with an EWMA. The C++ field is
dead and could be removed.

## Widgets

`AeroDropWidgets` is a WidgetKit extension offering a single widget with a
configurable mode, rendered at small, medium, large and extra-large:

- **Drop to Send** — drag files straight onto the widget.
- **Transfer Status** — the running transfer, or the last result.
- **Recent Files** — what you sent last, to the current device.

Right-click the widget → Edit Widget to switch mode.

The extension and the app are separate processes that can only communicate
through one JSON file, and only in one direction at a time:

```
┌──────────────────────────┐        ┌─────────────────────────────┐
│ AeroDrop.app             │        │ AeroDropWidgets.appex       │
│                          │        │                             │
│ TransferViewModel        │ write  │  AeroDropWidgetProvider     │
│   └─ WidgetBridge ───────┼───────►│      └─ renders snapshot    │
│                          │        │                             │
│  1.5 s poll ─────────────┼───────►│  DropVariant                │
│   └─ takePendingDrop()   │  read  │      └─ dropDestination     │
│      └─ enqueue + send   │        │         writes pendingDrop  │
└──────────────────────────┘        └─────────────────────────────┘
      aerodrop_widget_state.json  ── the only channel ──►
```

Two things widgets fundamentally cannot do, so this design leans on them
instead of fighting them:

**They are not live.** WidgetKit calls the timeline provider on a
system-decided schedule and throttles `reloadAllTimelines`. The widget
therefore never discovers peers or streams progress over the network — it
renders a snapshot the app writes to a shared JSON file
(`aerodrop_widget_state.json`) and refreshes on change, throttled to once a
minute, with terminal events (completed/failed) forcing an immediate reload.
Expect a transfer to look frozen mid-flight; the number is a snapshot, not a
live gauge.

**They cannot signal the app.** There is no supported push from an extension to
its host, so a file dropped on the widget is written to the shared file as a
pending drop and the app picks it up on a 1.5 s poll
(`WidgetBridge.takePendingDrop`). AeroDrop is a menu-bar app that stays
running, so the poll always succeeds. The payload is cleared on read so a
redraw can't resend it.

#### Shared container, and why there isn't an App Group

The canonical way to share state is the App Group container
(`group.com.siluna.AeroDrop`). It is implemented and preferred, but it is
**not enabled**, because an app-group entitlement requires a provisioning
profile and this project is built without a `DEVELOPMENT_TEAM`. Adding it
unconditionally breaks `xcodebuild` outright with *"entitlements that require
signing with a development certificate"*.

Instead the state lives in `~/Library/Application Support/AeroDrop/`, which both
the app and the unsandboxed extension can read and write with no entitlement.
Two details worth knowing if you touch this:

- `containerURL(forSecurityApplicationGroupIdentifier:)` returns a **path even
  when the group is unprovisioned**, but the container directory is never
  created — so the app group is only used once the directory really exists on
  disk. Checking the path alone is not enough, and writes fail with `ENOENT`.
- To move to the App Group, set a `DEVELOPMENT_TEAM` on both targets, add
  `com.apple.security.application-groups = [group.com.siluna.AeroDrop]` to both
  entitlements files, and set `ENABLE_APP_SANDBOX = YES` on the extension.

## Nearest device by default

To reduce taps, AeroDrop remembers the device you last used and re-selects it
on relaunch, falling back to the first device discovered. The sidebar still
overrides it, and the choice is stored under `AeroDropDefaultPeerID`.

This is *not* real proximity. Bonjour exposes no distance information, and
measuring latency instead would mean opening a TCP connection to every peer on
the network during discovery — which crashes the Android client's
`SSLServerSocket`, a constraint the code comments call out. So "nearest" means
"last used, else first found", and the naming is deliberately worded that way in
the code.
