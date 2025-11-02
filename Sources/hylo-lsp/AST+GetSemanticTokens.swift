import Foundation
import FrontEnd
import LanguageServerProtocol
import Logging

struct SemanticTokensWalker {
  public let document: DocumentUri
  public let translationUnit: Module.SourceContainer
  public let program: Program
  private let logger: Logger
  private(set) var tokens: [SemanticToken]

  public init(
    document: DocumentUri, translationUnit: Module.SourceContainer, program: Program, logger: Logger
  ) {
    self.document = document
    self.translationUnit = translationUnit
    self.program = program
    self.tokens = []
    self.logger = logger
  }

  public mutating func walk() -> [SemanticToken] {
    precondition(tokens.isEmpty)
    logger.debug("Walking \(translationUnit.topLevelDeclarations.count) top-level declarations")
    addMemberDeclarations(translationUnit.topLevelDeclarations)
    logger.debug("Generated \(tokens.count) semantic tokens")
    return tokens
  }

  mutating func addMemberDeclarations(_ members: [DeclarationIdentity]) {
    logger.debug("Processing \(members.count) member declarations")
    for (index, m) in members.enumerated() {
      logger.debug("Processing member \(index + 1)/\(members.count): \(m)")
      addSyntax(syntaxId: m.erased)
    }
  }

  mutating func addSyntax(syntaxId: AnySyntaxIdentity) {
    addSyntax(program[syntaxId])
  }

  mutating func addSyntax(_ syntax: any Syntax) {
    let syntaxType = type(of: syntax)
    logger.debug("Processing syntax: \(syntaxType)")

    switch syntax {
    // Declarations:
    case let d as AssociatedTypeDeclaration:
      addAssociatedType(d)
    case let d as BindingDeclaration:
      addBinding(d)
    case let d as ConformanceDeclaration:
      addConformance(d)
    case let d as EnumCaseDeclaration:
      addEnumCase(d)
    case let d as EnumDeclaration:
      addEnum(d)
    case let d as ExtensionDeclaration:
      addExtension(d)
    case let d as FunctionBundleDeclaration:
      addFunctionBundle(d)
    case let d as FunctionDeclaration:
      addFunction(d)
    case let d as GenericParameterDeclaration:
      addGenericParameter(d)
    case let d as ImportDeclaration:
      addImport(d)
    case let d as StructDeclaration:
      addStruct(d)
    case let d as TraitDeclaration:
      addTrait(d)
    case let d as TypeAliasDeclaration:
      addTypeAlias(d)
    case _ as VariableDeclaration:
      // NOTE: VariableDeclaration is handled by BindingDeclaration, which allows binding one or more variables
      break
    case let d as VariantDeclaration:
      addVariant(d)

    // Statements:
    case let s as Assignment:
      addAssignment(s)
    case let s as Block:
      addBlock(s)
    case let s as Discard:
      addDiscard(s)
    case let s as Return:
      addReturn(s)

    // Expressions:
    case let e as ArrowExpression:
      addArrowExpression(e)
    case let e as BooleanLiteral:
      addBooleanLiteral(e)
    case let e as Call:
      addCall(e)
    case let e as Conversion:
      addConversion(e)
    case let e as EqualityWitnessExpression:
      addEqualityWitnessExpression(e)
    case let e as If:
      addIf(e)
    case let e as ImplicitQualification:
      addImplicitQualification(e)
    case let e as InoutExpression:
      addInoutExpression(e)
    case let e as IntegerLiteral:
      addIntegerLiteral(e)
    case let e as KindExpression:
      addKindExpression(e)
    case let e as Lambda:
      addLambda(e)
    case let e as NameExpression:
      addNameExpression(e)
    case let e as New:
      addNew(e)
    case let e as PatternMatch:
      addPatternMatch(e)
    case let e as PatternMatchCase:
      addPatternMatchCase(e)
    case let e as RemoteTypeExpression:
      addRemoteTypeExpression(e)
    case let e as StaticCall:
      addStaticCall(e)
    case let e as StringLiteral:
      addStringLiteral(e)
    case let e as SynthethicExpression:
      addSyntheticExpression(e)
    case let e as TupleLiteral:
      addTupleLiteral(e)
    case let e as TupleTypeExpression:
      addTupleTypeExpression(e)
    case let e as WildcardLiteral:
      addWildcardLiteral(e)

    // Patterns:
    case let p as BindingPattern:
      addBindingPattern(p)
    case let p as ExtractorPattern:
      addExtractorPattern(p)
    case let p as TuplePattern:
      addTuplePattern(p)

    default:
      logger.warning("Unknown syntax node type: \(type(of: syntax)) - \(syntax)")
    // printStackTrace()
    }
  }

  mutating func addCaptureList(_ d: CaptureList) {
    // todo
  }

  mutating func addEnum(_ d: EnumDeclaration) {
    // todo
  }

  mutating func addImport(_ d: ImportDeclaration) {
    addKeywordIntroducer(site: d.introducer.site)
    addToken(range: d.identifier.site, type: TokenType.namespace)
  }

  mutating func addVariant(_ d: VariantDeclaration) {
    addKeywordIntroducer(site: d.effect.site)
    // todo: add body if present
    if d.body != nil {
      // addStatements(body)
    }
  }

  mutating func addEnumCase(_ d: EnumCaseDeclaration) {
    addKeywordIntroducer(site: d.introducer.site)
    addToken(range: d.identifier.site, type: .function)

    for param in d.parameters {
      addParameter(param)
    }

    // addExpr(d.body)
    // todo
  }
  // mutating func addNamespace(_ d: NamespaceDecl) {
  //   addAccessModifier(d.accessModifier)
  //   addIntroducer(d.introducerSite)
  //   addToken(range: d.identifier.site, type: .namespace)

  //   addMembers(d.members)
  // }
  // mutating func addSubscriptImpl(_ s: SubscriptImpl.ID) {
  //   let s = program[s]

  //   // NOTE: introducer + parameter add introducer twice for some reason
  //   addIntroducer(s.introducer)
  //   // addParameter(s.receiver)
  //   addBody(s.body)
  // }

  mutating func addBinding(_ d: BindingDeclaration) {
    // addAttributes(d.attributes)

    // addAccessModifier(d.accessModifier)
    // addIntroducer(d.memberModifier)
    // addBindingPattern(d.pattern)
    // addExpr(d.initializer)
    // todo
  }

  // mutating func addPattern(_ pattern: AnyPatternID) {
  //   let p = program[pattern]

  //   switch p {
  //   case let p as NamePattern:
  //     addToken(range: p.site, type: .variable)
  //   case let p as WildcardPattern:
  //     addIntroducer(p.site)
  //   case let p as BindingPattern:
  //     addIntroducer(p.introducer)
  //     addPattern(p.subpattern)
  //     addExpr(p.annotation)
  //   case let p as TuplePattern:
  //     for e in p.elements {
  //       if let label = e.label {
  //         addToken(range: label.site, type: .label)
  //       }

  //       addPattern(e.pattern)
  //     }

  //   default:
  //     logger.debug("Unknown pattern: \(p)")
  //   }
  // }

  mutating func addToken(range: SourceSpan, type: TokenType, modifiers: UInt32 = 0) {
    tokens.append(SemanticToken(range: range, type: type, modifiers: modifiers))
  }

  mutating func addKeywordIntroducer<T>(_ item: Parsed<T>) {
    addKeywordIntroducer(site: item.site)
  }

  mutating func addKeywordIntroducer(site: SourceSpan) {
    addToken(range: site, type: .keyword)
  }

  mutating func addBindingPattern(_ pattern: BindingPattern.ID) {
    let p = program[pattern]
    addKeywordIntroducer(p.introducer)

    // addPattern(p.subpattern)
    // addExpr(p.annotation, typeHint: .type)
    // todo
  }

  // mutating func addAttributes(_ attributes: [SourceRepresentable<Attribute>]) {
  //   for a in attributes {
  //     addAttribute(a.value)
  //   }
  // }

  // mutating func addAttribute(_ attribute: Attribute) {
  //   addToken(range: attribute.name.site, type: .function)

  //   for a in attribute.arguments {
  //     addExpr(a.value)
  //   }
  // }

  mutating func addParameters(_ parameters: [ParameterDeclaration.ID]) {
    for p in parameters {
      addParameter(p)
    }
  }

  mutating func addParameter(_ parameter: ParameterDeclaration.ID) {
    let p = program[parameter]
    // addLabel(p.label)

    // NOTE: We are currently using .identifier instead of .parameter here,
    // for aesthetic purposes. This is similar to swift tokens (todo review)
    addToken(range: p.identifier.site, type: .identifier)

    // todo
    // if let annotation = p.annotation {
    //   let a = program[annotation]
    //   let c = a.convention
    //   if c.site.start != c.site.end {
    //     addIntroducer(c.site)
    //   }

    //   addExpr(a.bareType, typeHint: .type)
    // }

    // addExpr(p.defaultValue)
  }

  #if false
    // https://code.visualstudio.com/api/language-extensions/semantic-highlight-guide#standard-token-types-and-modifiers
    func tokenType(_ d: AnyDeclID) -> TokenType {
      switch d.kind {
      case StructDeclaration.self: .type
      case TypeAliasDeclaration.self: .type
      case AssociatedTypeDeclaration.self: .type
      case ExtensionDeclaration.self: .type
      case ConformanceDeclaration.self: .type
      case GenericParameterDeclaration.self: .typeParameter
      case TraitDeclaration.self: .type
      case FunctionDeclaration.self: .function
      case VariableDeclaration.self: .variable
      case BindingDeclaration.self: .variable
      case ParameterDeclaration.self: .parameter
      case ModuleDeclaration.self: .namespace
      default: .unknown
      }
    }

    func tokenType(_ d: DeclReference?) -> TokenType {
      switch d {
      case .constructor:
        .function
      case .builtinFunction:
        .function
      case .compilerKnownType:
        .type
      case .builtinType:
        .type
      case .direct(let id, _):
        tokenType(id)
      case .member(let id, _, _):
        tokenType(id)
      case .builtinModule:
        .namespace
      case nil:
        .unknown
      }
    }
  #endif

  // mutating func addNameExpr(_ e: NameExpr, typeHint: TokenType?) {
  //   switch e.domain {
  //   case .operand:
  //     logger.debug("TODO: Domain.operand @ \(e.site)")
  //   case .implicit:
  //     // logger.debug("TODO: Domain.implicit @ \(e.site)")
  //     break
  //   case .explicit(let id):
  //     // logger.debug("TODO: Domain.explicit: \(id) @ \(e.site)")
  //     addExpr(id)
  //   case .none:
  //     break
  //   }

  //   // let n = NameExpr.ID(expr)!
  //   // let d = program.referredDecl[n]
  //   // let t = tokenType(d)
  //   // if d != nil && t == .unknown {
  //   //   logger.warning("Unknown decl reference: \(d!)")
  //   // }

  //   let t = typeHint ?? TokenType.variable

  //   addToken(range: e.name.site, type: t)
  //   addTypeArguments(e.arguments)
  // }

  // mutating func addTypeArguments(_ arguments: [LabeledArgument]) {
  //   for a in arguments {
  //     addLabel(a.label)
  //     addExpr(a.value, typeHint: .typeParameter)
  //   }
  // }

  // mutating func addExpr(_ expr: AnyExprID?, typeHint: TokenType? = nil) {
  //   guard let expr = expr else {
  //     return
  //   }

  //   let e = program[expr]
  //   switch e {
  //   case let e as NameExpr:
  //     // addToken(range: e.site, type: .variable)
  //     addNameExpr(e, typeHint: typeHint)
  //   case let e as TupleTypeExpr:

  //     for el in e.elements {

  //       addLabel(el.label)
  //       addExpr(el.type)
  //     }

  //   case let e as BooleanLiteralExpr:
  //     addIntroducer(e.site)
  //   case let e as NumericLiteralExpr:
  //     addToken(range: e.site, type: .number)
  //   case let e as StringLiteralExpr:
  //     addToken(range: e.site, type: .string)

  //   case let e as FunctionCallExpr:
  //     addExpr(e.callee, typeHint: .function)
  //     addArguments(e.arguments)
  //   case let e as SubscriptCallExpr:
  //     addExpr(e.callee, typeHint: .function)
  //     addArguments(e.arguments)
  //   case let e as SequenceExpr:
  //     addExpr(e.head)
  //     for el in e.tail {
  //       let op = program[el.operator]
  //       addToken(range: op.site, type: .operator)
  //       addExpr(el.operand)
  //     }

  //   case let e as LambdaExpr:
  //     addFunction(program[e.decl])

  //   case let e as ConditionalExpr:
  //     addIntroducer(e.introducerSite)
  //     addConditions(e.condition)
  //     addExpr(e.success)
  //     addIntroducer(e.failure.introducerSite)
  //     addExpr(e.failure.value)

  //   case let e as InoutExpr:
  //     addToken(range: e.operatorSite, type: .operator)
  //     addExpr(e.subject, typeHint: typeHint)

  //   case let e as TupleMemberExpr:
  //     addExpr(e.tuple)
  //     addToken(range: e.index.site, type: .number)

  //   case let e as TupleExpr:
  //     for el in e.elements {
  //       addLabel(el.label)
  //       addExpr(el.value)
  //     }

  //   case let e as ArrowTypeExpr:
  //     addIntroducer(e.receiverEffect)
  //     addExpr(e.environment)
  //     for p in e.parameters {
  //       addLabel(p.label)
  //       let pt = program[p.type]
  //       addIntroducer(pt.convention)
  //       addExpr(pt.bareType, typeHint: .type)
  //     }
  //     addExpr(e.output, typeHint: .type)

  //   case let e as MatchExpr:
  //     addIntroducer(e.introducerSite)
  //     addExpr(e.subject)

  //     for c in e.cases {
  //       addMatchCase(c)
  //     }

  //   case let e as CprogramExpr:
  //     addIntroducer(e.introducerSite)
  //     addExpr(e.left)
  //     addExpr(e.right, typeHint: .type)

  //   case _ as WildcardExpr:
  //     break

  //   case let e as ExistentialTypeExpr:
  //     addIntroducer(e.introducerSite)
  //     addConformances(e.traits)
  //     addWhereClause(e.whereClause)

  //   case let e as RemoteTypeExpr:
  //     addIntroducer(e.introducerSite)
  //     addIntroducer(e.convention)
  //     addExpr(e.operand)

  //   case let e as PragmaLiteralExpr:
  //     addToken(range: e.site, type: .identifier)

  //   case let e as ConformanceLensExpr:
  //     addExpr(e.subject, typeHint: .type)
  //     addExpr(e.lens, typeHint: .type)

  //   default:
  //     logger.debug("Unknown expr: \(e)")
  //   }
  // }

  // mutating func addMatchCase(_ matchCase: MatchCase.ID) {
  //   let c = program[matchCase]
  //   addPattern(c.pattern)
  //   addExpr(c.condition)

  //   switch c.body {
  //   case .expr(let e):
  //     addExpr(e)
  //   case .block(let b):
  //     addStatements(b)
  //   }
  // }

  // mutating func addConditions(_ conditions: [ConditionItem]) {
  //   for c in conditions {
  //     switch c {
  //     case .expr(let e):
  //       addExpr(e)
  //     case .decl(let d):
  //       addBinding(program[d])
  //     }
  //   }
  // }

  // mutating func addArguments(_ arguments: [LabeledArgument]) {
  //   for a in arguments {
  //     addLabel(a.label)
  //     addExpr(a.value)
  //   }
  // }

  mutating func addExtension(_ d: ExtensionDeclaration) {
    // addAccessModifier(d.accessModifier)
    // addIntroducer(d.introducerSite)
    // addExpr(d.subject)
    // addWhereClause(d.whereClause)
    // addMembers(d.members)
    // todo
  }

  mutating func addAssociatedType(_ d: AssociatedTypeDeclaration) {
    // addIntroducer(d.introducerSite)
    // addToken(range: d.identifier.site, type: .type)
    // addConformances(d.conformances)
    // addWhereClause(d.whereClause)
    // addExpr(d.defaultValue)
    //todo
  }

  mutating func addTypeAlias(_ d: TypeAliasDeclaration) {
    // addAccessModifier(d.accessModifier)
    // addIntroducer(d.introducerSite)
    // addToken(range: d.identifier.site, type: .type)
    // addGenericClause(d.genericClause)
    // addExpr(d.aliasedType)
    // todo
  }

  mutating func addConformance(_ d: ConformanceDeclaration) {
    // addAccessModifier(d.accessModifier)
    // addIntroducer(d.introducerSite)
    // addExpr(d.subject)
    // addConformances(d.conformances)
    // addWhereClause(d.whereClause)
    // addMembers(d.members)
    // todo
  }

  mutating func addGenericParameter(_ d: GenericParameterDeclaration) {
    // addToken(range: d.identifier.site, type: .typeParameter)
    // addConformances(d.conformances)
    // addExpr(d.defaultValue)
  }

  mutating func addTrait(_ d: TraitDeclaration) {
    // addAccessModifier(d.accessModifier)
    // addIntroducer(d.introducerSite)
    // addToken(range: d.identifier.site, type: .type)
    // addConformances(d.bounds)
    // addMembers(d.members)
    // todo
  }

  mutating func addStruct(_ d: StructDeclaration) {
    // addAccessModifier(d.accessModifier)
    // addIntroducer(d.introducerSite)
    // addToken(range: d.identifier.site, type: .type)
    // addGenericClause(d.genericClause)
    // addConformances(d.conformances)
    // addMembers(d.members)
    // todo
  }

  mutating func addMembers(_ members: [AnySyntaxIdentity]) {
    for m in members {
      addSyntax(syntaxId: m)
    }
  }

  // mutating func addSubscript(_ d: SubscriptDecl) {
  //   addAttributes(d.attributes)
  //   addAccessModifier(d.accessModifier)
  //   addIntroducer(d.memberModifier)
  //   addIntroducer(d.introducer)
  //   if let identifier = d.identifier {
  //     addToken(range: identifier.site, type: .function)
  //   }

  //   addGenericClause(d.genericClause)
  //   addParameters(d.parameters)
  //   addExpr(d.output, typeHint: .type)

  //   for i in d.impls {
  //     addSubscriptImpl(i)
  //   }
  // }

  // mutating func addInitializer(_ d: InitializerDecl) {
  //   addAttributes(d.attributes)
  //   addAccessModifier(d.accessModifier)
  //   addIntroducer(d.introducer)
  //   addGenericClause(d.genericClause)
  //   addParameters(d.parameters)
  //   addStatements(d.body)
  // }

  mutating func addFunction(_ d: FunctionDeclaration) {
    // Add the "fun" keyword
    addKeywordIntroducer(site: d.introducer.site)
    
    // Add function name
    addToken(range: d.identifier.site, type: .function)
    
    // Add parameters
    addParameters(d.parameters)
    
    // Add return type if present
    if let output = d.output {
      addSyntax(syntaxId: output.erased)
    }
    
    // Add body if present
    if let body = d.body {
      for statement in body {
        addSyntax(syntaxId: statement.erased)
      }
    }
  }

  // mutating func addOperator(_ d: OperatorDecl) {
  //   addAccessModifier(d.accessModifier)
  //   addIntroducer(d.introducerSite)
  //   addIntroducer(d.notation)
  //   addIntroducer(d.introducerSite)
  //   addToken(range: d.name.site, type: .operator)

  //   if let precedenceGroup = d.precedenceGroup {
  //     addToken(range: precedenceGroup.site, type: .identifier)
  //   }
  // }

  mutating func addFunctionBundle(_ d: FunctionBundleDeclaration) {
    // addAttributes(d.attributes)
    // addAccessModifier(d.accessModifier)
    // addIntroducer(d.notation)
    // addIntroducer(d.introducerSite)
    // addToken(range: d.identifier.site, type: .function)

    // addGenericClause(d.genericClause)
    // addParameters(d.parameters)
    // addExpr(d.output, typeHint: .type)

    // for i in d.impls {
    //   let i = program[i]
    //   addIntroducer(i.introducer)
    //   // addParameter(i.receiver)
    //   addBody(i.body)
    // }
    // todo
  }

  // mutating func addBody(_ body: FunctionBody?) {
  //   switch body {
  //   case nil:
  //     break
  //   case .expr(let e):
  //     addExpr(e)
  //   case .block(let b):
  //     addStatements(b)
  //   }
  // }

  // mutating func addStatements(_ b: BraceStmt.ID?) {
  //   guard let b = b else {
  //     return
  //   }

  //   addStatements(program[b].stmts)
  // }

  // mutating func addStatements(_ statements: [AnyStmtID]) {
  //   for s in statements {
  //     addStatement(s)
  //   }
  // }

  // mutating func addStatement(_ statement: AnyStmtID?) {
  //   guard let statement = statement else {
  //     return
  //   }

  //   let s = program[statement]

  //   switch s {
  //     case let s as ExprStmt:
  //       addExpr(s.expr)
  //     case let s as ReturnStmt:
  //       addToken(range: s.introducerSite, type: .keyword)
  //       addExpr(s.value)
  //     case let s as DeclStmt:
  //       addSyntax(s.decl)
  //     case let s as WhileStmt:
  //       addIntroducer(s.introducerSite)
  //       addConditions(s.condition)
  //       addStatements(s.body)
  //     case let s as ForStmt:
  //       addIntroducer(s.introducerSite)
  //       addBinding(program[s.binding], skipAccessModifier: true)
  //       addIntroducer(s.domain.introducerSite)
  //       addExpr(s.domain.value)
  //       if let filter = s.filter {
  //         addIntroducer(filter.introducerSite)
  //         addExpr(filter.value)
  //       }
  //       addStatements(s.body)

  //     case let s as DoWhileStmt:
  //       addIntroducer(s.introducerSite)
  //       addStatements(s.body)
  //       addIntroducer(s.condition.introducerSite)
  //       addExpr(s.condition.value)
  //     case let s as AssignStmt:
  //       addExpr(s.left)
  //       addExpr(s.right)
  //     case let s as ConditionalStmt:
  //       addIntroducer(s.introducerSite)
  //       addConditions(s.condition)
  //       addStatements(s.success)
  //       if let elseClause = s.failure {
  //         addIntroducer(elseClause.introducerSite)
  //         addStatement(elseClause.value)
  //       }
  //     case let s as YieldStmt:
  //       addIntroducer(s.introducerSite)
  //       addExpr(s.value)
  //     case let s as BraceStmt:
  //       addStatements(s.stmts)
  //     case let s as DiscardStmt:
  //       addExpr(s.expr)
  //     default:
  //       logger.warning("Unknown statement: \(s)")
  //   }
  // }

  // mutating func addWhereClause(_ whereClause: SourceRepresentable<WhereClause>?) {
  //   guard let whereClause = whereClause else {
  //     return
  //   }

  //   addIntroducer(whereClause.value.introducerSite)

  //   for c in whereClause.value.constraints {
  //     switch c.value {
  //     case .equality(let n, let e):
  //       let n = program[n]
  //       addToken(range: n.site, type: .type)
  //       addExpr(e)
  //     case .bound(let n, _):
  //       let n = program[n]
  //       addToken(range: n.site, type: .type)
  //     case .value(let e):
  //       addExpr(e)
  //     }
  //   }
  // }

  // mutating func addLabel(_ label: SourceRepresentable<Identifier>?) {
  //   if let label = label {
  //     addToken(range: label.site, type: .label)
  //   }
  // }

  // mutating func addAccessModifier(_ accessModifier: SourceRepresentable<AccessModifier>) {
  //   // Check for empty site
  //   if accessModifier.site.start != accessModifier.site.end {
  //     addIntroducer(accessModifier.site)
  //   }
  // }

  // mutating func addConformances(_ conformances: [NameExpr.ID]) {
  //   for id in conformances {
  //     let n = program[id]
  //     addToken(range: n.site, type: .type)
  //   }
  // }

  // mutating func addGenericClause(_ genericClause: SourceRepresentable<GenericClause>?) {
  //   if let genericClause = genericClause {
  //     addGenericClause(genericClause.value)
  //   }
  // }

  // mutating func addGenericClause(_ genericClause: GenericClause) {
  //   addWhereClause(genericClause.whereClause)

  //   for id in genericClause.parameters {
  //     let p = program[id]
  //     addToken(range: p.identifier.site, type: .type)
  //     addConformances(p.conformances)

  //     if let id = p.defaultValue {
  //       let defaultValue = program[id]
  //       addToken(range: defaultValue.site, type: .type)
  //     }
  //   }
  // }

  // MARK: - Statement methods

  mutating func addAssignment(_ s: Assignment) {
    // todo
  }

  mutating func addBlock(_ s: Block) {
    // todo
  }

  mutating func addDiscard(_ s: Discard) {
    // todo
  }

  mutating func addReturn(_ s: Return) {
    if let introducer = s.introducer {
      addKeywordIntroducer(site: introducer.site)
    }
    
    if let value = s.value {
      addSyntax(syntaxId: value.erased)
    }
  }

  // MARK: - Expression methods

  mutating func addArrowExpression(_ e: ArrowExpression) {
    // todo
  }

  mutating func addBooleanLiteral(_ e: BooleanLiteral) {
    addToken(range: e.site, type: .keyword)
  }

  mutating func addCall(_ e: Call) {
    // Add the function being called
    addSyntax(syntaxId: e.callee.erased)
    
    // Add arguments
    for argument in e.arguments {
      if let label = argument.label {
        addToken(range: label.site, type: .label)
      }
      addSyntax(syntaxId: argument.value.erased)
    }
  }

  mutating func addConversion(_ e: Conversion) {
    // todo
  }

  mutating func addEqualityWitnessExpression(_ e: EqualityWitnessExpression) {
    // todo
  }

  mutating func addIf(_ e: If) {
    // todo
  }

  mutating func addImplicitQualification(_ e: ImplicitQualification) {
    // todo
  }

  mutating func addInoutExpression(_ e: InoutExpression) {
    // todo
  }

  mutating func addIntegerLiteral(_ e: IntegerLiteral) {
    addToken(range: e.site, type: .number)
  }

  mutating func addKindExpression(_ e: KindExpression) {
    // todo
  }

  mutating func addLambda(_ e: Lambda) {
    // todo
  }

  mutating func addNameExpression(_ e: NameExpression) {
    addToken(range: e.name.site, type: .identifier)
  }

  mutating func addNew(_ e: New) {
    // todo
  }

  mutating func addPatternMatch(_ e: PatternMatch) {
    // todo
  }

  mutating func addPatternMatchCase(_ e: PatternMatchCase) {
    // todo
  }

  mutating func addRemoteTypeExpression(_ e: RemoteTypeExpression) {
    // todo
  }

  mutating func addStaticCall(_ e: StaticCall) {
    // todo
  }

  mutating func addStringLiteral(_ e: StringLiteral) {
    addToken(range: e.site, type: .string)
  }

  mutating func addSyntheticExpression(_ e: SynthethicExpression) {
    // todo
  }

  mutating func addTupleLiteral(_ e: TupleLiteral) {
    // todo
  }

  mutating func addTupleTypeExpression(_ e: TupleTypeExpression) {
    // todo
  }

  mutating func addWildcardLiteral(_ e: WildcardLiteral) {
    // todo
  }

  // MARK: - Pattern methods

  mutating func addBindingPattern(_ p: BindingPattern) {
    // todo
  }

  mutating func addExtractorPattern(_ p: ExtractorPattern) {
    // todo
  }

  mutating func addTuplePattern(_ p: TuplePattern) {
    // todo
  }
}

extension Program {

  public func getSemanticTokens(_ document: DocumentUri, logger: Logger)
    -> [SemanticToken]
  {
    logger.debug("List semantic tokens in document: \(document)")

    if let source = findTranslationUnit(AbsoluteUrl(URL(string: document)!), logger: logger) {
      logger.debug("Translation unit found with \(source.topLevelDeclarations.count) top-level declarations")
      
      var walker = SemanticTokensWalker(
        document: document, translationUnit: source,
        program: self, logger: logger)
      return walker.walk()
    }

    logger.error("Failed to locate translation unit for document: \(document)")
    return []
  }
}
