import Foundation
import XCTest

@testable import FrontEnd

/// Not committed: dumps random programs for differential testing when HYLO_DUMP_RANDOM is set to
/// an output directory. Each program gets a directory with `lib.hylo`, `main0.hylo`, `main1.hylo`,
/// and `merged.d/` (the three files in one module); a second directory `<seed>s` has selections
/// and unqualified uses of every identifier appended to the body of `use`.
final class DumpRandomPrograms: XCTestCase {

  func testDump() async throws {
    guard let out = ProcessInfo.processInfo.environment["HYLO_DUMP_RANDOM"] else { return }
    let count = Int(ProcessInfo.processInfo.environment["HYLO_DUMP_COUNT"] ?? "200")!
    for seed in 0 ..< UInt64(count) {
      let p = RandomProgram(seed: seed)
      try write(p, statements: [], to: "\(out)/\(seed)")

      let identifiers = await p.typeChecked().0.identifiers.sorted()
      // Identifiers are quoted so that synthesized ones (e.g., `$2`) are parsed.
      var statements: [String] = identifiers.map({ (n) in "let _ = `\(n)`" })
      for x in p.qualifications {
        for n in identifiers {
          statements.append("let _ = \(x).`\(n)`")
          for k in ["let", "inout", "set", "sink"] {
            statements.append("let _ = \(x).`\(n)`@\(k)")
          }
        }
      }
      try write(p, statements: statements, to: "\(out)/\(seed)s")
    }
  }

  /// Writes the sources of `p` with `statements` appended to `use` in `dir`.
  private func write(_ p: RandomProgram, statements: [String], to dir: String) throws {
    let fm = FileManager.default
    try fm.createDirectory(atPath: dir + "/merged.d", withIntermediateDirectories: true)
    let s = p.sources(using: statements)
    try p.library.write(toFile: dir + "/lib.hylo", atomically: true, encoding: .utf8)
    try s[0].write(toFile: dir + "/main0.hylo", atomically: true, encoding: .utf8)
    try s[1].write(toFile: dir + "/main1.hylo", atomically: true, encoding: .utf8)
    try p.library.write(toFile: dir + "/merged.d/lib.hylo", atomically: true, encoding: .utf8)
    let m0 = s[0].replacingOccurrences(of: "import Lib\n", with: "")
    try m0.write(toFile: dir + "/merged.d/main0.hylo", atomically: true, encoding: .utf8)
    try s[1].write(toFile: dir + "/merged.d/main1.hylo", atomically: true, encoding: .utf8)
  }

}
