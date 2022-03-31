// swift-tools-version:5.5

import PackageDescription

let package = Package(
    name: "ses-forwarder-lambda",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .executable(name: "SESForwarder", targets: ["SESForwarder"])
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server/swift-aws-lambda-runtime.git", .branch("main")),
        .package(url: "https://github.com/adam-fowler/swift-aws-lambda-events.git", .branch("ses-event-fixes")),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.0.0"),
        .package(url: "https://github.com/soto-project/soto.git", from: "6.0.0-alpha.1")
    ],
    targets: [
        .executableTarget(name: "SESForwarder", dependencies: [
            .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
            .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
            .product(name: "AsyncHTTPClient", package: "async-http-client"),
            .product(name: "SotoS3", package: "soto"),
            .product(name: "SotoSES", package: "soto")
        ])
    ]
)
