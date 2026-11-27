// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "PortSmoke", platforms: [.macOS(.v13)], dependencies: [
    .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")
], targets: [
    .executableTarget(name: "Smoke", dependencies: ["ZIPFoundation"], path: ".", sources: ["App/Core.swift", "Tests/main.swift"], linkerSettings: [.linkedLibrary("z")])
])
