import JSONRPC
import LanguageServerProtocol
import Logging
import StandardLibrary
import XCTest

@testable import HyloLanguageServerCore

/// Tests for the "Completion" (autocomplete) LSP feature.
///
/// These exercise the full recovery + type-check + enumeration pipeline through the
/// request handler, across multiple syntactic constructs and cursor positions.
final class CompletionTests: XCTestCase {

  var context: LSPTestContext!

  override func setUp() async throws {
    context = try await LSPTestContext.make(tag: "CompletionTests", rootUri: "file:///test")
  }

  // MARK: - Member access on a struct instance

  func testInstanceMemberCompletionEmpty() async throws {
    let source = try MarkedSource(
      """
      public struct Box {
        var value: Int
        public memberwise init
        public fun get() -> Int { return self.value }
      }

      public fun main() {
        let b = Box(value: 1)
        let _ = b.0️⃣
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    assertContains(items, ["value", "get"], context: "instance members of Box")
  }

  func testInstanceMemberCompletionPartialPrefix() async throws {
    // Bug A: completion must work when a prefix is already typed after the dot.
    let source = try MarkedSource(
      """
      public struct Box {
        var value: Int
        public memberwise init
        public fun get() -> Int { return self.value }
      }

      public fun main() {
        let b = Box(value: 1)
        let _ = b.ge0️⃣
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    // We return the full member set; the client filters by the typed prefix.
    assertContains(items, ["get"], context: "partial-prefix member completion")
  }

  // MARK: - Static / type-qualified access

  func testStaticMemberCompletion() async throws {
    // Bug B: `Type.` should surface static members / initializers.
    let source = try MarkedSource(
      """
      public struct Box {
        var value: Int
        public memberwise init
        public fun get() -> Int { return self.value }
      }

      public fun main() {
        let _ = Box.0️⃣
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    XCTAssertFalse(
      items.isEmpty, "expected static members for `Box.`, got none. \(labels(items))")
    // The initializer is invoked as `Box.new(...)`.
    assertContains(items, ["new"], context: "static members of Box")
    // Instance-only members should not appear in static position.
    assertDoesNotContain(items, ["value"], context: "static members of Box")
  }

  // MARK: - Leading-dot / implicit-member against the expected type

  func testLeadingDotCompletion() async throws {
    // Bug C: `.member` resolves against the expected type.
    let source = try MarkedSource(
      """
      public struct Box {
        var value: Int
        public memberwise init
      }

      public fun main() {
        let b: Box = .0️⃣
        _ = b
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    XCTAssertFalse(
      items.isEmpty, "expected leading-dot completions against `Box`, got none. \(labels(items))")
    assertContains(items, ["new"], context: "leading-dot members of Box")
  }

  // MARK: - Scope / identifier completion

  func testLocalScopeCompletion() async throws {
    let source = try MarkedSource(
      """
      public fun main() {
        let apple = 1
        let apricot = 2
        let _ = 0️⃣
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    assertContains(items, ["apple", "apricot"], context: "locals in scope")
  }

  func testTopLevelFunctionInScope() async throws {
    let source = try MarkedSource(
      """
      fun helper() -> Int { return 1 }

      public fun main() {
        let _ = 0️⃣
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    assertContains(items, ["helper"], context: "top-level functions in scope")
  }

  // MARK: - `self.` qualification of members in scope

  func testInstanceMembersInScopeAreSelfQualified() async throws {
    // Inside a method body, a sibling instance member must be inserted as `self.member`,
    // because Hylo has no implicit `self`.
    let source = try MarkedSource(
      """
      public struct Box {
        var value: Int
        public memberwise init
        public fun helper() -> Int { return self.value }
        public fun caller() -> Int {
          let _ = 0️⃣
          return 0
        }
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])

    let helper = try XCTUnwrap(
      items.first { $0.label == "helper" }, "expected `helper` in scope. \(labels(items))")
    XCTAssertEqual(
      helper.insertText?.hasPrefix("self.helper") ?? false, true,
      "expected `helper` to insert `self.helper...`, got \(helper.insertText ?? "nil")")
    XCTAssertEqual(helper.filterText, "helper", "filterText should match the bare member name")

    let value = try XCTUnwrap(
      items.first { $0.label == "value" }, "expected `value` in scope. \(labels(items))")
    XCTAssertEqual(
      value.insertText?.hasPrefix("self.value") ?? false, true,
      "expected `value` to insert `self.value`, got \(value.insertText ?? "nil")")
  }

  func testLocalsInScopeAreNotSelfQualified() async throws {
    // Locals must NOT be prefixed with `self.`.
    let source = try MarkedSource(
      """
      public struct Box {
        var value: Int
        public memberwise init
        public fun caller() -> Int {
          let local = 1
          let _ = 0️⃣
          return 0
        }
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    let local = try XCTUnwrap(
      items.first { $0.label == "local" }, "expected `local` in scope. \(labels(items))")
    XCTAssertEqual(
      local.insertText?.hasPrefix("self.") ?? false, false,
      "locals must not be self-qualified, got \(local.insertText ?? "nil")")
  }

  func testOperatorMembersAreNotOfferedInScope() async throws {
    // Operator members can't be invoked through name completion (`self.infix+` is invalid),
    // so they must not be offered.
    let source = try MarkedSource(
      """
      public struct Vec {
        var n: Int
        public memberwise init
        public fun infix+(other: Vec) -> Int { return self.n }
        public fun size() -> Int {
          let _ = 0️⃣
          return self.n
        }
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    // The sibling method `size` is offered (self-qualified); the operator is not.
    assertContains(items, ["size"], context: "non-operator members")
    for item in items {
      XCTAssertEqual(
        item.insertText?.contains("infix") ?? false, false,
        "operator member must not be offered, got \(item.label) -> \(item.insertText ?? "nil")")
    }
  }

  // MARK: - Robustness

  func testCompletionDoesNotCrashOnDanglingMemberAccess() async throws {
    // A dangling member access with code following it: the realistic "mid-edit" case.
    let source = try MarkedSource(
      """
      public fun main() {
        let n = 1
        let _ = n.0️⃣
        let m = 2
        _ = m
      }
      """)
    let uri = try await context.openDocument(source)
    // Should not throw, even though the cursor line is syntactically incomplete.
    _ = try await context.completion(uri: uri, at: source.markers[0])
  }

  // MARK: - Assertion helpers

  private func labels(_ items: [CompletionItem]) -> String {
    "labels: [\(items.map(\.label).joined(separator: ", "))]"
  }

  private func assertContains(
    _ items: [CompletionItem], _ expected: [String], context: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let present = Set(items.map(\.label))
    for e in expected where !present.contains(e) {
      XCTFail(
        "Expected completion '\(e)' (\(context)) but it was missing. \(labels(items))",
        file: file, line: line)
    }
  }

  private func assertDoesNotContain(
    _ items: [CompletionItem], _ unexpected: [String], context: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let present = Set(items.map(\.label))
    for u in unexpected where present.contains(u) {
      XCTFail(
        "Did not expect completion '\(u)' (\(context)) but it was present. \(labels(items))",
        file: file, line: line)
    }
  }

}

extension LSPTestContext {

  /// Performs a completion request in the document and returns the flattened item list.
  public func completion(uri: URL, at position: Position) async throws -> [CompletionItem] {
    let params = CompletionParams(
      uri: uri.absoluteString, position: position, triggerKind: .invoked, triggerCharacter: nil)
    switch await requestHandler.completion(id: .numericId(1), params: params) {
    case .success(let value):
      return value?.items ?? []
    case .failure(let error):
      throw TestFailure(error.message)
    }
  }

}
