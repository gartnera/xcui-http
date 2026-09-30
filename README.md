# xcui-http

Drive any installed iOS app's UI over HTTP, through XCUITest: read the element
tree, tap, type, swipe, drag, long-press, rotate, press home/lock, screenshot.
It's one UI test (`Sources/XCUIHTTP.swift`) that serves until `POST /shutdown`,
with no host app of its own, so it works against any app by bundle id, in the
Simulator or on a device.

## Install

Needs Xcode 16+ and [`xcodegen`](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
git clone https://github.com/gartnera/xcui-http && cd xcui-http
make install        # xcui-http into ~/.local/bin (PREFIX=… to change)
```

`xcui-http` builds and runs the runner from this checkout, so keep it where it
is (or point `XCUIHTTP_ROOT` at it).

## Usage

The app must already be installed on the Simulator or device.

```bash
xcui-http start --app com.example.app              # Simulator ("iPhone 17"; --sim <name>), launches the app
xcui-http start --app com.example.app --device <name|udid> --team <team id>
xcui-http launch -- --some-flag                    # relaunch with launch arguments (start takes them too)
xcui-http tree                                     # elements on screen, with refs (e1, e2, …)
xcui-http tap e3                                   # a ref, an identifier/label, or "x,y"
xcui-http type $'hello\n'                          # a trailing newline presses return
xcui-http screenshot s.png                         # 1x (points); --scale 3 for full resolution
xcui-http tree --app springboard                   # home screen and system alerts
xcui-http stop
```

`xcui-http help` lists every command.

Several Simulators and devices can run at once. Each `start` makes a session
named after its Simulator or device (`--session` to pick another name); each
Simulator gets its own port. When more than one is running, pass
`--session <name>` (or set `XCUIHTTP_SESSION`); `xcui-http list` shows them and
`xcui-http stop --all` stops them all.

```bash
xcui-http start --app com.example.app --sim "iPhone 17 Pro"
xcui-http start --app com.example.app --sim "iPhone Air"
xcui-http tap Settings --session iphone-air
```

`xcui-http start` regenerates the project, builds the runner (one build at a
time across sessions), runs it in the background (output: `xcui-http log`),
waits for it to serve, then launches the
app (`--no-launch` to leave it as it is). On a device it
generates the token that off-device requests need and finds the device's
CoreDevice tunnel address (works over Wi-Fi), re-discovering it if the tunnel
reconnects. `xcui-http env` prints both for use with curl.

## HTTP API

On port 8766, or the next free one for another Simulator (`--port`). The Simulator listens on loopback only; a device
listens on all interfaces and requires `X-Driver-Token` from off the device.

| Route | Body |
| --- | --- |
| `GET /ping` | replies with the default app's bundle id |
| `GET /tree` | |
| `GET /screenshot` | PNG at 1x, so pixels match the tree's points; `?scale=` up to the device's (e.g. 3) |
| `POST /tap` | ref, identifier/label, or `x,y` |
| `POST /type` | text (`\n` = return) |
| `POST /swipe` | `up\|down\|left\|right [identifier/label]` |
| `POST /drag` | `<from> <to> [hold seconds]` |
| `POST /press` | ref, identifier/label, or `x,y`; `?seconds=` (default 1) |
| `POST /button` | `home` or `lock` |
| `POST /orientation` | `portrait`, `left` or `right` |
| `POST /launch` | space-separated launch arguments |
| `POST /activate`, `/terminate`, `/shutdown` | |

Actions reply with the tree once the UI settles (`?settle=<seconds>`, default
0.5). `?app=<bundle id>` targets another app, and `?idle=0` skips XCUITest's
idle waits (`/press` always does, since an open context menu never goes idle).

The runner reads `XCUIHTTP_BUNDLE_ID`, `XCUIHTTP_PORT` and `XCUIHTTP_TOKEN`
from its environment (`TEST_RUNNER_<name>` when passed to `xcodebuild`).
