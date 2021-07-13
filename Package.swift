// swift-tools-version:5.5

import PackageDescription

let package = Package(
    name: "MovieContentAPIService",
    platforms: [
        .macOS("12"),
    ],
    products: [
        .executable(
            name: "MovieContentAPIService",
            targets: ["MovieContentAPIService"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.0.0"),
        .package(url: "https://github.com/tanmayb123/MovieContentService.git", from: "1.0.1"),
    ],
    targets: [
        .executableTarget(
            name: "MovieContentAPIService",
            dependencies: [
                .product(name: "MovieContentService", package: "MovieContentService"),
                .product(name: "Vapor", package: "vapor"),
            ]),
    ]
)
