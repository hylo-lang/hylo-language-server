import Foundation
import FrontEnd
import LanguageServerProtocol
import Logging

extension Program {

  public func findSourceContainer(_ url: AbsoluteUrl, logger: Logger) -> Module.SourceContainer? {
    // todo improve this, it's very inefficient. We should probably cache a mapping from URLs to translation units.
    for (_, module) in modules {
      if let (_, source) = module.sources.first(where: {
        return $0.value.source.name.absoluteUrl == url
      }) {
        return source
      }
    }
    logger.debug("Didn't find source container matching the url \(url)")
    return nil
  }

  public func findModuleContaining(sourceUrl url: AbsoluteUrl, logger: Logger) -> Module.ID? {
    for (moduleId, (_, module)) in modules.enumerated() {
      if module.sources.contains(where: {
        return $0.value.source.name.absoluteUrl == url
      }) {
        return moduleId
      }
    }
    return nil
  }
}
