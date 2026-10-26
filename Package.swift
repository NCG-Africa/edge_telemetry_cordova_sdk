// swift-tools-version:5.9

import Foundation
import PackageDescription

// Product name must equal the plugin id: cordova-ios 8 references it by id.
let package = Package(
    name: "@nathanclaire/rum-cordova",
    // macOS only so the native core's XCTests run on the host (`xcodebuild test`, see ci.yml); the plugin file is iOS-only.
    platforms: [.iOS(.v14), .macOS(.v11)],
    products: [
        .library(name: "@nathanclaire/rum-cordova", targets: ["EdgeRum"])
    ],
    dependencies: [
        .package(url: "https://github.com/apache/cordova-ios.git", from: "8.0.0")
    ],
    targets: [
        .target(
            name: "EdgeRum",
            dependencies: [
                "EdgeRumCrash",
                .product(name: "Cordova", package: "cordova-ios", condition: .when(platforms: [.iOS]))
            ],
            path: "ios/Sources/EdgeRum"
        ),
        // Spec E12: signal + Mach exception handlers, in C so the crash path stays async-signal-safe.
        .target(name: "EdgeRumCrash", path: "ios/Sources/EdgeRumCrash")
    ]
)

// Spec Q3: ios/Tests is not in the npm tarball, and SwiftPM rejects a target whose path is missing.
if FileManager.default.fileExists(atPath: Context.packageDirectory + "/ios/Tests/EdgeRumTests") {
    package.targets.append(.testTarget(name: "EdgeRumTests", dependencies: ["EdgeRum"], path: "ios/Tests/EdgeRumTests"))
}
