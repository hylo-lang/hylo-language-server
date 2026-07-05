import Foundation
import FrontEnd
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

    // Instance members are still offered in static position as *unbound* selections (Hylo permits
    // `Box.value`), but ranked after the static members and tagged in `detail`.
    let new = try XCTUnwrap(
      items.first { itemName($0) == "new" }, "expected `new` in static position. \(labels(items))")
    let value = try XCTUnwrap(
      items.first { itemName($0) == "value" },
      "expected the unbound instance member `value` in static position. \(labels(items))")
    XCTAssertEqual(
      value.detail?.contains("unbound") ?? false, true,
      "unbound instance member should be tagged in `detail`, got \(value.detail ?? "nil")")
    XCTAssertLessThan(
      new.sortText ?? "", value.sortText ?? "",
      "static members must rank before unbound instance members")
  }

  func testUnboundInstanceMethodInStaticPositionIncludesSelf() async throws {
    // An instance method reached through its type (`Box.get`) is an *unbound* selection: the
    // inserted snippet must carry the leading `self:` parameter the unbound call requires.
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
    let get = try XCTUnwrap(
      items.first { itemName($0) == "get" },
      "expected the unbound instance method `get` in static position. \(labels(items))")
    XCTAssertEqual(
      get.insertText?.contains("self:") ?? false, true,
      "unbound member snippet must include the `self:` parameter, got \(get.insertText ?? "nil")")
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

  // MARK: - Members through conformances, extensions, and givens

  func testMemberCompletionUnionsNativeConformanceAndExtension() async throws {
    // `x.` must offer the full member set the type checker would accept: native members, members
    // from an applicable extension, and the requirements of a trait the type conforms to.
    let source = try MarkedSource(
      """
      trait Greetable { fun greet() -> Bool }

      struct A {
        public var tag: Bool
        public memberwise init
      }

      given A is Greetable { fun greet() -> Bool { true } }
      extension A { fun extra() -> Bool { true } }

      public fun main() {
        let x = A(tag: true)
        let _ = x.0️⃣
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    assertContains(
      items, ["tag", "greet", "extra"], context: "native + conformance + extension members")
  }

  func testMemberCompletionOnGenericBoundReceiver() async throws {
    // The receiver is a generic parameter `T: Greetable`; the trait's members must complete on `T`
    // with no concrete witness (the bound supplies the conformance in the implicit context).
    let source = try MarkedSource(
      """
      trait Greetable { fun greet() -> Bool }

      public fun f<T is Greetable>(x: T) {
        let _ = x.0️⃣
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    assertContains(items, ["greet"], context: "bound-derived members on a generic receiver")
  }

  func testMemberCompletionThroughTraitRefinement() async throws {
    // `Ordered refines Named`: on a receiver known to be `Ordered`, both `Ordered`'s and `Named`'s
    // requirements must appear (the refinement makes `Named<T>` summonable from `Ordered<T>`).
    let source = try MarkedSource(
      """
      trait Named { fun named() -> Bool }
      trait Ordered refines Named { fun ordered() -> Bool }

      public fun f<T is Ordered>(x: T) {
        let _ = x.0️⃣
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    assertContains(items, ["named", "ordered"], context: "members via trait refinement")
  }

  func testMemberCompletionKeepsSameNamedMembersFromDistinctTraits() async throws {
    // Two in-scope traits both declare `shared`; both conformances are satisfiable, so both
    // candidates must be offered (members are deduped by declaration identity, never by name).
    let source = try MarkedSource(
      """
      trait P1 { fun shared() -> Bool }
      trait P2 { fun shared() -> Bool }

      struct A { public memberwise init }

      given A is P1 { fun shared() -> Bool { true } }
      given A is P2 { fun shared() -> Bool { false } }

      public fun main() {
        let x = A()
        let _ = x.0️⃣
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    let shared = items.filter { itemName($0) == "shared" }
    XCTAssertEqual(
      shared.count, 2,
      "expected both same-named trait members, got \(shared.count). \(labels(items))")
  }

  func testStaticMembersFromNativeExtensionAndConformance() async throws {
    // `T.` must offer static members from all three sources: native (`sf`), extension (`sg`), and a
    // static requirement reached through a conformance (`sh`). The conformance case relies on the
    // static flag being threaded into the trait branch of enumeration; with it dropped, `sh` is
    // skipped by the static/instance guard.
    let source = try MarkedSource(
      """
      struct A {
        public memberwise init
        public static fun sf() {}
      }
      extension A {
        public static fun sg() {}
      }
      trait P {
        static fun sh()
      }
      given A is P {
        public static fun sh() {}
      }
      public fun main() {
        let _ = A.0️⃣
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    assertContains(
      items, ["sf", "sg", "sh"], context: "static native + extension + conformance members")
  }

  // MARK: - Leading-dot in an argument position (expected type from the call)

  func testLeadingDotArgumentUnionsOverloadCandidates() async throws {
    // At `a(.)` where `a` is overloaded over unrelated parameter types, leading-dot completion
    // should offer the UNION of the candidates' static members — `foo` (from A) and `bar`/`car`
    // (from B), plus the shared `new`.
    //
    // This is a target for two pieces of work:
    //   1. Recovering the implicit member as a *call* (`.marker()`), so the frontend's callee
    //      path (`Typer.inferredType(calleeOf:)`) gives the qualification a type. A bare
    //      `.marker` in argument position is never assigned an expected type, so the receiver
    //      cannot be typed and no members are offered.
    //   2. Gathering every overload's parameter type at the cursor's argument index and unioning
    //      their members. A single solved type would surface only one candidate (the one the
    //      solver happens to pick), not the union.
    let source = try MarkedSource(
      """
      struct A {
        memberwise init
        static fun foo() -> A { .new() }
      }

      struct B {
        memberwise init
        static fun bar() -> B { .new() }
        static fun car() -> B { .new() }
      }

      fun a(x: A) {}
      fun a(x: B) {}

      fun main() {
        a(.0️⃣)
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    XCTAssertFalse(
      items.isEmpty, "expected leading-dot completions at `a(.)`, got none. \(labels(items))")
    assertContains(
      items, ["foo", "bar", "car", "new"], context: "union of A and B static members")
  }

  func testLeadingDotArgumentDisambiguatedByOtherArgument() async throws {
    // When another argument fixes the overload — `a(., B())` can only select `a(x: B, y: B)` —
    // exactly one candidate survives, so only B's static members should be offered.
    //
    // The disambiguation itself is already handled by the type checker; the missing piece is the
    // call-form recovery (item 1 above). Once the implicit member is recovered as `.marker()`,
    // the solved expected type is `B`, and the union collapses to a single candidate.
    let source = try MarkedSource(
      """
      struct A {
        memberwise init
        static fun foo() -> A { .new() }
      }

      struct B {
        memberwise init
        static fun bar() -> B { .new() }
        static fun car() -> B { .new() }
      }

      fun a(x: A, y: A) {}
      fun a(x: B, y: B) {}

      fun main() {
        a(.0️⃣, B())
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    XCTAssertFalse(
      items.isEmpty,
      "expected leading-dot completions at `a(., B())`, got none. \(labels(items))")
    assertContains(
      items, ["bar", "car", "new"], context: "static members of B (the surviving overload)")
    assertDoesNotContain(
      items, ["foo"], context: "A is not a candidate once `B()` fixes the overload")
  }

  func testLeadingDotArgumentDisambiguatedByPrecedingArgument() async throws {
    // The fixing argument comes *before* the hole — `a(A(), .)` can only select `a(x: A, y: A)` —
    // so the hole is at argument index 1 and only A's static members should be offered. This
    // exercises reading a non-hole argument that precedes the hole and aligning the hole index.
    let source = try MarkedSource(
      """
      struct A {
        memberwise init
        static fun foo() -> A { .new() }
      }

      struct B {
        memberwise init
        static fun bar() -> B { .new() }
      }

      fun a(x: A, y: A) {}
      fun a(x: B, y: B) {}

      fun main() {
        a(A(), .0️⃣)
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    assertContains(
      items, ["foo", "new"], context: "static members of A (the surviving overload)")
    assertDoesNotContain(
      items, ["bar"], context: "B is not a candidate once `A()` fixes the overload")
  }

  func testLeadingDotArgumentConsidersOverloadReachableViaDefault() async throws {
    // The hole is the only argument, but the surviving overload has a second, defaulted parameter
    // (`a(x: B, y: B = ...)`). It is viable — the default fills `y` — so B's members must be offered.
    // An exact-arity alignment would drop it and narrow the union, hiding valid completions.
    let source = try MarkedSource(
      """
      struct A {
        memberwise init
        static fun foo() -> A { .new() }
      }

      struct B {
        memberwise init
        static fun bar() -> B { .new() }
      }

      fun a(x: A, y: A) {}
      fun a(x: B, y: B = B()) {}

      fun main() {
        a(.0️⃣)
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    assertContains(
      items, ["bar", "new"], context: "static members of B, reachable via the defaulted parameter")
    assertDoesNotContain(
      items, ["foo"],
      context: "the two-required-argument overload of `a` does not match one argument")
  }

  func testLeadingDotArgumentWithLabelAlignsToLabeledParameter() async throws {
    // A labeled hole (`f(y: .)`) binds the parameter carrying that label, not the one at its
    // position: the first parameter is defaulted, so the single written argument sits at position
    // 0 but must be completed against the second parameter's type.
    let source = try MarkedSource(
      """
      struct A {
        memberwise init
        static fun foo() -> A { .new() }
      }

      struct B {
        memberwise init
        static fun bar() -> B { .new() }
      }

      fun f(_ x: A = A(), _ y: B) {}

      fun main() {
        f(y: .0️⃣)
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    assertContains(items, ["bar"], context: "static members of the labeled parameter's type")
    assertDoesNotContain(
      items, ["foo"], context: "the defaulted first parameter is not the labeled hole's target")
  }

  func testLeadingDotArgumentOnQualifiedCallee() async throws {
    // The callee is a member of a value (`w.take(.)`), not a top-level function. Completion must
    // resolve the member's overload, read its parameter type, and offer that type's static members.
    let source = try MarkedSource(
      """
      struct A {
        memberwise init
        static fun foo() -> A { .new() }
      }

      struct Wrapper {
        memberwise init
        fun take(x: A) {}
      }

      fun main() {
        let w = Wrapper()
        w.take(.0️⃣)
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    XCTAssertFalse(
      items.isEmpty, "expected leading-dot completions at `w.take(.)`, got none. \(labels(items))")
    assertContains(items, ["foo", "new"], context: "static members of A on a qualified callee")
  }

  // MARK: - `Self` in scope completion

  func testSelfCompletionInTypeScopeResolvesConcreteType() async throws {
    // Inside a struct, `Self` is offered and annotated with the concrete type it denotes.
    let source = try MarkedSource(
      """
      public struct Box {
        var value: Int
        public memberwise init
        public fun get() -> Int {
          let _ = 0️⃣
          return self.value
        }
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    let zelf = try XCTUnwrap(
      items.first { itemName($0) == "Self" }, "expected `Self` in a type scope. \(labels(items))")
    XCTAssertEqual(
      zelf.detail?.contains("Box") ?? false, true,
      "`Self` should resolve to the concrete type `Box`, got \(zelf.detail ?? "nil")")
  }

  func testSelfCompletionAvailableInNestedFunctionWithinMethod() async throws {
    // `Self` is legal at any depth under a type scope, including a function nested in a method.
    let source = try MarkedSource(
      """
      public struct Box {
        public memberwise init
        public fun get() -> Int {
          fun helper() -> Int {
            let _ = 0️⃣
            return 0
          }
          return helper()
        }
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    assertContains(items, ["Self"], context: "`Self` in a nested function within a method")
  }

  func testSelfCompletionNotOfferedAtTopLevel() async throws {
    // Outside any type scope, `Self` is not legal and must not be offered.
    let source = try MarkedSource(
      """
      public fun main() {
        let _ = 0️⃣
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    assertDoesNotContain(items, ["Self"], context: "`Self` outside a type scope")
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

  func testTupleBindingOffersIndividualVariables() async throws {
    // A binding whose pattern destructures a tuple (`let (a, b) = ...`) introduces two variables.
    // Completion must offer `a` and `b` individually, never the binding's `(a, b)` pattern.
    let source = try MarkedSource(
      """
      public fun main() {
        let (a, b) = (1, 2)
        let _ = 0️⃣
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    assertContains(items, ["a", "b"], context: "destructured variables of a tuple binding")
    assertDoesNotContain(
      items, ["(a, b)"], context: "the binding pattern itself is not a candidate")
  }

  func testScopeCompletionShowsAllOverloads() async throws {
    // Overloaded functions are distinct declarations; scope completion must offer every overload,
    // not collapse them to the first-declared one. Dedup suppresses genuine shadowing only, never
    // same-scope overloads.
    //
    // Declaration order is deliberately B-then-A to catch a collapse keeping only "first in
    // source".
    let source = try MarkedSource(
      """
      struct A {
        memberwise init
      }

      struct B {
        memberwise init
      }

      fun a(x: B, y: B) {}
      fun a(x: A, y: A) {}

      fun main() {
        let _ = 0️⃣
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    let overloads = items.filter { itemName($0) == "a" }
    XCTAssertEqual(
      overloads.count, 2,
      "expected both overloads of `a` in scope, got \(overloads.count): "
        + "\(overloads.map { $0.detail ?? $0.label })")
    // The two surviving items must be the two distinct signatures, not duplicates.
    let details = overloads.compactMap(\.detail).joined(separator: " | ")
    XCTAssertTrue(details.contains("A"), "expected an overload over A. details: \(details)")
    XCTAssertTrue(details.contains("B"), "expected an overload over B. details: \(details)")
  }

  func testScopeCompletionDistinguishesOverloadsByParameterDetail() async throws {
    // All overloads of `a` must appear, and each item's `detail` must carry its parameter names so
    // `a(x: Int)` and `a(xy: Int)` are distinguishable (the arrow type alone drops the names).
    let source = try MarkedSource(
      """
      fun a() {}
      fun a(x: Int) {}
      fun a(xy: Int) {}
      fun a(x: Bool) {
        let _ = 0️⃣
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    let overloads = items.filter { itemName($0) == "a" }
    XCTAssertEqual(
      overloads.count, 4, "expected all four overloads of `a`. \(labels(items))")
    let details = overloads.compactMap(\.detail)
    XCTAssertTrue(
      details.contains("a(x: Int) -> Void"),
      "expected an overload detailing `a(x: Int)`. details: \(details)")
    XCTAssertTrue(
      details.contains("a(xy: Int) -> Void"),
      "expected an overload detailing `a(xy: Int)`. details: \(details)")
    XCTAssertTrue(
      details.contains("a(x: Bool) -> Void"),
      "expected an overload detailing `a(x: Bool)`. details: \(details)")
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

  func testStandardLibraryTopLevelDeclarationsInScope() async throws {
    // The standard library is imported implicitly; its top-level declarations must be offered by
    // unqualified completion, not just the names declared in the current file.
    let source = try MarkedSource(
      """
      public fun main() {
        let _ = 0️⃣
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    assertContains(
      items, ["Int", "Bool", "precondition"], context: "standard-library top-level declarations")
  }

  func testOuterScopeFunctionOverloadRemainsVisible() async throws {
    // A method named like a top-level function does not shadow it — both are callable overloads
    // (mirroring `Typer.lookup`, which keeps collecting across scopes while every match is
    // overloadable). Only the inner one is a member and gets the `self.` insertion.
    let source = try MarkedSource(
      """
      fun log(x: Int) {}

      public struct S {
        public memberwise init
        public fun log() {}
        public fun caller() {
          let _ = 0️⃣
        }
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    let overloads = items.filter { itemName($0) == "log" }
    XCTAssertEqual(
      overloads.count, 2,
      "expected the member and the top-level overload of `log`, got \(overloads.count). "
        + labels(items))
    XCTAssertTrue(
      overloads.contains { $0.insertText?.hasPrefix("self.") ?? false },
      "expected the member overload to insert `self.log...`")
    XCTAssertTrue(
      overloads.contains { !($0.insertText?.hasPrefix("self.") ?? false) },
      "expected the top-level overload to insert a bare `log...`")
  }

  func testInnerBindingShadowsOuterFunction() async throws {
    // A binding is not overloadable: it shadows a same-named declaration of any outer scope.
    let source = try MarkedSource(
      """
      fun value() -> Int { return 1 }

      public fun main() {
        let value = 2
        let _ = 0️⃣
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    let matches = items.filter { itemName($0) == "value" }
    XCTAssertEqual(
      matches.count, 1,
      "expected the local to shadow the function: "
        + matches.map { "\($0.kind.map(String.init(describing:)) ?? "?") \($0.detail ?? "?")" }
        .joined(separator: " | "))
    XCTAssertEqual(matches.first?.kind, .variable, "expected the surviving item to be the local")
  }

  func testSuppressedBindingStillShadowsOuterOverload() async throws {
    // `Typer.lookup` stops a name's walk at the first group containing a non-overloadable
    // declaration even when that declaration is itself not collected (an inner overloadable
    // match already won). The middle `let f` is suppressed by the inner `fun f`, but it still
    // makes the outer `fun f(x:)` unreachable.
    let source = try MarkedSource(
      """
      fun f(x: Int) {}

      public fun main() {
        let f = 1
        fun g() {
          fun f() {}
          let _ = 0️⃣
        }
        g()
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    let matches = items.filter { itemName($0) == "f" }
    XCTAssertEqual(
      matches.count, 1,
      "expected only the innermost `f`; the suppressed `let f` ends the lookup. " + labels(items))
    XCTAssertEqual(matches.first?.kind, .function, "expected the surviving item to be `fun f()`")
  }

  func testDeclaredNameHidesPredefinedHomonym() async throws {
    // Predefined names (`Never`, `Void`, ...) resolve only where lookup finds nothing, so a
    // declared `Never` must hide the predefined item rather than duplicate it.
    let source = try MarkedSource(
      """
      public struct Never {}

      public fun main() {
        let _ = 0️⃣
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    let matches = items.filter { itemName($0) == "Never" }
    XCTAssertEqual(matches.count, 1, "expected a single `Never`. " + labels(items))
    XCTAssertNil(
      matches.first?.documentation,
      "expected the declared struct (no documentation), not the predefined item")
  }

  // MARK: - Snippet escaping

  func testTupleTypedParameterEscapedInSnippet() async throws {
    // A tuple type renders as `{Int, Int}`; its `}` must be escaped inside the snippet
    // placeholder, or it closes the placeholder early. The label stays unescaped.
    let source = try MarkedSource(
      """
      public fun f(pair: {Int, Int}) {}

      public fun main() {
        let _ = 0️⃣
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    let f = try XCTUnwrap(
      items.first { itemName($0) == "f" }, "expected `f` in scope. \(labels(items))")
    let insert = try XCTUnwrap(f.insertText, "expected a call snippet for `f`")
    XCTAssertTrue(
      insert.contains("${1:{Int, Int\\}}"),
      "expected the placeholder's closing brace escaped, got \(insert)")
    let detail = try XCTUnwrap(f.detail, "expected a detail for `f`")
    XCTAssertFalse(detail.contains("\\"), "the detail must stay unescaped, got \(detail)")
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
      items.first { itemName($0) == "helper" }, "expected `helper` in scope. \(labels(items))")
    XCTAssertEqual(
      helper.insertText?.hasPrefix("self.helper") ?? false, true,
      "expected `helper` to insert `self.helper...`, got \(helper.insertText ?? "nil")")
    XCTAssertEqual(helper.filterText, "helper", "filterText should match the bare member name")

    let value = try XCTUnwrap(
      items.first { itemName($0) == "value" }, "expected `value` in scope. \(labels(items))")
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
      items.first { itemName($0) == "local" }, "expected `local` in scope. \(labels(items))")
    XCTAssertEqual(
      local.insertText?.hasPrefix("self.") ?? false, false,
      "locals must not be self-qualified, got \(local.insertText ?? "nil")")
  }

  func testInstanceMembersNotOfferedInStaticFunction() async throws {
    // No instance `self` exists in a static function, so instance members cannot be named there
    // and must not be offered (inserting `self.value` would not type-check). Static members
    // remain available.
    let source = try MarkedSource(
      """
      public struct S {
        var value: Int
        public memberwise init
        public fun m() {}
        public static fun s() {
          let _ = 0️⃣
        }
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    assertDoesNotContain(
      items, ["value", "m"], context: "instance members in a static function body")
    assertContains(items, ["s"], context: "static members in a static function body")
    for item in items {
      XCTAssertEqual(
        item.insertText?.hasPrefix("self.") ?? false, false,
        "nothing may insert `self.` where no instance exists, got \(item.insertText ?? "nil")")
    }
  }

  // MARK: - Defaulted parameters

  func testDefaultedParameterKeepsDefaultInsidePlaceholder() async throws {
    // A defaulted parameter renders as `name: Type = default` and the default stays inside the
    // snippet placeholder, so accepting and overtyping the placeholder never leaves residue like
    // `f(y: BB())` behind.
    let source = try MarkedSource(
      """
      public struct B {
        public memberwise init
      }

      public fun f(y: B = B()) {}

      public fun main() {
        let _ = 0️⃣
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    let f = try XCTUnwrap(
      items.first { itemName($0) == "f" }, "expected `f` in scope. \(labels(items))")
    let insert = try XCTUnwrap(f.insertText, "expected a call snippet for `f`")
    XCTAssertTrue(
      insert.contains("${1:B = B.new()}"),
      "expected the default inside the placeholder, got \(insert)")
    let detail = try XCTUnwrap(f.detail, "expected a detail for `f`")
    XCTAssertTrue(
      detail.contains("y: B = B.new()"), "expected `= default` in the detail, got \(detail)")
  }

  // MARK: - Parameter rendering

  func testParameterDetailReadsLikeTheDeclaration() async throws {
    // Hylo's labeling is the opposite of Swift's: a lone name declares an unlabeled parameter,
    // `_` gives the parameter its own name as label, and two names read label-then-name. The
    // detail must render each parameter the way the declaration spells it.
    let source = try MarkedSource(
      """
      public fun a(x: Int) {}
      public fun b(xy z: Int) {}
      public fun c(_ g: Int) {}

      public fun main() {
        let _ = 0️⃣
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])

    let a = try XCTUnwrap(items.first { itemName($0) == "a" }, labels(items))
    XCTAssertTrue(a.detail?.contains("(x: Int)") ?? false, "unlabeled: got \(a.detail ?? "nil")")
    let b = try XCTUnwrap(items.first { itemName($0) == "b" }, labels(items))
    XCTAssertTrue(b.detail?.contains("(xy z: Int)") ?? false, "labeled: got \(b.detail ?? "nil")")
    let c = try XCTUnwrap(items.first { itemName($0) == "c" }, labels(items))
    XCTAssertTrue(
      c.detail?.contains("(_ g: Int)") ?? false, "self-labeled: got \(c.detail ?? "nil")")
  }

  // MARK: - Argument labels in the menu

  func testFunctionLabelsShowArgumentLabels() async throws {
    // A function's menu label spells the call's argument labels (`_` for an unlabeled position);
    // the filter text stays the bare name so prefix matching is unaffected.
    let source = try MarkedSource(
      """
      public fun f(x: Int, _ y: Int) {}
      public fun g() {}

      public fun main() {
        let _ = 0️⃣
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])

    let f = try XCTUnwrap(items.first { itemName($0) == "f" }, labels(items))
    XCTAssertEqual(f.label, "f(_:y:)")
    XCTAssertEqual(f.filterText, "f")
    let g = try XCTUnwrap(items.first { itemName($0) == "g" }, labels(items))
    XCTAssertEqual(g.label, "g()")
  }

  func testLabelDetailsClientGetsSignatureInLabelDetails() async throws {
    // A client that declares `labelDetailsSupport` gets a bare label with the call signature in
    // `labelDetails` instead of embedded in the label; disambiguating types move with it.
    // Non-callable items are unaffected. (The default test context declares no support, so every
    // other test exercises the embedded-label fallback.)
    let detailed = try await LSPTestContext.make(
      tag: "CompletionTests.labelDetails", rootUri: "file:///test",
      supportsCompletionLabelDetails: true)
    let source = try MarkedSource(
      """
      public struct A { public memberwise init }
      public struct B { public memberwise init }

      public fun f(_ x: A) {}
      public fun f(_ x: B) {}

      public fun main() {
        let v = A()
        let _ = 0️⃣
      }
      """)
    let uri = try await detailed.openDocument(source)
    let items = try await detailed.completion(uri: uri, at: source.markers[0])

    let overloads = items.filter { itemName($0) == "f" }
    XCTAssertEqual(overloads.map(\.label), ["f", "f"], labels(items))
    XCTAssertEqual(
      Set(overloads.compactMap(\.labelDetails?.detail)), ["(x: A)", "(x: B)"], labels(items))

    let variable = try XCTUnwrap(items.first { itemName($0) == "v" }, labels(items))
    XCTAssertNil(variable.labelDetails, "a non-callable item carries no label details")
    XCTAssertEqual(variable.label, "v")
  }

  func testCollidingOverloadLabelsShowDifferingParameterTypes() async throws {
    // Overloads whose labels collide additionally show the types at the positions where they
    // differ — and only at those positions.
    let source = try MarkedSource(
      """
      public struct A { public memberwise init }
      public struct B { public memberwise init }

      public fun f(_ x: A) {}
      public fun f(_ x: B) {}
      public fun g(_ x: A, _ y: A) {}
      public fun g(_ x: A, _ y: B) {}

      public fun main() {
        let _ = 0️⃣
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])

    let fLabels = Set(items.filter { itemName($0) == "f" }.map(\.label))
    XCTAssertEqual(fLabels, ["f(x: A)", "f(x: B)"], labels(items))
    let gLabels = Set(items.filter { itemName($0) == "g" }.map(\.label))
    XCTAssertEqual(gLabels, ["g(x:, y: A)", "g(x:, y: B)"], labels(items))
  }

  // MARK: - Comments and string literals

  func testNoCompletionInsideLineComment() async throws {
    let source = try MarkedSource(
      """
      public fun main() {
        // e.g.0️⃣
        let x = 1
        _ = x
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    XCTAssertTrue(items.isEmpty, "no completion inside a line comment. \(labels(items))")
  }

  func testNoCompletionInsideBlockComment() async throws {
    let source = try MarkedSource(
      """
      public fun main() {
        /* a /* nested */ block.0️⃣ */
        let x = 1
        _ = x
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    XCTAssertTrue(items.isEmpty, "no completion inside a block comment. \(labels(items))")
  }

  func testCompletionAfterClosedComment() async throws {
    // The suppression must not extend past the end of a terminated comment.
    let source = try MarkedSource(
      """
      public fun main() {
        /* comment */ let apple = 1
        let _ = 0️⃣
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    assertContains(items, ["apple"], context: "completion after a closed comment")
  }

  // String literals cannot be exercised end-to-end (the frontend does not type-check them yet
  // and traps on any document containing one), so the scanner is tested directly.

  func testScannerDetectsStringLiterals() {
    XCTAssertTrue(isInsideIgnored(#"let s = "file." + x"#, atOffset: 14), "inside the literal")
    XCTAssertFalse(isInsideIgnored(#"let s = "file." + x"#, atOffset: 15), "right after the literal")
    XCTAssertFalse(isInsideIgnored(#"let s = "file." + x"#, atOffset: 19), "past the literal")
    XCTAssertTrue(
      isInsideIgnored(#"let s = "a\"b." + x"#, atOffset: 14), "an escaped quote does not terminate")
    XCTAssertTrue(
      isInsideIgnored(#"let s = "unterminated"#, atOffset: 21),
      "an unterminated literal extends to the end")
  }

  func testScannerDetectsComments() {
    XCTAssertTrue(isInsideIgnored("// e.g. x\ny", atOffset: 8), "inside a line comment")
    XCTAssertFalse(isInsideIgnored("// e.g. x\ny", atOffset: 10), "the next line is code")
    XCTAssertTrue(isInsideIgnored("/* a /* b */ c */ x", atOffset: 9), "inside a nested block comment")
    XCTAssertTrue(isInsideIgnored("/* a /* b */ c */ x", atOffset: 14), "between nested closers")
    XCTAssertFalse(isInsideIgnored("/* a /* b */ c */ x", atOffset: 18), "after the block comment")
    XCTAssertTrue(
      isInsideIgnored("/* unterminated x", atOffset: 16),
      "an unterminated comment extends to the end")
  }

  /// Returns `true` iff the scanner classifies the position `offset` characters into `text` as
  /// inside a comment or string literal.
  private func isInsideIgnored(_ text: String, atOffset offset: Int) -> Bool {
    let source = SourceFile(stringLiteral: text)
    let t = source.text
    return isInCommentOrStringLiteral(source, at: t.index(t.startIndex, offsetBy: offset))
  }

  // MARK: - Namespace qualification

  func testBuiltinMemberCompletionIsMarkedIncomplete() async throws {
    // `Builtin`'s members (machine types, literal types, intrinsics) are recognized by name
    // rather than declared, so they cannot be enumerated. The empty result must be marked
    // incomplete so the client re-queries instead of caching the emptiness.
    let source = try MarkedSource(
      """
      public fun main() {
        let _ = Builtin.0️⃣
      }
      """)
    let uri = try await context.openDocument(source)
    let list = try await context.completionList(uri: uri, at: source.markers[0])
    XCTAssertTrue(
      list.items.isEmpty, "builtin members cannot be enumerated, got \(list.items.map(\.label))")
    XCTAssertTrue(list.isIncomplete, "an unenumerable result must be marked incomplete")
  }

  func testModuleNamespaceMembersAreItsTopLevelDeclarations() async throws {
    // A module namespace offers the module's top-level declarations. Exercised directly on the
    // enumeration because the frontend currently rejects an explicit `import Hylo`, so a
    // module-qualified name cannot be typed end-to-end yet.
    let source = try MarkedSource(
      """
      public fun main() {
        let _ = 0️⃣
      }
      """)
    let uri = try await context.openDocument(source)
    let document = try await context.documentProvider.getDocumentContext(
      at: AbsoluteURL(fromUrlString: uri.absoluteString))
    var program = document.program
    let stdlib = try XCTUnwrap(program.identity(module: Module.standardLibraryName))
    let list = program.namespaceMemberCompletions(of: Namespace(identifier: .module(stdlib)))
    assertContains(
      list.items, ["Int", "Bool", "precondition"], context: "top-level declarations of a module")
  }

  // MARK: - Standard-library documents

  func testCompletionInStandardLibraryDocument() async throws {
    // A document under a directory recognized as a standard-library root (an ancestor contains
    // Core/Void.hylo) is compiled as part of the library itself. Completion must still honor the
    // in-memory contents — the sentinel splice happens in the library build.
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
      .appendingPathComponent("HyloFakeStdlib-\(UUID().uuidString)")
      .resolvingSymlinksInPath()
    try fileManager.createDirectory(
      at: root.appendingPathComponent("Core"), withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }

    try "public struct Marker { public memberwise init }".write(
      to: root.appendingPathComponent("Core/Void.hylo"), atomically: true, encoding: .utf8)

    let source = try MarkedSource(
      """
      public struct Box {
        public memberwise init
        public fun get() { }
      }

      public fun test() {
        let b = Box()
        let _ = b.0️⃣
      }
      """)
    let documentURL = root.appendingPathComponent("Fixture.hylo")
    try source.source.write(to: documentURL, atomically: true, encoding: .utf8)

    let uri = try await context.openDocument(source, uri: documentURL.absoluteString)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    assertContains(items, ["get", "new"], context: "members in a standard-library document")
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

  func testCompletionAtTopLevelFallsBackToFileScope() async throws {
    // The cursor is at top level, outside any declaration body, where the recovered program may have
    // no syntax tree containing it. Completion must still fall back to file-scope lookup and offer
    // the top-level declarations rather than returning nothing.
    let source = try MarkedSource(
      """
      fun helper() -> Int { return 1 }
      struct Widget { public memberwise init }
      0️⃣
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    assertContains(
      items, ["helper", "Widget"], context: "top-level declarations via file-scope fallback")
  }

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

  func testSynthesizedMembersAreFiltered() async throws {
    // Completing on a type with conformances (here `Int`, which conforms to several refined stdlib
    // traits) must not surface the synthesized storage of implicit (`using`/`given`) bindings, e.g.
    // stored conformance witnesses. These are addressed through implicit resolution, not member
    // selection. They happen to be named `$e`/`$f`, which the filtered result must not contain.
    let source = try MarkedSource(
      """
      public fun main() {
        let x = 1
        let _ = x.0️⃣
      }
      """)
    let uri = try await context.openDocument(source)
    let items = try await context.completion(uri: uri, at: source.markers[0])
    let synthesized = items.filter { itemName($0).hasPrefix("$") }
    XCTAssertTrue(
      synthesized.isEmpty, "synthesized members leaked into completion: \(labels(synthesized))")
  }

  // MARK: - Assertion helpers

  /// Returns the name `item` completes: its filter text when set (a function's label carries the
  /// argument labels, e.g. `f(x:)`, while its filter text is the bare `f`), its label otherwise.
  private func itemName(_ item: CompletionItem) -> String {
    item.filterText ?? item.label
  }

  private func labels(_ items: [CompletionItem]) -> String {
    "labels: [\(items.map(\.label).joined(separator: ", "))]"
  }

  private func assertContains(
    _ items: [CompletionItem], _ expected: [String], context: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let present = Set(items.map(itemName))
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
    let present = Set(items.map(itemName))
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

  /// Performs a completion request in the document and returns the full completion list,
  /// including its `isIncomplete` flag.
  public func completionList(uri: URL, at position: Position) async throws -> CompletionList {
    let params = CompletionParams(
      uri: uri.absoluteString, position: position, triggerKind: .invoked, triggerCharacter: nil)
    switch await requestHandler.completion(id: .numericId(1), params: params) {
    case .success(let value):
      guard case .optionB(let list)? = value else {
        throw TestFailure("expected a CompletionList, got \(String(describing: value))")
      }
      return list
    case .failure(let error):
      throw TestFailure(error.message)
    }
  }

}
