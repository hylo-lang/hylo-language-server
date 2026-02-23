// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

let commonCompileSettings: [SwiftSetting] = [
  // .unsafeFlags(["-warnings-as-errors"])
  // .enableExperimentalFeature("StrictConcurrency")
  // .unsafeFlags(["-strict-concurrency=complete", "-warn-concurrency"])
]

let toolCompileSettings =
  commonCompileSettings + [
    .unsafeFlags(
      ["-parse-as-library"],
      .when(platforms: [.windows]
      ))
  ]

let package = Package(
  name: "hylo-lsp",

  platforms: [
    .macOS(.v15)
  ],

  products: [
    .library(name: "HyloLanguageServerCore", targets: ["HyloLanguageServerCore"]),
    .executable(name: "hylo-language-server", targets: ["HyloLanguageServerDriver"]),
  ],
  dependencies: [
    .package(url: "https://github.com/groue/Semaphore", from: "0.0.8"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.1.4"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    .package(url: "https://github.com/sushichop/Puppy.git", from: "0.7.0"),
    .package(url: "https://github.com/ChimeHQ/JSONRPC.git", from: "0.9.0"),
    .package(
      url: "https://github.com/ChimeHQ/LanguageServer",
      revision: "2bbf9508fdf6f7a17b2c34776b7485af73de338a"),
    .package(path: "./hylo-new"),
  ],
  targets: [

    .target(
      name: "HyloLanguageServerCore",
      dependencies: [
        "Semaphore",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "Logging", package: "swift-log"),
        "Puppy",
        "LanguageServer",
        .product(name: "HyloStandardLibrary", package: "hylo-new"),
        .product(name: "HyloFrontEnd", package: "hylo-new"),
      ],
      path: "Sources/HyloLanguageServerCore",
      swiftSettings: commonCompileSettings
    ),

    .executableTarget(
      name: "HyloLanguageServerDriver",
      dependencies: [
        "HyloLanguageServerCore",
        .product(name: "HyloStandardLibrary", package: "hylo-new"),
      ],
      path: "Sources/HyloLanguageServerDriver",
      swiftSettings: toolCompileSettings
    ),

    .testTarget(
      name: "HyloLanguageServerCoreTests",
      dependencies: ["HyloLanguageServerCore", "JSONRPC"],
    ),

    .testTarget(
      name: "HyloLanguageServerTests",
      dependencies: [
        "HyloLanguageServerCore",
        .product(name: "HyloStandardLibrary", package: "hylo-new"),
        .product(name: "HyloFrontEnd", package: "hylo-new"),
        .product(name: "Logging", package: "swift-log"),
      ],
      resources: [.copy("example.hylo")]
    ),
  ]
)
