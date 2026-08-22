# A course: how a Hylo language server, the compiler, and build systems fit together

A ground-up curriculum for understanding the Hylo language server and everything it
touches — the LSP protocol, the compiler frontend used as a library, why build systems
enter the picture, how other ecosystems solve the same problem, and the specific design
this repository uses for multi-file / multi-module / multi-workspace projects.

It is written to be **read in order**. Each lesson states a concept, says *why it
matters*, points at the **actual code** in this repo (`file:line` — approximate, they
drift), gives a concrete example, and ends with a couple of *check-yourself* questions.
Where a lesson goes deeper elsewhere, it links the reference doc.

Prerequisites: you can read Swift and a little CMake, and you have compiled a program
before. No prior LSP or compiler-internals knowledge is assumed.

Companion references (this course summarizes and connects them):
- `HYLO-LSP-IMPLEMENTATION-GUIDE.md` — the server, feature by feature.
- `LSP-BUILD-SYSTEM-INTEGRATION.md` — the build-system integration design (the subject of
  Parts 5–6 here).
- `docs/research/autocompletion/SYNTHESIS.md` — how mature servers do completion.

---

## Map of the course

```
Part 1  What a language server is           (protocol, the 3-layer mental model)
Part 2  Positions and text sync             (the UTF-16 trap; the document store)
Part 3  The compiler frontend as a library  (Program/Module/SourceFile; the pipeline)
Part 4  Five constraints that shape everything
Part 5  Why build systems must be involved  (the unit-of-compilation mismatch)
Part 6  How other ecosystems solve it       (clangd, rust-analyzer, SourceKit-LSP, fortls)
Part 7  The Hylo design                      (3-layer resolver, the manifest, discovery)
Part 8  Not-top-level & multi-language targets
Part 9  Cross-module references              (down-closure vs whole-graph)
Part 10 Where the compiler and build system meet (interface hash, separate compilation)
Part 11 End-to-end: one keystroke, traced through the code
Glossary
```

---

# Part 1 — What a language server is

## 1.1 The problem it solves

Before LSP, every editor needed a bespoke integration for every language: N editors ×
M languages = N×M plugins. The **Language Server Protocol** (LSP), introduced by
Microsoft for VS Code and now an open standard, collapses that to N+M. A **language
server** is a separate program that speaks a fixed JSON-RPC protocol; any **client**
(VS Code, Neovim, Emacs…) that speaks the protocol gets full language intelligence —
go-to-definition, hover, diagnostics, rename — for free.

The Hylo language server is such a program. Its entry point is
`Sources/hylo-language-server/CommandLine.swift`: it starts, opens a stdio pipe, and
begins listening. The VS Code extension (`vscode-hylo`) downloads and launches this
binary and talks to it.

## 1.2 The transport: JSON-RPC over stdio

Client and server exchange **JSON-RPC 2.0** messages framed with `Content-Length`
headers, over the server's stdin/stdout. Three message kinds:

- **Request** — has an `id`; expects a **Response** with the same `id`. (e.g.
  `textDocument/definition`.)
- **Notification** — no `id`, no reply. (e.g. `textDocument/didChange`.)
- Responses can arrive **out of order**; you match them to requests by `id`.

You never hand-code this. Three ChimeHQ packages handle it (guide §11):
- `JSONRPC` — the framed stdio transport.
- `LanguageServerProtocol` — typed `Codable` structs for every message.
- `LanguageServer` — glues them into a message loop (`JSONRPCClientConnection`).

None of these supply *language intelligence*. They are plumbing. Everything from here on
is what *you* build on top.

## 1.3 The lifecycle handshake

A session is a fixed dance (guide §5.1):

```
client → initialize (request, carries capabilities + workspaceFolders)
server → InitializeResult (carries ServerCapabilities — what features you support)
client → initialized (notification)
       … normal work …
client → shutdown (request) → exit (notification) → process exits
```

Two rules that bite if ignored: you must answer `initialize` before sending anything
else, and you must not send requests *to* the client until `initialized` arrives. In this
repo, `DocumentProvider.initialize` records the workspace folders and client
capabilities and returns `serverCapabilities` (`ServerCapabilities.swift`); the
`initialized` notification then starts file watching (`startFileWatching`).

## 1.4 The 3-layer mental model (memorize this)

Every compiler-backed language server, including this one, has three layers. Keeping them
separate in your head is the single most useful thing in this course; bugs cluster at the
seams (guide §2).

```
┌────────────────────────────────────────────────────────────────────────┐
│ 1. Document store / VFS   uri → (text, version). The editor's buffer,    │
│                           not the disk file, is the truth once opened.   │
│                           Here: DocumentProvider + Document.swift.       │
├────────────────────────────────────────────────────────────────────────┤
│ 2. Analysis host          Owns compiler state; answers semantic queries; │
│                           rebuilds when buffers change.                  │
│                           Here: the `Program` built inside DocumentProvider│
│                           wrapping Hylo's HyloFrontEnd.                   │
├────────────────────────────────────────────────────────────────────────┤
│ 3. Feature providers      One per request (hover, definition…). Ideally  │
│                           pure functions of (analysis snapshot, params). │
│                           Here: the files under Features/.               │
└────────────────────────────────────────────────────────────────────────┘
```

Hylo's frontend is linked **in-process** (a Swift package dependency), like rust-analyzer
and gopls, and unlike SourceKit-LSP (which talks to a separate `sourcekitd`). Simpler, and
the right choice — but a frontend crash or hang takes the whole server down.

**Check yourself.** (a) Why can responses arrive out of order, and how does the client
cope? (b) Which of the three layers would a "go to definition returns the wrong range on a
line with an emoji" bug live in?

---

# Part 2 — Positions, text sync, and the document store

## 2.1 The single most pervasive bug class: position encoding

An LSP `Position` is `{ line, character }`, both zero-based. The trap is `character`: by
default it counts **UTF-16 code units**, not bytes, not Unicode scalars, not visible
characters. A Basic-Multilingual-Plane character is one UTF-16 unit; an astral character
(most emoji) is two. In `"😀x"`, the `x` is at `character: 2`.

Get this wrong and *every* range you return is subtly off on any line containing non-ASCII
text — invisible in ASCII tests, maddening in the field. This is why the guide (§4)
insists: do all position↔offset conversion at **one boundary** and never do
`String.Index` arithmetic in a feature handler.

In this repo the conversion is correct and centralized:
`LSPInterop/LSP+PositionStringIndex.swift` counts `utf16.count`, and the frontend exposes
native UTF-16 conversion (`SourcePosition.lineAndUTF16Offset`,
`SourceFile.index(line:utf16Offset:)`), bridged in `LSP+SourceSpan.swift`. LSP 3.17 lets
the client and server *negotiate* the encoding via `positionEncodings`; if nobody says
otherwise, UTF-16 is mandatory.

## 2.2 The document store: whose text is the truth?

Once the client sends `textDocument/didOpen`, the **editor's in-memory buffer** — not the
file on disk — is authoritative for that file until `didClose`. The server must mirror
that buffer exactly.

In this repo, `DocumentProvider` (an **actor**, so all access is serialized without manual
locks) holds `documents: [AbsoluteURL: Document]`. `registerDocument`
(`didOpen`), `updateDocument` (`didChange`), `unregisterDocument` (`didClose`) maintain
it. `Document.applyChanges` splices incremental edits using the UTF-16-correct conversion.

A subtlety that matters later (Part 7): a client may ask about a file it never opened. So
`getDocumentContext` falls back to reading the file from
disk (`implicitlyRegisterDocument`). The document store therefore serves *both* open
buffers and on-disk files.

**Check yourself.** (a) You return a hover range computed with byte offsets on a file
containing `café`. What breaks and where? (b) After `didOpen`, why must the server ignore
the on-disk contents of that file?

---

# Part 3 — The compiler frontend as a library

The analysis host wraps `HyloFrontEnd`. To reason about the server you must understand a
few frontend types. (Files below are in `hylo-new/Sources/FrontEnd/`.)

## 3.1 The core data model

- **`Program`** (`Program.swift`) — the whole world: a set of modules, their syntax
  trees, and a `TypeStore`. A `Program` is a **value type** (a struct). That is
  load-bearing: the server can cheaply *copy* a `Program` (e.g. the memoized
  standard-library program, `standardLibraryProgram(from:openBuffers:)`) and extend the
  copy per document, with no shared mutable state.
- **`Module`** (`Module.swift`) — a named unit of compilation with a list of source files
  and a list of *dependencies* (other modules it may use). Key operations:
  `addSource(_:)`, `addDependency(_:)`.
- **`SourceFile`** (`Files/SourceFile.swift`) — a file's name + contents, with UTF-16
  position machinery. Named by a `FileName` (`Files/FileName.swift`); the case that
  matters here is `.local(URL)`.
- **Identities** — syntax nodes, declarations, scopes are referred to by lightweight IDs
  (`SyntaxIdentity`, `DeclarationIdentity`, `ScopeIdentity`), not pointers. You look
  things up *through* the `Program`.

## 3.2 The compilation pipeline

A module is compiled in phases, each a method on `Program`:

```
demandModule(name) → Module.ID          create/find the module
program[m].addSource(s)                  attach source files
await program.assignScopes(m)            build lexical scope tree     (Scoper.swift)
program.assignTypes(m, loggingInferenceWhere:)   type-check the module (Typer.swift)
   ↓ (only for actual compilation, not the LSP)
program.lower(m) / applyTransformationPasses(m)  → IR → object code
```

The language server stops after `assignTypes`: it needs types and resolved names, not
machine code. You can see the exact sequence in `DocumentProvider.compile(_:into:)`
(register dependencies → attach sources → `assignScopes` → `assignTypes`).

## 3.3 What you can read back after type-checking

Feature providers query the typed `Program`. The load-bearing read-back APIs (guide §7):

- `Program.type(assignedTo: node)` — the inferred type of any node (→ **hover**).
- `Program.declaration(referredToBy: nameExpr)` — the declaration a name resolves to (→
  **definition**, **references**). Note: this is a *forward* map (use → decl). There is no
  reverse map (see Part 4).
- `Program[decl].site` — the `SourceSpan` where a declaration lives (→ the **location**
  definition returns).
- `Program.declarations(lexicallyIn:)`, `topLevelDeclarations`, `name(of:)`, `tag(of:)` —
  structure (→ **document symbols**, **semantic tokens**).

Follow the whole chain in `Features/Definition.swift`: find the node at the cursor
(`innermostTree(containing:)`), resolve it (`declaration(referredToBy:)`), return
`program[decl].site`. If the declaration happens to be in a *different file* of the same
module, that site is in that other file — which is the entire reason multi-file analysis
"just works" once the module contains all its files (Part 7).

## 3.4 In-process means multiple modules already coexist

Crucially, a single `Program` can hold **many modules at once**. The server already relies
on this: the standard library is one module; the user's code is another that
`addDependency(Module.standardLibraryName)`s onto it. So "compile several user modules
together" is not a new capability — it is the same mechanism the stdlib already uses
(Part 7 exploits this).

**Check yourself.** (a) Why is `Program` being a value type important for caching the
stdlib? (b) After `assignTypes`, which API gives you the *type* shown in a hover, and which
gives you the *declaration* a go-to-definition jumps to?

---

# Part 4 — Five frontend constraints that shape everything

The frontend was built to *compile*, not to *serve an editor*. Five properties (guide §3,
§7) determine what is a quick win and what is a research project. Internalize them; nearly
every design tension traces back here.

1. **Type-checking is whole-module only.** The only entry point is `Typer.apply()`, which
   checks an *entire* module top to bottom. There is no "re-check just this function."
   Consequence: on every edit, the server rebuilds the document's module from scratch
   (reusing only the cached, already-typed stdlib). For small files, fine; for large ones,
   this is the dominant latency, and there is no server-only fix.

2. **No incrementality.** The `fingerprint` fields exist for *serialization*, not for
   incremental compilation. "Re-type only the edited body" is a **frontend** project.

3. **No cancellation.** Nothing checks a cancel token mid-check. The LSP `$/cancelRequest`
   can stop you *sending* a stale result but cannot stop the frontend *computing* it. A
   slow compile blocks the actor serving it.

4. **No reverse index.** `declaration(referredToBy:)` is use→decl. There is *no*
   decl→uses map. So **references** and **rename** must traverse the whole AST and resolve
   every name: O(AST) per request. This is the crux of Part 9.

5. **No expected-type read-back, no doc comments.** After checking you can read a node's
   *inferred* type but not the *expected* type at a hole (it lived in the Typer's private
   state and was discarded). And the lexer discards doc comments, so hover can show a
   signature but not prose. Both are frontend changes to lift.

Keep this list handy: when a feature feels hard, it is usually bumping one of these.

**Check yourself.** (a) Why does moving the cursor in a 2000-line file cost a full
type-check? (b) Which constraint makes project-wide rename expensive, and why?

---

# Part 5 — Why build systems must be involved

## 5.1 The unit-of-compilation mismatch

Here is the pivotal idea of the whole build-integration story.

- **CMake compiles one object per source file.** `a.c` → `a.o`, `b.c` → `b.o`.
- **Hylo compiles one object per *module*, consuming *all* its sources at once.**

These do not reconcile directly. If you naïvely told CMake `add_executable(app a.hylo
b.hylo)`, it would emit *two* compile commands, each compiling the *whole* module, producing
two identical objects that collide at link with duplicate `main`. (The
`hylo-cmake-experiment` repo works around this with a "first source carries the
compilation, the rest are `HEADER_FILE_ONLY`" trick — see its `FINDINGS.md`.)

The same mismatch appears in the *editor*. To analyze one file, the server must know the
**whole module** the file belongs to, because the type-checker only works per-module
(Part 4, constraint 1). A symbol defined in a sibling file is invisible unless that sibling
is in the module.

## 5.2 The three questions only the build system can answer

For any file the editor asks about, the server needs (this is the spine of
`LSP-BUILD-SYSTEM-INTEGRATION.md` §1):

- **Q1 — membership:** which module is this file in, and what are the module's *other*
  sources?
- **Q2 — dependencies:** which modules does it depend on, and where are their interfaces?
- **Q3 — configuration:** stdlib root, target triple, conditional-compilation flags.

A lone editor cannot answer these from one file. A build system knows all three — it *is*
the thing that groups files into targets and wires their dependencies. Hence: the server
must obtain Q1–Q3 from the build system, whatever it is, and degrade gracefully when there
is none.

## 5.3 The unit is the module — so which interchange format?

Because the settings unit is the *module*, the natural interchange is a **module graph**,
not a list of per-file commands. This immediately rules *in* rust-analyzer's
`rust-project.json` shape and rules *out* clangd's `compile_commands.json` shape — a point
Part 6 makes concrete.

**Check yourself.** (a) Why would `add_executable(app a.hylo b.hylo)` produce a link
error? (b) State Q1/Q2/Q3 for a file `foo/bar.hylo` from memory.

---

# Part 6 — How other ecosystems solve it

Studying four mature servers gives us the design vocabulary. Two axes matter: **what the
per-file settings unit is**, and **how the model is delivered**.

| Server | Settings unit | Delivery | No-build-system fallback |
|---|---|---|---|
| clangd | one command **per file** | `compile_commands.json` (walk up dirs) | filename-proximity flag guess; bare `clang foo.cc` |
| rust-analyzer | **per crate** | `cargo metadata`; or static `rust-project.json` | `DetachedFiles`: each file its own crate + sysroot |
| SourceKit-LSP | **per target/module** | SwiftPM; `compile_commands.json`; or **BSP** | synthesized `fallback` args (file + SDK) |
| fortls | (whole tree) | **none** — parses every file under `source_dirs` | it *is* the fallback |

Four lessons, each of which becomes a Hylo design decision in Part 7:

1. **The unit is the module, not the file.** clangd's per-file model is the odd one out —
   it fits C, where one file → one object. Rust (crate), Swift (target), Fortran (module),
   **and Hylo (module)** all key settings to a whole-module unit and hand the checker the
   module's *entire* file list to answer for one file. → Hylo copies the crate-graph shape.
   (`compile_commands.json` also cannot carry Hylo in practice — mind the produce/consume
   split: SourceKit-LSP can *read* a compilation database, but **CMake only *emits* one for
   C/C++/CUDA** — never Swift/Fortran/out-of-tree languages — so no build system would ever
   write Hylo entries into it. Swift closes this gap with SwiftPM/BSP, not CMake.)

2. **Two delivery philosophies, and you want both.** A *static artifact* the build tool
   writes (`rust-project.json`) — simple, no live process, goes stale on graph change. Or a
   *live session* (the **Build Server Protocol**, BSP) — the build server answers queries
   and pushes change notifications — richer but heavier. → Hylo does static first (L1),
   BSP later (L2).

3. **A "prepare" step is first-class.** Before a file's semantics resolve, its
   dependencies' compiled interfaces must exist: SourceKit-LSP's `buildTarget/prepare`,
   rust-analyzer's build-scripts pass. → For Hylo, "compile (or load the `.hylomodule` of)
   each imported module first."

4. **The fallback is mandatory.** Every server degrades to single-file analysis backed by
   the sysroot/stdlib rather than going dark. → Hylo keeps its current single-file mode as
   the floor.

**The Build Server Protocol, briefly.** BSP inverts LSP's roles: the language server is a
*client*, the build tool is a *server*. Same JSON-RPC base. Core messages:
`build/initialize`, `workspace/buildTargets`, `buildTarget/sources`,
`buildTarget/inverseSources` (file → owning targets), `buildTarget/compile`. SourceKit-LSP
adds `sourcekit/textDocument/sourceKitOptions` (per-file compiler args) and
`sourcekit/buildTarget/prepare`. A repo names its build server in a `buildServer.json` at
the root. Bazel, sbt, Mill, Gradle ship BSP servers; CMake does not (its old server mode
was removed in 3.20 in favor of the **File API** — Part 8).

**Check yourself.** (a) Why is `compile_commands.json` a poor fit for Hylo even though it
is the most widely supported format? (b) In BSP, who is the client and who is the server,
and why is that "inverted" relative to LSP?

---

# Part 7 — The Hylo design: a three-layer resolver

Now we can state the design (full version: `LSP-BUILD-SYSTEM-INTEGRATION.md` §4). The
build system is hidden behind **one interface** — "given a file, return its module, that
module's sources, and its import closure" — with three implementations, tried highest
first:

```
L2  Live BSP build server   — graph updates live, mixed-language; the ideal end state
L1  Static manifest         — hylo-project.json: the module graph any build system emits
L0  File-level fallback     — no build system: the single open file as its own module
```

Each layer is a strict superset of the fidelity below it. L1 is the 80/20 and is what this
repo implements today.

## 7.1 L1: the manifest is the lingua franca

A build system emits `hylo-project.json`; the server reads it with **zero
build-system-specific code**. It is `rust-project.json`-shaped (a module graph), per Part
6 lesson 1:

```jsonc
{
  "schemaVersion": 1,
  "stdlibRoot": "…/StandardLibrary/Sources",          // Q3
  "modules": [
    { "name": "Support", "originTarget": "Support",
      "archive": "…/Support.hylomodule",              // optional prebuilt interface
      "imports": [],                                   // Q2 (direct edges)
      "sources": ["…/Support.hylo", "…/Extra.hylo"] }, // Q1 (the whole module)
    { "name": "App", "imports": ["Support"], "sources": ["…/App.hylo"] }
  ]
}
```

The Swift type mirroring this is `HyloProjectManifest` in
`Sources/HyloLanguageServerCore/ProjectModel.swift`.

## 7.2 Discovery: finding the manifest (and *the right one*)

Naïvely you would walk up from the file to the nearest `hylo-project.json`, as clangd does
for `compile_commands.json`. But a build system writes the manifest into the **build tree**
(`cmake-build-debug/`, `build/`), which is *off* the source file's upward path — so a pure
walk-up never finds it, and the file silently drops to single-file fallback. (This is a real
bug that was hit: "it only works if I copy the manifest to the root.")

`ProjectModel.discoverManifests` (`ProjectModel.swift`) fixes it properly. It collects
candidate manifest paths from:
1. an **explicit client setting** (the editor extension configured the build and *knows*
   its directory — the clangd `--compile-commands-dir` / rust-analyzer `linkedProjects`
   pattern) — `explicitPaths`;
2. **every ancestor of the file, and each ancestor's conventional build subdirectories**
   (`build/`, `cmake-build-*/`, `out/`, `.hylo/`);
3. **each workspace-folder root and its build subdirectories**.

*Every* readable candidate is returned (duplicates and unparseable files skipped), so the
whole workspace graph can be assembled from a multi-root or multi-target workspace, and
the out-of-source build-tree manifest is found. Membership is then decided by source
path: `workspacePlan(from:)` indexes every module's sources into `fileToModule`, with
symlinks resolved so `/var` vs `/private/var` (macOS) matches. A file in the index
belongs to that module; a file no manifest claims falls to L0.

## 7.3 The workspace plan: ordering the module graph

`ProjectModel.workspacePlan(from:)` unions all discovered manifests' modules — keyed by
`(originTarget, name)`, first declaration wins — and **topologically orders** the whole
graph with a cycle-safe visited set, `"Hylo"` (the stdlib) first. The resulting
`WorkspacePlan` precomputes each module's **down-closure**; a document's build scope is
`downClosureKeys(of:)` — dependencies first, the file's own module last. For the diamond
`App → Left → Base`, `Right → Base`, opening `App.hylo` yields the scope
`[Hylo, Base, Left, App]` (never `Right`, which `App` doesn't reach).

Why dependencies-first? Because to type-check a module that imports `Support`, `Support`
must already be scoped, typed, and registered in the `Program` — exactly the discipline the
stdlib already uses (Part 3.4).

## 7.4 Building the program (and buffer coherence)

`DocumentProvider.buildProgram(from:openBuffers:persist:)` walks the scope in plan order
and, per module: reload it from its **archive** if neither it nor its transitive
dependencies changed (Part 9's lifecycle doc covers the cache), else `demandModule`, wire
`addDependency` (stdlib + each import), attach the module's sources, `assignScopes`,
`assignTypes`.

One subtlety worth its own lesson: **which text does a source get?** For every file, an
*open editor buffer* wins over the on-disk contents — and not just the file being queried,
but **every** open file of the module (`openBuffers`, keyed by symlink-resolved path). If
it used only the queried file's buffer, a whole-module compile would go incoherent the
moment two of the module's files were edited. `DocumentProvider` builds `openBuffers`
from all client-owned documents plus the current one.

## 7.5 The fallback (L0) and how it degrades

If no manifest lists the file (`fileToModule` misses), `buildProgramForDocument` falls
through to the historical single-file path: one `Main` module containing just the open file,
on top of the stdlib. Cross-file references don't resolve — but nothing breaks. This is the
mandatory fallback of Part 6 lesson 4. The test `testNoManifestFallsBackToSingleFile`
pins exactly this behavior (the call to a sibling's function reports `undefined symbol`).

## 7.6 The whole path in `DocumentProvider`

`buildProgramForDocument` is where the layers meet:

```
resolveWorkspacePlan(for: file)   — memoized; always contains a "Hylo" module
                                    (synthesized from the bundled stdlib if undescribed)
file in plan.fileToModule?  → L1: build the module's down-closure
else                        → L0: single-file `Main` module on the stdlib program
```

The stdlib is not special-cased: editing a stdlib file goes through the same path as any
module. Rebuilds are served from a per-scope program memo when nothing changed, and from
per-module archives when only some modules changed; diagnostics publishing is debounced
(the lifecycle doc specifies both). Parts 4 and 9 explain the underlying costs.

**Check yourself.** (a) Your manifest is in `build/`, sources in the project root, and go-to
definition across files doesn't work. Which of §7.2's three candidate sources fixes it, and
why is membership decided by `fileToModule` rather than by which manifest is nearest?
(b) You open two files of one module and
edit both; why must `buildProgram` see *both* buffers, not just the one you queried?

---

# Part 8 — Not top-level: multi-language targets

A hard requirement: a build target may link Hylo **and** Swift **and** C into one artifact.
Hylo must not assume it "owns" the target or fight the other languages for it.

The manifest design dissolves this (`LSP-BUILD-SYSTEM-INTEGRATION.md` §6.1): **a module is
a *view of the Hylo slice* of a target, never the target itself.** A target
`libfoo = {a.hylo, b.hylo, x.swift, y.c}` yields one Hylo module `foo = {a.hylo, b.hylo}`;
`x.swift` is SourceKit-LSP's business, `y.c` is clangd's. Each language server sees its own
slice of the same target; none needs to be top-level.

In CMake terms the Hylo integration is a *participant*: it sets per-source properties on
`.hylo` files and contributes them to whatever target the user chose. It does **not**
dictate the target's linker language or wrap it in a Hylo-owned custom command.

**The ideal discovery mechanism** makes this even cleaner: the **CMake File API**
(`.cmake/api/v1`, object `codemodel-v2`) exposes, for *every* target, each source's
`language` and per-source compile flags — **including out-of-tree languages registered via
`enable_language`**, which `CMAKE_EXPORT_COMPILE_COMMANDS` does not. A File-API-reading tool
can extract the Hylo slice of any target with *no* Hylo-specific project setup at all — the
user just adds `.hylo` files to a normal target and a tool discovers them by extension. That
is the endpoint; the hand-written `hylo-project.json` emitter is the pragmatic step toward
it.

**Check yourself.** (a) A target has 3 Swift files and 2 Hylo files. How many modules does
the Hylo manifest list, and which files? (b) Why is the CMake File API a better ultimate
source than a Hylo-authored `project()` call?

---

# Part 9 — Cross-module references: the deep one

This is the part that forces the biggest architectural idea, and it's worth slowing down.

## 9.1 Down-closure vs reverse dependents

Everything in Part 7 builds a file's module plus its **down-closure** — the modules it
*imports*. That is exactly right for the queries that follow a name *outward*:

- **go-to-definition / hover**: you have a use, you want its declaration. The declaration
  is in this module or something it imports. Down-closure suffices.

But some queries run the *other* direction — they need the modules that **import this one**,
its **reverse dependents**:

- **find-references**: "everywhere that uses `Support.answer`" includes call sites in `App`,
  which imports `Support`. `App` is *not* in `Support`'s down-closure.
- **rename**: same set as references, plus edits.
- **workspace symbols, call hierarchy**: inherently whole-project.

A `Program` built as a down-closure literally does not contain the reverse dependents, so
these queries cannot see them. That is the ceiling this part lifts.

## 9.2 The consequence: closure(D) on demand

To answer a reverse-direction query about a symbol declared in module `D`, the server
builds **closure(D)** — `D`, its transitive dependents, and everything any of them
imports (the smallest import-closed set containing `D` and all its dependents; a bare
`down(D) ∪ up(D)` is *not* buildable, because a dependent may import modules unrelated
to `D`). The manifest already enumerates every module, so the plan knows the closure;
the program for it is built when references/rename asks
(`DocumentProvider.closure(potentiallyReferencing:resolvedIn:at:)`), reusing per-module
archives so unchanged modules load rather than recompile. For a stdlib-declared symbol
closure(D) is the whole workspace — the cost is accepted on the explicit user action.
The full scoping rules live in `LSP-PROGRAM-LIFECYCLE.md` §2 and §4.

## 9.3 What it takes, in dependency order

1. **Build the declaring module's closure, not the document's down-closure** —
   implemented as above. This is what makes cross-module references/rename *correct*.
   Prerequisite: the discovery fix of §7.2, so the server first finds *every* manifest
   across a multi-root / multi-target workspace.
2. **A reverse (decl → uses) index in the frontend.** References is O(AST) today (Part 4,
   constraint 4); over the whole project that's O(*all* ASTs) per query. An index built once
   and maintained incrementally makes references, rename, workspace-symbols, and call
   hierarchy cheap. This is a *frontend* investment.
3. **Interface-hash-gated dependent recheck.** Editing module `M` re-type-checks `M` (Part
   4, constraint 1). But a dependent's typed AST only changes if `M`'s *observable
   interface* changed — see Part 10. So recompile `M`; recheck dependents only when its
   interface hash moves; keep every other module's typed AST cached (keyed by source
   fingerprint). Without this, one keystroke in a low-level module rechecks its entire
   reverse cone.

Step 1 makes it correct; steps 2–3 make it fast. The scalable end-state adds a **persistent
symbol index** (occurrences on disk) so these queries hit the index instead of holding every
typed AST live — but the on-demand closure `Program` is the correct and sufficient first
step.

## 9.4 A subtle enabling fix: the import guard

None of this works if `import M` doesn't resolve in-process. It didn't: the import-table
builder in `Typer.swift` had an inverted guard,
`if table.contains(m) { table.append(m) }` — appending a module only if it was *already*
present, i.e. never. Only the stdlib worked (it's appended explicitly). The one-character
fix, `if !table.contains(m)`, makes cross-module `import` resolve, and is what lets the
whole-graph `Program` (and the multi-module tests) function. A reminder that deep features
sometimes rest on tiny correctness fixes.

**Check yourself.** (a) Explain, in terms of down-closure vs reverse dependents, why
go-to-definition on `Support.answer` works with today's per-document program but
find-references on it does not. (b) Why does step 3 (interface hash) exist — what goes wrong
without it once the whole graph is in memory?

---

# Part 10 — Where the compiler and the build system meet

A short but important part: the *build-graph* insight that makes incremental multi-module
tractable. (Full treatment: the sibling repo's `HYLO-COMPILER-FOR-BUILD-SYSTEMS.md`.)

## 10.1 Separate compilation — Hylo's structural advantage

Hylo has **true separate compilation**: a module compiles to an object that references its
dependencies' symbols as *undefined*, resolved at link — no monomorphization pulls a
dependency's body into the dependent. (Rust cannot do this for a generic; it instantiates
the body in the dependent.) This means a real per-module build graph is *possible*.

## 10.2 The catch: interface ≠ implementation

Separate compilation only pays off if you can tell when a dependent *doesn't* need
rebuilding. Today Hylo's `.hylomodule` archive conflates two things: the **interface** a
dependent type-checks against, and the **compiled IR** (the bodies). So *any body edit*
changes the archive, and every dependent that depends on the archive rebuilds — throwing the
advantage away.

## 10.3 The fix: an interface hash

Have the compiler emit a body-independent **digest of the module's observable surface**
(public signatures, frozen layouts, inlinable bodies) — and *not* private decls or ordinary
bodies. Then a dependent must recompile *iff* that hash changed. This is the same idea as
Swift's `.swiftmodule`/`.swiftdeps` split and C++20 BMIs.

Why this lives in *this* course: it is exactly step 3 of Part 9.3. In the editor, holding
the whole graph in memory is only affordable if editing a low-level module doesn't recheck
its whole reverse cone every keystroke — and the interface hash is the signal that says
"the dependents' view didn't change, keep their cached ASTs." The build system and the
editor want the *same* mechanism. And it is why the manifest's `archive` field is optional:
until the interface hash exists, the server prefers compiling dependencies from *source*
(which sidesteps the conflation entirely) rather than loading a body-polluted archive.

**Check yourself.** (a) Why does a pure body edit in `Support` currently invalidate every
dependent, and what does the interface hash change about that? (b) How is the editor's
"don't recheck dependents" need the same as the build system's "don't rebuild dependents"?

---

# Part 11 — End to end: one keystroke, traced through the code

Tie it together. A user in VS Code has a CMake project; the extension launched
`hylo-language-server` and passed the build directory. The user types a character in
`App.hylo`, which imports `Support`, then hovers a call to `Support.answer`.

```
1. Client → didChange (notification): App.hylo, incremental edit, new version.
   HyloNotificationHandler → DocumentProvider.updateDocument
     · Document.applyChanges splices the edit (UTF-16-correct).           [Part 2]
     · scheduleDiagnosticsRefresh: a debounce timer (300ms) restarts; when
       the burst quiesces, one drain rebuilds App's module and publishes
       diagnostics for it and any affected open document.

2. Client → hover (request, id=N): App.hylo, position of the call. This may
   arrive before the debounce fires — the program is built on demand:
   HyloRequestHandler.hover → getDocumentContext(App.hylo)
     · buildProgramForDocument(App.hylo, latest buffer):                  [Part 7.6]
         resolveWorkspacePlan — memoized; on a miss, discoverManifests
         tries explicit dir + ancestors + build subdirs + ws roots.       [Part 7.2]
         fileToModule[App.hylo] → App; scope = down(App) =
         [Hylo, Support, App]  (deps first).                              [Part 7.3]
         openBuffers = {App.hylo: new buffer, …other open files…}.        [Part 7.4]
         buildProgram: load Hylo and Support from their archives
         (unchanged), compile App with addDependency(Support).
         `import Support` resolves.                                       [Part 9.4]
         The result is memoized per scope; an unchanged workspace is
         served without rebuilding.

3. Answering hover from the typed Program:
     · Position → SourcePosition (UTF-16).                                [Part 2.1]
     · innermostTree(containing:) finds the call node.                    [Part 3.3]
     · declaration(referredToBy:) resolves it to Support.answer's decl.
     · type(assignedTo:)/TreePrinter render the signature.
   Server → Response(id=N): hover contents.
```

Every labeled step is a concept from an earlier part. Notice what is *not* here: the
program of step 2 is a down-closure, so a **find-references** on `answer` takes one more
step — re-resolving the declaration in closure(`Support`), built on demand — before
scanning (Part 9.2).

**Capstone exercise.** Re-run this trace for **find-references on `Support.answer`**. At
which step does it diverge from hover, which program does it scan, and why is the answer
still complete when `App` was edited but never saved?

---

# Glossary

- **LSP** — Language Server Protocol. Editor(client) ↔ language server, JSON-RPC.
- **BSP** — Build Server Protocol. Language server(client) ↔ build tool(server). Delivers
  the project model live.
- **Analysis host** — the server layer owning compiler state and answering queries.
- **`Program` / `Module` / `SourceFile`** — the frontend's world / a compilation unit / a
  file. `Program` is a value type (cheap to copy).
- **Whole-module type-checking** — the frontend checks an entire module at once; no
  per-declaration entry point.
- **Manifest (`hylo-project.json`)** — the static, build-system-agnostic module graph the
  server reads (L1). rust-project.json-shaped.
- **Discovery** — locating the manifest that describes a file (ancestors + build subdirs +
  workspace roots + explicit setting; chosen by membership).
- **Workspace plan** — the topologically ordered module graph of all discovered
  manifests, with the file → module index; a query's build scope is a subset of it.
- **Down-closure** — a module and the modules it imports. Enough for definition/hover.
- **Reverse dependents** — modules that import a given module. Needed for
  references/rename/workspace-symbols; absent from a down-closure.
- **Fallback (L0)** — single-file analysis when no build system is found. Mandatory.
- **Prepare** — building a dependency's interface before analyzing a dependent.
- **Interface hash** — a body-independent digest of a module's observable surface; the
  signal for "must dependents recompile/recheck?".
- **Separate compilation** — compiling a module to an object with undefined references to
  its dependencies, resolved at link; Hylo has it, Rust (for generics) does not.
- **Position encoding** — LSP `character` counts UTF-16 code units by default; the classic
  off-by-N bug source.

---

## Suggested reading order after this course

1. `HYLO-LSP-IMPLEMENTATION-GUIDE.md` — deepen on each feature (hover, completion, rename…).
2. `LSP-BUILD-SYSTEM-INTEGRATION.md` — the full build-integration design + recommendations.
3. `docs/research/autocompletion/SYNTHESIS.md` — completion across mature servers.
4. Sibling repo `hylo-cmake-experiment/` — `FINDINGS.md`,
   `HYLO-COMPILER-FOR-BUILD-SYSTEMS.md`, `UPSTREAM-MULTIFILE-MODULES.md` for the compiler /
   CMake side and the interface hash.
