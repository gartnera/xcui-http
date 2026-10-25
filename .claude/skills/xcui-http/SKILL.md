---
name: xcui-http
description: Drive, inspect and screenshot any installed iOS app's UI on a Simulator or device with the xcui-http CLI (XCUITest over HTTP) - read the element tree, tap, type, swipe, drag, long-press, rotate, press home/lock, handle system alerts. Use to check an iOS change in the running app, reproduce a UI bug, or walk through a flow.
---

# xcui-http

`xcui-http` runs a background XCUITest runner against an installed app and
drives it from the shell. The app must already be installed (build and
`xcrun simctl install` it first).

```bash
xcui-http start --app com.example.app    # Simulator "iPhone 17" (--sim <name|udid>); builds the runner if needed, launches the app
xcui-http tree                           # elements on screen, with refs
xcui-http tap e3                         # a ref, an identifier/label, or "x,y" in points
xcui-http type $'hello\n'                # into the focused field; a trailing newline presses return
xcui-http screenshot /tmp/s.png          # then Read it to look at it
xcui-http stop
```

`xcui-http help` lists every command and flag.

## Reading the tree

```
e4 button "Sign In" #signInButton @16,700 361x50
e5 textfield "Email" =me@example.com @16,300 361x44 disabled
```

ref, type, `"label"`, `#identifier`, `=value`, `@x,y wxh` frame in points,
then `disabled` / `selected`. Indentation is nesting.

- Refs are renumbered on every tree, and every action returns a new tree.
  Only use refs from the most recent output.
- Actions (`tap`, `type`, `swipe`, …) print the tree after the UI settles, so
  there's no need to call `tree` again after one.
- Prefer a label or identifier (`xcui-http tap "Sign In"`) when it's unique;
  it matches controls before static text.
- Screenshots are 1x, so their pixels are the tree's points; `--scale 3` for
  full resolution.

## Gotchas

- System alerts (permissions, etc.) and the home screen belong to SpringBoard:
  `xcui-http tree --app springboard`, `xcui-http tap Allow --app springboard`.
- Relaunch with launch arguments: `xcui-http launch -- -SomeFlag YES`.
- A sheet that loads slowly may not be in the returned tree yet; raise
  `--settle <seconds>` (default 3) or call `tree` again.
- `press` long-presses (`--seconds`), e.g. for context menus.
- Several sessions can run at once (one per Simulator/device). With more than
  one, pass `--session <name>`; `xcui-http list` shows them.
- On a device: `--device <name|udid>` (and `--team <id>` if the keychain has
  more than one development team).
- If something fails, `xcui-http log` shows the runner's xcodebuild output.
- `start` on a running session reuses it, or rebuilds it if the xcui-http
  checkout changed.
