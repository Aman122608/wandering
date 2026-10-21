# Wandering

On-device iOS location simulation, built from open components. Teleport, then
walk / bike / drive / cruise a real road route, with speed variation and GPS
noise. No licence, no daily caps, no server.

Everything runs on the phone. The only external pieces are the tunnel app you
already have installed and Apple's own developer services.

## How it works

```
Wandering ──TCP──▶ developer tunnel (LocalDevVPN utun) ──▶ remotepairingd:49152
                                                              │
                                          RSD ▸ DTX ▸ com.apple.instruments…
                                          ▸ LocationSimulation
                                          ▸ simulateLocationWithLatitude:longitude:
```

- **Transport** — [`jkcoxson/idevice`](https://github.com/jkcoxson/idevice) (MIT), compiled for
  iOS arm64 in [`wander-free`](https://github.com/Aman122608/wander-free) and downloaded as
  `vendor/libidevice_ffi.a` during CI. No protocol code in this repo.
- **Tunnel** — provided by an already-installed packet-tunnel app (LocalDevVPN). Wandering
  never asks for the NetworkExtension entitlement, which is what makes a free Apple ID
  signing profile sufficient.
- **Movement** — `Sources/Engine/TrackBuilder.swift`: per-segment road speeds from the
  route's own steps, turn-angle slow-down, speed variation, pedestrian micro-pauses,
  correlated GPS noise, and a breathing hold at the end.
- **Keep-alive** — silent looping audio plus coarse background location. Both exist only
  to stop iOS suspending the app; the simulated fix comes from the tunnel.

## Install

1. Install **LocalDevVPN** and connect it once (it provides the tunnel interface).
2. Generate a pairing file on a computer with `pymobiledevice3` and AirDrop it to the phone.
3. Install the IPA from the latest release with **SideStore / AltStore / ESign**, signed with
   your own Apple ID.
4. Open Wandering → Settings → **Import pairing file** → **Connect to the tunnel**.
5. Enable **Developer Mode** (Settings → Privacy & Security) and let Wandering mount the
   developer disk image on first connect.

## Using it

- **Teleport** — tap the map, then *Teleport*.
- **Route** — search an address (or paste `lat, lon`), add two or more stops, pick one of the
  offered routes, then **Move**.
- **Presets** — Walking (slow, most noise, occasional pauses), Biking, Driving (follows each
  street's speed), Car (holds your max speed).
- **Max speed** — caps every preset; the slider range follows the preset.
- **Stop** — restores the real GPS (`simulate-location clear`).

## Status

| Piece | State |
|---|---|
| Project skeleton, CI, IPA packaging | working |
| Map, address search, multi-route planning, presets, engine, player | written, first compile pass in progress |
| Tunnel discovery + endpoint sweep | working |
| Developer-transport FFI calls | stub — being wired to `libidevice_ffi` now |
| Keep-alive (audio + location) | written |
| Airplane-mode start (Shortcut-driven) | pending |

## Building

```bash
# one-time dependency fetch
curl -L -o /tmp/idevice.zip \
  https://github.com/Aman122608/wander-free/releases/download/idevice-v0.1.68/idevice-ios-arm64.zip
unzip -q /tmp/idevice.zip -d vendor

brew install xcodegen
./build_ipa.sh     # → build/Wandering.ipa (unsigned)
```

## Tunnel facts (verified on a real iPhone, iOS 27.2)

These cost a lot of builds to establish, so they are written down:

- **Dial `10.7.0.1:49152`, not the utun peer.** LocalDevVPN is a packet *swapper*: the
  app dials the fake-client address and the provider swaps src/dst so `remotepairingd`
  sees a connection from inside its own subnet. Dialing the utun peer (e.g. `10.7.1.1`)
  accepts TCP and then closes after ~20 ms — that is what produced every
  `Connection reset by peer` (errno 54) and sent us chasing pairing for several builds.
- **The pairing file was never the problem.** Once the address was right, the imported
  record handshook on the first try. Do not offer re-pairing on a reset until a probe
  shows the device *waited for us* and still refused.
- **The personalised disk image fails to mount on iOS 27.2** (`ImageMountFailed`, 15/0)
  and is **not needed** for location: the DVT location service is opened during the RSD
  handshake, before any mount. Mount is best-effort; failure only affects services that
  need the image (process control, screenshots).
- **`com.apple.dt.simulatelocation` over lockdownd (`10.7.0.1:62078`) is not reachable**
  through this tunnel — the port closes immediately. Kept in the tree as a dead fallback
  with its probe, because it would be the cheaper path if a future tunnel exposes it.
- A parked spoof needs **no connection**: writes land, the tunnel closes, the location
  stays. Movement needs the tunnel open for the duration of the stream.
