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
