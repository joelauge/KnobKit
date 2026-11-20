# KnobKit

A macOS menu bar configurator for the Epomaker x Aula F75. It turns the encoder knob
into a context-aware control: what a turn, press, double press, long press or
hold-and-turn does depends on the frontmost app, the active mode, and which modifier
keys you are holding.

## How it works

The F75 reports its knob as three consumer-control signals: volume up, volume down
and mute. KnobKit never touches the keyboard's firmware. It works on the Mac side:

1. An **event tap** sees those volume / mute events before any app does and can
   swallow them. (Needs the Accessibility permission.)
2. A **HID listener** records which physical device sent each volume / mute press, so
   only the F75 is treated as "the knob". The MacBook's own volume keys and other
   keyboards behave normally. It reads the consumer-control page only, never
   keystrokes. (Needs the Input Monitoring permission.)
3. A **gesture engine** turns ticks and presses into gestures, a **resolver** finds the
   binding for the current app, mode and modifier layer, and an **action runner**
   performs it.

Because the knob shares its signals with the F75's Fn media keys (Fn + volume keys),
those keys count as the knob too.

## Concepts

| Thing | Meaning |
| --- | --- |
| Profile | A set of bindings for one or more apps (by bundle id, `*` suffix matches a prefix, optional window-title filter). `Global` applies everywhere. |
| Mode | A named set of bindings inside a profile. The knob cycles through modes; the menu bar icon shows the active one. |
| Always | A per-profile layer that applies in every mode. |
| Layer | The modifier keys held while using the knob: none, or any combination of ⌃ ⌥ ⇧ ⌘. Each combination is its own set of bindings. |
| Gesture | Turn left / right, press, double press, triple press. Turns can also have a separate "spun fast" action. Long press and hold + turn exist in the editor but the F75 cannot send them (see Limits). |

Lookup order for any gesture: app profile's current mode, app profile's Always,
Global's current mode, Global's Always. Anything unbound falls through to the system
(volume / mute).

### Actions

System default, do nothing, volume with a custom step, mute, any media or brightness
key, Apollo monitor level / mute / dim / mono (see below), keystroke (with repeat count), keystroke with a held modifier (for ⌘⇥ / ⌃⇥ style
switchers), type text, scroll (pixels or lines, smooth, with modifiers), click a menu
bar item by name, open an app / file / URL, shell command, AppleScript, run a
Shortcut, switch mode, and macros (a sequence of any of these with delays).

Per binding: a label, "speed up when spun fast" (acceleration), "fire every N
detents", and a different action when spun fast.

Modes can also remap ordinary keys and shortcuts to any action. Key remaps apply to
every keyboard, not only the F75.

## Universal Audio Apollo

Apollo interfaces have no macOS volume control, so the system volume keys (and an
unconfigured knob) do nothing on them. KnobKit talks to the UA mixer engine on this
Mac instead (TCP port 4710 on localhost, the channel UA Console itself uses) and
finds the output that carries the monitor level.

- **Apollo monitor level**: a step in dB per detent (0.5 dB resolution).
- **Apollo monitor mute / dim / mono**: toggles.
- **Ceiling** (General > Universal Audio monitor, default -20 dB): the knob never
  raises the level above this, however fast it is spun. A level already above the
  ceiling, set on the hardware, is left alone and can still be turned down.
- Both actions have "use the Mac's own volume when the current output has one", on by
  default, so the same binding works on headphones or built-in speakers.
- Changes made on the hardware or in UA Console are followed.
- General > "Use the Apollo for volume" rewrites Global's stock volume bindings to
  these actions; a fresh install does it automatically when the UA mixer is running.

The control protocol is not documented by UA. If a UAD update changes it, the HUD
shows "UA mixer not reachable" and nothing else is affected. The UAD software must be
running.

## Build and run

Requires Xcode (Swift 5.9 or later) on macOS 14 or later.

Install to `/Applications` and launch (replaces a previous install, and removes the
copy in `build/` so macOS only ever sees one KnobKit):

```bash
scripts/install.sh
```

Open at login is the toggle under General, or from a shell:

```bash
/Applications/KnobKit.app/Contents/MacOS/KnobKit --login-item on
```

(`off` and `status` work too.) To build without installing, for development:

```bash
scripts/build.sh
```

```bash
open build/KnobKit.app
```

The script signs with the first `Apple Development` identity in the keychain so the
permission grants survive rebuilds. Set `KNOBKIT_SIGN_IDENTITY` to choose another
identity, or to `-` for an ad-hoc signature (macOS will then ask for the permissions
again after every build).

Run the logic tests with:

```bash
swift test
```

## Files

| Path | What |
| --- | --- |
| `~/Library/Application Support/KnobKit/config.json` | Everything: settings, profiles, modes, bindings. Readable JSON, safe to edit by hand; use General > Reload from disk afterwards. |
| `~/Library/Logs/KnobKit/knobkit.log` | Knob events, which device sent them, and what was done. Ordinary typing is never logged. |
| `Sources/KnobCore` | Config model, gesture engine, resolver, defaults. No UI, unit tested. |
| `Sources/KnobKit` | The app: event tap, HID listener, actions, HUD, menu bar popover, configurator. |

## Connections

Bluetooth, the 2.4G dongle and USB each present the F75 as a different HID device.
Any device whose name contains F75 / AULA / Epomaker (or vendor `0x3554`) is selected
automatically the first time it is seen; others can be ticked under Devices.

## Testing without the knob

The Live monitor page has buttons that feed simulated knob input through the same
path as real events. From a shell, start the app with the hook enabled and send
tokens:

```bash
open build/KnobKit.app --args --allow-simulation
```

```bash
build/KnobKit.app/Contents/MacOS/KnobKit --send "cw cw opt+ccw press down wait:700 up"
```

Tokens: `cw`, `ccw`, `press`, `down`, `up`, `wait:<ms>`, each optionally prefixed with
modifiers (`cmd+shift+cw`). The hook is off unless `--allow-simulation` is passed.

## Troubleshooting

**The knob only changes the keyboard's lighting, and the Live monitor stays empty.**
The F75's knob has two modes built into the keyboard. In lighting mode (the knob's
own light breathes) turning changes backlight brightness and pressing cycles effects,
all inside the keyboard: nothing is sent to the Mac, so KnobKit has nothing to work
with. Hold the knob down for 3 to 5 seconds, until the Win and Caps Lock lights flash,
to switch to volume mode (the knob's light stays steady). The same long hold switches
back.

**Events show up as "not the knob".** The device that sent them is not ticked under
Devices, or Input Monitoring is not granted.

## Limits

- No firmware access: key matrix remapping, RGB lighting and on-board layers stay in
  Epomaker's own tools. KnobKit only acts on what the keyboard sends to the Mac.
- The knob cannot be told apart from the F75's own Fn volume / mute keys.
- The F75 sends a knob press as an instant tap (about 20 ms) however long it is held,
  so long press and hold-and-turn can never fire. Mode switching therefore defaults to
  double press (next) and triple press (previous). A single press waits one
  double-press window (Knob feel) before acting wherever a double press is bound.
- Over Bluetooth the knob reports an ordinary turn at 15 to 25 detents per second and
  tops out near 33; the speed thresholds under Knob feel are calibrated to that.
- Scroll actions go to whatever is under the pointer, as with any scroll wheel.
- Secure input fields (password prompts) block synthetic keystrokes by design.
