import XCTest
import Logging
@testable import HyloLanguageServerCore
import LanguageServerProtocol

/// Tests for the "Hover" LSP feature.
///
/// These tests verify the server's ability to provide contextual information
/// when hovering over symbols, including type information and documentation.
final class HoverTests: XCTestCase {
  
  var context: LSPTestContext!
  
  override func setUp() async throws {
    var logger = Logger(label: "HoverTests")
    logger.logLevel = .debug
    
    let stdlibPath = "/workspaces/hylo-language-server/hylo-new/StandardLibrary"
    context = LSPTestContext(stdlibPath: stdlibPath, logger: logger)
    try await context.initialize(rootUri: "file:///test")
  }
  
  // MARK: - Basic Hover Tests
  
  func testHoverOnFunctionName() async throws {
    // Test hover information on a function
    let source: MarkedHyloSource = """
    fun factorial(_ n: Int) -> Int {
      if n < 2 { 1 } else { n * factorial(n - 1) }
    }
    
    public fun main() {
      let _ = <CURSOR/>factorial(6)
    }
    """
    
    let doc = await context.openDocument(source)
    let hover = try await doc.hover()
    
    // Verify hover contains type information
    try assertHoverContains(hover, "Int")
  }
  
  func testHoverOnVariable() async throws {
    // Test hover on a variable
    let source: MarkedHyloSource = """
    public fun main() {
      let x = 42
      let y = <CURSOR/>x + 1
    }
    """
    
    let doc = await context.openDocument(source)
    let hover = try await doc.hover()
    
    // The hover should contain type information
    XCTAssertNotNil(hover)
  }
  
  func testHoverOnExpression() async throws {
    // Test with a more complex expression
    let source: MarkedHyloSource = """
    public fun main() {
      let x = 42
      let y = 10
      let result = x + <CURSOR/>y
    }
    """
    
    let doc = await context.openDocument(source)
    let hover = try await doc.hover()
    
    // Should get hover information for the variable
    XCTAssertNotNil(hover)
  }
  
  // MARK: - Invariant Tests
  
  func testHoverIsIdempotent() async throws {
    // Property: Hovering at the same position multiple times should give the same result
    let source: MarkedHyloSource = """
    public fun main() {
      let x = <CURSOR/>42
    }
    """
    
    let doc = await context.openDocument(source)
    
    let hover1 = try await doc.hover()
    let hover2 = try await doc.hover()
    let hover3 = try await doc.hover()
    
    // All hover responses should be equivalent
    let content1 = hover1.map { extractHoverContent($0.contents) }
    let content2 = hover2.map { extractHoverContent($0.contents) }
    let content3 = hover3.map { extractHoverContent($0.contents) }
    
    XCTAssertEqual(content1, content2)
    XCTAssertEqual(content2, content3)
  }
}
