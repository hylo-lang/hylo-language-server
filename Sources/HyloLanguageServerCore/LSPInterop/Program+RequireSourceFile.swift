import FrontEnd
import LanguageServerProtocol

extension Program {

  /// Returns the source file id at `location`, or throws if the file is not found.
  func requireSourceFile(at location: AbsoluteURL) throws -> SourceFile.ID {
    if let s = self.sourceFile(named: location.localFileName) {
      return s
    } else {
      throw LSPError.internalError(
        message: "Failed to locate source file: \(location)")
    }
  }

}
