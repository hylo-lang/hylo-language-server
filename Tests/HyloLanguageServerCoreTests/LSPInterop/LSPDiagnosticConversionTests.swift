import FrontEnd
import LanguageServerProtocol
import XCTest

final class LSPDiagnosticConversionTests: XCTestCase {
  func testBasicProperties() {
    let f: SourceFile = "fun main()"

    let hyloDiagnostic = FrontEnd.Diagnostic(.error, "hello", at: f.span)
    let lspDiagnostic = LanguageServerProtocol.Diagnostic(hyloDiagnostic)
    XCTAssertEqual(lspDiagnostic.severity, .error)
    XCTAssertEqual(lspDiagnostic.range, LSPRange(f.span))
    XCTAssertEqual(lspDiagnostic.message, "hello")
    XCTAssertEqual(lspDiagnostic.relatedInformation, [])
  }

  func testSeverity() {
    let f: SourceFile = "fun main()"

    XCTAssertEqual(
      LanguageServerProtocol.Diagnostic(
        FrontEnd.Diagnostic(.error, "hello", at: f.span)
      ).severity, .error)
    XCTAssertEqual(
      LanguageServerProtocol.Diagnostic(
        FrontEnd.Diagnostic(.warning, "hello", at: f.span)
      ).severity, .warning)
    XCTAssertEqual(
      LanguageServerProtocol.Diagnostic(
        FrontEnd.Diagnostic(.note, "hello", at: f.span)
      ).severity, .information)
  }

  func testRelatedInfo() throws {
    let f: SourceFile = "fun main()"
    let hyloDiagnostic = FrontEnd.Diagnostic(
      .error, "hello", at: f.span,
      notes: [
        .init(.note, "world", at: f.span)
      ])
    let lspDiagnostic = LanguageServerProtocol.Diagnostic(hyloDiagnostic)
    let relatedInfo = try XCTUnwrap(lspDiagnostic.relatedInformation)
    XCTAssertEqual(relatedInfo.count, 1)
    XCTAssertEqual(relatedInfo[0].message, "world")
    XCTAssertEqual(relatedInfo[0].location, LanguageServerProtocol.Location(f.span))
  }
}
