import Foundation
import FrontEnd
import JSONRPC
import LanguageServerProtocol
import Logging

extension HyloRequestHandler {
  public func semanticTokensFull(id: JSONId, params: SemanticTokensParams) async -> Result<
    SemanticTokensResponse, AnyJSONRPCResponseError
  > {

    await withDocumentAST(params.textDocument) { ast in
      await semanticTokensFull(id: id, params: params, program: ast)
    }
  }

  public func semanticTokensFull(
    id: JSONId, params: SemanticTokensParams, program: Program
  ) async -> Result<SemanticTokensResponse, AnyJSONRPCResponseError> {
    let tokens = getSemanticTokens(of: params.textDocument.uri, in: program, logger: logger)
    logger.debug("[\(params.textDocument.uri)] Return \(tokens.count) semantic tokens")
    return .success(SemanticTokens(tokens: tokens))
  }
}

private func getSemanticTokens(of document: DocumentUri, in program: Program, logger: Logger)
  -> [SemanticToken]
{
  logger.debug("List semantic tokens in document: \(document)")

  if let source = program.findSourceContainer(AbsoluteUrl(URL(string: document)!), logger: logger) {
    logger.debug(
      "Translation unit found with \(source.topLevelDeclarations.count) top-level declarations")

    var walker = SemanticTokensWalker(
      document: document, translationUnit: source,
      program: program, logger: logger)
    return walker.walk()
  }

  logger.error("Failed to locate translation unit for document: \(document)")
  return []
}

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
    // Add modifiers
    for modifier in d.modifiers {
      addKeyword(at: modifier.site)
    }

    // Add the "enum" keyword
    addKeyword(at: d.introducer.site)

    // Add enum name
    addToken(range: d.identifier.site, type: .type)

    // Add members
    addMemberDeclarations(d.members)
  }

  mutating func addImport(_ d: ImportDeclaration) {
    addKeyword(at: d.introducer.site)
    addToken(range: d.identifier.site, type: HyloSemanticTokenType.namespace)
  }

  mutating func addVariant(_ d: VariantDeclaration) {
    addKeyword(at: d.effect.site)

    // todo: add body if present
    if let body = d.body {
      for statement in body {
        addSyntax(syntaxId: statement.erased)
      }
    }
  }

  mutating func addEnumCase(_ d: EnumCaseDeclaration) {
    addKeyword(at: d.introducer.site)
    addToken(range: d.identifier.site, type: .function)

    for param in d.parameters {
      addParameter(param)
    }
  }

  mutating func addBinding(_ d: BindingDeclaration) {
    // Add modifiers
    for modifier in d.modifiers {
      addKeyword(at: modifier.site)
    }

    // Add role-specific keywords
    if d.role == .given {
      // "given" keyword is already handled by modifiers or would need separate tracking
    }

    // Add the binding pattern
    addSyntax(syntaxId: d.pattern.erased)

    // Add initializer if present
    if let initializer = d.initializer {
      addSyntax(syntaxId: initializer.erased)
    }
  }

  mutating func addToken(range: SourceSpan, type: HyloSemanticTokenType, modifiers: UInt32 = 0) {
    tokens.append(SemanticToken(range: range, type: type, modifiers: modifiers))
  }

  mutating func addKeywordIntroducer<T>(_ item: Parsed<T>) {
    addKeyword(at: item.site)
  }

  mutating func addKeyword(at site: SourceSpan) {
    addToken(range: site, type: .keyword)
  }

  mutating func addBindingPattern(_ pattern: BindingPattern.ID) {
    let p = program[pattern]
    addKeywordIntroducer(p.introducer)

    // Add nested pattern
    addSyntax(syntaxId: p.pattern.erased)

    // Add type ascription if present
    if let ascription = p.ascription {
      addSyntax(syntaxId: ascription.erased)
    }
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

    // Add type annotation if present
    if let annotation = p.ascription {
      addSyntax(syntaxId: annotation.erased)
    }

    // Add default value if present
    if let defaultValue = p.defaultValue {
      addSyntax(syntaxId: defaultValue.erased)
    }
  }

  mutating func addContextParameters(_ contextParams: ContextParameters) {
    // Add type parameters (generics)
    for typeParam in contextParams.types {
      addSyntax(syntaxId: typeParam.erased)
    }

    // Add where clause (usings)
    if !contextParams.usings.isEmpty {
      // The "where" keyword would be implicit in the site, but we can try to extract it
      for using in contextParams.usings {
        addSyntax(syntaxId: using.erased)
      }
    }
  }

  mutating func addExtension(_ d: ExtensionDeclaration) {
    // Add the "extension" keyword
    addKeyword(at: d.introducer.site)

    // Add context parameters (generics and where clauses)
    if !d.contextParameters.isEmpty {
      addContextParameters(d.contextParameters)
    }

    // Add the extended type
    addSyntax(syntaxId: d.extendee.erased)

    // Add members
    addMemberDeclarations(d.members)
  }

  mutating func addAssociatedType(_ d: AssociatedTypeDeclaration) {
    addKeyword(at: d.introducer.site)
    addToken(range: d.identifier.site, type: .type)
  }

  mutating func addTypeAlias(_ d: TypeAliasDeclaration) {
    // Add modifiers
    for modifier in d.modifiers {
      addKeyword(at: modifier.site)
    }

    // Add the "type" keyword
    addKeyword(at: d.introducer.site)

    // Add type alias name
    addToken(range: d.identifier.site, type: .type)

    // Add generic parameters
    for param in d.parameters {
      addSyntax(syntaxId: param.erased)
    }

    // Add aliased type
    addSyntax(syntaxId: d.aliasee.erased)
  }

  mutating func addConformance(_ d: ConformanceDeclaration) {
    // Add modifiers
    for modifier in d.modifiers {
      addKeyword(at: modifier.site)
    }

    // Add the "given" keyword
    addKeyword(at: d.introducer.site)

    // Add identifier if present
    if let identifier = d.identifier {
      addToken(range: identifier.site, type: .identifier)
    }

    // Add context parameters (generics and where clauses)
    if !d.contextParameters.isEmpty {
      addContextParameters(d.contextParameters)
    }

    // Add the witness (static call)
    addSyntax(syntaxId: d.witness.erased)

    // Add members if present
    if let members = d.members {
      addMemberDeclarations(members)
    }
  }

  mutating func addGenericParameter(_ d: GenericParameterDeclaration) {
    addToken(range: d.identifier.site, type: .typeParameter)

    // Add kind ascription if present
    if let ascription = d.ascription {
      addSyntax(syntaxId: ascription.erased)
    }
  }

  mutating func addTrait(_ d: TraitDeclaration) {
    // Add modifiers
    for modifier in d.modifiers {
      addKeyword(at: modifier.site)
    }

    // Add the "trait" keyword
    addKeyword(at: d.introducer.site)

    // Add trait name
    addToken(range: d.identifier.site, type: .type)

    // Add members
    addMemberDeclarations(d.members)
  }

  mutating func addStruct(_ d: StructDeclaration) {
    // Add modifiers
    for modifier in d.modifiers {
      addKeyword(at: modifier.site)
    }

    // Add the "struct" keyword
    addKeyword(at: d.introducer.site)

    // Add struct name
    addToken(range: d.identifier.site, type: .type)

    // Add generic parameters
    for param in d.parameters {
      addSyntax(syntaxId: param.erased)
    }

    // Add conformances
    for conformance in d.conformances {
      addSyntax(syntaxId: conformance.erased)
    }

    // Add members
    addMemberDeclarations(d.members)
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
    // Add modifiers
    for modifier in d.modifiers {
      addKeyword(at: modifier.site)
    }

    // Add the "fun" keyword
    addKeyword(at: d.introducer.site)

    // Add function name
    addToken(range: d.identifier.site, type: .function)

    // Add context parameters (generics and where clauses)
    if !d.contextParameters.isEmpty {
      addContextParameters(d.contextParameters)
    }

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
    // Add modifiers
    for modifier in d.modifiers {
      addKeyword(at: modifier.site)
    }

    // Add "fun" keyword
    addKeyword(at: d.introducer.site)

    // Add function bundle name
    addToken(range: d.identifier.site, type: .function)

    // Add context parameters (generics and where clauses)
    if !d.contextParameters.isEmpty {
      addContextParameters(d.contextParameters)
    }

    // Add parameters
    addParameters(d.parameters)

    // Add return type if present
    if let output = d.output {
      addSyntax(syntaxId: output.erased)
    }

    // Add variants
    for variant in d.variants {
      addSyntax(syntaxId: variant.erased)
    }
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
    // Add left-hand side
    addSyntax(syntaxId: s.lhs.erased)

    // Add right-hand side
    addSyntax(syntaxId: s.rhs.erased)
  }

  mutating func addBlock(_ s: Block) {
    // Add introducer if present (e.g., "do" keyword)
    if let introducer = s.introducer {
      addKeyword(at: introducer.site)
    }

    // Add all statements in the block
    for statement in s.statements {
      addSyntax(syntaxId: statement.erased)
    }
  }

  mutating func addDiscard(_ s: Discard) {
    // Add the discarded value
    addSyntax(syntaxId: s.value.erased)
  }

  mutating func addReturn(_ s: Return) {
    if let introducer = s.introducer {
      addKeyword(at: introducer.site)
    }

    if let value = s.value {
      addSyntax(syntaxId: value.erased)
    }
  }

  // MARK: - Expression methods

  mutating func addArrowExpression(_ e: ArrowExpression) {
    // Add environment if present
    if let environment = e.environment {
      addSyntax(syntaxId: environment.erased)
    }

    // Add parameters
    for parameter in e.parameters {
      if let label = parameter.label {
        addToken(range: label.site, type: .label)
      }
      addSyntax(syntaxId: parameter.ascription.erased)
    }

    // Add effect
    addKeyword(at: e.effect.site)

    // Add output type
    addSyntax(syntaxId: e.output.erased)
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
    // Add source expression
    addSyntax(syntaxId: e.source.erased)

    // Add target type
    addSyntax(syntaxId: e.target.erased)

    // The operator (as, as!, as*) would need special handling
    // but it doesn't seem to have a separate token site
  }

  mutating func addEqualityWitnessExpression(_ e: EqualityWitnessExpression) {
    // Add left-hand side
    addSyntax(syntaxId: e.lhs.erased)

    // Add right-hand side
    addSyntax(syntaxId: e.rhs.erased)
  }

  mutating func addIf(_ e: If) {
    // Add "if" keyword
    addKeyword(at: e.introducer.site)

    // Add conditions
    for condition in e.conditions {
      addSyntax(syntaxId: condition.erased)
    }

    // Add success block
    addSyntax(syntaxId: e.success.erased)

    // Add failure block
    addSyntax(syntaxId: e.failure.erased)
  }

  mutating func addImplicitQualification(_ e: ImplicitQualification) {
    // This is an implicit qualification (e.g., `.bar`), but it doesn't have
    // explicit content to tokenize beyond the site itself
  }

  mutating func addInoutExpression(_ e: InoutExpression) {
    // Add the mutation marker ("&")
    addToken(range: e.marker.site, type: .operator)

    // Add the lvalue
    addSyntax(syntaxId: e.lvalue.erased)
  }

  mutating func addIntegerLiteral(_ e: IntegerLiteral) {
    addToken(range: e.site, type: .number)
  }

  mutating func addKindExpression(_ e: KindExpression) {
    switch e.value {
    case .proper:
      // "*" kind - already handled by the site
      addToken(range: e.site, type: .keyword)
    case .arrow(let input, let output):
      // Arrow kind
      addSyntax(syntaxId: input.erased)
      addSyntax(syntaxId: output.erased)
    }
  }

  mutating func addLambda(_ e: Lambda) {
    // Add the underlying function
    addSyntax(syntaxId: e.function.erased)
  }

  mutating func addNameExpression(_ e: NameExpression) {
    addToken(range: e.name.site, type: .identifier)
  }

  mutating func addNew(_ e: New) {
    // Add qualification
    addSyntax(syntaxId: e.qualification.erased)

    // Add the target name expression
    addSyntax(syntaxId: e.target.erased)
  }

  mutating func addPatternMatch(_ e: PatternMatch) {
    // Add "match" keyword
    addKeyword(at: e.introducer.site)

    // Add scrutinee
    addSyntax(syntaxId: e.scrutinee.erased)

    // Add branches
    for branch in e.branches {
      addSyntax(syntaxId: branch.erased)
    }
  }

  mutating func addPatternMatchCase(_ e: PatternMatchCase) {
    // Add "case" keyword
    addKeyword(at: e.introducer.site)

    // Add pattern
    addSyntax(syntaxId: e.pattern.erased)

    // Add body statements
    for statement in e.body {
      addSyntax(syntaxId: statement.erased)
    }
  }

  mutating func addRemoteTypeExpression(_ e: RemoteTypeExpression) {
    // Add access effect
    addKeyword(at: e.access.site)

    // Add projectee type
    addSyntax(syntaxId: e.projectee.erased)
  }

  mutating func addStaticCall(_ e: StaticCall) {
    // Add callee
    addSyntax(syntaxId: e.callee.erased)

    // Add arguments
    for argument in e.arguments {
      addSyntax(syntaxId: argument.erased)
    }
  }

  mutating func addStringLiteral(_ e: StringLiteral) {
    addToken(range: e.site, type: .string)
  }

  mutating func addSyntheticExpression(_ e: SynthethicExpression) {
    // Synthetic expressions are compiler-generated, may not need tokenization
    // or the structure may vary
  }

  mutating func addTupleLiteral(_ e: TupleLiteral) {
    // Add all elements
    for element in e.elements {
      addSyntax(syntaxId: element.erased)
    }
  }

  mutating func addTupleTypeExpression(_ e: TupleTypeExpression) {
    // Add all element types
    for element in e.elements {
      addSyntax(syntaxId: element.erased)
    }

    // Note: ellipsis token could be handled here if needed
    if let ellipsis = e.ellipsis {
      addToken(range: ellipsis.site, type: .operator)
    }
  }

  mutating func addWildcardLiteral(_ e: WildcardLiteral) {
    // Add wildcard token
    addToken(range: e.site, type: .keyword)
  }

  // MARK: - Pattern methods

  mutating func addBindingPattern(_ p: BindingPattern) {
    // Add introducer keyword (let, set, var, inout, sinklet)
    addKeyword(at: p.introducer.site)

    // Add nested pattern
    addSyntax(syntaxId: p.pattern.erased)

    // Add type ascription if present
    if let ascription = p.ascription {
      addSyntax(syntaxId: ascription.erased)
    }
  }

  mutating func addExtractorPattern(_ p: ExtractorPattern) {
    // Add extractor expression
    addSyntax(syntaxId: p.extractor.erased)

    // Add elements
    for element in p.elements {
      if let label = element.label {
        addToken(range: label.site, type: .label)
      }
      addSyntax(syntaxId: element.value.erased)
    }
  }

  mutating func addTuplePattern(_ p: TuplePattern) {
    // Add all element patterns
    for element in p.elements {
      addSyntax(syntaxId: element.erased)
    }
  }
}
