import FrontEnd
import LanguageServerProtocol
import Foundation
import Logging

#if definitionResolverMigrated
struct DefinitionResolver {
  let logger: Logger

  public init(logger: Logger) {
    self.logger = logger
  }


  public func nameRange(of d: AnyDeclID, in program: Program) -> SourceSpan? {
    // if let e = self.ast[d] as? SingleEntityDecl { return Name(stem: e.baseName) }

    switch d.kind {
    case FunctionDecl.self:
      return program[FunctionDecl.ID(d)!].identifier!.site
    case InitializerDecl.self:
      return program[InitializerDecl.ID(d)!].site
    case MethodImpl.self:
      return program[MethodDecl.ID(d)!].identifier.site
    case SubscriptImpl.self:
      return program[SubscriptDecl.ID(d)!].site
    case VarDecl.self:
      return program[VarDecl.ID(d)!].identifier.site
    case ParameterDecl.self:
      return program[ParameterDecl.ID(d)!].identifier.site
    default:
      return nil
    }
  }


  func locationLink<T>(_ d: T, in program: Program) -> LocationLink where T: NodeIDProtocol {
    let range = program[d].site
    let targetUri = range.file.url
    var selectionRange = LSPRange(range)

    if let d = AnyDeclID(d) {
      selectionRange = LSPRange(nameRange(of: d, in: program) ?? range)
    }

    return LocationLink(targetUri: targetUri.absoluteString, targetRange: LSPRange(range), targetSelectionRange: selectionRange)
  }

  func locationResponse<T>(_ d: T, in program: Program) -> DefinitionResponse where T: NodeIDProtocol{
    let location = locationLink(d, in: program)
    return .optionC([location])
  }


  func resolveName(_ id: NameExpr.ID, source: AnySyntaxIdentity, in program: Program) -> DefinitionResponse? {
    if let d = program.referredDecl[id] {
      switch d {
      case let .constructor(d, _):
        let initializer = program[d]
        let range = program[d].site
        let selectionRange = LSPRange(initializer.introducer.site)
        let response = LocationLink(targetUri: range.file.url.absoluteString, targetRange: LSPRange(range), targetSelectionRange: selectionRange)
        return .optionC([response])
      case let .builtinFunction(f):
        logger.warning("builtinFunction: \(f)")
        return nil
      case .compilerKnownType:
        logger.warning("compilerKnownType: \(d)")
        return nil
      case let .member(m, _, _):
        return locationResponse(m, in: program)
      case let .direct(d, args):
        logger.debug("direct declaration: \(d), generic args: \(args), name: \(program.name(of: d) ?? "__noname__")")
        // let fnNode = program[d]
        // let range = LSPRange(hylocRange: fnNode.site)
        return locationResponse(d, in: program)
        // if let fid = FunctionDecl.ID(d) {
        //   let f = sourceModule.functions[Function.ID(fid)]!
        //   logger.debug("Function: \(f)")
        // }
      default:
        logger.warning("Unknown declaration kind: \(d)")
        break
      }
    }

    if let r = resolveExpr(AnyExprID(id)) {
      return r
    }

    if let x = AnyPatternID(source) {
      logger.debug("pattern: \(x)")
    }

    if let s = program.nodeToScope[source] {
      logger.debug("scope: \(s)")
      if let decls = program.scopeToDecls[s] {
        for d in decls {
            if let t = program.declType[d] {
              logger.debug("decl: \(d), type: \(t)")
            }
        }
      }


      if let fn = program[s] as? FunctionDecl {
        logger.debug("TODO: Need to figure out how to get resolved return type of function signature: \(fn.site)")
        return nil
        // return .failure(JSONRPCResponseError(code: ErrorCodes.InternalError, message: "TODO: Need to figure out how to get resolved return type of function signature: \(fn.site)"))
      }
    }

    // return .failure(JSONRPCResponseError(code: ErrorCodes.InternalError, message: "Internal error, must be able to resolve declaration"))
    logger.error("Internal error, must be able to resolve declaration")
    return nil
  }

  func resolveExpr(_ id: AnyExprID, in program: Program) -> DefinitionResponse? {
    if let t = program.exprType[id] {
      switch t.base {
      case let u as ProductType:
        return locationResponse(u.decl, in: program)
      case let u as TypeAliasType:
        return locationResponse(u.decl, in: program)
      case let u as AssociatedTypeType:
        return locationResponse(u.decl, in: program)
      case let u as GenericTypeParameterType:
        return locationResponse(u.decl, in: program)
      case let u as NamespaceType:
        return locationResponse(u.decl, in: program)
      case let u as TraitType:
        return locationResponse(u.decl, in: program)
      default:
        logger.warning("Unknown expression type: \(t)")
        return nil
      }
    }

    return nil
  }


  public func resolve(_ p: SourcePosition, in program: Program) -> DefinitionResponse? {
      logger.debug("Look for symbol definition at position: \(p)")
      guard let id = program.findInnermostTree(containing: p, reportingDiagnosticsTo: logger) else {
      logger.warning("Did not find node @ \(p)")
      return nil
    }

    let node = program[id]
    logger.debug("Found node: \(node), id: \(id)")

    if let d = AnyDeclID(id) {
      return locationResponse(d, in: program)
    }

    if let ex = node as? FunctionCallExpr {
      if let n = NameExpr.ID(ex.callee) {
        return resolveName(n, source: id)
      }
    }

    if let n = NameExpr.ID(id) {
      return resolveName(n, source: id)
    }

    logger.warning("Unknown node: \(node)")
    return nil
  }

}
#endif