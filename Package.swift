// swift-tools-version: 6.3
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
    .macOS(.v26)
  ],

  products: [
    .library(name: "HyloLanguageServerCore", targets: ["HyloLanguageServerCore"]),
    .executable(name: "hylo-language-server", targets: ["hylo-language-server"]),
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
    .package(
      url: "https://github.com/ChimeHQ/LanguageServerProtocol.git", 
      revision: "82be567879ade4d904c81bff1006c5de6f78babb"),
    .package(path: "./hylo-new"),
    .package(
      url: "https://github.com/kyouko-taiga/Archivist.git",
      revision: "9d5540fe2b7143c4ee1bb40e0f578a29bbfdf86f"),
    .package(
      url: "https://github.com/tothambrus11/SwiftyFileSystemWatcher",
      revision: "0d715c535b4d2325031fa49922ceb806beb335a6"),
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
        .product(name: "Archivist", package: "archivist"),
        "SwiftyFileSystemWatcher",
      ],
      swiftSettings: commonCompileSettings
    ),

    .executableTarget(
      name: "hylo-language-server",
      dependencies: [
        "HyloLanguageServerCore",
        .product(name: "HyloStandardLibrary", package: "hylo-new"),
      ],
      swiftSettings: toolCompileSettings
    ),

    .testTarget(
      name: "HyloLanguageServerCoreTests",
      dependencies: ["HyloLanguageServerCore", "JSONRPC"],
    ),
  ]
)
