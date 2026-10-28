# Striker

An in-app **Objective-C runtime console** for iOS. Embed it in any app or tweak,
then drive it from your Mac **over USB** to inspect and poke the live runtime:
list classes/methods/ivars, dump the view and view-controller hierarchy, send
typed `objc_msgSend` messages, read/write memory, and install selector/vtable
hooks — all **in-process**, with no frida and no dyld injection.

Striker is a developer/reverse-engineering instrument. It is meant to be
compiled into a **debug/dev build** and left dormant (or absent) in release
builds. The listener binds to `127.0.0.1` only and is reachable solely through a
USB-forwarded port you start yourself.

> Status: this repository provides the embeddable console (`src/`), the USB
> driver (`driver/striker.py`), and the embedding docs. Each build must be
> compiled and exercised on-device; see *Status & verification* below for what
> is implemented versus what still needs on-device confirmation.

## Why

Frida's gadget is unreliable on recent iOS (it has repeatedly tripped in the
dyld initializer on iOS 26/27). Striker sidesteps that entirely: it is ordinary
in-process code that starts from your tweak's entry point, so it works wherever
your tweak loads — jailbreak or sideload. It complements, rather than replaces,
[FLEX](https://github.com/FLEXTool/FLEX): FLEX is an on-device GUI; Striker is a
scriptable console you drive from the terminal and automate.

## How it connects

```
 Mac                                   iPhone (USB)
 ┌────────────┐   iproxy 45678 45678   ┌───────────────────────────┐
 │ striker.py │ ─────────────────────▶ │ app + Striker listener     │
 │  (driver)  │ ◀───────────────────── │ 127.0.0.1:45678            │
 └────────────┘      USB / usbmuxd      └───────────────────────────┘
```

1. In one terminal: `iproxy 45678 45678` (from `libimobiledevice`) forwards a
   local port to the device's loopback over USB.
2. In another: `./driver/striker.py <command>` (or run it with no args for a
   REPL). Protocol: one command line in; the UTF-8 result plus a `0x04` (EOT)
   byte back; the connection stays open for the next command.

The app only answers while it is **foregrounded** (iOS suspends background apps).

## Command surface

Grouped by area (run `help` on-device for the authoritative list of what the
compiled build supports):

- **Runtime:** `classes [filter]`, `class <Name>`, `methods <Name> [filter]`,
  `method <Name> <sel>`, `ivars <Name>`, `instances <Name> [max]`, `images`.
- **UI:** `uitree [depth] [nodes] [all]` (view hierarchy with frames,
  accessibility ids and owning VC), `uivc` (VC/presentation tree),
  `uimenu`, `uidump` (serialize the hierarchy to a JSON file for USB pull).
- **Objects:** `obj <addr>` (class chain + ivar values).
- **Typed messaging:** `send` / `sendp` (pointer return) / `sendd` (double) /
  `sendrect` (CGRect) / `sendq` (main-queue) / `sendm` (multi-arg) — each uses
  the correct C prototype for `objc_msgSend`.
- **Memory:** `read` / `readf` / `write` / `vt` (vtable) / `dumpmem` /
  `scanstr` / `scanhex` / `findstr`.
- **Hooks:** `watch <Class> <sel>`, `hooksel`, `unhooksel`, `hookvt`, `unhook`.
- **Files:** `ls <path>`, `fileop <op> <a> [b]`, `home`, `b64 <path>`,
  `logtail [n]`.

## Embedding in your app/tweak

1. Add this repo as a submodule and compile `src/striker.m` into your tweak's
   C/ObjC target (it needs `-fobjc-arc`; include `src/` on the header path).
2. Start it once, from your tweak's entry point, **gated for dev builds only**:

   ```objc
   #import "striker.h"
   // e.g. behind a build flag and/or a bundle-root marker file so release
   // builds never open the listener:
   #ifdef STRIKER_ENABLED
       StrikerStartOnPort(45678);   // pick a per-app port if several apps embed Striker
   #endif
   ```

3. Build, install, foreground the app, then `iproxy <port> <port>` and drive it
   with `driver/striker.py`.

For a Swift (Orion) tweak, call `StrikerStart()` from your `Tweak` `init()` and
expose it behind a hidden setting as well as the build flag.

## Gotchas (hard-won; keep them in mind)

- **Foreground only.** The console does not answer while the app is suspended in
  the background. Do **not** relaunch the process to foreground it — that wipes
  the session you are inspecting.
- **One autorelease pool per command.** Autoreleased objects are gone by the
  next command; keep a live object alive with `alloc`+`init` and refer to it by
  address across commands.
- **Pointer returns need `sendp`.** Binding a pointer/C-string return as `id`
  and letting ARC retain it crashes in `objc_retain`.
- **Never `dispatch_sync` across a serial queue and the main thread** — it
  deadlocks. Use the main-queue send variants where a call must run on main.
- **Validate heap candidates before messaging** them: a bare isa match is not
  proof an address is a live, fully-initialized object.
- Each client connection runs on its own thread and each command is wrapped in
  `@try/@catch`, so one bad command cannot take down the listener.

## Status & verification

- Implemented here: the embeddable listener/dispatch, the command set above, and
  the USB driver.
- Each target build must be compiled with Theos and exercised on a real device
  (the listener, `iproxy` bridge, and every command path are confirmed per build
  on-device, not asserted here).

## License

GPL-3.0. See [LICENSE](LICENSE).
