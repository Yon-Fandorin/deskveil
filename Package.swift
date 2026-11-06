// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SoftLock",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "SoftLock", targets: ["SoftLock"])],
    targets: [
        .executableTarget(name: "SoftLock", path: "Sources", exclude: ["LidService.swift"], resources: [.process("Resources")]),
        .testTarget(name: "SoftLockTests", dependencies: ["SoftLock"], path: "Tests", exclude: ["check_localization.py", "check_guardian.py", "check_cover_guardian.py", "check_lid_service.py", "check_lid_identity.py", "check_release_guard.py", "check_deferred_update.py", "check_app_lifecycle.py"])
    ]
)
