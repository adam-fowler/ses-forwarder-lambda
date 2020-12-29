// swift-tools-version:5.2

import PackageDescription

let package = Package(
    name: "ses-forwarder-lambda",
    platforms: [
        .macOS(.v10_13),
    ],
    products: [
        .executable(name: "SESForwarder", targets: ["SESForwarder"])
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server/swift-aws-lambda-runtime.git", from: "0.3.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.0.0"),
        .package(url: "https://github.com/soto-project/soto.git", from: "5.0.0")
    ],
    targets: [
        .target(name: "SESForwarder", dependencies: [
            .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
            .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-runtime"),
            .product(name: "AsyncHTTPClient", package: "async-http-client"),
            .product(name: "SotoS3", package: "soto"),
            .product(name: "SotoSES", package: "soto")
        ])
    ]
)
