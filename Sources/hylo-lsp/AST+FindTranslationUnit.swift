import Foundation
import FrontEnd
import LanguageServerProtocol
import Logging

extension Program {

  public func findTranslationUnit(_ url: AbsoluteUrl, logger: Logger) -> Module.SourceContainer? {
    // todo improve this, it's very inefficient. We should probably cache a mapping from URLs to translation units.
    for (_, module) in modules {
      if let (_, source) = module.sources.first(where: { $0.value.source.name.absoluteUrl == url })
      {
        logger.debug("Found translation unit for url \(url)")
        return source
      }
    }
    logger.debug("Didn't find translation unit matching the url \(url)")
    return nil
  }
}
