import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging

private let dummyNode = "code_completion_node"

/// Returns the primary members of a type
private func primaryMembers(of t: AnyTypeIdentity, in p: Program) -> [DeclarationIdentity] {
    // We may want to move (and complete) this function to Program
    if let t = p.types[t] as? Struct {
        p[t.declaration].members
    } else if let t = p.types[t] as? Enum {
        p[t.declaration].members
    } else if let t = p.types[t] as? Trait {
        p[t.declaration].members
    } else {
        []
    }
}

/// Return true iff the declaration is a function declaration with either init or memberwiseinit as an introducer
private func isInit(_ e: DeclarationIdentity, in p: Program) -> Bool {
    guard let c = p.cast(e, to: FunctionDeclaration.self) else {
        return false
    }
    return p[c].introducer.value == FunctionDeclaration.Introducer.`init`
        || p[c].introducer.value == FunctionDeclaration.Introducer.memberwiseinit
}

extension SourceFile {
    public func index(p: DocumentPosition) -> SourceFile.Index {
        self.index(line: p.hylo.0, column: p.hylo.1)
    }
}

/// A position in a document, defined by its line and column
public struct DocumentPosition {

    /// The line of the position - 0 indexed
    private let line: Int

    // The column of the position - 0 indexed
    private let column: Int

    /// A LSP compatible position (0-indexed)
    public var lsp: (Int, Int) {
        (self.line, self.column)
    }

    /// A Hylo compatible position (1-indexed)
    public var hylo: (Int, Int) {
        (self.line + 1, self.column + 1)
    }

    /// Return a DocumentPosition builded from a LSP Position instance
    static public func from(_ p: Position) -> DocumentPosition {
        return DocumentPosition(line: p.line, column: p.character)
    }
}

extension HyloRequestHandler {

    /// Return a Response containing a AnyJSONRPCResponseError
    private func jsonFailure(message: String, code: Int = ErrorCodes.InternalError) -> Response<
        CompletionResponse
    > {
        // TODO: Is there a way to force the code parameter to be an ErrorCodes ? If so, do we want to do that ?
        // And is there a way to specify that the response we return is a AnyJSONRPCResponseError ? And not a generic CompletionResponse
        //  -> For now this don't work we can't return the AnyJsonRPCError directly
        return .failure(AnyJSONRPCResponseError(code: code, message: message))
    }

    /// Entry point for LSP completion request
    public func completion(id: JSONId, params: CompletionParams) async -> Response<
        CompletionResponse
    > {
        return await withAnalyzedDocument(
            params.textDocument, fn: { await completionResponse(from: $0, with: params) })
    }

    /// Build a completion response from a document and a position in said document
    private func completionResponse(from document: AnalyzedDocument, with params: CompletionParams)
        async -> Response<CompletionResponse>
    {
        let position = DocumentPosition.from(params.position)
        guard let u = DocumentProvider.validateDocumentUrl(params.textDocument.uri) else {
            return jsonFailure(
                message: "Invalid document uri: \(params.textDocument.uri)",
                code: ErrorCodes.InvalidParams)
        }
        guard let input = document.program.findSourceContainer(u, logger: logger) else {
            return jsonFailure(
                message: "Failed to locate translation unit : \(params.textDocument.uri)")
        }

        // Try to insert a dummy node if needed, default to base program and source if errors

        // TODO: Here, if the hc succeeded the first time to compile the source file, and fails when we add a dummy token, this means
        // that this is our fault. For now, we default on the base program and source, do we want to throw ? (or do something else ?)
        let (program, source) =
            await insertDummyNodeIfNeeded(
                in: input.source, at: position, program: document.program, url: u) ?? (
                document.program, input.source
            )

        let sourcePosition = SourcePosition(
            source.index(line: position.hylo.0, column: position.hylo.1),
            in: source
        )

        guard let node = program.findNode(sourcePosition, logger: logger) else {
            // Here, we have no node on the autocompletion request
            // TODO: Do we want to return keywords/global symbols ?
            return jsonFailure(message: "Could not find any AST node at cursor position")
        }

        return buildCompletion(from: node, in: program)
    }

    /// Build the completion response from an AST node in a Program
    private func buildCompletion(from node: AnySyntaxIdentity, in program: Program) -> Response<
        CompletionResponse
    > {
        if program.isExpression(node) {
            switch program[program.castToExpression(node)!] {
            case let n as NameExpression:
                buildCompletion(from: n, in: program)
            case let c as Call:
                .success(TwoTypeOption.optionB(CompletionList(from: c, in: program)))
            default:
                jsonFailure(message: "Could not find the expression type of this node")
            }
        } else if program.isScope(node) {
            .success(
                TwoTypeOption.optionB(
                    CompletionList(from: program.castToScope(node)!, in: program)
                )
            )
        } else {
            jsonFailure(message: "Did not find a completion type for this")
        }
    }

    /// Build a CompletionResponse from a NameExpression in a Program
    private func buildCompletion(from n: NameExpression, in program: Program) -> Response<
        CompletionResponse
    > {
        if n.name.value.identifier == dummyNode {
            // Here, we have detected the dummy token
            logger.debug("Dummy token detected")
            if let q: ExpressionIdentity = n.qualification {
                return .success(
                    TwoTypeOption.optionB(
                        CompletionList(from: q, in: program, log: logger))
                )
            } else {
                logger.error("No qualification for expression with dot")
                return .success(TwoTypeOption.optionA([]))
            }
        } else {
            return jsonFailure(message: "Did not find dummy token for NameExpression")
        }
    }

    /// Insert a dummy node in the source file if needed. Return the new Program and the modified SourceFile
    private func insertDummyNodeIfNeeded(
        in source: SourceFile, at position: DocumentPosition, program: Program, url: AbsoluteUrl
    ) async -> (Program, SourceFile)? {
        let i = source.index(p: position)
        return if dummyNodeNeeded(in: source, at: i) {
            await insertDummyNode(in: source, at: i, url: url)
        } else {
            (program, source)
        }
    }

    /// Insert a dummy node in the source file, and build a program from this modified source. Return the new Program and the modified SourceFile
    private func insertDummyNode(in s: SourceFile, at i: SourceFile.Index, url: AbsoluteUrl) async
        -> (Program, SourceFile)?
    {
        var finalContent = s.text
        finalContent.insert(contentsOf: dummyNode, at: s.index(after: i))

        return try? await documentProvider.buildProgramFromModifiedString(
            url: url, newText: finalContent)
    }

    /// Return true iff the string in SourceFile at position ends with a '.'.
    private func dummyNodeNeeded(in source: SourceFile, at position: SourceFile.Index) -> Bool {
        source[source.index(before: position)] == "."
    }
}

/// Create a label and a snippet for CompletionItem from an Arrow in a Program
private func buildLabelAndSnippets(from a: Arrow, in p: Program, includeParenthesis: Bool = true)
    -> (String, String)
{
    // The label will look like "(p1: t1, p2: t2)"
    var label = "("
    // The snippet will look like "(p1: ${1:t1}, p2: ${2:t2})"
    var snippet = if includeParenthesis { "(" } else { "" }
    var i = 0
    for a in a.inputs
    where (a.label == nil || a.label != "self") {
        if i != 0 {
            label += ", "
            snippet += ", "
        }
        if let l = a.label {
            label += "\(l): "
            snippet += "\(l): "
        }
        label += p.show(a.type)
        snippet += "${\(i + 1):\(p.show(a.type))}"
        if let d = a.defaultValue {
            label += p.show(d)
            snippet += p.show(d)
        }
        i += 1
    }
    if includeParenthesis {
        snippet += ")$0"
    }
    label += ")"
    return (label, snippet)
}

extension CompletionList {

    /// Create a complete CompletionList from all the members of a scope and all its parent
    public init(from s: ScopeIdentity, in p: Program) {
        // Takes all the scope containing the scope s (and the scope s itself),
        // And for each of these scopes, we take all the declarations lexically in it, and we create a CompletionItem for each of these declarations
        self.init(
            isIncomplete: false,
            items: p.scopes(from: s).reduce(into: []) { r, s in
                r.append(
                    contentsOf: p.declarations(lexicallyIn: s).compactMap({ d in
                        if p.tag(of: d).value != BindingDeclaration.self {
                            CompletionItem.create(from: d, in: p)
                        } else {
                            nil
                        }
                    }))
            })
    }

    /// Create a CompletionList from all the different overload available from a Call
    public init(from c: Call, in p: Program) {
        switch p[c.callee] {
        case let n as New:
            let mt = p.type(assignedTo: n.qualification, assuming: Metatype.self)
            var l: [CompletionItem] = []
            for m in primaryMembers(of: p.types[mt].inhabitant, in: p) {
                guard let c = p.cast(m, to: FunctionDeclaration.self) else {
                    continue
                }
                if let a = p.types[p.type(assignedTo: c)] as? Arrow {
                    let r = buildLabelAndSnippets(from: a, in: p, includeParenthesis: false)
                    l.append(
                        CompletionItem(
                            label: r.0, kind: CompletionItemKind.function, insertText: r.1,
                            insertTextFormat: InsertTextFormat.snippet))
                }
            }
            self.init(isIncomplete: false, items: l)
        default:
            //TODO: For now, it is not implemented, I think later, we would need to add completion for other call types
            self.init(
                isIncomplete: false,
                items: [CompletionItem(label: "Not implemented", detail: "")])
        }
    }

    /// Create a complete CompletionList from all the constructors of a StructDeclaration
    public init(_ s: StructDeclaration.ID, in p: Program) {
        var l: [CompletionItem] = []
        for m in p[s].members where isInit(m, in: p) {
            let c = p.cast(m, to: FunctionDeclaration.self)!
            if case let t as Arrow = p.types[p.type(assignedTo: c)] {
                l.append(CompletionItem(from: t, in: p))
            }
        }
        self.init(isIncomplete: false, items: l)
    }

    /// Create a complete CompletionList from all the primary members of an expression type
    public init(from e: ExpressionIdentity, in p: Program, log: Logger) {
        // TODO: The incomplete list should be here -> for now we get only the primary members,
        // In the future, we will need to search for all the members
        self.init(
            isIncomplete: false,
            items: primaryMembers(of: p.type(assignedTo: e), in: p).compactMap({
                if !isInit($0, in: p) { CompletionItem.create(from: $0, in: p) } else { nil }
            }))
    }

    /// Merge two CompletionList together. Combining their elements by union, and `isIncomplete` by a AND
    public func merge(with other: CompletionList) -> CompletionList {
        CompletionList(
            isIncomplete: self.isIncomplete && other.isIncomplete, items: self.items + other.items)
    }
}

extension CompletionItem {

    /// Create a CompletionItem from a declaration, or nil if no completion item should be created for this declaration
    static public func create(from d: DeclarationIdentity, in p: Program) -> CompletionItem? {
        switch p.tag(of: d) {
        case VariableDeclaration.self:
            self.init(from: p.cast(d, to: VariableDeclaration.self)!, in: p)
        case FunctionDeclaration.self:
            self.init(from: p.cast(d, to: FunctionDeclaration.self)!, in: p)
        case ParameterDeclaration.self:
            self.init(from: p.cast(d, to: ParameterDeclaration.self)!, in: p)
        case StructDeclaration.self:
            self.init(from: p.cast(d, to: StructDeclaration.self)!, in: p)
        case BindingDeclaration.self:
            self.init(from: p.cast(d, to: BindingDeclaration.self)!, in: p)
        case ExtensionDeclaration.self:
            nil
        default:
            self.init(
                label: "Not implemented",
                detail:
                    "decl : \(p.show(d))\n tag : \(p.tag(of: d).description)"
            )
        }

    }

    /// Build a CompletionItem from an Arrow, by taking its different parameters and their types
    public init(from a: Arrow, in p: Program) {
        // The completion item will look like (p1: t1, p2: t2) with p{1-2} being the function parameters and t{1-2} their respective types
        let (label, snippet) = buildLabelAndSnippets(from: a, in: p)
        self.init(
            label: label, kind: CompletionItemKind.function, insertText: snippet,
            insertTextFormat: InsertTextFormat.snippet)
    }

    /// Create a CompletionItem representing a StructDeclaration by its identifier
    private init(from d: ConcreteSyntaxIdentity<StructDeclaration>, in p: Program) {
        self.init(label: p[d].identifier.value, kind: CompletionItemKind.struct)
    }

    /// Create a CompletionItem representing a FunctionDeclaration by its identifier, parameters and return value
    private init(
        from c: ConcreteSyntaxIdentity<FunctionDeclaration>, in p: Program
    ) {
        let d = p[c]
        var detail =
            d.modifiers.reduce("", { "\($0)\($1.description) " }) + d.identifier.value.description
        var snippet = d.identifier.value.description
        if let t = p.types[p.type(assignedTo: c)] as? Arrow {
            let r = buildLabelAndSnippets(from: t, in: p)
            detail += r.0
            snippet += r.1
            let type = p.types[t.output]
            detail += " -> \(p.show(type))"
        }
        self.init(
            label: d.identifier.value.description, kind: CompletionItemKind.function,
            detail: detail, insertText: snippet, insertTextFormat: InsertTextFormat.snippet)
    }

    /// Create a CompletionItem representing a BindingDeclaration by its pattern
    private init(from c: ConcreteSyntaxIdentity<BindingDeclaration>, in p: Program) {
        let b = p[p[c].pattern]
        let label = p.show(b.pattern)
        var detail = "\(b.introducer.description) \(label)"
        let type = p.type(assignedTo: b.pattern)
        let typeName =
            if let remoteTypeID = p.types.cast(type, to: RemoteType.self) {
                p.types[remoteTypeID].projectee
            } else {
                type
            }
        detail += ": \(p.show(typeName))"
        detail = p[c].modifiers.reduce(detail, { "\($1) \($0)" })
        self.init(
            label: label, detail: detail
        )
    }

    /// Build a CompletionItem representing a ParameterDeclaration by its identifier, ascription and default value
    private init(from c: ConcreteSyntaxIdentity<ParameterDeclaration>, in p: Program) {
        let d = p[c]
        var detail = "\(d.identifier.value)"
        if d.ascription != nil {
            let t = p[d.ascription!]
            detail += ":\(p.show(t))"
        }
        if d.defaultValue != nil {
            detail += "=\(p.show(d.defaultValue!))"
        }
        self.init(
            label: d.identifier.description, kind: CompletionItemKind.variable,
            detail: detail)
    }

    /// Create a CompletionItem representing a VariableDeclaration by its identifier and type
    private init(
        from d: ConcreteSyntaxIdentity<VariableDeclaration>, in p: Program
    ) {
        self.init(
            label: p[d].identifier.value, kind: CompletionItemKind.variable,
            detail: "\(p[d].identifier.value): \(p.show(p.type(assignedTo: d)))")
    }
}
