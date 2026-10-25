import ArgumentParser
import Foundation
import FrontEnd
import HyloLanguageServerCore
import JSONRPC
import Logging
import StandardLibrary

@main
struct HyloLspCommand: AsyncParsableCommand {

  static let configuration = CommandConfiguration(commandName: "hylo-language-server")

  @Option(help: "Log level")
  var logLevel: Logger.Level = Logger.Level.debug

  // https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#implementationConsiderations
  // These are VS Code compatible transport flags:

  @Flag(help: "Stdio transport")
  var stdio: Bool = true  // Obsolete, kept for compatibility

  @Option(help: "Path to the Hylo standard library")
  var stdlibPath: String = bundledStandardLibrarySources.path

  func run() async throws {
    let logger = Logger(label: "s", factory: SwiftLogNoOpLogHandler.init)

    var sources: [SourceFile] = []
    try SourceFile.forEach(in: URL(fileURLWithPath: stdlibPath)) { (s) in sources.append(s) }
    await serveLanguageServer(channel: .stdioPipe(), logger: logger, standardLibrary: sources)
  }

}

// Allow log level to be specified as an argument.
//
// Assuming none of our dependencies conform Logger.Level to ExpressibleByArgument.
// swift-format-ignore: AvoidRetroactiveConformances
extension Logger.Level: @retroactive ExpressibleByArgument {

}
