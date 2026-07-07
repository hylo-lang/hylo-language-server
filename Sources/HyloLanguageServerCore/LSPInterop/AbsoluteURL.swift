import Foundation
import FrontEnd

/// An absolute URL in canonical spelling.
///
/// Local file URLs are normalized on construction: `.` and `..` path components are collapsed,
/// percent-encoding is normalized, and the Windows drive letter is lowercased. Normalization is a
/// pure function of the URL — the file system is never consulted and symlinks are not resolved —
/// so identity is the normalized spelling, uniformly on every platform. URLs of other schemes,
/// file URLs with a remote host, and file URLs carrying a query or fragment are only made
/// absolute.
///
/// A file URL is representable iff its path percent-decodes to a non-empty string, contains no
/// percent-encoded path separator, and its `..` components do not escape the root.
public struct AbsoluteURL: Sendable, Hashable, CustomStringConvertible {

  let url: URL

  /// Creates an instance from a native path, interpreted relative to the current working
  /// directory if not absolute.
  ///
  /// - Requires: `path` is not a URL string and is representable.
  public init(fromPath path: String) {
    precondition(!path.contains("://"))
    self.init(URL(fileURLWithPath: path))
  }

  /// Creates an instance from a URL string.
  ///
  /// - Throws: `LSPError.invalidParameter` iff `urlString` is not a URL with a scheme or is not
  ///   representable.
  public init(fromUrlString urlString: String) throws {
    guard let url = URL(string: urlString), url.scheme != nil else {
      throw LSPError.invalidParameter(message: "Invalid URL string: \(urlString)")
    }
    try self.init(validating: url)
  }

  /// Creates an instance from a server-constructed URL.
  ///
  /// - Requires: `url` has a scheme and is representable.
  public init(_ url: URL) {
    do {
      try self.init(validating: url)
    } catch {
      preconditionFailure("Invalid URL: \(url)")
    }
  }

  /// Creates an instance from `url`, canonicalizing it.
  ///
  /// - Throws: `LSPError.invalidParameter` iff `url` has no scheme or is not representable.
  public init(validating url: URL) throws {
    self.url =
      if url.scheme != nil {
        try Self.canonicalized(url)
      } else {
        throw LSPError.invalidParameter(message: "URL without a scheme: \(url)")
      }
  }

  /// Creates an instance from a URL already in canonical spelling, skipping normalization.
  ///
  /// - Requires: `url` was produced by `AbsoluteURL`.
  init(fromCanonical url: URL) {
    self.url = url
  }

  /// The absolute native path.
  public var nativePath: String {
    toNativeSeparators(url.path)
  }

  /// The absolute URL as a string.
  public var description: String {
    url.absoluteString
  }

  /// The identifier for the corresponding file in Hylo front-end.
  public var localFileName: FileName {
    .local(url)
  }

  /// Returns the canonical spelling of `url`.
  ///
  /// - Throws: `LSPError.invalidParameter` iff `url` is not representable.
  private static func canonicalized(_ url: URL) throws -> URL {
    let u = url.absoluteURL
    guard u.isFileURL, u.query == nil, u.fragment == nil,
      u.host == nil || u.host?.isEmpty == true || u.host == "localhost"
    else {
      return u
    }
    let decoded = u.path
    guard !decoded.isEmpty, !decoded.lowercased().contains("%2f") else {
      throw LSPError.invalidParameter(message: "URL does not denote a representable path: \(u)")
    }
    var path = try lexicallyStandardized(decoded)
    #if os(Windows)
      path = lowercasingDriveLetter(path)
    #endif
    return URL(fileURLWithPath: path, isDirectory: false)
  }

  /// Returns `path` with `.` and `..` components collapsed.
  ///
  /// - Throws: `LSPError.invalidParameter` iff a `..` component escapes the root or the Windows
  ///   drive.
  private static func lexicallyStandardized(_ path: String) throws -> String {
    // Identity must not depend on disk state; `standardizedFileURL` consults the file system on
    // Darwin (it strips `/private` from paths that exist).
    let isAbsolute = path.hasPrefix("/")
    var components: [Substring] = []
    for c in path.split(separator: "/") {
      switch c {
      case ".":
        continue
      case "..":
        if components.isEmpty || (components.count == 1 && isDriveComponent(components[0])) {
          throw LSPError.invalidParameter(message: "Path escapes its root: \(path)")
        } else {
          components.removeLast()
        }
      default:
        components.append(c)
      }
    }
    return (isAbsolute ? "/" : "") + components.joined(separator: "/")
  }

  /// Returns `true` iff `component` spells a Windows drive, e.g. `c:`.
  private static func isDriveComponent(_ component: Substring) -> Bool {
    component.count == 2 && component.last == ":" && component.first?.isASCII == true
      && component.first?.isLetter == true
  }

  #if os(Windows)
    /// Returns `path` with its drive letter lowercased.
    private static func lowercasingDriveLetter(_ path: String) -> String {
      // Lowercase matches the drive-letter spelling VS Code uses in its URIs.
      var s = Array(path)
      let i = (s.first == "/") ? 1 : 0
      if s.count > i + 1, s[i + 1] == ":", s[i].isASCII, s[i].isUppercase {
        s[i] = Character(s[i].lowercased())
        return String(s)
      }
      return path
    }
  #endif

}

/// Converts path component separators to their native version.
func toNativeSeparators(_ path: String) -> String {
  #if os(Windows)
    path.replacingOccurrences(of: "/", with: "\\")
  #else
    path
  #endif
}
