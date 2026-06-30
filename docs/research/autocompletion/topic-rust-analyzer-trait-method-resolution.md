# rust-analyzer: Method/Member Resolution and Enumeration for Dot Completion

## 0. Orientation: two layers, and a recent architectural shift

rust-analyzer splits the work across two crates:

- **`hir-ty`** — the type-system engine. Contains `method_resolution.rs` plus its submodules `method_resolution/probe.rs` and `method_resolution/confirm.rs`, and `autoderef.rs`. This is where receiver types are dereferenced, candidates are assembled, and the trait solver is consulted.
- **`ide-completion`** — the IDE feature layer. `completions/dot.rs` drives DOT completion: it asks `hir-ty` (through the `hir` façade) to *enumerate* applicable methods/fields and turns each into a completion item.

A major caveat that shapes any reading of the current source: **rust-analyzer is mid-migration from a Chalk-based trait solver to a port of rustc's "next-generation" trait solver.** The method-resolution code I quote below from `master` (`MethodResolutionContext`, `probe.rs`/`confirm.rs`, `InferCtxt`, `ParamEnv`, `consider_probe`) is the **new** machinery, modeled directly on `rustc_hir_typeck::method::probe`. Historically — and in most material you'll find online — the entry points were named `iterate_method_candidates`, `iterate_method_candidates_dyn`, `iterate_trait_method_candidates`, `iterate_inherent_methods`, and the solver was **`chalk-solve`** (the `hir-ty/src/traits.rs` + `chalk_ir`/`chalk_solve` integration). Both designs share the same *shape*, so the transfer lessons hold regardless of which snapshot you read. I flag which is which throughout.

Primary sources:
- `crates/hir-ty/src/method_resolution.rs` — https://github.com/rust-lang/rust-analyzer/blob/master/crates/hir-ty/src/method_resolution.rs
- `crates/hir-ty/src/method_resolution/probe.rs` — https://github.com/rust-lang/rust-analyzer/blob/master/crates/hir-ty/src/method_resolution/probe.rs
- `crates/hir-ty/src/autoderef.rs` — https://github.com/rust-lang/rust-analyzer/blob/master/crates/hir-ty/src/autoderef.rs
- `crates/ide-completion/src/completions/dot.rs` — https://github.com/rust-lang/rust-analyzer/blob/master/crates/ide-completion/src/completions/dot.rs
- `crates/hir-def/src/resolver.rs` — https://github.com/rust-lang/rust-analyzer/blob/master/crates/hir-def/src/resolver.rs

---

## 1. The IDE-side driver: `complete_dot` (ide-completion/src/completions/dot.rs)

DOT completion does **not** itself know about traits or autoderef; it delegates enumeration to `hir-ty` and concerns itself with *deduplication and visibility presentation*.

### Fields — `complete_fields`
Fields are gathered by **walking the autoderef chain** directly:

```rust
fn complete_fields(
    acc: &mut Completions,
    ctx: &CompletionContext<'_, '_>,
    receiver: &hir::Type<'_>,
    mut named_field: impl FnMut(&mut Completions, hir::Field, hir::Type<'_>),
    mut tuple_index: impl FnMut(&mut Completions, usize, hir::Type<'_>),
    has_parens: bool,
)
```

It iterates `receiver.autoderef(ctx.db)` and keeps a `seen_names` set so a field shadowed deeper in the deref chain is not offered twice. With `has_parens` it restricts to callable (function/closure) field types — the "calling a field that holds a closure" case.

### Methods — `complete_methods`
Methods are enumerated via a callback into `hir-ty`:

```rust
receiver.iterate_method_candidates_split_inherent(...)  // drives a MethodCandidateCallback
```

The callback (`Callback: MethodCandidateCallback`) carries two dedup structures:
- `seen_methods` — dedup by **`FunctionId`** across the whole walk (avoids the *same* method appearing twice when reachable as both inherent and via trait).
- `seen_inherent_methods` — tracks inherent methods **by name** so a private-but-shadowing inherent method can be filtered.

The crucial design comment: *"We don't want to exclude inherent trait methods — that is, methods of traits available from `where` clauses or `dyn Trait`."* So trait methods are **not** name-deduped against each other; only inherent ones are.

### Visibility presentation (`on_inherent_method`)
Visibility is resolved by `ctx.is_visible(...)` returning a tri-state:
- `Visible::Yes` → offered, but skipped if the same name was already seen (shadowing).
- `Visible::Editable` → private but in an editable file → offered anyway.
- `Visible::No` → only offered if the name hasn't been seen.

Trait methods *skip the visibility check entirely* — the comment notes deduplicating inherent methods by name "is usually meaningless" for traits. This split mirrors Rust's rule that a trait method is callable iff the *trait* is in scope, independent of the method's own `pub`-ness.

### `complete_undotted_self`
When `enable_self_on_the_fly` is on, typing a bare identifier inside a method body also completes `self.<field>`/`self.<method>` by synthesizing a `DotAccess { receiver: None, .. }` from the `self` parameter type and re-running `complete_fields`/`complete_methods`.

### `.await` / `.iter()` sugar
`complete_dot` additionally injects `.await` for `Future` receivers (`enable_auto_await`) and `.iter()`/`.into_iter()` (`enable_auto_iter`) — these are not real members, they are completion affordances layered on top of the real enumeration.

**Incomplete-code handling here:** the receiver type is taken as `receiver_ty.original`; if inference produced `{unknown}` for the receiver, `autoderef` and method iteration simply yield nothing rather than crashing (the type engine treats unknowns as `TyKind::Error`, see §3). The completion layer is robust to partial expressions because it operates on whatever inferred type the (error-tolerant) frontend produced.

---

## 2. Enumerating candidates: `method_resolution.rs` + `probe.rs`

### 2.1 The two enumeration entry points
The "find all members for completion" path is distinct from the "resolve this one call" path:
- `probe_all()` — enumerate **all** applicable candidates (this is what completion wants).
- `probe_for_name()` — find the single best candidate for an actual call.

Both funnel through `probe_op()`, which (1) computes the autoderef steps, (2) builds a `ProbeContext`, (3) assembles candidates, (4) applies find-all vs find-one. (Source: `probe.rs`.)

The whole operation is parameterized by `MethodResolutionContext`, which **captures the in-scope trait set as precomputed data**:

```rust
pub struct MethodResolutionContext<'a, 'db> {
    pub infcx: &'a InferCtxt<'db>,
    pub resolver: &'a Resolver<'db>,
    pub param_env: ParamEnv<'db>,
    pub traits_in_scope: &'a FxHashSet<TraitId>,
    pub edition: Edition,
    pub features: &'a UnstableFeatures,
    pub call_span: Span,
    pub receiver_span: Span,
}
```

### 2.2 `Mode` — receiver-call vs path
```rust
pub enum Mode {
    MethodCall,  // receiver.method(...): autoderefs performed, static methods excluded
    Path,        // Type::item / <T>::item: no autoderef, static methods included
}
```
DOT completion uses `MethodCall`. `Path` mode (used by `iterate_path_candidates`) is for `Type::` completion and offers associated functions without a `self`.

### 2.3 Autoderef-driven steps and receiver adjustments
For `MethodCall`, `probe_op` first builds the **deref ladder** (`method_autoderef_steps`):

```rust
pub struct CandidateStep<'db> {
    pub self_ty: Canonical<'db, QueryResponse<'db, Ty<'db>>>,
    pub autoderefs: usize,
    pub from_unsafe_deref: bool,    // step came from dereffing a raw pointer
    pub unsize: bool,               // [T; N] -> [T] coercion
    pub reachable_via_deref: bool,  // reachable purely through Deref (vs Receiver) chain
    // ...
}
```

For each step, the resolver may further adjust the receiver:

```rust
pub enum AutorefOrPtrAdjustment {
    Autoref { mutbl: Mutability, unsize: bool },  // insert & / &mut, maybe unsize
    ToConstPtr,                                    // *mut T -> *const T
}
```

So the full receiver transform for a candidate is: *N derefs, then optionally one autoref (`&`/`&mut`) or `*mut→*const`*. This is exactly rustc's "autoderef then autoref" algorithm: try the type, then `&T`, then `&mut T`, deref, repeat. `reachable_via_deref` distinguishes the plain `Deref` chain from the more permissive arbitrary-`self`-types `Receiver` chain.

### 2.4 The candidate taxonomy
```rust
pub enum CandidateKind<'db> {
    InherentImplCandidate { impl_def_id: ImplId, receiver_steps: usize },
    ObjectCandidate(PolyTraitRef<'db>),      // method from a dyn Trait's principal
    TraitCandidate(PolyTraitRef<'db>),       // from a trait in traits_in_scope
    WhereClauseCandidate(PolyTraitRef<'db>), // from a generic param's bound / where-clause
}
```

Assembly order (in the `pick_all_method` / assemble routines):

1. **Inherent impls** — `assemble_inherent_candidates`. For every autoderef step, `assemble_probe` dispatches on the type's shape (ADT / foreign / `dyn` / param / primitive) and calls `assemble_inherent_impl_candidates_for_type`, which **looks up the precomputed `InherentImpls` index** keyed by *simplified type*:
   ```rust
   pub struct InherentImpls { map: FxHashMap<SimplifiedType, Box<[ImplId]>> }
   ```
   Keying by `simplify_type(.., TreatParams::InstantiateWithInfer)` is a fast pre-filter: only impls whose self-type head-symbol matches the receiver are even considered.

2. **Trait extension methods in scope** — `assemble_extension_candidates_for_traits_in_scope`. Iterates **`self.ctx.traits_in_scope`** (see §4); for each trait, instantiates it with fresh inference vars and adds a `TraitCandidate` for items whose `self` could apply. The trait index itself splits blanket vs non-blanket impls:
   ```rust
   struct OneTraitImpls {
       non_blanket_impls: FxHashMap<SimplifiedType, (Box<[ImplId]>, Box<[BuiltinDeriveImplId]>)>,
       blanket_impls: Box<[ImplId]>,
   }
   ```
   `blanket_impls(trait)` returns the impls with a generic self type (e.g. `impl<T: Display> ToString for T`) — these can't be keyed by simplified type so they're always candidates and must be checked by the solver.

3. **Where-clause / param-bound candidates** — `assemble_inherent_candidates_from_param`. When the receiver is a generic type parameter `T`, it scans the `param_env`'s predicates for trait bounds on `T` (i.e. `T: Trait`), fast-rejecting with `DeepRejectCtxt`, and adds `WhereClauseCandidate`s. **This is how `T: Trait` makes `Trait`'s methods dot-completable on a `T` receiver even with no concrete impl in sight.**

4. **Object (`dyn Trait`) candidates** — `assemble_inherent_candidates_from_object`. Extracts the principal trait from a `dyn` type, **elaborates supertraits**, and adds `ObjectCandidate`s (vtable-dispatched methods).

### 2.5 Visibility filtering at assembly time
```rust
fn push_candidate(&mut self, candidate: Candidate<'db>, is_inherent: bool) {
    let is_accessible = if is_inherent {
        let visibility = self.db().assoc_visibility(candidate_id);
        self.ctx.resolver.is_visible(self.db(), visibility)
    } else {
        true  // trait methods always accessible
    };
    if is_accessible { /* push to inherent/extension list */ }
    else { self.private_candidates.push(candidate); }  // kept only for diagnostics
}
```
Two rules worth stealing: **(a) inherent-method visibility is checked against the cursor's module via the `Resolver`; (b) trait-method "visibility" is governed entirely by trait-in-scope, not the fn's own modifier.** Private inherent matches are stashed for "this exists but is private" diagnostics (`MethodError::PrivateMatch`).

### 2.6 Confirming a candidate against the trait solver — `consider_probe`
```rust
fn consider_probe(
    &self,
    self_ty: Ty<'db>,
    instantiate_self_ty_obligations: &[PredicateObligation<'db>],
    probe: &Candidate<'db>,
) -> ProbeResult
```
For each assembled candidate this: instantiates the impl/trait generics with fresh inference vars; **relates the candidate's self type to the actual receiver type** (respecting variance per `Mode`); registers the impl's/trait's predicates as **obligations**; **evaluates all obligations via the trait solver**; and rejects on opaque-type mismatches. Returns `Match`/`NoMatch`. This is the step that enforces `where`-clauses and conditional impls: a blanket `impl<T: Display> ToString for T` only survives if `Self: Display` is provable.

### 2.7 The result — `Pick`
```rust
pub struct Pick<'db> {
    pub item: CandidateId,
    pub kind: PickKind<'db>,
    pub autoderefs: usize,
    pub autoref_or_ptr_adjustment: Option<AutorefOrPtrAdjustment>,
    pub self_ty: Ty<'db>,
    pub receiver_steps: Option<usize>,    // inherent impls only
    pub shadowed_candidates: Vec<CandidateId>,
}
```
A `Pick` is the *complete receiver transformation*: how many derefs, whether to autoref, and which impl/trait supplied the method. `shadowed_candidates` records candidates hidden by the chosen one (used for "ambiguous"/lint diagnostics). Errors are surfaced as:
```rust
pub enum MethodError<'db> {
    NoMatch, Ambiguity(Vec<CandidateSource>),
    PrivateMatch(Pick<'db>),
    IllegalSizedBound { candidates: Vec<FunctionId>, needs_mut: bool },
    ErrorReported,
}
```

---

## 3. Autoderef: `autoderef.rs` — and incomplete-type tolerance

```rust
pub fn autoderef<'db>(
    db: &'db dyn HirDatabase,
    env: ParamEnvAndCrate<'db>,
    ty: Canonical<'db, Ty<'db>>,
) -> impl Iterator<Item = Ty<'db>> + use<'db>
```
Guarantee: *"the yielded types don't contain inference variables (but may contain `TyKind::Error`)."*

```rust
pub(crate) enum AutoderefKind {
    Builtin,     // &T, *mut T, etc.
    Overloaded,  // dispatch through a Deref impl
}
const AUTODEREF_RECURSION_LIMIT: usize = 20;
```

Each step tries `cur_ty.builtin_deref(include_raw_pointers)` first, else `overloaded_deref_ty()` (resolve `Deref<Target = ?>` via the trait solver). Termination and robustness are explicitly engineered for IDE use on broken code:

- **Unknown receiver:** `if self.state.cur_ty.is_ty_var() { return None; }` — an undetermined receiver stops the chain instead of looping. During finalization, leftover inference vars are `replace_infer_with_error` (→ `TyKind::Error`), so downstream code keeps working.
- **Recursion cap:** stops at `AUTODEREF_RECURSION_LIMIT = 20`.
- **Cycle guard:** *"If the deref chain contains a cycle (e.g. A derefs to B and B derefs to A), we would revisit some already visited types."* It tracks visited types (`Vec::contains`) and breaks on a cycle — important when a user's half-written `impl Deref` is circular.

This is the core "how it survives invalid code at the cursor" mechanism: **unknown ⇒ error type, never a crash or hang; bounded + cycle-guarded iteration.**

---

## 4. Which traits are "in scope"? `hir-def/src/resolver.rs::traits_in_scope`

The trait set fed to `MethodResolutionContext.traits_in_scope` is computed lexically at the cursor's scope:

```rust
pub fn traits_in_scope(&self, db: &dyn DefDatabase) -> FxHashSet<TraitId>
```

It unions traits from, roughly:
- **Block scopes** — `m.def_map[m.module_id].scope.traits()` for each enclosing block (locally `use`d traits).
- **Enclosing `impl` blocks** — if the impl has a `target_trait`, that trait (and its generic context) is in scope, resolved via `resolve_path_in_type_ns_fully`.
- **Prelude** — `prelude.def_map(db)[prelude].scope.traits()` (so `ToString`, `Iterator`, etc. are always available).
- **Module scope** — module-visible traits via `self.module_scope.def_map[...].scope.traits()`.

```rust
pub fn traits_in_scope_from_block_scopes(&self)
    -> impl Iterator<Item = TraitId> + '_
```
Note the documented design boundary: *"Trait availability derives from explicit scoping mechanisms (blocks, impls, preludes) rather than where-clause resolution at this layer."* — i.e. `use`/prelude/impl govern the `TraitCandidate` set, while **`where`-clause–derived methods come in separately as `WhereClauseCandidate`s** in `probe.rs` (§2.4 step 3). Keeping those two sources distinct is deliberate.

---

## 5. The trait-solver's role (chalk → next-gen)

Across both eras the solver does the same job for completion: given a candidate impl/trait and a (possibly partially-inferred) self type, **decide whether the required obligations hold** (`Self: Bound`, associated-type equalities, blanket-impl preconditions). Concretely:
- It powers `overloaded_deref_ty` (is there a `Deref` impl, and what's `Target`?), which builds the autoderef chain.
- It powers `consider_probe`'s obligation evaluation, which prunes blanket/conditional impls whose `where`-clauses fail.

Historically this was **`chalk-solve`** invoked from `hir-ty/src/traits.rs` (Chalk's canonical-goal/`Solution` API, with rust-analyzer providing a `RustIrDatabase`). `master` is porting **rustc's next-gen trait solver** (`InferCtxt`/`ParamEnv`/`PredicateObligation` in the quoted signatures) into rust-analyzer, replacing Chalk. For an autocomplete designer the takeaway is solver-agnostic: *enumeration produces a superset of syntactic candidates; the solver is the semantic filter that says which actually apply.* (Performance note: this filter is the expensive part — see real issues like "Slow completion in `iterate_trait_method_candidates`" #17068 and "Trait solver taking >10s in auto complete" #19291.)

---

## 6. Transfer notes for a trait-based, Swift-implemented LSP (Hylo)

1. **Two-phase: cheap syntactic enumeration, then semantic filtering.** Mirror `assemble_*` (gather a superset by self-type head symbol) then `consider_probe` (let the conformance/given solver reject). Don't try to make enumeration exact; make it *complete and fast*, and let the solver prune.

2. **Index impls/conformances by a "simplified type" key**, splitting **blanket/conditional conformances** into a separate always-considered bucket (rust-analyzer's `non_blanket_impls` map vs `blanket_impls`). Hylo's conformance lookup should pre-bucket conformances by the head type constructor; generic/blanket conformances (`extension<T> T: P where ...`) go in the unkeyed bucket and are always trial-fit.

3. **Model the four candidate sources explicitly**, as Hylo has direct analogues:
   - inherent members (members declared on the type),
   - trait/extension methods gated by **what's in lexical scope** (Hylo `trait` conformances + imported extensions),
   - **bound-derived members from generic parameters** (`T: P` / Hylo trait bounds & *givens* → the `WhereClauseCandidate` analogue — these must be completable on a `T` receiver with no concrete witness),
   - existential/`dyn`-like members (Hylo's existentials), elaborating **supertraits/refinements**.
   The `WhereClauseCandidate` path is the one easiest to forget and the most valuable for generic-heavy code: enumerate trait methods reachable purely through the parameter's declared bounds and in-scope givens.

4. **Separate "method visibility" from "trait/given in scope."** rust-analyzer never checks a trait method's own visibility — availability is "is the trait imported?" Hylo should gate extension/trait members on *conformance/given visibility & scope*, and reserve `pub`/access checks for inherent members. Keep private-but-matching items around for "exists but inaccessible" diagnostics rather than dropping them silently (`MethodError::PrivateMatch`).

5. **Make the receiver-adjustment chain a first-class, bounded iterator that is error-tolerant.** Port the autoderef design literally: yield types that may be `Error` but never inference variables; **stop on an unresolved receiver**; cap iterations (RA uses 20); and **guard against cycles** in user-defined deref/coercion. For Hylo (mutable value semantics, projections, `subscript`/access chains) the analogue is the projection/conversion chain — bound it and cycle-guard it so a malformed user type can't hang completion. Carry the full adjustment (how many steps, plus any ref/`inout` adjustment) in the equivalent of `Pick`, so the inserted snippet is correct.

6. **Deduplicate carefully and asymmetrically.** Dedup by *declaration identity* across the whole walk (RA's `seen_methods` by `FunctionId`) to avoid showing the same member reached two ways; dedup inherent members *by name* for shadowing; but **do not name-dedup trait/given members against each other** — multiple in-scope traits legitimately offer same-named methods and the user needs to see them.

7. **Tolerate the cursor's broken state at the type layer, not the feature layer.** RA's robustness comes from the *type engine* converting unknowns to `Error` and from bounded iterators — `completions/dot.rs` itself does almost no error handling. Hylo should likewise make its typed-AST/inference layer produce error-typed-but-walkable receivers, so the completion code can stay simple.

8. **Budget the solver.** The semantic filter dominates latency. Consider caching per-(receiver-head, trait-set) candidate sets, fast pre-rejection (RA's `DeepRejectCtxt` / simplified-type keys) before full conformance solving, and a time/step budget with graceful "show syntactic superset" degradation — directly motivated by RA's documented completion-latency regressions.

Sources:
- https://github.com/rust-lang/rust-analyzer/blob/master/crates/hir-ty/src/method_resolution.rs
- https://github.com/rust-lang/rust-analyzer/blob/master/crates/hir-ty/src/method_resolution/probe.rs
- https://github.com/rust-lang/rust-analyzer/blob/master/crates/hir-ty/src/autoderef.rs
- https://github.com/rust-lang/rust-analyzer/blob/master/crates/ide-completion/src/completions/dot.rs
- https://github.com/rust-lang/rust-analyzer/blob/master/crates/hir-def/src/resolver.rs
- Trait solving overview (rustc dev guide): https://rustc-dev-guide.rust-lang.org/traits/resolution.html
- Perf/behavior issues: https://github.com/rust-lang/rust-analyzer/issues/17068 , https://github.com/rust-lang/rust-analyzer/issues/19291 , https://github.com/rust-lang/rust-analyzer/issues/17233