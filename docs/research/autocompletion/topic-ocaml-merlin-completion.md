# Merlin & ocaml-lsp Completion: Environment-at-Point, Type Direction, and Error Recovery

## 1. The big picture: completion is a query over a typed AST, not over text

Merlin treats the editor buffer as a (possibly broken) program that it always reduces to **a typed AST plus a list of errors**, never to "an exception." Completion is then a *query* that (a) finds the AST node and its **typing environment** at the cursor, and (b) folds that environment for names matching a prefix, optionally ranked by an expected type. This is the central idea worth transferring to Hylo: build the typed tree once, attach an `Env`/scope to every node, and make completion a fold over the environment reachable at the cursor node.

The pipeline is orchestrated by `Mpipeline` (`src/kernel/mpipeline.ml`), which "implements a few high-level primitives that connect all pieces together," wiring:
- `Mconfig` (`src/kernel/mconfig.ml`) — one big settings record + parser/dumper; `mconfig_dot.ml` reads `.merlin`/dune project config.
- `Mreader` (`src/kernel/mreader.ml`) — "turns an `Msource.t` into an AST," via `mreader_lexer.ml`, `mreader_parser.ml`, and crucially `mreader_recover.ml` (syntax-error recovery) and `mreader_explain.ml` (diagnostics).
- `Mtyper` (`src/kernel/mtyper.ml`) — "wraps the OCaml typechecker, to type the ASTs produced by `mreader.ml`"; `mocaml.ml` sets up/restores typechecker global state.
- `Query_commands` (`src/frontend/query_commands.ml`) — "executes the queries defined by the protocol. It uses `src/kernel` for parse and typing. Then it uses `src/analysis` to get some results."
- `src/analysis/*` — `completion.ml`, `expansion.ml`, `mbrowse.ml`, `browse_tree.ml`, `locate.ml`, `destruct.ml`, etc.

Sources: [ARCHITECTURE.md](https://github.com/ocaml/merlin/blob/main/doc/dev/ARCHITECTURE.md), [experience report (arXiv 1807.06702)](https://arxiv.org/pdf/1807.06702).

---

## 2. Building the typing environment at the cursor

### 2.1 The Typedtree is the source of environments

OCaml's typechecker annotates **every** Typedtree node with the typing `Env.t` in force at that node (values, constructors, labels, types, modules, module-types in scope, including local `let`/`open`/functor parameters). Merlin exploits this: instead of re-deriving scopes, it *navigates to the node at the cursor and reads off its environment.*

Two analysis modules do the navigation:
- `Mbrowse` (`src/analysis/mbrowse.ml`) — "uniform navigation in typedtree, mainly answering 'what is around this position?'" It exposes `Mbrowse.of_typedtree`, `Mbrowse.enclosing` (the stack of nodes enclosing a position), and `Mbrowse.leaf_node` (innermost node + its env).
- `Browse_tree` (`src/analysis/browse_tree.ml`) — "uniform traversal of typedtree," wrapping `Browse_raw`.

### 2.2 The exact code path for completion

In `query_commands.ml`, both `Complete_prefix` and `Expand_prefix` resolve the cursor to a typed node and pull the environment out of it:

```ocaml
let pipeline, typer = for_completion pipeline pos in
let pos    = Mpipeline.get_lexing_pos pipeline pos in
let branch = Mtyper.node_at ~skip_recovered:true typer pos in
let env, _ = Mbrowse.leaf_node branch in
```

- `Mtyper.node_at ?disambiguate ?(skip_recovered=false) t pos` walks the Typedtree to the node whose location matches the cursor; `skip_recovered:true` ignores synthesized/recovery nodes so completion attaches to *real* user context.
- `Mbrowse.leaf_node branch` returns `(env, node)` — **the environment-at-point**. This `env` is the entire input to candidate generation.

This is the model to copy for Hylo: a function `nodeAt(position) -> (Scope/Env, Node)` over the typed AST, where the env already encodes everything in scope (including trait conformances and givens reachable from that scope).

Sources: [query_commands.ml](https://github.com/ocaml/merlin/blob/master/src/frontend/query_commands.ml), [mbrowse.ml](https://github.com/ocaml/merlin/blob/main/src/analysis/mbrowse.ml), [mtyper.ml](https://github.com/ocaml/merlin/blob/main/src/kernel/mtyper.ml).

---

## 3. Candidate generation: folding the environment

The engine is `src/analysis/completion.ml`. Key functions:

### 3.1 `get_candidates` — the core fold
Signature (approximately):
```ocaml
get_candidates ?get_doc ?target_type ?prefix_path ~prefix kind ~validate env branch
```
It enumerates everything in scope by **folding over `Env.t`** per namespace:
- `Env.fold_values`, `Env.fold_constructors`, `Env.fold_types`, `Env.fold_modules`, `Env.fold_labels`, `Env.fold_modtypes`, `Env.fold_classes`.
- A `prefix_path` (the qualified part of a `Module.sub.prefix`) restricts the fold to a namespace; the bare `prefix` filters the leaf name.
- `validate` is a predicate per namespace; `kind` selects which namespaces to enumerate (values, constructors, types, modules, module types, labels, keywords).

Each hit becomes a completion item via `make_candidate` (name, kind, type, docstring) wrapped by `make_weighted_candidate` carrying sort metadata `(priority, time, name)`.

### 3.2 `branch_complete` / `complete_prefix` — context dispatch
- `branch_complete config ~kinds ?get_doc ?target_type ~keywords prefix branch` is the dispatcher called from `query_commands.ml`. It looks at the innermost AST node to decide the completion *mode*:
  - **Method call** (`obj#m…`): `complete_methods` enumerates the object type's methods.
  - **Record expression / pattern**: it sets `is_label` and enumerates the record's labels (label declarations from the record's type descriptor, via `Datarepr`/`Env.lookup_all_labels_from_type`).
  - **Polymorphic / sum-type constructors**: `fold_variant_constructors` / `fold_sumtype_constructors`.
  - Otherwise the general identifier path.
- `complete_prefix ?get_doc ?target_type ?(kinds=[]) ~keywords ~prefix ~is_label config (env,node) branch` classifies the node and chooses namespaces accordingly.

### 3.3 Prefix parsing with `Longident`
The textual prefix is parsed into a qualified path: `Longident.Lident "x"` (bare) vs `Longident.Ldot (path, leaf)` (`Module.x`). Merlin splits off the trailing component (the part still being typed) from the resolved `prefix_path`, so `List.ma` folds *only* the `List` module's values for names starting with `ma`. This name decomposition — giving each path component its own location — is also what powers "type at point on `List` vs on `length`" (report §4.1).

Sources: [completion.ml](https://github.com/ocaml/merlin/blob/main/src/analysis/completion.ml).

---

## 4. Type-directed completion

This is Merlin's most transferable idea for a trait/generics language.

### 4.1 Finding the expected type: `application_context`
In `query_commands.ml`:
```ocaml
let target_type, context = Completion.application_context ~prefix branch in
```
`application_context` inspects the enclosing node. If completion happens **inside a function application** (`Texp_apply`), it walks the function's arrow type and computes the type expected at the current argument position. `labels_of_application` extracts still-unapplied labeled/optional argument names from the same `Texp_apply` so labels like `~foo:` are offered. The resulting `target_type` is threaded as `?target_type` into `get_candidates`.

### 4.2 Ranking by unification cost: `type_check`
Inside `get_candidates`, each candidate's type scheme is trial-unified against `target_type`:
- Take a `Btype.snapshot ()`, attempt `Ctype.unify_var env target_type candidate_scheme`, then roll back (snapshot/backtrack — the same rollback mechanism the OCaml toplevel uses, report §3.3).
- **Priority = `1000 - cost - head_arrows`**, where `cost` = number of unification variables instantiated to make the types unify, and arrow heads are skipped so a function whose *result* matches (partial application) still ranks, but is penalized by how many arguments it still needs.
- Final sort: **priority, then binding time (most recently bound identifiers first — locality), then alphabetical.** "Binding time" means a local `let` ranks above a stdlib value of equal type fit.

This gives "offer the values that fit the hole, best fit first" without a separate constraint solver — it reuses the typechecker's own unification + snapshot.

Sources: [completion.ml](https://github.com/ocaml/merlin/blob/main/src/analysis/completion.ml), report §3.3.

---

## 5. The "expand-prefix" command (fuzzy / spell-corrected)

`Expand_prefix` is a distinct command (`["expand","prefix",string,"at",pos]`) handled separately:
```ocaml
Completion.expand_prefix env ~global_modules ~kinds prefix
```
It does **not** do type-directed ranking; instead it uses `src/analysis/expansion.ml` (`Expansion.explore`) to expand abbreviated/misspelled qualified paths against the set of global modules — e.g. `L.ma → List.map`. The PROTOCOL describes it as "behaves like complete-prefix but also handles partial, incorrect, or wrongly spelled prefixes … a useful fallback if normal completion gave no results." The `with doc` variants additionally do an OCamldoc lookup (more expensive), so doc fetching is opt-in.

Sources: [PROTOCOL.md](https://github.com/ocaml/merlin/blob/main/doc/dev/PROTOCOL.md), [OLD-PROTOCOL.md](https://github.com/ocaml/merlin/blob/main/doc/dev/OLD-PROTOCOL.md), [expansion.ml](https://github.com/ocaml/merlin/blob/main/src/analysis/expansion.ml).

---

## 6. Handling incomplete / invalid code at the cursor

This is where Merlin's design is most instructive; the guarantee is *"there is always a typed AST, however wrong."*

### 6.1 Parser recovery (`mreader_recover.ml`, Menhir extension)
- The Menhir LR parser enters **recovery** at the first unexpected token (LR detects errors at the earliest position). It does **not backtrack**; it keeps all parsed input and only *fills holes*.
- Missing right-hand nodes are **synthesized** using grammar annotations: `[@cost n]` on transitions and `[@recovery value]` giving a semantic value, e.g. `%token <string> STRING [@cost 1] [@recovery ""]` and `match_cases [@recovery []]`. A minimum-cost completion is searched so the synthesized program is most likely to make user code well-typed.
- **Indentation heuristic** decides whether to synthesize a node or resume consuming real tokens (compare current token column vs top-of-stack column).
- Semantic actions must be observably pure (recovery may run them multiple times); failing actions get infinite cost.
- Lexer recovery is deliberately minimal: log error, resume from next lexable char (report §3.5).

### 6.2 Typer recovery (patched OCaml typechecker)
- **All-errors, not first-error**: Merlin "sneaks into the recursion" of the type-checker's expression/pattern/module functions, catches the raised error, logs it, and resumes — so one bad subterm doesn't kill the rest.
- **Fake nodes for ill-typed subterms**: when a subterm fails, Merlin emits a Typedtree node *with the type its context expected* and the partial sub-derivations as children. This keeps source positions present in the typed tree, so cursor queries still land on a node (with an env).
- **"Future environment" perspective**: a missing record label or unresolved name isn't fatal — the typer continues "as if it will be added later." Quote: the shift from "is this subterm correct in my environment?" to "would this subterm be correct in a *future extension* of my typing environment?"

### 6.3 The completion-specific hack: dummy identifier insertion
When there is *nothing* under the cursor, `for_completion` (in `mpipeline.ml`) re-runs typing with a **dummy/empty identifier injected at the cursor** so the typechecker produces a node with a usable environment and expected type:
- `(1 + ❚)` → inserting an ident lets it type-check and yields the `int` expectation.
- `(f ❚)` → the inserted ident creates a `Texp_apply` node, so `application_context` can read `f`'s argument type as `target_type`.
This `for_completion` path is why `Complete_prefix` calls `for_completion pipeline pos` rather than the normal typed pipeline.

Sources: report §§3.4–3.8, §4.2; [query_commands.ml](https://github.com/ocaml/merlin/blob/master/src/frontend/query_commands.ml), [mpipeline.ml](https://github.com/ocaml/merlin/blob/main/src/kernel/mpipeline.ml).

---

## 7. Caching / incrementality (so completion is fast on every keystroke)

`Mtyper` (`src/kernel/mtyper.ml`) implements **prefix-reuse incremental typing**:
- `fresh_env config` captures a clean baseline: `Typer_raw.fresh_env ()`, type-var state `Btype.snapshot ()`, `Ident.get_currentstamp ()`, `Shape.Uid.get_current_stamp ()`.
- The typer caches a list of typed `item` records, each holding its typed tree fragment, signature, post-item environment (`part_env`), id/uid stamps (`part_stamp`, `part_uid`), a validity snapshot (`part_snapshot`), and a lazy occurrence index (`part_index`).
- `compatible_prefix` compares cached items against the new parsetree items top-down: while `Types.is_valid ritem.part_snapshot` **and** `compare ritem.parsetree_item pitem = 0`, the prefix is reused (`Hit { reused; typed }`); the first mismatch is a `Miss`. Typing then **resumes from the last good snapshot** and only re-types the changed suffix.
- This rests on the toplevel's snapshot/rollback: "after a buffer change, Merlin restarts typing from the last snapshot before the change," giving bounded work per edit under the "edits are local" assumption (report §3.3).
- Interface caches: `cmi_cache.ml`/`cmt_cache.ml` cache `.cmi`/`.cmt`; `local_store.ml` snapshots/restores the typechecker's mutable globals between queries. Merlin also re-checks `.cmi` mtimes so recompiles invalidate the env (report §3.8.1).
- `get_typedtree` reassembles the full tree from items; `node_at` and `get_index` (forcing `part_index`) drive position queries and occurrences.

For PPX-preprocessed buffers, where no incremental interface exists, Merlin falls back to **memoizing the typing environment per prefix sequence of phrases** (report §2.3.4).

Sources: [mtyper.ml](https://github.com/ocaml/merlin/blob/main/src/kernel/mtyper.ml), report §§2.3.4, 3.3, 3.8.1.

---

## 8. Polymorphism and functors

- **Polymorphism**: candidate type schemes are *instantiated* before trial-unification with the expected type, so a `'a list`-returning function unifies with an `int list` hole at `cost` measured in instantiated variables (§4). Report §4.1 also notes the local vs global tension: a local occurrence of `[]` may be `int list`, but Merlin can also report the more general `'a list` from the unit's global environment — relevant when the local derivation is corrupted by an earlier error.
- **Functors / module aliases**: handled mostly in `locate.ml` (go-to-definition), and acknowledged as *hard*. For `module M = Id(A)`, resolving `M.f` currently lands on the functor *application*, not `A.f`; users want it to follow `include`/aliases/functor results. The lesson: name resolution through functor application and module equality needs an explicit "how deep do you want to follow aliases?" policy. For completion specifically, because everything flows through the post-application `Env.t` attached to nodes, completing `M.` *does* enumerate the functor result's signature correctly even though jump-to-def is ambiguous.

Sources: report §§4.1, 4.3; [locate.ml](https://github.com/ocaml/merlin/blob/main/src/analysis/locate.ml).

---

## 9. ocaml-lsp layer

`ocaml-lsp` (`ocaml/ocaml-lsp`) is a thin LSP server built on `merlin-lib`; it does not reimplement completion. On `textDocument/completion` it calls Merlin's `Complete_prefix` (and `Expand_prefix` as fallback / on demand), maps Merlin completion kinds → LSP `CompletionItemKind`, and defers docs and types to `completionItem/resolve` (mirroring Merlin's "with doc" being expensive). It reuses Merlin's `Query_protocol.Complete_prefix`/`Expand_prefix` and the `Mpipeline` machinery above. (Behavioral cite: ocaml-lsp's completion module wraps `Query_commands`; the substantive algorithm is entirely Merlin's.)

Source: [ocaml/ocaml-lsp](https://github.com/ocaml/ocaml-lsp).

---

## 10. Transfer notes for a trait-based, Swift-implemented Hylo LSP

1. **Make completion a query over the typed AST, with an environment on every node.** Hylo's frontend already has a typed AST, scopes, and conformance lookup; expose `nodeAt(pos) -> (Scope, Node)` analogous to `Mbrowse.leaf_node`. The scope must already carry *everything visible*: locals, module members, in-scope traits, and **given/implicit instances** — so completion is just folding that scope by namespace, exactly like `Env.fold_*`.

2. **Type-direct completion by trial-solving against the expected type — reuse your own checker.** Merlin's `application_context` + unify-with-rollback is the template. In Hylo, when completing an argument or an expression with a known expected type, run the conformance/constraint solver in a *snapshot/transactional* mode: a candidate ranks higher the fewer fresh type variables / the cheaper the conformance derivation needed to make it fit. Critically, this naturally extends Merlin's "cost" to **trait-bound satisfaction**: prefer candidates whose required conformances are already satisfied by givens in scope; penalize those needing additional bounds. This is the single highest-value idea to port.

3. **Member/`.`-completion via the receiver's type + its conformances.** Merlin's record/method/variant dispatch in `branch_complete` maps directly: for `recv.` enumerate stored members **plus** the methods contributed by every trait `recv`'s type conforms to (resolved through Hylo's conformance lookup), just as Merlin merges record labels and object methods. Split the qualified prefix like `Longident` so `T.` only enumerates `T`'s namespace.

4. **Always produce a typed tree for broken input; attach scopes to error nodes.** Adopt Merlin's "typed AST + error list, never an exception" contract and its **fake-node-with-expected-type** trick so the cursor always lands on a node carrying a scope. Without this, completion dies exactly when the user is mid-edit (the common case).

5. **Insert a dummy identifier at an empty cursor.** Port the `for_completion` hack: synthesize a placeholder expression at the caret so the checker forms an application/member node and yields an expected type and conformance context — especially valuable for `f(<here>)` where the parameter's type (and its trait bounds) drives ranking.

6. **Parser recovery with cost-annotated synthesis + indentation heuristic.** If Hylo's parser can be made recoverable, Merlin's minimum-cost hole-filling (`[@cost]`/`[@recovery]`) plus the indentation-based "synthesize vs consume" decision is a proven, language-agnostic recipe.

7. **Incremental typing via prefix-reuse and snapshots.** Mirror `Mtyper`'s `compatible_prefix`: cache per-top-level-declaration typed items with a validity snapshot; on edit, reuse the unchanged prefix and re-check only the suffix. Combine with stamp/UID snapshots so the solver's mutable state is restorable. Cache compiled module interfaces and invalidate on mtime change. In Swift, model the "snapshot/rollback of unification state" explicitly (value-type checker state or an undo log) — Merlin gets this for free from OCaml's toplevel design, Hylo will need to build it.

8. **Rank by `(type-fit, locality, name)`.** Reuse Merlin's three-tier sort: trait-aware fit cost first, then binding recency (locals/givens introduced nearest the cursor win), then lexicographic.

9. **Separate cheap completion from expensive fuzzy/doc lookup.** Keep a fast `complete-prefix` and a fallback fuzzy `expand-prefix`; make docstring/type rendering lazy (LSP `resolve`), as both Merlin and ocaml-lsp do.

---

### Primary sources
- Completion engine: https://github.com/ocaml/merlin/blob/main/src/analysis/completion.ml
- Command dispatch / cursor→env: https://github.com/ocaml/merlin/blob/master/src/frontend/query_commands.ml
- Incremental typer & cache: https://github.com/ocaml/merlin/blob/main/src/kernel/mtyper.ml
- Architecture overview: https://github.com/ocaml/merlin/blob/main/doc/dev/ARCHITECTURE.md
- Env-at-point navigation: https://github.com/ocaml/merlin/blob/main/src/analysis/mbrowse.ml , https://github.com/ocaml/merlin/blob/main/src/analysis/browse_tree.ml
- Fuzzy expansion: https://github.com/ocaml/merlin/blob/main/src/analysis/expansion.ml
- Protocol (complete-prefix / expand-prefix semantics): https://github.com/ocaml/merlin/blob/main/doc/dev/PROTOCOL.md , https://github.com/ocaml/merlin/blob/main/doc/dev/OLD-PROTOCOL.md
- Experience report (recovery, incrementality, completion heuristics, functors): https://arxiv.org/pdf/1807.06702 (also http://gallium.inria.fr/~scherer/drafts/merlin.pdf)
- LSP wrapper: https://github.com/ocaml/ocaml-lsp