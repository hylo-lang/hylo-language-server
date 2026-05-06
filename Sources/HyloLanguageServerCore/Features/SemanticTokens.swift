import FrontEnd
import JSONRPC
import LanguageServerProtocol
import Logging
import LanguageServer

extension HyloRequestHandler {

  public func semanticTokensFull(
    id: JSONId, params: SemanticTokensParams
  ) async -> Response<SemanticTokensResponse> {
    await reportingLSPError {
      let p = try await documentProvider.getParsedProgram(url: params.textDocument.uri)
      return try await semanticTokensFull(id: id, params: params, program: p)
    }
  }

  public func semanticTokensFull(
    id: JSONId, params: SemanticTokensParams, program: Program
  ) async throws -> SemanticTokensResponse {
    logger.debug("List semantic tokens in document: \(params.textDocument.uri)")

    let source = try AbsoluteURL(fromUrlString: params.textDocument.uri)
    guard let s = program.sourceFile(named: source.localFileName) else {
      logger.error("Failed to locate translation unit for document: \(params.textDocument.uri)")
      throw LSPError.invalidParameter(message:
        "Failed to locate translation unit for document: \(params.textDocument.uri)")
    }

    let ds = program.topLevelDeclarations(in: s)
    var walker = SemanticTokensWalker(
      topLevelDeclarations: ds,
      program: program, logger: logger)

    return SemanticTokens(tokens: walker.walk())
  }

}

struct SemanticTokensWalker<TopLevelDeclarations: Sequence>
where TopLevelDeclarations.Element == DeclarationIdentity {

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
    addMembers(topLevelDeclarations)
    logger.debug("Generated \(tokens.count) semantic tokens")
    return tokens
  }

  /// Adds the tokens of the member declarations.
  mutating func addMembers(_ members: some Sequence<DeclarationIdentity>) {
    for d in members {
      addSyntax(d.erased)
    }
  }

  mutating func addSyntax(_ s: AnySyntaxIdentity) {
    let tag = program.tag(of: s)

    // Declarations:
    switch tag {
    case AssociatedTypeDeclaration.self:
      addAssociatedType(
        program[program.castUnchecked(s, to: AssociatedTypeDeclaration.self)])
    case BindingDeclaration.self:
      addBinding(program[program.castUnchecked(s, to: BindingDeclaration.self)])
    case ConformanceDeclaration.self:
      addConformance(program[program.castUnchecked(s, to: ConformanceDeclaration.self)])
    case EnumCaseDeclaration.self:
      addEnumCase(program[program.castUnchecked(s, to: EnumCaseDeclaration.self)])
    case EnumDeclaration.self:
      addEnum(program[program.castUnchecked(s, to: EnumDeclaration.self)])
    case ExtensionDeclaration.self:
      addExtension(program[program.castUnchecked(s, to: ExtensionDeclaration.self)])
    case FunctionBundleDeclaration.self:
      addFunctionBundle(
        program[program.castUnchecked(s, to: FunctionBundleDeclaration.self)])
    case FunctionDeclaration.self:
      addFunction(program[program.castUnchecked(s, to: FunctionDeclaration.self)])
    case GenericParameterDeclaration.self:
      addGenericParameter(
        program[program.castUnchecked(s, to: GenericParameterDeclaration.self)])
    case ImportDeclaration.self:
      addImport(program[program.castUnchecked(s, to: ImportDeclaration.self)])
    case ParameterDeclaration.self:
      addParameter(program[program.castUnchecked(s, to: ParameterDeclaration.self)])
    case StructDeclaration.self:
      addStruct(program[program.castUnchecked(s, to: StructDeclaration.self)])
    case TraitDeclaration.self:
      addTrait(program[program.castUnchecked(s, to: TraitDeclaration.self)])
    case TypeAliasDeclaration.self:
      addTypeAlias(program[program.castUnchecked(s, to: TypeAliasDeclaration.self)])
    case VariableDeclaration.self:
      addVariable(program[program.castUnchecked(s, to: VariableDeclaration.self)])
    case VariantDeclaration.self:
      addVariant(program[program.castUnchecked(s, to: VariantDeclaration.self)])

    // Statements:
    case Assignment.self:
      addAssignment(program[program.castUnchecked(s, to: Assignment.self)])
    case Block.self:
      addBlock(program[program.castUnchecked(s, to: Block.self)])
    case Discard.self:
      addDiscard(program[program.castUnchecked(s, to: Discard.self)])
    case Return.self:
      addReturn(program[program.castUnchecked(s, to: Return.self)])
    case Yield.self:
      addYield(program[program.castUnchecked(s, to: Yield.self)])

    // Expressions:
    case ArrowExpression.self:
      addArrowExpression(program[program.castUnchecked(s, to: ArrowExpression.self)])
    case BooleanLiteral.self:
      addBooleanLiteral(program[program.castUnchecked(s, to: BooleanLiteral.self)])
    case Call.self:
      addCall(program[program.castUnchecked(s, to: Call.self)])
    case Conversion.self:
      addConversion(program[program.castUnchecked(s, to: Conversion.self)])
    case EqualityWitnessExpression.self:
      addEqualityWitnessExpression(
        program[program.castUnchecked(s, to: EqualityWitnessExpression.self)])
    case If.self:
      addIf(program[program.castUnchecked(s, to: If.self)])
    case ImplicitQualification.self:
      addImplicitQualification(
        program[program.castUnchecked(s, to: ImplicitQualification.self)])
    case InoutExpression.self:
      addInoutExpression(program[program.castUnchecked(s, to: InoutExpression.self)])
    case IntegerLiteral.self:
      addIntegerLiteral(program[program.castUnchecked(s, to: IntegerLiteral.self)])
    case FloatingPointLiteral.self:
      addFloatingPointLiteral(program[program.castUnchecked(s, to: FloatingPointLiteral.self)])
    case KindExpression.self:
      addKindExpression(program[program.castUnchecked(s, to: KindExpression.self)])
    case Lambda.self:
      addLambda(program[program.castUnchecked(s, to: Lambda.self)])
    case NameExpression.self:
      addNameExpression(program[program.castUnchecked(s, to: NameExpression.self)])
    case New.self:
      addNew(program[program.castUnchecked(s, to: New.self)])
    case PatternMatch.self:
      addPatternMatch(program[program.castUnchecked(s, to: PatternMatch.self)])
    case PatternMatchCase.self:
      addPatternMatchCase(program[program.castUnchecked(s, to: PatternMatchCase.self)])
    case RemoteTypeExpression.self:
      addRemoteTypeExpression(
        program[program.castUnchecked(s, to: RemoteTypeExpression.self)])
    case StaticCall.self:
      addStaticCall(program[program.castUnchecked(s, to: StaticCall.self)])
    case StringLiteral.self:
      addStringLiteral(program[program.castUnchecked(s, to: StringLiteral.self)])
    case SyntheticExpression.self:
      addSyntheticExpression(program[program.castUnchecked(s, to: SyntheticExpression.self)])
    case TupleLiteral.self:
      addTupleLiteral(program[program.castUnchecked(s, to: TupleLiteral.self)])
    case TupleMember.self:
      addTupleMember(program[program.castUnchecked(s, to: TupleMember.self)])
    case TupleTypeExpression.self:
      addTupleTypeExpression(program[program.castUnchecked(s, to: TupleTypeExpression.self)])
    case WildcardLiteral.self:
      addWildcardLiteral(program[program.castUnchecked(s, to: WildcardLiteral.self)])

    // Patterns:
    case BindingPattern.self:
      addBindingPattern(program[program.castUnchecked(s, to: BindingPattern.self)])
    case ExtractorPattern.self:
      addExtractorPattern(program[program.castUnchecked(s, to: ExtractorPattern.self)])
    case TuplePattern.self:
      addTuplePattern(program[program.castUnchecked(s, to: TuplePattern.self)])

    default:
      logger.warning("Unknown syntax node type: \(tag)")
    }
  }

  mutating func addEnum(_ d: EnumDeclaration) {
    // Add modifiers
    for modifier in d.modifiers {
      addKeyword(at: modifier.site)
    }

    // Add the "enum" keyword
    addKeyword(at: d.introducer.site)

    // Add enum name
    addToken(range: d.identifier.site, type: .type, modifiers: .declaration)

    // Add generic parameters
    for p in d.parameters {
      addGenericParameter(program[p])
    }

    // Add representation if present
    if let representation = d.representation {
      addSyntax(representation.erased)
    }
    
    // Add conformances
    for c in d.conformances {
      addSyntax(c.erased)
    }

    // Add members
    addMembers(d.members)
  }

  mutating func addImport(_ d: ImportDeclaration) {
    addKeyword(at: d.introducer.site)
    addToken(range: d.identifier.site, type: .namespace, modifiers: .declaration)
  }

  mutating func addVariant(_ d: VariantDeclaration) {
    addKeyword(at: d.effect.site)

    if let body = d.body {
      for statement in body {
        addSyntax(statement.erased)
      }
    }
  }

  mutating func addEnumCase(_ d: EnumCaseDeclaration) {
    addKeyword(at: d.introducer.site)
    addToken(range: d.identifier.site, type: .enumMember, modifiers: .declaration)

    for p in d.parameters {
      addParameter(program[p])
    }

    if let body = d.body {
      addSyntax(body.erased)
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
    addSyntax(d.pattern.erased)

    // Add initializer if present
    if let initializer = d.initializer {
      addSyntax(initializer.erased)
    }
  }

  mutating func addToken(range: SourceSpan, type: HyloSemanticTokenType, modifiers: HyloSemanticTokenModifier = []) {
    tokens.append(SemanticToken(range: range, type: type, modifiers: modifiers))
  }

  mutating func addKeywordIntroducer<T>(_ item: Parsed<T>) {
    addKeyword(at: item.site)
  }

  mutating func addKeyword(at site: SourceSpan) {
    addToken(range: site, type: .keyword)
  }

  mutating func addParameters(_ parameters: [ParameterDeclaration.ID]) {
    for p in parameters {
      addParameter(program[p])
    }
  }

  mutating func addParameter(_ p: ParameterDeclaration) {
    // addLabel(p.label)

    addToken(range: p.identifier.site, type: .parameter, modifiers: .declaration)

    // Add type annotation if present
    if let annotation = p.ascription {
      addSyntax(annotation.erased)
    }

    // Add default value if present
    if let defaultValue = p.defaultValue {
      addSyntax(defaultValue.erased)
    }
  }

  mutating func addContextParameters(_ contextParams: ContextParameters) {
    // Add type parameters (generics)
    for typeParam in contextParams.types {
      addSyntax(typeParam.erased)
    }

    // Add where clause (usings)
    if !contextParams.usings.isEmpty {
      // The "where" keyword would be implicit in the site, but we can try to extract it
      for using in contextParams.usings {
        addSyntax(using.erased)
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
    addSyntax(d.extendee.erased)

    // Add members
    addMembers(d.members)
  }

  mutating func addAssociatedType(_ d: AssociatedTypeDeclaration) {
    addKeyword(at: d.introducer.site)
    addToken(range: d.identifier.site, type: .type, modifiers: .declaration)
  }

  mutating func addTypeAlias(_ d: TypeAliasDeclaration) {
    // Add modifiers
    for modifier in d.modifiers {
      addKeyword(at: modifier.site)
    }

    // Add the "type" keyword
    addKeyword(at: d.introducer.site)

    // Add type alias name
    addToken(range: d.identifier.site, type: .type, modifiers: .declaration)

    // Add generic parameters
    for param in d.parameters {
      addSyntax(param.erased)
    }

    // Add aliased type
    addSyntax(d.aliasee.erased)
  }

  mutating func addVariable(_ d: VariableDeclaration) {
    addToken(range: d.identifier.site, type: .variable, modifiers: .declaration)
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
      addToken(range: identifier.site, type: .variable, modifiers: .declaration)
    }

    // Add context parameters (generics and where clauses)
    if !d.contextParameters.isEmpty {
      addContextParameters(d.contextParameters)
    }

    // Add the witness (static call)
    addSyntax(d.witness.erased)

    // Add members if present
    if let members = d.members {
      addMembers(members)
    }
  }

  mutating func addGenericParameter(_ d: GenericParameterDeclaration) {
    addToken(range: d.identifier.site, type: .typeParameter, modifiers: .declaration)

    // Add kind ascription if present
    if let ascription = d.ascription {
      addSyntax(ascription.erased)
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
    addToken(range: d.identifier.site, type: .type, modifiers: .declaration)

    // Add generic parameters
    for p in d.parameters {
      addSyntax(p.erased)
    }

    // Add members
    addMembers(d.members)
  }

  mutating func addStruct(_ d: StructDeclaration) {
    // Add modifiers
    for modifier in d.modifiers {
      addKeyword(at: modifier.site)
    }

    // Add the "struct" keyword
    addKeyword(at: d.introducer.site)

    // Add struct name
    addToken(range: d.identifier.site, type: .type, modifiers: .declaration)

    // Add generic parameters
    for param in d.parameters {
      addSyntax(param.erased)
    }

    // Add conformances
    for conformance in d.conformances {
      addSyntax(conformance.erased)
    }

    // Add members
    addMembers(d.members)
  }

  mutating func addMembers(_ members: [AnySyntaxIdentity]) {
    for m in members {
      addSyntax(m)
    }
  }

  mutating func addFunction(_ d: FunctionDeclaration) {
    // Add modifiers
    for modifier in d.modifiers {
      addKeyword(at: modifier.site)
    }

    // Add the "fun" keyword
    addKeyword(at: d.introducer.site)

    // Add function name
    addToken(range: d.identifier.site, type: .function, modifiers: .declaration)

    // Add captures
    for c in d.captures.explicit {
      addSyntax(c.erased)
    }

    // Add context parameters (generics and where clauses)
    if !d.contextParameters.isEmpty {
      addContextParameters(d.contextParameters)
    }

    // Add parameters
    addParameters(d.parameters)

    // Add return type if present
    if let output = d.output {
      addSyntax(output.erased)
    }

    // Add access effect if explicitly specified
    if !d.effect.site.region.isEmpty {
      addKeyword(at: d.effect.site)
    }

    // Add body if present
    if let body = d.body {
      for statement in body {
        addSyntax(statement.erased)
      }
    }
  }

  mutating func addFunctionBundle(_ d: FunctionBundleDeclaration) {
    // Add modifiers
    for modifier in d.modifiers {
      addKeyword(at: modifier.site)
    }

    // Add "fun" keyword
    addKeyword(at: d.introducer.site)

    // Add function bundle name
    addToken(range: d.identifier.site, type: .function, modifiers: .declaration)

    // Add captures
    for c in d.captures.explicit {
      addSyntax(c.erased)
    }

    // Add context parameters (generics and where clauses)
    if !d.contextParameters.isEmpty {
      addContextParameters(d.contextParameters)
    }

    // Add parameters
    addParameters(d.parameters)

    // Add return type if present
    if let output = d.output {
      addSyntax(output.erased)
    }

    // Add variants
    for variant in d.variants {
      addSyntax(variant.erased)
    }

    // Add access effect if explicitly specified
    if !d.effect.site.region.isEmpty {
      addKeyword(at: d.effect.site)
    }
  }

  // MARK: - Statement methods

  mutating func addAssignment(_ s: Assignment) {
    // Add left-hand side
    addSyntax(s.lhs.erased)

    // Add right-hand side
    addSyntax(s.rhs.erased)
  }

  mutating func addBlock(_ s: Block) {
    // Add introducer if present (e.g., "do" keyword)
    if let introducer = s.introducer {
      addKeyword(at: introducer.site)
    }

    // Add all statements in the block
    for statement in s.statements {
      addSyntax(statement.erased)
    }
  }

  mutating func addDiscard(_ s: Discard) {
    // Add the discarded value
    addSyntax(s.value.erased)
  }

  mutating func addReturn(_ s: Return) {
    if let introducer = s.introducer {
      addKeyword(at: introducer.site)
    }

    if let value = s.value {
      addSyntax(value.erased)
    }
  }
  
  mutating func addYield(_ s: Yield) {
    if let introducer = s.introducer {
      addKeyword(at: introducer.site)
    }
    
    addSyntax(s.value.erased)
  }

  // MARK: - Expression methods

  mutating func addArrowExpression(_ e: ArrowExpression) {
    // Add environment if present
    if let environment = e.environment {
      addSyntax(environment.erased)
    }

    // Add parameters
    for parameter in e.parameters {
      if let label = parameter.label {
        addToken(range: label.site, type: .label)
      }
      addSyntax(parameter.ascription.erased)
    }

    // Add effect
    if !e.effect.site.region.isEmpty {
      addKeyword(at: e.effect.site)
    }

    // Add output type
    addSyntax(e.output.erased)
  }

  mutating func addBooleanLiteral(_ e: BooleanLiteral) {
    addToken(range: e.site, type: .keyword)
  }

  mutating func addCall(_ e: Call) {
    // Add the function being called
    addSyntax(e.callee.erased)

    // Add arguments
    for argument in e.arguments {
      if let label = argument.label {
        addToken(range: label.site, type: .label)
      }
      addSyntax(argument.value.erased)
    }
  }

  mutating func addConversion(_ e: Conversion) {
    // Add source expression
    addSyntax(e.source.erased)

    // Add conversion operator
    addToken(range: e.semantics.site, type: .operator)

    // Add target type
    addSyntax(e.target.erased)

  }

  mutating func addEqualityWitnessExpression(_ e: EqualityWitnessExpression) {
    // Add left-hand side
    addSyntax(e.lhs.erased)

    // Add right-hand side
    addSyntax(e.rhs.erased)
  }

  mutating func addIf(_ e: If) {
    // Add "if" keyword
    addKeyword(at: e.introducer.site)

    // Add conditions
    for condition in e.conditions {
      addSyntax(condition.erased)
    }

    // Add success block
    addSyntax(e.success.erased)

    // Add failure block
    addSyntax(e.failure.erased)
  }

  mutating func addImplicitQualification(_ e: ImplicitQualification) {
    // This is an implicit qualification (e.g., `.bar`), but it doesn't have
    // explicit content to tokenize beyond the site itself
  }

  mutating func addInoutExpression(_ e: InoutExpression) {
    // Add the mutation marker ("&")
    addToken(range: e.marker.site, type: .operator)

    // Add the lvalue
    addSyntax(e.lvalue.erased)
  }

  mutating func addIntegerLiteral(_ e: IntegerLiteral) {
    addToken(range: e.site, type: .number)
  }

  mutating func addFloatingPointLiteral(_ e: FloatingPointLiteral) {
    addToken(range: e.site, type: .number)
  }

  mutating func addKindExpression(_ e: KindExpression) {
    switch e.value {
    case .proper:
      // "*" kind - already handled by the site
      addToken(range: e.site, type: .keyword)
    case .arrow(let input, let output):
      // Arrow kind
      addSyntax(input.erased)
      addSyntax(output.erased)
    }
  }

  mutating func addLambda(_ e: Lambda) {
    // Add the underlying function
    addSyntax(e.function.erased)
  }

  mutating func addNameExpression(_ e: NameExpression) {
    if let q = e.qualification { addSyntax(q.erased) }
    
    // todo add more specific type and modifiers after type-checking 
    addToken(range: e.name.site, type: .identifier)
  }

  mutating func addNew(_ e: New) {
    // Add qualification
    addSyntax(e.qualification.erased)

    // Add the target name expression
    addSyntax(e.target.erased)
  }

  mutating func addPatternMatch(_ e: PatternMatch) {
    // Add "match" keyword
    addKeyword(at: e.introducer.site)

    // Add scrutinee
    addSyntax(e.scrutinee.erased)

    // Add branches
    for branch in e.branches {
      addSyntax(branch.erased)
    }
  }

  mutating func addPatternMatchCase(_ e: PatternMatchCase) {
    // Add "case" keyword
    addKeyword(at: e.introducer.site)

    // Add pattern
    addSyntax(e.pattern.erased)

    // Add body statements
    for statement in e.body {
      addSyntax(statement.erased)
    }
  }

  mutating func addRemoteTypeExpression(_ e: RemoteTypeExpression) {
    // Add access effect
    addKeyword(at: e.access.site)

    // Add projectee type
    addSyntax(e.projectee.erased)
  }

  mutating func addStaticCall(_ e: StaticCall) {
    // Add callee
    addSyntax(e.callee.erased)

    // Add arguments
    for argument in e.arguments {
      addSyntax(argument.erased)
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
      addSyntax(element.erased)
    }
  }
  
  mutating func addTupleMember(_ e: TupleMember) {
    // Add parent expression
    addSyntax(e.parent.erased)
    
    // Add member index
    addToken(range: e.member.site, type: .number)
  }

  mutating func addTupleTypeExpression(_ e: TupleTypeExpression) {
    // Add all element types
    for element in e.elements {
      addSyntax(element.erased)
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
    addSyntax(p.pattern.erased)

    // Add type ascription if present
    if let ascription = p.ascription {
      addSyntax(ascription.erased)
    }
  }

  mutating func addExtractorPattern(_ p: ExtractorPattern) {
    // Add extractor expression
    addSyntax(p.extractor.erased)

    // Add elements
    for element in p.elements {
      if let label = element.label {
        addToken(range: label.site, type: .label)
      }
      addSyntax(element.value.erased)
    }
  }

  mutating func addTuplePattern(_ p: TuplePattern) {
    // Add all element patterns
    for element in p.elements {
      addSyntax(element.erased)
    }
  }

}
