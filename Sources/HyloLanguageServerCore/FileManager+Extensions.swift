import Foundation

extension FileManager {

  /// Returns the URLs of all non-directory entries under `directory` satisfying `predicate`, in
  /// deterministic order, spelled under `directory`.
  ///
  /// Symlinked subdirectories are not entered; `directory` itself may be a symlink.
  func files(under directory: URL, where predicate: (URL) throws -> Bool) throws -> [URL] {
    // Walked manually: Foundation's URL enumerator resolves symlinks on some platforms, changing
    // the spelling, and its path enumerator does not traverse a symlinked root.
    var files: [URL] = []
    var directories = [directory]
    while let d = directories.popLast() {
      for entry in try contentsOfDirectory(atPath: toNativeSeparators(d.path)).sorted() {
        let url = d.appendingPathComponent(entry)
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        // The conjunction is symlink-safe on every platform: `isDirectory` follows symlinks on
        // some and uses the link itself on others.
        if values?.isDirectory == true && values?.isSymbolicLink != true {
          directories.append(url)
        } else if try predicate(url) {
          files.append(url)
        }
      }
    }
    return files
  }

}
