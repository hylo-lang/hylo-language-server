import FrontEnd

// See https://github.com/swiftlang/swift/issues/75601
@preconcurrency import func Foundation.exit
@preconcurrency import func Foundation.fputs
@preconcurrency import var Foundation.stderr
@preconcurrency import struct Foundation.URL

/// A minimal test runner verifying that the compiler's front-end works.
///
/// This is needed in the WASM target, where XCTest is not available.
///
/// The only argument is the path of a directory containing the standard library's sources.
@main
struct FrontEndSmokeTest {

  static func main() async throws {
    guard CommandLine.arguments.count == 2 else {
      fputs("usage: frontend-smoke-test <standard-library-sources>\n", stderr)
      exit(2)
    }

    var p = Program(forTesting: true)

    let s = p.demandModule(Module.standardLibraryName)
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try SourceFile.forEach(in: root) { (f) in
      _ = p[s].addSource(f)
    }

    let m = p.demandModule(.init("Test"))
    p[m].addDependency(Module.standardLibraryName)
    _ = p[m].addSource(
      """
      fun use<T>(x: T) {}

      public fun main() {
        var x = 40
        &x = x + 2
        use(x == 42)
      }
      """)

    for m in p.moduleIdentities {
      await p.assignScopes(m)
    }
    for m in p.moduleIdentities {
      p.assignTypes(m, loggingInferenceWhere: nil)
    }
    for m in p.moduleIdentities {
      p.applyTransformationPasses(m)
    }

    let ds = Array(p.diagnostics)
    if !ds.isEmpty {
      print("FAILURE: \(ds.count) diagnostic(s) reported: \(ds.descriptions(joinedBy: "\n"))")
      exit(1)
    }
  }

}
