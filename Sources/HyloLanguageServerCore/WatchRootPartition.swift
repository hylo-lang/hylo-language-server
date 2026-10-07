import Foundation

/// The canonical spelling under which a directory is both watched and compared for coverage:
/// symlink-resolved, `.`/`..` collapsed, `/`-separated, and drive-lowercased on Windows.
///
/// Symlink resolution matches how source roots are already spelled (`resolvingSymlinksInPath`),
/// so folder roots and plan roots meet in one namespace; the funnel re-resolves event paths to
/// the same namespace before comparing them to disk keys.
///
/// Returns `nil` for a URL that does not denote a representable local path.
func canonicalWatchRoot(_ url: URL) -> String? {
  (try? AbsoluteURL(validating: url.resolvingSymlinksInPath()))?.canonicalPath
}

/// Returns the elements of `roots` that no directory in `folders` covers.
///
/// When the client watches the workspace folders (dynamic `workspace/didChangeWatchedFiles`
/// registration), the server-side watcher only needs the roots falling outside every folder —
/// typically the bundled standard library and externally discovered package roots.
///
/// A folder covers a root iff the root is the folder itself or lies beneath it. Both sides are
/// compared in `canonicalWatchRoot` spelling; comparison ignores trailing separators, and on
/// Windows (a case-insensitive file system) it ignores case. Runs in time proportional to
/// `roots.count * folders.count`.
func uncoveredWatchRoots(among roots: Set<String>, coveredBy folders: [String]) -> Set<String> {
  let normalizedFolders = folders.map { (f) in caseFolded(withoutTrailingSeparators(f)) }
  return roots.filter { (root) in
    let r = caseFolded(withoutTrailingSeparators(root))
    return !normalizedFolders.contains { (f) in
      r == f || r.hasPrefix(f.hasSuffix("/") ? f : f + "/")
    }
  }
}

/// Returns `path` without trailing path separators, preserving a lone root separator.
private func withoutTrailingSeparators(_ path: String) -> String {
  var p = Substring(path)
  while p.count > 1, p.hasSuffix("/") { p.removeLast() }
  return String(p)
}

/// Returns `path` folded to the case its file system compares under: lowercased on Windows,
/// unchanged on POSIX (where paths are case-sensitive).
private func caseFolded(_ path: String) -> String {
  #if os(Windows)
    path.lowercased()
  #else
    path
  #endif
}
