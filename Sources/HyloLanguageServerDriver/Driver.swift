import ArgumentParser
import Foundation
import JSONRPC
import Logging
import Puppy
import StandardLibrary
import HyloLanguageServerCore

// Allow loglevel as `ArgumentParser.Option`
extension Logger.Level: @retroactive ExpressibleByArgument {
}

@main
struct HyloLspCommand: AsyncParsableCommand {

  static let configuration = CommandConfiguration(commandName: "hylo-language-server")

  @Option(help: "Log level")
  var logLevel: Logger.Level = Logger.Level.debug

  // https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#implementationConsiderations
  // These are VS Code compatible transport flags:

  @Flag(help: "Stdio transport")
  var stdio: Bool = true // Obsolete, kept for compatibility

  @Option(help: "Path to the Hylo standard library")
  var stdlibPath: String = bundledStandardLibrarySources.path

  func run() async throws {
    var logger = Logger(label: "s")
    logger.handler=NullLogHandler(label: "s")

    let server = HyloLanguageServer(dataChannel: .stdioPipe(), logger: logger, stdlibPath: stdlibPath)
    await server.run()
  }
}
