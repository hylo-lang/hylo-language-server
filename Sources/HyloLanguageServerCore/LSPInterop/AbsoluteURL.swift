import FrontEnd

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Represents a URL that's guaranteed to be absolute.
///
/// In case of file:// scheme, the url is normalized to be absolute and start with file:///
public struct AbsoluteURL: Sendable, Hashable, CustomStringConvertible {

  let url: URL

  /// Creates an AbsoluteUrl from a native path.
  ///
  /// If the path is not absolute, it will be interpreted relative to the current working directory.
  public init(fromPath path: String) {
    precondition(path.firstRange(of: "://") == nil)
    // TODO: avoid standardizedFileURL, it's doing file access
    self.url = URL(fileURLWithPath: path).standardizedFileURL
  }

  /// Creates an instance from `urlString`.
  ///
  /// - Throws iff `urlString` is not an absolute URL naming a file.
  public init(fromUrlString urlString: String) throws {
    guard let url = URL(string: urlString), url.scheme != nil else {
      throw LSPError.invalidParameter(message: "Invalid URL string: \(urlString)")
    }
    // The first path component is `/`; the frontend traps on a source name without a file.
    guard url.pathComponents.count > 1 else {
      throw LSPError.invalidParameter(message: "URL names no file: \(urlString)")
    }
    self.init(url.absoluteURL)
  }

  // Requires `url` to have a scheme
  public init(_ url: URL) {
    precondition(url.scheme != nil)
    self.url = url.absoluteURL
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

}

/// Converts path component separators to their native version.
func toNativeSeparators(_ path: String) -> String {
  #if os(Windows)
    path.replacingOccurrences(of: "/", with: "\\")
  #else
    path
  #endif
}
