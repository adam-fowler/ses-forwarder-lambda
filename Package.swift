// swift-tools-version:5.10

import PackageDescription

let package = Package(
    name: "ses-forwarder-lambda",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SESForwarder", targets: ["SESForwarder"])
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server/swift-aws-lambda-runtime.git", from: "0.3.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
        .package(url: "https://github.com/soto-project/soto-core.git", from: "7.10.0"),
        .package(url: "https://github.com/soto-project/soto-codegenerator", from: "7.8.2"),
    ],
    targets: [
        .executableTarget(
            name: "SESForwarder",
            dependencies: [
                .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-runtime"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .byName(name: "SotoServices"),
            ]
        ),
        .target(
            name: "SotoServices",
            dependencies: [.product(name: "SotoCore", package: "soto-core")],
            plugins: [.plugin(name: "SotoCodeGeneratorPlugin", package: "soto-codegenerator")]
        ),
    ]
)
