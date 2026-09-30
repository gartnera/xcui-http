// swift-tools-version:5.9
// The `xcui-http` CLI (make install). The runner it starts is the XcodeGen
// project in project.yml.
import PackageDescription

let package = Package(
    name: "xcui-http",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "xcui-http", targets: ["xcui-http"])],
    targets: [.executableTarget(name: "xcui-http", path: "cli")]
)
