// swift-tools-version:5.9

import PackageDescription

// Product name must equal the plugin id: cordova-ios 8 references it by id.
let package = Package(
    name: "@nathanclaire/rum-cordova",
    platforms: [.iOS(.v14)],
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
                .product(name: "Cordova", package: "cordova-ios")
            ],
            path: "ios/Sources/EdgeRum"
        )
    ]
)
