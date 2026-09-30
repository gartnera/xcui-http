import Foundation

let usage = """
    xcui-http: start, drive and stop xcui-http runners.

      xcui-http start --app <bundle id> [--sim <name|udid>] [--device <name|id>] [--team <id>]
                [--session <name>] [--port <n>] [--no-launch] [-- launch args…]
      xcui-http list | status | stop [--all] | env | log
      xcui-http tree
      xcui-http tap <ref|label|x,y>            xcui-http press <ref|label|x,y> [--seconds 1.5]
      xcui-http type <text>                    xcui-http drag <from> <to> [hold seconds]
      xcui-http swipe <up|down|left|right> [identifier/label]
      xcui-http button <home|lock>             xcui-http orientation <portrait|left|right>
      xcui-http launch [-- args…]              xcui-http activate | terminate
      xcui-http screenshot [file.png]          (default: screenshot.png; 1x, --scale 3 for more)
      xcui-http raw <GET|POST> <path> [body]

    Actions take --app <bundle id|springboard>, --no-idle (skip XCUITest's idle
    waits) and --settle <seconds>. A device needs --team (or XCUIHTTP_TEAM) to
    sign the runner.

    Several Simulators and devices can run at once, one session each, named
    after the Simulator or device (or --session). Commands pick one with
    --session (or XCUIHTTP_SESSION), or use the only one running. Each
    session's URL, token and runner pid live in $XCUIHTTP_STATE_DIR (default
    ~/.local/state/xcui-http)/sessions/<name>.json, and its xcodebuild output
    in <name>.log next to it.
    """

/// The checkout this was built from, where project.yml lives.
let root = ProcessInfo.processInfo.environment["XCUIHTTP_ROOT"].map { URL(fileURLWithPath: $0) }
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let stateDir = ProcessInfo.processInfo.environment["XCUIHTTP_STATE_DIR"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/xcui-http")
let sessionsDir = stateDir.appendingPathComponent("sessions")

struct Session: Codable {
    var name: String
    var url: String
    var token: String?
    var pid: Int32
    var app: String
    /// Simulator UDID, or CoreDevice identifier for a device.
    var target: String
    /// CoreDevice identifier; the URL is re-discovered from it if the tunnel moves.
    var device: String?
    var port: Int

    var statePath: URL { sessionsDir.appendingPathComponent("\(name).json") }
    var logPath: URL { sessionsDir.appendingPathComponent("\(name).log") }
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("xcui-http: \(message)\n".utf8))
    exit(1)
}

func note(_ message: String) {
    FileHandle.standardError.write(Data("xcui-http: \(message)\n".utf8))
}

// MARK: - Arguments

let valued: Set<String> = ["app", "sim", "device", "team", "port", "seconds", "settle", "scale", "session"]
let (flags, args) = { () -> ([String: String], [String]) in
    var flags: [String: String] = [:]
    var args: [String] = []
    var argv = CommandLine.arguments.dropFirst()[...]
    while let a = argv.popFirst() {
        if a == "--" {
            args += argv
            break
        }
        guard a.hasPrefix("--") else { args.append(a); continue }
        let parts = a.dropFirst(2).split(separator: "=", maxSplits: 1).map(String.init)
        if valued.contains(parts[0]) {
            guard let value = parts.count > 1 ? parts[1] : argv.popFirst() else { die("--\(parts[0]) needs a value") }
            flags[parts[0]] = value
        } else {
            flags[parts[0]] = ""
        }
    }
    return (flags, args)
}()

// MARK: - Sessions

func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

func allSessions() -> [Session] {
    let files = (try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "json" }
        .compactMap { try? JSONDecoder().decode(Session.self, from: Data(contentsOf: $0)) }
        .sorted { $0.name < $1.name }
}

/// The session named by --session or XCUIHTTP_SESSION, else the only one running.
func load() -> Session {
    let sessions = allSessions()
    if let name = flags["session"] ?? ProcessInfo.processInfo.environment["XCUIHTTP_SESSION"] {
        guard let session = sessions.first(where: { $0.name == name }) else {
            die("no session \"\(name)\"; have: \(sessions.map(\.name).joined(separator: ", ").nonEmpty ?? "none")")
        }
        return session
    }
    let running = sessions.filter { alive($0.pid) }
    switch (running.count, sessions.count) {
    case (1, _): return running[0]
    case (0, 1): return sessions[0]   // exited: `log` and `stop` still want it
    case (0, 0): die("no session; run `xcui-http start --app <bundle id>`")
    default:
        die("several sessions (\((running.isEmpty ? sessions : running).map(\.name).joined(separator: ", "))); pass --session <name>")
    }
}

func save(_ session: Session) {
    try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try! encoder.encode(session).write(to: session.statePath)
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
    /// "iPhone 17 Pro" → "iphone-17-pro".
    var slug: String {
        lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
    }
}

// MARK: - Tools

@discardableResult
func run(_ tool: String, _ arguments: [String]) -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [tool] + arguments
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do { try process.run() } catch { die("\(tool): \(error.localizedDescription)") }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let errors = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        die("\(tool) \(arguments.joined(separator: " ")) failed:\n\(String(decoding: errors, as: UTF8.self))")
    }
    return data
}

func devicectl(_ arguments: [String]) -> [String: Any] {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("xcui-http-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    run("xcrun", ["devicectl"] + arguments + ["--json-output", file.path, "--quiet"])
    guard let data = try? Data(contentsOf: file),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let result = json["result"] as? [String: Any] else { die("unexpected devicectl output") }
    return result
}

struct Device {
    let identifier: String
    let udid: String
    let name: String
}

/// A paired iOS device by name, CoreDevice identifier or UDID.
func findDevice(_ query: String) -> Device {
    let devices = devicectl(["list", "devices"])["devices"] as? [[String: Any]] ?? []
    let ios = devices.compactMap { d -> (Device, Bool)? in
        let hardware = d["hardwareProperties"] as? [String: Any]
        guard hardware?["platform"] as? String == "iOS",
              let identifier = d["identifier"] as? String,
              let udid = hardware?["udid"] as? String else { return nil }
        let name = (d["deviceProperties"] as? [String: Any])?["name"] as? String ?? identifier
        let paired = (d["connectionProperties"] as? [String: Any])?["pairingState"] as? String == "paired"
        return (Device(identifier: identifier, udid: udid, name: name), paired)
    }
    guard let (device, paired) = ios.first(where: { d, _ in
        [d.identifier, d.udid, d.name].contains { $0.caseInsensitiveCompare(query) == .orderedSame }
    }) else {
        die("no iOS device \"\(query)\"; have: \(ios.map(\.0.name).joined(separator: ", ").nonEmpty ?? "none")")
    }
    guard paired else { die("\(device.name) isn't paired") }
    return device
}

/// The device's CoreDevice tunnel address; asking for details brings the tunnel up.
func tunnelURL(_ identifier: String, port: Int) -> String {
    let details = devicectl(["device", "info", "details", "--device", identifier])
    guard let ip = (details["connectionProperties"] as? [String: Any])?["tunnelIPAddress"] as? String else {
        die("no CoreDevice tunnel to the device (is it unlocked and on the network?)")
    }
    return "http://[\(ip)]:\(port)"
}

/// An available iOS Simulator by name or UDID: (udid, name).
func findSimulator(_ query: String) -> (String, String) {
    let json = try? JSONSerialization.jsonObject(
        with: run("xcrun", ["simctl", "list", "devices", "available", "--json"])) as? [String: Any]
    let runtimes = json?["devices"] as? [String: [[String: Any]]] ?? [:]
    let sims = runtimes.filter { $0.key.contains("iOS") }.values.joined().compactMap { d -> (String, String)? in
        guard let udid = d["udid"] as? String, let name = d["name"] as? String else { return nil }
        return (udid, name)
    }
    guard let sim = sims.first(where: { udid, name in
        udid.caseInsensitiveCompare(query) == .orderedSame || name.caseInsensitiveCompare(query) == .orderedSame
    }) else {
        die("no iOS Simulator \"\(query)\"; have: \(Set(sims.map(\.1)).sorted().joined(separator: ", "))")
    }
    return sim
}

/// Whether nothing is listening on the Mac's loopback at this port.
func portFree(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port).bigEndian)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
    }
}

// MARK: - HTTP

func attempt(_ session: Session, _ method: String, _ path: String, _ body: String? = nil,
             timeout: TimeInterval = 600) async throws -> (Int, Data) {
    guard let url = URL(string: session.url + path) else { die("bad URL \(session.url + path)") }
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = method
    request.httpBody = body.map { Data($0.utf8) }
    if let token = session.token { request.setValue(token, forHTTPHeaderField: "X-Driver-Token") }
    let (data, response) = try await URLSession.shared.data(for: request)
    return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
}

func send(_ session: inout Session, _ method: String, _ path: String, _ body: String? = nil) async -> (Int, Data) {
    do {
        return try await attempt(session, method, path, body)
    } catch {
        // The tunnel address changes when the tunnel reconnects. Retry only then:
        // a request to the old address never reached the runner, while any other
        // failure may have, and repeating a tap or typing would act twice.
        if let device = session.device, alive(session.pid) {
            let url = tunnelURL(device, port: session.port)
            if url != session.url {
                session.url = url
                save(session)
                do { return try await attempt(session, method, path, body) } catch {
                    die("can't reach \(session.url): \(error.localizedDescription)")
                }
            }
        }
        die(alive(session.pid)
            ? "can't reach \(session.url): \(error.localizedDescription)"
            : "the runner exited; see \(session.logPath.path)")
    }
}

func query(_ extra: [String: String] = [:]) -> String {
    var items = extra.map { URLQueryItem(name: $0.key, value: $0.value) }
    if let app = flags["app"] { items.append(URLQueryItem(name: "app", value: app)) }
    if flags["no-idle"] != nil { items.append(URLQueryItem(name: "idle", value: "0")) }
    if let settle = flags["settle"] { items.append(URLQueryItem(name: "settle", value: settle)) }
    var components = URLComponents()
    components.queryItems = items
    return items.isEmpty ? "" : "?" + (components.percentEncodedQuery ?? "")
}

func call(_ method: String, _ path: String, _ body: String? = nil) async {
    var session = load()
    let (status, data) = await send(&session, method, path, body)
    FileHandle.standardOutput.write(data)
    if status != 200 { exit(1) }
}

// MARK: - Commands

/// Spawns xcodebuild with output appended to the log. With `detached`, it's in
/// its own session so it outlives us.
func spawn(_ arguments: [String], env: [String: String] = [:], log: URL, detached: Bool) -> Int32 {
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, log.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    posix_spawn_file_actions_adddup2(&actions, 1, 2)
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    if detached { posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID)) }

    let argv = (["/usr/bin/xcodebuild"] + arguments).map { strdup($0) } + [nil]
    let merged = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
    let envp = merged.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { (argv + envp).forEach { free($0) } }
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, "/usr/bin/xcodebuild", &actions, &attr, argv, envp)
    guard rc == 0 else { die("spawning xcodebuild: \(String(cString: strerror(rc)))") }
    return pid
}

/// Regenerates the project if needed and builds the runner for `destination`,
/// one build at a time across sessions (they share the derived data).
func build(_ destination: [String], settings: [String], log: URL) {
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    let lock = open(stateDir.appendingPathComponent("build.lock").path, O_CREAT | O_RDWR, 0o644)
    guard lock >= 0 else { die("can't open the build lock in \(stateDir.path)") }
    defer { close(lock) }   // releases the lock
    if flock(lock, LOCK_EX | LOCK_NB) != 0 {
        note("waiting for another session's build")
        flock(lock, LOCK_EX)
    }

    let spec = root.appendingPathComponent("project.yml")
    guard FileManager.default.fileExists(atPath: spec.path) else {
        die("no project.yml in \(root.path); did the checkout move? Set XCUIHTTP_ROOT")
    }
    func mtime(_ url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
    }
    if mtime(spec) > mtime(project.appendingPathComponent("project.pbxproj")) {
        run("xcodegen", ["generate", "--spec", spec.path, "--project", root.path])
    }

    note("building the runner")
    let pid = spawn(["build-for-testing"] + common + destination + settings, log: log, detached: false)
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    guard status == 0 else { die("building the runner failed; see \(log.path)") }
}

let project = root.appendingPathComponent("XCUIHTTP.xcodeproj")
let common = ["-project", project.path, "-scheme", "XCUIHTTP",
              "-derivedDataPath", root.appendingPathComponent("build").path]

func start(launchArguments: [String]) async {
    guard let app = flags["app"] else { die("start needs --app <bundle id>") }
    let sessions = allSessions()
    let live = sessions.filter { alive($0.pid) }

    var env = ["TEST_RUNNER_XCUIHTTP_BUNDLE_ID": app]
    let destination: [String]
    var settings: [String]
    var session: Session
    if let query = flags["device"] {
        let device = findDevice(query)
        guard let team = flags["team"] ?? ProcessInfo.processInfo.environment["XCUIHTTP_TEAM"] else {
            die("a device needs --team <team id> (or XCUIHTTP_TEAM) to sign the runner")
        }
        let port = flags["port"].flatMap(Int.init) ?? 8766
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        env["TEST_RUNNER_XCUIHTTP_TOKEN"] = token
        destination = ["-destination", "id=\(device.udid)"]
        settings = ["DEVELOPMENT_TEAM=\(team)", "-allowProvisioningUpdates"]
        session = Session(name: flags["session"] ?? device.name.slug, url: "", token: token, pid: 0,
                          app: app, target: device.identifier, device: device.identifier, port: port)
        note("starting on \(device.name) (session \(session.name))")
    } else {
        let (udid, name) = findSimulator(flags["sim"] ?? "iPhone 17")
        // Simulators share the Mac's loopback, so each needs its own port.
        let taken = Set(live.filter { $0.device == nil }.map(\.port))
        guard let port = flags["port"].flatMap(Int.init)
                ?? (8766...8866).first(where: { !taken.contains($0) && portFree($0) }) else {
            die("no free port in 8766-8866")
        }
        destination = ["-destination", "id=\(udid)"]
        settings = ["CODE_SIGN_IDENTITY=-", "CODE_SIGNING_REQUIRED=NO", "AD_HOC_CODE_SIGNING_ALLOWED=YES"]
        session = Session(name: flags["session"] ?? name.slug, url: "http://localhost:\(port)", pid: 0,
                          app: app, target: udid, port: port)
        note("starting on the \(name) Simulator (session \(session.name), port \(port))")
    }
    env["TEST_RUNNER_XCUIHTTP_PORT"] = String(session.port)
    if let existing = live.first(where: { $0.name == session.name || $0.target == session.target }) {
        die("session \(existing.name) is already running there (pid \(existing.pid)); " +
            "`xcui-http stop --session \(existing.name)` first")
    }

    try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    try? Data().write(to: session.logPath)
    build(destination, settings: settings, log: session.logPath)
    if let device = session.device { session.url = tunnelURL(device, port: session.port) }

    let test = ["test-without-building"] + common + destination
    func launchRunner() -> UInt64 {
        let offset = (try? FileManager.default.attributesOfItem(atPath: session.logPath.path)[.size] as? UInt64) ?? 0
        session.pid = spawn(test, env: env, log: session.logPath, detached: true)
        save(session)
        return offset
    }
    var logOffset = launchRunner()

    let deadline = Date(timeIntervalSinceNow: 600)
    var retries = 3
    while Date() < deadline {
        var status: Int32 = 0
        if waitpid(session.pid, &status, WNOHANG) == session.pid {
            // Right after a runner stops, the Simulator refuses to launch the
            // next one for a few seconds ("Busy", failed preflight checks).
            let log = (try? Data(contentsOf: session.logPath)).map { String(decoding: $0.dropFirst(Int(logOffset)), as: UTF8.self) } ?? ""
            if log.contains("Application failed preflight checks"), retries > 0 {
                retries -= 1
                note("the Simulator is busy; retrying")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                logOffset = launchRunner()
                continue
            }
            try? FileManager.default.removeItem(at: session.statePath)
            die("the runner exited before serving; see \(session.logPath.path)")
        }
        if let (status, _) = try? await attempt(session, "GET", "/ping", timeout: 2), status == 200 {
            print("serving \(app) at \(session.url) (session \(session.name), pid \(session.pid))")
            guard flags["no-launch"] == nil else { return }
            // The runner stays up if this fails, so `launch` can be retried.
            let (status, data) = await send(&session, "POST", "/launch", launchArguments.joined(separator: " "))
            guard status == 200 else {
                FileHandle.standardError.write(data)
                die("launching \(app) failed; the runner is still serving")
            }
            print("launched \(app)")
            return
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
    die("timed out waiting for the runner; see \(session.logPath.path)")
}

func stop(_ session: Session) async {
    if alive(session.pid) {
        // Best effort: a runner that's stuck gets SIGTERM below.
        _ = try? await attempt(session, "POST", "/shutdown", timeout: 5)
        for _ in 0..<100 where alive(session.pid) { usleep(100_000) }
        if alive(session.pid) { kill(session.pid, SIGTERM) }
    }
    try? FileManager.default.removeItem(at: session.statePath)
    print("stopped \(session.name)")
}

func describe(_ s: Session) -> String {
    "\(s.name): \(alive(s.pid) ? "running" : "exited") \(s.app) at \(s.url) (pid \(s.pid))"
}

let command = args.first ?? "help"
let rest = Array(args.dropFirst())

switch command {
case "start":
    await start(launchArguments: rest)
case "stop":
    if flags["all"] != nil {
        for session in allSessions() { await stop(session) }
    } else {
        await stop(load())
    }
case "list":
    allSessions().forEach { print(describe($0)) }
case "status":
    let s = load()
    print(describe(s))
    if !alive(s.pid) { exit(1) }
case "env":
    let s = load()
    print("XCUIHTTP=\(s.url)")
    if let token = s.token { print("XCUIHTTP_TOKEN=\(token)") }
case "log":
    let s = load()
    guard let data = try? Data(contentsOf: s.logPath) else { die("no log at \(s.logPath.path)") }
    FileHandle.standardOutput.write(data)
case "tree":
    await call("GET", "/tree" + query())
case "tap", "press", "type", "swipe", "drag", "button", "orientation":
    guard !rest.isEmpty else { die("\(command) needs an argument") }
    let extra = command == "press" ? flags["seconds"].map { ["seconds": $0] } ?? [:] : [:]
    await call("POST", "/\(command)" + query(extra), rest.joined(separator: " "))
case "launch", "activate", "terminate":
    await call("POST", "/\(command)" + query(), rest.joined(separator: " "))
case "screenshot":
    let file = rest.first ?? "screenshot.png"
    var session = load()
    let path = "/screenshot" + (flags["scale"].map { "?scale=\($0)" } ?? "")
    let (status, data) = await send(&session, "GET", path)
    guard status == 200 else { die(String(decoding: data, as: UTF8.self)) }
    do { try data.write(to: URL(fileURLWithPath: file)) } catch { die(error.localizedDescription) }
    print(file)
case "raw":
    guard rest.count >= 2 else { die("raw <METHOD> <path> [body]") }
    await call(rest[0].uppercased(), rest[1], rest.count > 2 ? rest.dropFirst(2).joined(separator: " ") : nil)
case "help", "-h", "--help":
    print(usage)
default:
    print(usage)
    exit(1)
}
