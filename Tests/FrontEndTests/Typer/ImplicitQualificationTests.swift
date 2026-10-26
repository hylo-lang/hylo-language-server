import FrontEnd
import XCTest

/// Tests the typing of implicit qualifications.
final class ImplicitQualificationTests: XCTestCase {

  /// Checks that the implicit qualification of an argument has the metatype of the parameter to
  /// which the argument is passed in the selected overload.
  func testArgument() async {
    var p = await Program.withMinimalStandardLibrary()
    let m = p.addUserModule(
      named: "M",
      source: """
        struct A {
          public memberwise init
          public static let k: A = A()
        }

        enum E {
          case a
        }

        fun f(x: A) {}
        fun f(x: E) {}

        fun main() {
          f(.k)
          f(.a)
        }
        """)
    p = await p.typeChecked()
    XCTAssertFalse(p.containsError, "\(p.diagnostics)")

    let qualifications = p.select(from: m, .tag(ImplicitQualification.self))
    XCTAssertEqual(
      qualifications.map({ (q) in p.type(maybeAssignedTo: q).map({ (t) in p.show(t) }) }),
      ["Metatype<A>", "Metatype<E>"])
  }

}
