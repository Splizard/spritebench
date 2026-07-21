// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "SpriteBenchSwift",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "SpriteBenchSwift",
            type: .dynamic,
            targets: ["SpriteBenchSwift"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftGodot", branch: "main"),
    ],
    targets: [
        .target(
            name: "SpriteBenchSwift",
            dependencies: [
                .product(name: "SwiftGodot", package: "swiftgodot"),
            ],
            plugins: [
                .plugin(name: "EntryPointGeneratorPlugin", package: "swiftgodot")
            ]
        ),
    ]
)
