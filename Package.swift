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
        .package(url: "https://github.com/swift-server/swift-aws-lambda-runtime", from: "0.1.0"),
        .package(url: "https://github.com/swift-server/async-http-client", from: "1.0.0"),
        .package(url: "https://github.com/swift-aws/aws-sdk-swift", .upToNextMinor(from: "5.0.0-alpha.4"))
    ],
    targets: [
        .target(name: "SESForwarder", dependencies: [
            .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
            .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-runtime"),
            .product(name: "AsyncHTTPClient", package: "async-http-client"),
            .product(name: "AWSS3", package: "aws-sdk-swift"),
            .product(name: "AWSSES", package: "aws-sdk-swift"),
            .product(name: "AWSSNS", package: "aws-sdk-swift")
        ])
    ]
)
