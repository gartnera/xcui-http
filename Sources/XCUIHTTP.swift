import XCTest
import Network

/// Drives any installed app's UI interactively over HTTP, through XCUITest. It's
/// one test that serves until `POST /shutdown`; `xcui-http start` (cli/main.swift) runs
/// it in the background on a Simulator or device and wraps these routes.
///
///     curl localhost:8766/ping                   # replies with the default app's bundle id
///     curl localhost:8766/tree                  # elements on screen, with refs (e1, e2, …)
///     curl -d e3 localhost:8766/tap              # tap a ref, an identifier/label, or "x,y"
///     curl -d 'Settings' localhost:8766/tap
///     curl -d 'hello' localhost:8766/type        # type into the focused field ("\n" = return)
///     curl -d 'down' localhost:8766/swipe        # swipe the app, or "down <identifier/label>"
///     curl -d 'e3 200,600' localhost:8766/drag   # press and drag from one point/ref to another
///     curl -d e3 'localhost:8766/press?seconds=1.5'   # long-press (default 1 s); skips the idle waits
///     curl -d home localhost:8766/button         # press home (wakes the screen), or "lock"
///     curl -d left localhost:8766/orientation    # rotate: portrait, or left/right (landscape)
///     curl localhost:8766/screenshot > s.png
///     curl -d '--some-flag' localhost:8766/launch   # (re)launch with arguments; also /activate, /terminate
///     curl -X POST localhost:8766/shutdown
///
/// Actions reply with the tree after the UI settles. They target the app in
/// `XCUIHTTP_BUNDLE_ID`; `?app=<bundle id>` targets another installed app (e.g.
/// `com.apple.Preferences`), and `?app=springboard` the home screen and system
/// alerts.
///
/// XCUITest waits for the app to go idle before and after each event, and an
/// open context menu never does, so each wait runs to its one-minute timeout.
/// `/press` skips those waits; `?idle=0` skips them for any other action (e.g.
/// tapping an item in the menu `/press` opened).
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

    private let netQueue = DispatchQueue(label: "xcui-http.net")
    private let lock = NSLock()
    private var jobs: [(request: Request, conn: NWConnection)] = []
    /// Open connections (guarded by `lock`), closed on shutdown.
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var serving = true
    /// Frames from the last tree, by ref.
    private var refs: [String: CGRect] = [:]
    /// XCUITest failures raised by the current request, reported to the client
    /// instead of failing the test.
    private var issues: [String] = []
    private let token = env["XCUIHTTP_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }

    override func record(_ issue: XCTIssue) {
        issues.append(issue.compactDescription)
    }

    /// Read by the idle-wait hook; set per request.
    private static var skipIdleWait = false

    /// Makes XCUITest's idle wait (private, the hook WebDriverAgent uses too)
    /// a no-op while `skipIdleWait` is set.
    private static let idleWaitHook: Void = {
        let selector = NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:isPreEvent:")
        guard let cls = NSClassFromString("XCUIApplicationProcess"),
              let method = class_getInstanceMethod(cls, selector) else {
            return print("[xcui-http] idle-wait hook not found; /press and ?idle=0 will still wait")
        }
        typealias Wait = @convention(c) (AnyObject, Selector, Bool, Bool) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Wait.self)
        let hook: @convention(block) (AnyObject, Bool, Bool) -> Void = { process, animations, preEvent in
            if !skipIdleWait { original(process, selector, animations, preEvent) }
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
            return text(200, "\(Self.bundleID ?? "")\n")
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
        Self.skipIdleWait = request.path == "/press" || request.query["idle"] == "0"
        defer { Self.skipIdleWait = false }
        var acted = true
        switch (request.method, request.path) {
        case ("GET", "/tree"):
            acted = false
        case ("POST", "/tap"):
            guard let point = locate(body, in: target) else { return notFound(body) }
            point.tap()
        case ("POST", "/type"):
            target.typeText(request.body)   // untrimmed: a trailing "\n" presses return
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
        case ("POST", "/drag"):
            let words = body.split(separator: " ").map(String.init)
            guard words.count >= 2, let from = locate(words[0], in: target), let to = locate(words[1], in: target) else {
                return text(400, "usage: <from> <to> [hold seconds]\n")
            }
            from.press(forDuration: words.count > 2 ? Double(words[2]) ?? 0.05 : 0.05, thenDragTo: to)
        case ("POST", "/press"):
            guard let point = locate(body, in: target) else { return notFound(body) }
            point.press(forDuration: request.query["seconds"].flatMap(Double.init) ?? 1)
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
            if scale >= shot.image.scale { return (200, shot.pngRepresentation, "image/png") }
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            let png = UIGraphicsImageRenderer(size: shot.image.size, format: format).pngData { _ in
                shot.image.draw(in: CGRect(origin: .zero, size: shot.image.size))
            }
            return (200, png, "image/png")
        default:
            return text(404, "GET /ping /tree /screenshot; POST /tap /type /swipe /drag /press /button /orientation /launch /activate /terminate /shutdown\n")
        }
        if acted {
            let settle = request.query["settle"].flatMap(Double.init) ?? 0.5
            RunLoop.current.run(until: Date(timeIntervalSinceNow: settle))
        }
        let failures = issues.isEmpty ? "" : issues.map { "! \($0)\n" }.joined()
        return text(issues.isEmpty ? 200 : 500, failures + tree(target))
    }

    /// One line per meaningful element, indented under its meaningful ancestors:
    /// `e4 button "Settings" #id =value @x,y wxh`.
    private func tree(_ app: XCUIApplication) -> String {
        refs = [:]   // stale refs would tap an earlier screen
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

    /// A ref from the last tree, "x,y" in points, or an identifier/label.
    private func locate(_ query: String, in app: XCUIApplication) -> XCUICoordinate? {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        if let frame = refs[query] {
            return origin.withOffset(CGVector(dx: frame.midX, dy: frame.midY))
        }
        let xy = query.split(separator: ",").compactMap { Double($0) }
        if xy.count == 2 {
            return origin.withOffset(CGVector(dx: xy[0], dy: xy[1]))
        }
        let match = element(query, in: app)
        return match.exists ? match.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)) : nil
    }

    /// Exact identifier/label match, else a case-insensitive label substring.
    private func element(_ query: String, in app: XCUIApplication) -> XCUIElement {
        let all = app.descendants(matching: .any)
        let exact = all.matching(NSPredicate(format: "identifier == %@ OR label == %@", query, query)).firstMatch
        return exact.exists ? exact : all.matching(NSPredicate(format: "label CONTAINS[c] %@", query)).firstMatch
    }

    private func notFound(_ query: String) -> (Int, Data, String) {
        text(404, "no element matches \"\(query)\" (refs come from the last /tree)\n")
    }

    private func text(_ status: Int, _ body: String) -> (Int, Data, String) {
        (status, Data(body.utf8), "text/plain; charset=utf-8")
    }

    private static let interactive: Set<XCUIElement.ElementType> = [
        .button, .textField, .secureTextField, .searchField, .textView, .switch, .toggle,
        .slider, .stepper, .link, .cell, .segmentedControl, .picker, .menuItem, .tab,
    ]

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
