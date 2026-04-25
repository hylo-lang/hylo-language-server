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
    
    logger.debug("List semantic tokens in document: \(params.textDocument.uri)")

    guard let source = AbsoluteUrl(fromUrlString: params.textDocument.uri) else {
      return .invalidParameters("Invalid document URI: \(params.textDocument.uri)")
    }
    guard let s = program.sourceFile(named: source.localFileName) else {
      logger.error("Failed to locate translation unit for document: \(params.textDocument.uri)")
      return .invalidParameters("Failed to locate translation unit for document: \(params.textDocument.uri)")
    }

    let ds = program.topLevelDeclarations(in: s)
    var walker = SemanticTokensWalker(
      topLevelDeclarations: ds,
      program: program, logger: logger)

    return .success(SemanticTokens(tokens: walker.walk()))
  }
}

struct SemanticTokensWalker<TopLevelDeclarations: Sequence> where TopLevelDeclarations.Element == DeclarationIdentity {
  public let topLevelDeclarations: TopLevelDeclarations
  public let program: Program
  private let logger: Logger
  private(set) var tokens: [SemanticToken]

  public init(
    topLevelDeclarations: TopLevelDeclarations, program: Program, logger: Logger
  ) {
    self.topLevelDeclarations = topLevelDeclarations
    self.program = program
    self.tokens = []
    self.logger = logger
  }

  public mutating func walk() -> [SemanticToken] {
    precondition(tokens.isEmpty)
    addMemberDeclarations(topLevelDeclarations)
    logger.debug("Generated \(tokens.count) semantic tokens")
    return tokens
  }

  mutating func addMemberDeclarations(_ members: some Sequence<DeclarationIdentity>) {
    for d in members {
      addSyntax(syntaxId: d.erased)
    }
  }

  mutating func addSyntax(syntaxId: AnySyntaxIdentity) {
    let tag = program.tag(of: syntaxId)
    logger.debug("Processing syntax: \(tag)")

    // Declarations:
    switch program.tag(of: syntaxId) {
    case AssociatedTypeDeclaration.self:
      addAssociatedType(
        program[program.castUnchecked(syntaxId, to: AssociatedTypeDeclaration.self)])
    case BindingDeclaration.self:
      addBinding(program[program.castUnchecked(syntaxId, to: BindingDeclaration.self)])
    case ConformanceDeclaration.self:
      addConformance(program[program.castUnchecked(syntaxId, to: ConformanceDeclaration.self)])
    case EnumCaseDeclaration.self:
      addEnumCase(program[program.castUnchecked(syntaxId, to: EnumCaseDeclaration.self)])
    case EnumDeclaration.self:
      addEnum(program[program.castUnchecked(syntaxId, to: EnumDeclaration.self)])
    case ExtensionDeclaration.self:
      addExtension(program[program.castUnchecked(syntaxId, to: ExtensionDeclaration.self)])
    case FunctionBundleDeclaration.self:
      addFunctionBundle(
        program[program.castUnchecked(syntaxId, to: FunctionBundleDeclaration.self)])
    case FunctionDeclaration.self:
      addFunction(program[program.castUnchecked(syntaxId, to: FunctionDeclaration.self)])
    case GenericParameterDeclaration.self:
      addGenericParameter(
        program[program.castUnchecked(syntaxId, to: GenericParameterDeclaration.self)])
    case ImportDeclaration.self:
      addImport(program[program.castUnchecked(syntaxId, to: ImportDeclaration.self)])
    case StructDeclaration.self:
      addStruct(program[program.castUnchecked(syntaxId, to: StructDeclaration.self)])
    case TraitDeclaration.self:
      addTrait(program[program.castUnchecked(syntaxId, to: TraitDeclaration.self)])
    case TypeAliasDeclaration.self:
      addTypeAlias(program[program.castUnchecked(syntaxId, to: TypeAliasDeclaration.self)])
    case VariableDeclaration.self:
      // NOTE: VariableDeclaration is handled by BindingDeclaration, which allows binding one or more variables
      break
    case VariantDeclaration.self:
      addVariant(program[program.castUnchecked(syntaxId, to: VariantDeclaration.self)])

    // Statements:
    case Assignment.self:
      addAssignment(program[program.castUnchecked(syntaxId, to: Assignment.self)])
    case Block.self:
      addBlock(program[program.castUnchecked(syntaxId, to: Block.self)])
    case Discard.self:
      addDiscard(program[program.castUnchecked(syntaxId, to: Discard.self)])
    case Return.self:
      addReturn(program[program.castUnchecked(syntaxId, to: Return.self)])

    // Expressions:
    case ArrowExpression.self:
      addArrowExpression(program[program.castUnchecked(syntaxId, to: ArrowExpression.self)])
    case BooleanLiteral.self:
      addBooleanLiteral(program[program.castUnchecked(syntaxId, to: BooleanLiteral.self)])
    case Call.self:
      addCall(program[program.castUnchecked(syntaxId, to: Call.self)])
    case Conversion.self:
      addConversion(program[program.castUnchecked(syntaxId, to: Conversion.self)])
    case EqualityWitnessExpression.self:
      addEqualityWitnessExpression(
        program[program.castUnchecked(syntaxId, to: EqualityWitnessExpression.self)])
    case If.self:
      addIf(program[program.castUnchecked(syntaxId, to: If.self)])
    case ImplicitQualification.self:
      addImplicitQualification(
        program[program.castUnchecked(syntaxId, to: ImplicitQualification.self)])
    case InoutExpression.self:
      addInoutExpression(program[program.castUnchecked(syntaxId, to: InoutExpression.self)])
    case IntegerLiteral.self:
      addIntegerLiteral(program[program.castUnchecked(syntaxId, to: IntegerLiteral.self)])
    case KindExpression.self:
      addKindExpression(program[program.castUnchecked(syntaxId, to: KindExpression.self)])
    case Lambda.self:
      addLambda(program[program.castUnchecked(syntaxId, to: Lambda.self)])
    case NameExpression.self:
      addNameExpression(program[program.castUnchecked(syntaxId, to: NameExpression.self)])
    case New.self:
      addNew(program[program.castUnchecked(syntaxId, to: New.self)])
    case PatternMatch.self:
      addPatternMatch(program[program.castUnchecked(syntaxId, to: PatternMatch.self)])
    case PatternMatchCase.self:
      addPatternMatchCase(program[program.castUnchecked(syntaxId, to: PatternMatchCase.self)])
    case RemoteTypeExpression.self:
      addRemoteTypeExpression(
        program[program.castUnchecked(syntaxId, to: RemoteTypeExpression.self)])
    case StaticCall.self:
      addStaticCall(program[program.castUnchecked(syntaxId, to: StaticCall.self)])
    case StringLiteral.self:
      addStringLiteral(program[program.castUnchecked(syntaxId, to: StringLiteral.self)])
    case SyntheticExpression.self:
      addSyntheticExpression(program[program.castUnchecked(syntaxId, to: SyntheticExpression.self)])
    case TupleLiteral.self:
      addTupleLiteral(program[program.castUnchecked(syntaxId, to: TupleLiteral.self)])
    case TupleTypeExpression.self:
      addTupleTypeExpression(program[program.castUnchecked(syntaxId, to: TupleTypeExpression.self)])
    case WildcardLiteral.self:
      addWildcardLiteral(program[program.castUnchecked(syntaxId, to: WildcardLiteral.self)])

    // Patterns:
    case BindingPattern.self:
      addBindingPattern(program[program.castUnchecked(syntaxId, to: BindingPattern.self)])
    case ExtractorPattern.self:
      addExtractorPattern(program[program.castUnchecked(syntaxId, to: ExtractorPattern.self)])
    case TuplePattern.self:
      addTuplePattern(program[program.castUnchecked(syntaxId, to: TuplePattern.self)])

    default:
      logger.warning("Unknown syntax node type: \(tag)")
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

  mutating func addSyntheticExpression(_ e: SyntheticExpression) {
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
