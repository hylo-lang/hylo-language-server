import Foundation

/// Represents a URL that's guaranteed to be absolute.
///
/// In case of file:// scheme, the url is normalized to be absolute and start with file:///
public struct AbsoluteUrl: Sendable, Hashable, CustomStringConvertible {
  let url: URL

  /// Creates an AbsoluteUrl from a native path.
  ///
  /// If the path is not absolute, it will be interpreted relative to the current working directory.
  public init(fromPath path: String) {
    precondition(!path.contains("://"))
    // TODO: avoid standardizedFileURL, it's doing file access
    self.url = URL(fileURLWithPath: path).standardizedFileURL
  }

  /// Creates an AbsoluteUrl from a URL string.
  public init?(fromUrlString urlString: String) {
    guard let url = URL(string: urlString), url.scheme != nil else {
      return nil
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
}

/// Converts path component separators to their native version.
func toNativeSeparators(_ path: String) -> String {
  #if os(Windows)
    path.replacingOccurrences(of: "/", with: "\\")
  #else
    path
  #endif
}
