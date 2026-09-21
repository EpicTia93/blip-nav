# Blip

Keyboard-driven targeting for everything on your Mac. Double-tap **Right ⌘**, every
clickable thing on screen gets a number, and you either type the number or type what the
thing is called.

It merges what three separate tools do: Homerow's hint labels, Wooshy's search-by-text,
and Superkey's double-tap trigger — across every visible window, not one app.

## How it works

Two scanners run on every activation and are merged:

- **Accessibility** walks the AX tree of every on-screen app, in parallel. Precise, and
  the resulting targets can be pressed directly. ~20ms warm.
- **OCR** captures the screen and reads it with Vision. Slower (~400ms), but it sees
  canvas-drawn apps, remote desktops and anything else AX is blind to.

Accessibility results are drawn immediately; OCR results are appended when they land, so
numbers already on screen never change under your fingers.

Keys: **letters filter · digits select · Tab steps between remaining matches · Enter
takes the pointed-at match · Esc dismisses**.
Numbers are assigned once per activation and stay put, which is what lets digits and
letters share one prompt unambiguously.

## Build

```
make run       # build, bundle, sign and launch
make test      # unit tests
make icon      # regenerate AppIcon.icns from logo.png
make identity  # print the designated requirement TCC matches against
```

Blip must be **signed with a stable identity** and always built to the same path.
Accessibility and Screen Recording grants are keyed to the code signature and bundle
path; an ad-hoc signature is keyed to the binary hash instead, so permissions would
silently vanish on every rebuild. `make identity` prints what TCC actually matches — if
that line changes between builds, permissions will reset.

The app is deliberately **not sandboxed**: the App Sandbox blocks Accessibility control
of other processes entirely.

## Permissions

| Grant | Needed for | Without it |
|---|---|---|
| Accessibility | The trigger, reading other apps, clicking | Nothing works |
| Screen Recording | OCR only | Falls back to Accessibility-only, and says so |

## Debugging

`blip-probe` runs the real scan pipeline headlessly and prints what it found — far more
useful than squinting at a transient overlay:

```
swift run blip-probe --timings          # per-app AX wall times
swift run blip-probe --windows          # window list + AX window matching
swift run blip-probe --ocr --all        # include the Vision pass
swift run blip-probe --repeat 5         # cold vs warm connection timing
```

Runtime logs:

```
log show --last 5m --info --debug --predicate 'subsystem == "com.mattiapuppo.blip"'
```

## Layout

- `Sources/BlipCore` — pure logic: coordinates, hint numbering, fuzzy matching, merging,
  occlusion. No system frameworks, so it is all unit-testable headlessly.
- `Sources/BlipKit` — Accessibility, ScreenCaptureKit, Vision, the event tap, actuation.
- `Sources/Blip` — the agent app: overlay panels, menu bar item, settings.
- `Sources/blip-probe` — the debug CLI.

### Things that are load-bearing

- All internal geometry is **CG space** (top-left origin, Y down). The flip to AppKit
  happens in exactly one place, at draw time. `Geometry` holds every conversion.
- `AXUIElementSetMessagingTimeout` is mandatory — one beachballing app would otherwise
  stall the whole scan.
- `AXManualAccessibility` must be set before reading windows, or Chromium and Electron
  apps report an empty tree.
- Fully occluded windows are culled *before* traversal, not after. This is the single
  biggest saving in the scan.
- `maxDepth` is 60. Web content nests 40+ levels deep; at 25 the scanner silently missed
  most in-page buttons.
- The event tap must re-enable itself on `.tapDisabledByTimeout`, or Blip stops
  responding to its own hotkey with no error anywhere.
- The overlay panel must never become key. If it does, Blip becomes frontmost and
  clicking the target app stops behaving predictably.
