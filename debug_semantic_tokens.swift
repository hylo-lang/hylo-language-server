#!/usr/bin/env swift

import Foundation
import FrontEnd
import Logging
@testable import hylo_lsp

// Create a simple test for semantic tokens
let logger = Logger(label: "semantic-tokens-debug")

// Set up console logger
LoggingSystem.bootstrap { label in
    var handler = StreamLogHandler.standardOutput(label: label)
    handler.logLevel = .debug
    return handler
}

let examplePath = "/workspaces/hylo-language-server/Tests/hylo-language-server-tests/example.hylo"
let exampleUri = "file://\(examplePath)"

do {
    let sourceFile = try SourceFile(contentsOf: URL(fileURLWithPath: examplePath))
    logger.info("Loaded source file: \(sourceFile.text)")
    
    // Try to parse and build a program
    var program = Program()
    let diagnostics = DiagnosticSet()
    
    // Parse the source
    let parsed = try program.parse([sourceFile], reportingDiagnosticsTo: diagnostics)
    logger.info("Parsed successfully")
    
    // Assign scopes
    let scopeAssigned = try program.assignScopes(to: parsed, reportingDiagnosticsTo: diagnostics)
    logger.info("Scope assignment successful")
    
    // Try basic semantic tokens
    let tokens = program.getSemanticTokens(exampleUri, logger: logger)
    logger.info("Generated \(tokens.count) semantic tokens")
    
    for token in tokens {
        logger.info("Token: \(token.type) at \(token.range)")
    }
    
} catch {
    logger.error("Error: \(error)")
}