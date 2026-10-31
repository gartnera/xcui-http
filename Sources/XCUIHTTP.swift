import XCTest
import Network

/// Drives any installed app's UI interactively over HTTP, through XCUITest. It's
/// one test that serves until `POST /shutdown`; `xcui-http start` (cli/main.swift) runs
/// it in the background on a Simulator or device and wraps these routes.
///
///     curl localhost:8766/ping                   # {"app": default bundle id, "source": build's source hash}
///     curl localhost:8766/tree                  # elements on screen, with refs (e1, e2, …)
///     curl -d e3 localhost:8766/tap              # tap a ref, an identifier/label, or "x,y"
///     curl -d 'Settings' localhost:8766/tap
///     curl -d 'hello' localhost:8766/type        # type into the focused field ("\n" = return)
///     curl -d 'down' localhost:8766/swipe        # swipe the app, or "down <identifier/label>"
///     curl -d 'e3 200,600' localhost:8766/drag   # press and drag from one point/ref to another
///     curl -d e3 'localhost:8766/press?seconds=1.5'   # long-press (default 1 s); ?idle=0 by default
///     curl -d e3 localhost:8766/doubletap
///     curl -d '2 Map' localhost:8766/pinch       # pinch <scale> (>1 zooms in) the app or <identifier/label>
///     curl -d 'Map' localhost:8766/twofingertap  # <identifier/label>, smaller than the screen
///     curl -d $'e3\nhello' localhost:8766/fill    # tap a field, clear it, type (target, newline, text)
///     curl -d 'Done' 'localhost:8766/wait?timeout=10'   # until an identifier/label is on screen; &gone=1 until it isn't
///     curl -d 'down Privacy' localhost:8766/scroll     # scroll down|up|left|right until it's fully on screen
///     curl -d 'Privacy' 'localhost:8766/tap?scroll=down'   # the same first, on /tap /doubletap /press /fill
///     curl -d 'myapp://item/3' localhost:8766/open     # open a URL (deep link) in the app
///     curl -d home localhost:8766/button         # press home (wakes the screen), or "lock"
///     curl -d left localhost:8766/orientation    # rotate: portrait, or left/right (landscape)
///     curl localhost:8766/screenshot > s.png     # ?annotate=1 outlines the last tree's controls with their refs
///     curl -d '--some-flag' localhost:8766/launch   # (re)launch with arguments; also /activate, /terminate
///     curl -X POST localhost:8766/shutdown
///
/// Actions reply with the tree after the UI settles. They target the app in
/// `XCUIHTTP_BUNDLE_ID`; `?app=<bundle id>` targets another installed app (e.g.
/// `com.apple.Preferences`), and `?app=springboard` the home screen and system
/// alerts.
///
/// XCUITest waits for the app to go idle before and after each event, by
/// default for up to a minute, and some apps (an open context menu, a looping
/// animation) never do. Each wait here gives up after `?idle=<seconds>`
/// (default 3); `?idle=0` skips them, as `/press` does by default.
///
/// The Simulator shares the Mac's network, so there it listens on loopback
/// only. On a device it listens on all interfaces, and requests from off the
/// device must send `XCUIHTTP_TOKEN` as `-H "X-Driver-Token: …"`; `xcui-http` finds
/// the device's CoreDevice tunnel address (works over Wi-Fi) and sends it.
///
/// Configured through the runner's environment (`TEST_RUNNER_<name>` when
/// passed to `xcodebuild`): `XCUIHTTP_BUNDLE_ID`, `XCUIHTTP_PORT` (default
/// 8766) and `XCUIHTTP_TOKEN`.
final class XCUIHTTP: XCTestCase {
    private static let env = ProcessInfo.processInfo.environment
    static let port = NWEndpoint.Port(env["XCUIHTTP_PORT"] ?? "") ?? 8766
    static let bundleID = env["XCUIHTTP_BUNDLE_ID"].flatMap { $0.isEmpty ? nil : $0 }
    /// Hash of the sources this was built from (see Runner-Info.plist).
    static let source = Bundle(for: XCUIHTTP.self).object(forInfoDictionaryKey: "XCUIHTTPSource") as? String ?? "unknown"

    private let netQueue = DispatchQueue(label: "xcui-http.net")
    private let lock = NSLock()
    private var jobs: [(request: Request, conn: NWConnection)] = []
    /// Open connections (guarded by `lock`), closed on shutdown.
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var serving = true
    /// Frames from the last tree, by ref.
    private var refs: [String: CGRect] = [:]
    /// The refs in the last tree that are controls, for annotated screenshots.
    private var controlRefs: Set<String> = []
    /// XCUITest failures raised by the current request, reported to the client
    /// instead of failing the test.
    private var issues: [String] = []
    private let token = env["XCUIHTTP_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }

    override func record(_ issue: XCTIssue) {
        issues.append(issue.compactDescription)
    }

    static let defaultIdleTimeout: TimeInterval = 3
    /// Most seconds each idle wait may take (0 skips it); read by the
    /// idle-wait hook, set per request.
    private static var idleTimeout = defaultIdleTimeout

    /// Caps XCUITest's idle wait at `idleTimeout`, through private API that
    /// WebDriverAgent uses too: the wait itself, and the timeout it uses (also
    /// used for app-state waits like launch's, so it's only changed around it).
    private static let idleWaitHook: Void = {
        let selector = NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:isPreEvent:")
        guard let cls = NSClassFromString("XCUIApplicationProcess"),
              let method = class_getInstanceMethod(cls, selector) else {
            return print("[xcui-http] idle-wait hook not found; idle waits take up to XCUITest's timeout")
        }
        typealias Wait = @convention(c) (AnyObject, Selector, Bool, Bool) -> Void
        typealias GetTimeout = @convention(c) () -> Double
        typealias SetTimeout = @convention(c) (Double) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Wait.self)
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        let getTimeout = dlsym(rtldDefault, "_XCTApplicationStateTimeout").map { unsafeBitCast($0, to: GetTimeout.self) }
        let setTimeout = dlsym(rtldDefault, "_XCTSetApplicationStateTimeout").map { unsafeBitCast($0, to: SetTimeout.self) }
        if getTimeout == nil || setTimeout == nil {
            print("[xcui-http] _XCTSetApplicationStateTimeout not found; idle waits take up to XCUITest's timeout")
        }
        let hook: @convention(block) (AnyObject, Bool, Bool) -> Void = { process, animations, preEvent in
            guard idleTimeout > 0 else { return }
            guard let getTimeout, let setTimeout else { return original(process, selector, animations, preEvent) }
            let previous = getTimeout()
            setTimeout(idleTimeout)
            defer { setTimeout(previous) }
            original(process, selector, animations, preEvent)
        }
        method_setImplementation(method, imp_implementationWithBlock(hook))
    }()

    func testServe() throws {
        continueAfterFailure = true
        Self.idleWaitHook
        let listener: NWListener
        #if targetEnvironment(simulator)
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: Self.port)
        listener = try NWListener(using: params)
        #else
        listener = try NWListener(using: .tcp, on: Self.port)
        if token == nil { print("[xcui-http] no XCUIHTTP_TOKEN: only on-device clients accepted") }
        #endif
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            let id = ObjectIdentifier(conn)
            self.lock.lock()
            self.connections[id] = conn
            self.lock.unlock()
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .cancelled, .failed:
                    self?.lock.lock()
                    self?.connections[id] = nil
                    self?.lock.unlock()
                default: break
                }
            }
            conn.start(queue: self.netQueue)
            self.receive(conn, Data())
        }
        listener.start(queue: netQueue)
        print("[xcui-http] serving on port \(Self.port.rawValue), app \(Self.bundleID ?? "(none: pass ?app=)")")

        // XCUITest calls must run on the main thread, one at a time, so requests
        // queue here rather than on the main queue (where they could interleave
        // while XCUITest spins the run loop).
        while serving {
            lock.lock()
            let job = jobs.isEmpty ? nil : jobs.removeFirst()
            lock.unlock()
            if let job {
                Self.respond(job.conn, handle(job.request))
            } else {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            }
        }

        // Shut down: drop queued requests, let replies in flight (e.g. /shutdown's)
        // finish sending, then close whatever is left.
        listener.cancel()
        lock.lock()
        let queued = jobs.map(\.conn)
        jobs.removeAll()
        lock.unlock()
        queued.forEach { $0.cancel() }
        let deadline = Date(timeIntervalSinceNow: 0.5)
        while Date() < deadline {
            lock.lock()
            let allClosed = connections.isEmpty
            lock.unlock()
            if allClosed { break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        lock.lock()
        let remaining = Array(connections.values)
        lock.unlock()
        remaining.forEach { $0.cancel() }
    }

    // MARK: - Routes

    private func handle(_ request: Request) -> (Int, Data, String) {
        switch (request.method, request.path) {
        case ("GET", "/ping"):
            let info = ["app": Self.bundleID ?? "", "source": Self.source]
            return (200, try! JSONSerialization.data(withJSONObject: info, options: .sortedKeys) + Data("\n".utf8),
                    "application/json")
        case ("POST", "/shutdown"):
            serving = false
            return text(200, "bye\n")
        default: break
        }
        guard let bundleID = request.query["app"].map({ $0 == "springboard" ? "com.apple.springboard" : $0 })
                ?? Self.bundleID else {
            return text(400, "no app: set XCUIHTTP_BUNDLE_ID or pass ?app=<bundle id>\n")
        }
        let target = XCUIApplication(bundleIdentifier: bundleID)
        let body = request.body.trimmingCharacters(in: .whitespacesAndNewlines)
        issues = []
        Self.idleTimeout = request.query["idle"].flatMap(Double.init)
            ?? (request.path == "/press" ? 0 : Self.defaultIdleTimeout)
        defer { Self.idleTimeout = Self.defaultIdleTimeout }
        var acted = true
        /// With `?scroll=<direction>`, scrolls an identifier/label until it's fully on screen first.
        func reveal(_ query: String, prefer: Set<XCUIElement.ElementType> = Self.interactive) throws {
            guard let direction = request.query["scroll"], refs[query] == nil, point(query) == nil else { return }
            guard Self.directions.contains(direction) else {
                throw Failure(status: 400, message: "scroll: down, up, left or right\n")
            }
            try scroll(direction, to: query, in: target, swipes: request.query["max"].flatMap(Int.init) ?? 10,
                       prefer: prefer)
        }
        do {
            switch (request.method, request.path) {
            case ("GET", "/tree"):
                acted = false
            case ("POST", "/tap"):
                try reveal(body)
                try locate(body, in: target).tap()
            case ("POST", "/doubletap"):
                try reveal(body)
                try locate(body, in: target).doubleTap()
            case ("POST", "/type"):
                target.typeText(request.body)   // untrimmed: a trailing "\n" presses return
            case ("POST", "/fill"):
                // "<target>\n<text>": the text untrimmed, so a trailing "\n" presses return.
                let parts = request.body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                let query = parts[0].trimmingCharacters(in: .whitespaces)
                guard !query.isEmpty else { return text(400, "usage: <target>\\n<text>\n") }
                try reveal(query, prefer: Self.textInputs)
                try fill(query, with: parts.count > 1 ? String(parts[1]) : "", in: target)
            case ("POST", "/swipe"):
                var words = body.split(separator: " ").map(String.init)
                guard let direction = words.first else { return text(400, "direction required\n") }
                words.removeFirst()
                let element = words.isEmpty ? target : element(words.joined(separator: " "), in: target)
                switch direction {
                case "up": element.swipeUp()
                case "down": element.swipeDown()
                case "left": element.swipeLeft()
                case "right": element.swipeRight()
                default: return text(400, "direction: up, down, left or right\n")
                }
            case ("POST", "/pinch"):
                var words = body.split(separator: " ").map(String.init)
                guard let scale = words.first.flatMap(Double.init), scale > 0 else {
                    return text(400, "usage: <scale> [identifier/label] (>1 zooms in, <1 out)\n")
                }
                words.removeFirst()
                let element = words.isEmpty ? target : element(words.joined(separator: " "), in: target)
                // The velocity's sign has to match the direction.
                element.pinch(withScale: scale, velocity: scale >= 1 ? 1 : -1)
            case ("POST", "/twofingertap"):
                // XCUITest can't place it on a screen-sized element (the app, its window, a full-screen web view).
                guard !body.isEmpty else { return text(400, "usage: <identifier/label> (not the whole screen)\n") }
                element(body, in: target).twoFingerTap()
            case ("POST", "/drag"):
                let words = body.split(separator: " ").map(String.init)
                guard words.count >= 2 else { return text(400, "usage: <from> <to> [hold seconds]\n") }
                let from = try locate(words[0], in: target), to = try locate(words[1], in: target)
                from.press(forDuration: words.count > 2 ? Double(words[2]) ?? 0.05 : 0.05, thenDragTo: to)
            case ("POST", "/press"):
                try reveal(body)
                try locate(body, in: target).press(forDuration: request.query["seconds"].flatMap(Double.init) ?? 1)
            case ("POST", "/wait"):
                guard !body.isEmpty else { return text(400, "usage: <identifier/label>\n") }
                let gone = request.query["gone"].map { $0 != "0" } ?? false
                let deadline = Date(timeIntervalSinceNow: request.query["timeout"].flatMap(Double.init) ?? 10)
                while true {
                    // A failed snapshot (the app briefly in the background) proves nothing either way.
                    let found = find(body, in: target)
                    if found.ok, (found.match != nil) != gone { break }
                    guard Date() < deadline else {
                        return text(408, "timed out waiting for \"\(body)\" to \(gone ? "go away" : "appear")\n" + tree(target))
                    }
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
                }
                acted = false
            case ("POST", "/scroll"):
                var words = body.split(separator: " ").map(String.init)
                guard words.count >= 2, Self.directions.contains(words[0]) else {
                    return text(400, "usage: <down|up|left|right> <identifier/label>\n")
                }
                let direction = words.removeFirst()
                try scroll(direction, to: words.joined(separator: " "), in: target,
                           swipes: request.query["max"].flatMap(Int.init) ?? 10)
            case ("POST", "/open"):
                guard let url = URL(string: body), url.scheme != nil else { return text(400, "usage: <url>\n") }
                guard #available(iOS 16.4, *) else { return text(501, "opening URLs needs iOS 16.4\n") }
                target.open(url)
            case ("POST", "/button"):
                switch body {
                case "home": XCUIDevice.shared.press(.home)   // also wakes the screen
                case "lock":
                    // Private, as WebDriverAgent uses it; toggles the screen like the side button.
                    let press = NSSelectorFromString("pressLockButton")
                    guard XCUIDevice.shared.responds(to: press) else { return text(501, "pressLockButton unavailable\n") }
                    XCUIDevice.shared.perform(press)
                default: return text(400, "button: home or lock\n")
                }
            case ("POST", "/orientation"):
                // No upside-down: most iPhone apps don't support it, so it'd be a silent no-op.
                let orientations: [String: UIDeviceOrientation] = [
                    "portrait": .portrait, "left": .landscapeLeft, "right": .landscapeRight,
                ]
                guard let orientation = orientations[body] else {
                    return text(400, "orientation: portrait, left or right\n")
                }
                XCUIDevice.shared.orientation = orientation
            case ("POST", "/launch"):
                target.launchArguments = body.split(separator: " ").map(String.init)
                target.launch()
            case ("POST", "/activate"):
                target.activate()
            case ("POST", "/terminate"):
                target.terminate()
                return text(200, "terminated\n")
            case ("GET", "/screenshot"):
                // 1x by default, so pixels match the tree's points; ?scale= up to native.
                let shot = XCUIScreen.main.screenshot()
                let scale = request.query["scale"].flatMap(Double.init) ?? 1
                guard scale > 0 else { return text(400, "scale must be positive\n") }
                let annotate = request.query["annotate"].map { $0 != "0" } ?? false
                if annotate, refs.isEmpty { _ = tree(target) }
                if scale >= shot.image.scale, !annotate { return (200, shot.pngRepresentation, "image/png") }
                let format = UIGraphicsImageRendererFormat()
                format.scale = min(scale, shot.image.scale)
                let png = UIGraphicsImageRenderer(size: shot.image.size, format: format).pngData { _ in
                    shot.image.draw(in: CGRect(origin: .zero, size: shot.image.size))
                    if annotate { drawRefs() }
                }
                return (200, png, "image/png")
            default:
                return text(404, "GET /ping /tree /screenshot; POST /tap /doubletap /type /fill /swipe /pinch /twofingertap /drag /press /wait /scroll /open /button /orientation /launch /activate /terminate /shutdown\n")
            }
        } catch let failure as Failure {
            return text(failure.status, failure.message + (failure.withTree ? tree(target) : ""))
        } catch {
            return text(500, "\(error)\n")
        }
        var listing = tree(target)
        if acted {
            // Settled once two trees a poll apart match, up to `settle` seconds: a
            // sheet's out-of-process content (a file or photo picker) arrives after
            // the tap's idle wait.
            let deadline = Date(timeIntervalSinceNow: request.query["settle"].flatMap(Double.init) ?? 3)
            while Date() < deadline {
                RunLoop.current.run(until: min(deadline, Date(timeIntervalSinceNow: 0.3)))
                let next = tree(target)
                if next == listing { break }
                listing = next
            }
        }
        let failures = issues.isEmpty ? "" : issues.map { "! \($0)\n" }.joined()
        return text(issues.isEmpty ? 200 : 500, failures + listing)
    }

    /// One line per meaningful element, indented under its meaningful ancestors:
    /// `e4 button "Settings" #id =value @x,y wxh`.
    private func tree(_ app: XCUIApplication) -> String {
        refs = [:]   // stale refs would tap an earlier screen
        controlRefs = []
        guard app.state == .runningForeground else {
            return "app not in the foreground (state \(app.state.rawValue)); POST /launch or /activate\n"
        }
        let snapshot: XCUIElementSnapshot
        do { snapshot = try app.snapshot() } catch { return "snapshot failed: \(error.localizedDescription)\n" }
        let screen = snapshot.frame
        var lines: [String] = []
        func visit(_ node: XCUIElementSnapshot, depth: Int) {
            let value = (node.value as? String) ?? (node.value as? NSNumber)?.stringValue ?? ""
            let meaningful = !node.label.isEmpty || !node.identifier.isEmpty || !value.isEmpty
                || Self.interactive.contains(node.elementType)
            // The on-screen part, so refs tap what's visible; also makes the lock
            // screen's infinite frames finite.
            let f = node.frame.intersection(screen)
            var childDepth = depth
            if meaningful, f.width > 0, f.height > 0, !f.isInfinite {
                let ref = "e\(refs.count + 1)"
                refs[ref] = f
                if Self.interactive.contains(node.elementType) { controlRefs.insert(ref) }
                var line = String(repeating: "  ", count: depth) + "\(ref) \(Self.name(node.elementType))"
                if !node.label.isEmpty { line += " \"\(node.label)\"" }
                if !node.identifier.isEmpty, node.identifier != node.label { line += " #\(node.identifier)" }
                if !value.isEmpty, value != node.label { line += " =\(value)" }
                line += " @\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))"
                if !node.isEnabled { line += " disabled" }
                if node.isSelected { line += " selected" }
                lines.append(line)
                childDepth += 1
            }
            node.children.forEach { visit($0, depth: childDepth) }
        }
        visit(snapshot, depth: 0)
        return lines.joined(separator: "\n") + "\n"
    }

    /// A request that can't be carried out: replied with `status`, and the tree
    /// when it helps to see what's there instead.
    private struct Failure: Error {
        var status = 404
        let message: String
        var withTree = false
    }

    /// "x,y" in points, unless it's a ref.
    private func point(_ query: String) -> CGPoint? {
        let xy = query.split(separator: ",").compactMap { Double($0) }
        return refs[query] == nil && xy.count == 2 ? CGPoint(x: xy[0], y: xy[1]) : nil
    }

    /// The middle of a ref from the last tree, "x,y" in points, or an
    /// identifier/label on screen (`prefer`ring those kinds of element).
    private func locate(_ query: String, in app: XCUIApplication,
                        prefer: Set<XCUIElement.ElementType> = interactive) throws -> XCUICoordinate {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        if let p = point(query) {
            return origin.withOffset(CGVector(dx: p.x, dy: p.y))
        }
        let frame: CGRect
        if let ref = refs[query] {
            frame = ref
        } else {
            let found = find(query, in: app, prefer: prefer)
            guard let match = found.match else {
                throw Failure(message: found.offscreen
                    ? "\"\(query)\" is off screen; --scroll to it first\n"
                    : "no element on screen matches \"\(query)\" (refs come from the last tree; --scroll to look further along)\n")
            }
            frame = match.visible
        }
        return origin.withOffset(CGVector(dx: frame.midX, dy: frame.midY))
    }

    private struct Found {
        /// The best match's whole frame, and the part of it on screen.
        var match: (frame: CGRect, visible: CGRect)?
        /// There are matches, but none on screen.
        var offscreen = false
        /// The screen above the keyboard, if it's up; zero if there was no snapshot.
        var screen = CGRect.zero
        /// Changes when anything moves, to tell when scrolling reaches the end.
        var layout = 0
        var ok: Bool { screen != .zero }
    }

    /// The best match on screen for an identifier/label (or a field's
    /// placeholder), in the order `element` uses, from one snapshot (so it sees
    /// what the tree does). Only the keyboard's own keys count as on screen
    /// under the keyboard.
    private func find(_ query: String, in app: XCUIApplication,
                      prefer: Set<XCUIElement.ElementType> = interactive) -> Found {
        guard app.state == .runningForeground, let snapshot = try? app.snapshot() else { return Found() }
        let full = snapshot.frame
        var keyboard: CGRect?
        var layout = Hasher()
        // Preferred kinds (controls) matching exactly, others matching exactly,
        // preferred kinds whose label contains it, then others whose label does.
        var candidates: [(bucket: Int, frame: CGRect, inKeyboard: Bool)] = []
        func visit(_ node: XCUIElementSnapshot, inKeyboard: Bool) {
            let inKeyboard = inKeyboard || node.elementType == .keyboard
            if node.elementType == .keyboard { keyboard = node.frame }
            layout.combine(node.frame.minX); layout.combine(node.frame.minY); layout.combine(node.label)
            let placeholder = node.placeholderValue ?? ""
            let exact = node.identifier == query || node.label == query || placeholder == query
            if exact || node.label.range(of: query, options: .caseInsensitive) != nil
                || placeholder.range(of: query, options: .caseInsensitive) != nil {
                candidates.append(((exact ? 0 : 2) + (prefer.contains(node.elementType) ? 0 : 1), node.frame, inKeyboard))
            }
            node.children.forEach { visit($0, inKeyboard: inKeyboard) }
        }
        snapshot.children.forEach { visit($0, inKeyboard: false) }   // not the app itself, labeled with its name
        var screen = full
        if let keyboard, keyboard.minY > full.minY, keyboard.minY < full.maxY {
            screen.size.height = keyboard.minY - full.minY
        }
        var found = Found(screen: screen, layout: layout.finalize())
        for bucket in 0..<4 {
            for candidate in candidates where candidate.bucket == bucket {   // in tree order
                let visible = candidate.frame.intersection(candidate.inKeyboard ? full : screen)
                if visible.isNull || visible.isEmpty || visible.isInfinite {
                    found.offscreen = true
                } else {
                    found.match = (candidate.frame, visible)
                    return found
                }
            }
        }
        return found
    }

    /// Taps a field, clears it and types `text`.
    private func fill(_ query: String, with text: String, in app: XCUIApplication) throws {
        // A field before a button labeled the same. The middle, since a search
        // field's trailing edge has its dictation and clear buttons.
        try locate(query, in: app, prefer: Self.textInputs).tap()
        let field = app.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
        guard field.waitForExistence(timeout: 2) else {
            throw Failure(status: 409, message: "nothing has keyboard focus after tapping \"\(query)\"\n", withTree: true)
        }
        func current() -> String {
            let value = field.value as? String ?? ""
            return value == field.placeholderValue ? "" : value
        }
        if !current().isEmpty {
            // Select all, then delete; one delete per character after, in case
            // select-all didn't take (it needs a hardware keyboard, so its
            // failure isn't the request's).
            let before = issues.count
            field.typeKey("a", modifierFlags: .command)
            issues.removeSubrange(before...)
            field.typeText(XCUIKeyboardKey.delete.rawValue)
            for _ in 0..<3 {
                let value = current()
                if value.isEmpty { break }
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
            }
            guard current().isEmpty else {
                throw Failure(status: 500, message: "couldn't clear \"\(query)\"\n", withTree: true)
            }
        }
        if !text.isEmpty { field.typeText(text) }
    }

    /// Drags the screen in steps, without flinging, until an identifier/label is
    /// fully on screen (or fills half of it); "down" reveals what's below.
    private func scroll(_ direction: String, to query: String, in app: XCUIApplication, swipes: Int,
                        prefer: Set<XCUIElement.ElementType> = interactive) throws {
        var last: Int?
        for swipe in 0...swipes {
            let found = find(query, in: app, prefer: prefer)
            guard found.ok else {
                throw Failure(status: 409, message: "can't read the app's UI (is it in the foreground?)\n")
            }
            if let match = found.match, match.visible == match.frame
                || (match.visible.height >= found.screen.height / 2 && match.visible.width >= found.screen.width / 2) {
                return
            }
            guard found.layout != last else {
                throw Failure(message: "reached the end without \"\(query)\" fully on screen\n", withTree: true)
            }
            guard swipe < swipes else {
                throw Failure(message: "no \"\(query)\" fully on screen after \(swipes) swipes (?max= for more)\n",
                              withTree: true)
            }
            last = found.layout
            let (from, to): (CGPoint, CGPoint) = switch direction {
            case "down": (CGPoint(x: 0.5, y: 0.7), CGPoint(x: 0.5, y: 0.3))
            case "up": (CGPoint(x: 0.5, y: 0.3), CGPoint(x: 0.5, y: 0.7))
            case "right": (CGPoint(x: 0.8, y: 0.5), CGPoint(x: 0.2, y: 0.5))
            default: (CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.8, y: 0.5))
            }
            let s = found.screen   // above the keyboard, so the drag doesn't type
            let origin = app.coordinate(withNormalizedOffset: .zero)
            func at(_ p: CGPoint) -> XCUICoordinate {
                origin.withOffset(CGVector(dx: s.minX + s.width * p.x, dy: s.minY + s.height * p.y))
            }
            // Holding at the end stops the content where the finger left it.
            at(from).press(forDuration: 0.05, thenDragTo: at(to), withVelocity: .default, thenHoldForDuration: 0.1)
        }
    }

    /// Outlines the last tree's controls on a screenshot, labeled with their refs.
    private func drawRefs() {
        let color = UIColor.systemPink
        let font = UIFont.boldSystemFont(ofSize: 10)
        // A cell and the button filling it share a frame: label only the inner
        // one (refs number depth-first, so the higher).
        var byFrame: [String: String] = [:]
        for ref in controlRefs {
            let key = NSCoder.string(for: refs[ref]!)
            if let other = byFrame[key], Int(other.dropFirst())! > Int(ref.dropFirst())! { continue }
            byFrame[key] = ref
        }
        for ref in byFrame.values {
            let frame = refs[ref]!
            color.setStroke()
            let outline = UIBezierPath(rect: frame.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()
            let label = NSAttributedString(string: ref, attributes: [.font: font, .foregroundColor: UIColor.white])
            let size = label.size()
            let tag = CGRect(x: frame.minX, y: frame.minY, width: ceil(size.width) + 4, height: ceil(size.height))
            color.setFill()
            UIRectFill(tag)
            label.draw(at: CGPoint(x: tag.minX + 2, y: tag.minY))
        }
    }

    /// Exact identifier/label match, else a case-insensitive label substring;
    /// controls first, so "Convert" finds the button, not a title reading the same.
    private func element(_ query: String, in app: XCUIApplication) -> XCUIElement {
        let all = app.descendants(matching: .any)
        let controls = all.matching(NSPredicate(format: "elementType IN %@", Self.interactive.map(\.rawValue)))
        let exact = NSPredicate(format: "identifier == %@ OR label == %@", query, query)
        let partial = NSPredicate(format: "label CONTAINS[c] %@", query)
        let candidates = [controls.matching(exact), all.matching(exact), controls.matching(partial), all.matching(partial)]
        return candidates.map(\.firstMatch).first(where: \.exists) ?? all.matching(partial).firstMatch
    }

    private func text(_ status: Int, _ body: String) -> (Int, Data, String) {
        (status, Data(body.utf8), "text/plain; charset=utf-8")
    }

    private static let interactive: Set<XCUIElement.ElementType> = [
        .button, .textField, .secureTextField, .searchField, .textView, .switch, .toggle,
        .slider, .stepper, .link, .cell, .segmentedControl, .picker, .menuItem, .tab,
    ]

    private static let directions: Set<String> = ["down", "up", "left", "right"]

    private static let textInputs: Set<XCUIElement.ElementType> = [.textField, .secureTextField, .searchField, .textView]

    private static func name(_ type: XCUIElement.ElementType) -> String {
        let names: [XCUIElement.ElementType: String] = [
            .any: "any", .other: "other", .application: "app", .window: "window", .alert: "alert",
            .button: "button", .navigationBar: "navbar", .tabBar: "tabbar", .toolbar: "toolbar",
            .staticText: "text", .textField: "textfield", .secureTextField: "securefield",
            .searchField: "searchfield", .textView: "textview", .switch: "switch", .toggle: "toggle",
            .slider: "slider", .stepper: "stepper", .link: "link", .image: "image", .icon: "icon",
            .cell: "cell", .table: "table", .collectionView: "collection", .scrollView: "scroll",
            .segmentedControl: "segmented", .picker: "picker", .menu: "menu", .menuItem: "menuitem",
            .webView: "webview", .sheet: "sheet", .keyboard: "keyboard", .key: "key", .tab: "tab",
        ]
        return names[type] ?? "type\(type.rawValue)"
    }

    // MARK: - HTTP

    private struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]   // lowercased names
        let body: String
    }

    private func receive(_ conn: NWConnection, _ buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch Self.parse(buffer) {
            case .request(let request):
                guard self.authorized(request, conn) else {
                    return Self.respond(conn, (403, Data("forbidden\n".utf8), "text/plain"))
                }
                self.lock.lock()
                self.jobs.append((request, conn))
                self.lock.unlock()
            case .malformed:
                Self.respond(conn, (400, Data("bad request\n".utf8), "text/plain"))
            case .incomplete where done || error != nil:
                conn.cancel()
            case .incomplete:
                self.receive(conn, buffer)
            }
        }
    }

    /// Browsers send Origin (and a foreign Host under DNS rebinding); curl sends
    /// neither. Clients off the device also need the token.
    private func authorized(_ request: Request, _ conn: NWConnection) -> Bool {
        guard request.headers["origin"] == nil else { return false }
        if case .hostPort(let host, _) = conn.endpoint, Self.isLoopback(host) {
            let name = request.headers["host"]?.split(separator: ":").first.map(String.init)
            return name == "localhost" || name == "127.0.0.1"
        }
        return token != nil && request.headers["x-driver-token"] == token
    }

    private static func isLoopback(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback || address.asIPv4?.isLoopback == true
        default: return false
        }
    }

    private enum Parsed {
        case request(Request)
        case incomplete
        case malformed
    }

    private static func parse(_ data: Data) -> Parsed {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return .malformed }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return .malformed }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2 { headers[kv[0].lowercased()] = kv[1].trimmingCharacters(in: .whitespaces) }
        }
        var length = 0
        if let header = headers["content-length"] {
            guard let n = Int(header), n >= 0 else { return .malformed }
            length = n
        }
        let body = data[headerEnd.upperBound...]
        guard body.count >= length else { return .incomplete }
        let url = URLComponents(string: String(parts[1]))
        let query = Dictionary((url?.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { _, last in last }
        return .request(Request(method: String(parts[0]), path: url?.path ?? String(parts[1]), query: query,
                                headers: headers, body: String(decoding: body.prefix(length), as: UTF8.self)))
    }

    private static func respond(_ conn: NWConnection, _ response: (Int, Data, String)) {
        let (status, payload, type) = response
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: \(type)\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in conn.cancel() })
    }
}
