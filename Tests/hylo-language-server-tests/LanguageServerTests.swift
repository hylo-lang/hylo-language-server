import FrontEnd
import Logging
import XCTest

@testable import hylo_lsp

final class LanguageServerTests: XCTestCase {
  func testListDocumentSymbols() throws {
    let exampleFileUri = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("example.hylo")
    let source = try SourceFile(contentsOf: exampleFileUri)

    // var uriMapping: [String: TranslationUnit.ID] = [:]
    // var ast = AST()
    // var d = DiagnosticSet()
    // let moduleId = try ast.loadModule(
    //   "RootModule", parsing: [source], withBuiltinModuleAccess: false, reportingDiagnosticsTo: &d)
    // let tu = ast[moduleId].sources.first!
    // uriMapping[exampleFileUri.absoluteString] = tu

    // let logger = Logger(label: "test-list-document-symbols")

    // let res = ast.listDocumentSymbols(
    //   exampleFileUri.absoluteString, uriMapping: uriMapping, logger: logger)
    // XCTAssertGreaterThan(res.count, 0)
  }
}
