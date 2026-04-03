// swift-tools-version: 6.3
// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Sebastian Ritter

import PackageDescription

let package = Package(
  name: "be42",
  defaultLocalization: "en",
  platforms: [.macOS(.v26)],
  products: [
    // Products define the executables and libraries a package produces, making them visible to other packages.
    .library(
      name: "be42",
      targets: ["be42"]
    ),
    .executable(name: "ben", targets: ["ben"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.1"),
  ],
  targets: [
    .target(
      name: "be42"
    ),
    .executableTarget(
      name: "ben",
      dependencies: [
        "be42",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        
      ]
    ),
    .testTarget(
      name: "be42Tests",
      dependencies: ["be42"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
