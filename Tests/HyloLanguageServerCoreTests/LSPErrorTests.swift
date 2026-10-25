import HyloLanguageServerCore
import LanguageServerProtocol
import XCTest

final class LSPErrorTests: XCTestCase {

  func testCodes() {
    XCTAssertEqual(LSPError.invalidParameter(message: "").code, ErrorCodes.InvalidParams)
    XCTAssertEqual(LSPError.internalError(message: "").code, ErrorCodes.InternalError)
    XCTAssertEqual(LSPError.methodNotFound(message: "").code, ErrorCodes.MethodNotFound)
  }

  func testReportingLSPError() {
    let e = LSPError(reporting: LSPError.methodNotFound(message: "m"))
    XCTAssertEqual(e.code, ErrorCodes.MethodNotFound)
    XCTAssertEqual(e.message, "m")
  }

  func testReportingOtherError() {
    let e = LSPError(reporting: CocoaError(.fileNoSuchFile))
    XCTAssertEqual(e.code, ErrorCodes.InternalError)
    XCTAssertEqual(e.message, "\(CocoaError(.fileNoSuchFile))")
  }

}
