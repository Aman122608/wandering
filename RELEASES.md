# Wandering — release notes

Newest first. Each entry says what changed and what to check, so a build is never just
"try it and see".

## Latest — chase mode fixes + release notes

**Changed**
- Chase (Follow me) measured "time since the last fix" *after* stamping it, so every fix
  looked instantaneous and was rejected as a jump. The path never grew.
- Now the interval is measured against the last **accepted** fix, and the jump test only
  applies when that interval is at least 0.5 s.
- **Re-anchor:** after a radio cycle or a GPS re-acquisition, a big jump restarts the path
  instead of rejecting everything after it (`chase: re-anchored after a 43 s gap`).
- Stopping parks the spoof at the point that was being **reported**, not at the end of the
  real path — stop no longer snaps you forward to your true position.
- Path compaction can no longer discard path the cursor has not consumed.
- The `verify:` line is suppressed while chasing: it compared the device fix against the
  coordinate we had just written, so it was measuring itself.
- Follow me card on the map: Start/Stop, mph now, metres behind, GPS accuracy, write count.
- Cap slider is mph, and no longer writes a log line per drag step.

**Check**
- Card `writes` climbs about once a second.
- Log shows `chase: N m along · N m behind · N mph · N m GPS · N writes` every 10 s.
- Drive above the cap: `mph now` pins at the cap and `m behind` grows. Stop: it drains to 0.

## build 44 — cellular sequencing

**Changed**
- `airplane: radio confirmed off — building the tunnel inside it`: the radio is dropped
  first and the tunnel is dialled inside the quiet window, which is the order the shipping
  app uses.
- Connect reports its real result instead of returning early when another attempt was in
  flight (that made the sequence believe a tunnel existed).
- A restore leg that cannot be fired from the background is **queued** and sent when the
  app is active again, instead of failing silently and leaving the radio off.

**Check**
- One pass: `radio confirmed off` → `tunnel up on attempt 1` → `Done`.
- No `Shortcuts refused` lines; if one appears it is followed by `restore queued` and a
  later `sending the restore leg`.

## build 42 — locations stick

**Changed**
- A parked location (after a teleport or the end of a route) is re-sent every **4 seconds**
  with a breathing offset capped at 1.5 m across. Wander and StikDebug both use 4 s, and
  both say why: iOS re-checks the simulated location and a single write can be replaced by
  the real fix.

**Check**
- Park somewhere, leave it two minutes, confirm the position is still held.
- Log shows `hold: still pinned (N resends)` about once a minute.

## build 41 — no more connect storms

**Changed**
- One connect at a time; a second caller joins the running attempt.
- The pre-connect probe checks only `10.7.0.1:49152` (one second); the full candidate sweep
  is capped at 4 seconds and there is a 4-second cooldown after a failure.

**Check**
- With the tunnel down the app stays responsive instead of lagging for a minute.

## build 39 — tunnel address

**Changed**
- The app dials `10.7.0.1:49152` — the fake-client address the provider swaps — not the
  utun peer, which accepts TCP and then closes after ~20 ms.

**Check**
- `peer stayed silent for 1501 ms — it waits for us` on the probe line, then
  `ffi: tunnel open`.
