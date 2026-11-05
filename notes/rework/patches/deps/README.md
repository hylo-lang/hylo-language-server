# Local dependency patches for FoundationEssentials-only WebAssembly builds

`hylo-language-server-wasm` is linked with hylo-new's `foundation-essentials.toolset.json`
(`hylo-new/foundation-essentials.toolset.json` from the language server; the language server no
longer keeps a copy of its own), which
disables autolinking of `Foundation`, `FoundationInternationalization`, `_FoundationICU` and
`CoreFoundation`, so that only `FoundationEssentials` ends up in the module. Code still compiles
against the full Foundation (the WebAssembly SDK ships it), so any reference to a symbol that
lives only in `Foundation` becomes an `undefined symbol` error from `wasm-ld`. The patches below
remove those references from three external dependencies.

Note that no compile-time condition can tell whether Foundation will be linked: with the Swift
6.4 WebAssembly SDK, `canImport(Foundation)` and `canImport(FoundationEssentials)` are both true,
exactly as on Linux (checked with a probe package for both targets; `canImport(Dispatch)` is
false only on WebAssembly). So a guard like `canImport(Foundation) && !canImport(FoundationEssentials)`
would not help, and a guard on `canImport(FoundationEssentials)` would wrongly remove API on
Linux. The patches therefore prefer, in order: not needing the Foundation-only API at all; a
guard on the capability the API actually depends on; and only as a last resort `os(WASI)`.

| Package | Clone | Base revision (as pinned) | Branch | Commits |
|---|---|---|---|---|
| ChimeHQ/LanguageServerProtocol | `LanguageServerProtocol/` | `48ab36295c56c6cc5ba783a37a0c1324fef54ff6` (revision pin) | `hylo-local-patches` | `370956f` Trim header whitespace without Foundation-only API; `aa67d1a` Leave snippets out of WASI builds |
| ChimeHQ/JSONRPC | `JSONRPC/` | `c6ec759d41a76ac88fe7327c41a77d9033943374` (0.9.0) | `hylo-local-patches` | `75bc8ce` Build the stdio data channel only where Dispatch is available |
| attaswift/BigInt | `BigInt/` | `63feef7820abb1a8fb08587d7da56bb0b7db8751` (6.0.1) | `hylo-local-patches` | `7edfb70` Truncate Decimal without NSDecimalRound |

The base revisions are those in `Package.resolved` of the language server (`core-driver-split`)
and of hylo-new (BigInt is the same in both). `git format-patch` exports are in `patches/`;
apply them with `git am` on the base revision. The commit messages give the exact link errors.

## What each patch does

- **LanguageServerProtocol, `370956f`**: `MessageFraming.readHeader` used
  `trimmingCharacters(in: .whitespaces)`; both that method and `CharacterSet.whitespaces` are
  Foundation-only. It now trims tabs, Unicode space separators (Zs) and U+200B with the standard
  library. No `#if`. Verified identical to `trimmingCharacters(in: .whitespaces)` on Linux for
  every Unicode scalar in four positions.
- **LanguageServerProtocol, `aa67d1a`**: `Snippet` uses `NSRegularExpression` and exposes
  `NSRange` publicly (`elementRanges`), which are Foundation-only. `Snippet.swift`,
  `NSRegularExpression+Matching.swift` and `SnippetTests.swift` are wrapped in `#if !os(WASI)`.
  Nothing in the package or in the language server uses `Snippet`.
- **JSONRPC, `75bc8ce`**: `DataChannel+StdioPipe.swift` uses `FileHandle.readabilityHandler`,
  which swift-corelibs-foundation declares only `#if canImport(Dispatch)`. WASI has no Dispatch,
  so this is a *compile* error on WASI, independent of the toolset. Wrapped in
  `#if canImport(Dispatch)`, the same condition as the API it uses.
- **BigInt, `7edfb70`**: the `Decimal` initializers rounded with `NSDecimalRound`
  (Foundation-only; `Decimal` itself is in FoundationEssentials). This only linked in release
  builds, where the call is optimized away. The integral part is now computed with BigUInt
  arithmetic (significand times or divided by a power of ten), keeping the `Decimal` API on all
  platforms. Verified against the old implementation on 200,000 random decimals plus NaN and
  extreme magnitudes; the existing 211 tests pass.

None of the patches changes behavior or API on Apple platforms, Linux or Windows. On WASI,
`Snippet` and `stdioPipe()`/`FileHandle.dataStream` are unavailable (the latter never compiled
there anyway).

## Using them

Use `swift package edit` in the consuming package (language server checkout, or hylo-new for
BigInt):

```sh
swift package edit LanguageServerProtocol --path /home/hylo/wt/deps/LanguageServerProtocol
swift package edit JSONRPC                --path /home/hylo/wt/deps/JSONRPC
swift package edit BigInt                 --path /home/hylo/wt/deps/BigInt

HYLO_LSP_WASM=1 swift build -j 4 --product hylo-language-server-wasm \
  --swift-sdks-path /home/hylo/wt/swift-sdks --swift-sdk swift-6.4.0-RELEASE_wasm \
  --toolset hylo-new/foundation-essentials.toolset.json
```

Release builds use cross-module optimization: add `-c release -Xswiftc -cross-module-optimization`.
With the patched BigInt, debug builds link too (`NSDecimalRound` is gone, so nothing depends on
the optimizer inlining it away).

This works with the revision pin on LanguageServerProtocol and the version pins on the others.
It rewrites `Package.resolved` (edited packages are dropped from the pins), so do not commit that
change; `swift package unedit <Name>` for each package, then `git checkout Package.resolved`,
undoes it. Edit mode uses the working tree of the clone, so keep the clones on
`hylo-local-patches`.

**SwiftPM mirrors do not work for this.** Tested with `swift package config set-mirror
--original https://github.com/ChimeHQ/JSONRPC --mirror file:///home/hylo/wt/deps/JSONRPC` (and
likewise for the others, including the `.git` spelling of the URL): SwiftPM then fetches from
the local clone, but still resolves the manifest requirement, so it checks out the pinned
revision `48ab362` for LanguageServerProtocol and tagged releases for the others (it even
re-resolved JSONRPC to the `0.9.2` tag, since the mirror change invalidated the pins), never the
patch commits. Mirrors would only help if the patch commits were tagged with a version the
requirement selects, or if the consumer's manifest named the patch revision/branch, both of which
are worse than `swift package edit`.

## Verification (2026-10-25, Swift 6.4, Linux x86_64)

- Native `swift build -j 4` and `swift test -j 4` in each clone: JSONRPC 35 tests passed;
  LanguageServerProtocol 31 tests passed; BigInt 211 tests passed.
- Language server `core-driver-split` (9cc00f4, hylo-new 88d6b037) in a throwaway worktree:
  - unpatched, debug: JSONRPC fails to compile (`cannot find 'readabilityHandler' in scope`);
  - JSONRPC patched only, debug: `wasm-ld` undefined symbols from BigInt (`NSDecimalRound`) and
    LanguageServerProtocol (`trimmingCharacters`, `CharacterSet.whitespaces`,
    `NSRegularExpression`, `NSMakeRange`, ...);
  - all patches, debug: links (`hylo-language-server-wasm.wasm`, 61.8 MB); release: links
    (52.3 MB);
  - `node Tools/wasm-smoke-test.mjs` passes for both (initialize, didOpen, hover,
    documentSymbol answered without error).
- Logs are in `logs/`.

## Verification (2026-10-26, Swift 6.4, Linux x86_64)

- Language server `core-driver-split` (final history, hylo-new `18f6e65`), toolset
  `hylo-new/foundation-essentials.toolset.json`, all three patches via `swift package edit`:
  - debug: links (61.8 MB; 40.0 MB after `llvm-objcopy --strip-all`, 13.0 MB gzip -9);
    `Tools/wasm-smoke-test.mjs` passes, which now checks the exact hover
    (`[Void](let Int) let -> Int`, `NameExpression`) and symbols (`twice`, `main`); didOpen
    with the standard library about 11 s;
  - release: 52.3 MB, stripped 20.98 MB, gzip -9 5.93 MB; smoke test passes, didOpen median
    2065 ms over 9 runs;
  - release with `-Xswiftc -cross-module-optimization`: 53.7 MB, stripped 21.23 MB, gzip -9
    5.98 MB; smoke test passes (stripped and unstripped), didOpen median 1318 ms over 9 runs.
- Logs: `/home/hylo/wt/l1-wasm-debug.log`, `/home/hylo/wt/l1-wasm-rel-nocmo.log`,
  `/home/hylo/wt/l1-wasm-rel-cmo.log`.

## Verification (2026-10-26, after review fixes)

- Language server `core-driver-split` (`MessageServer` noncopyable, `lsp_alloc` checks its size;
  smoke test also checks that `lsp_alloc(-1)` traps): debug links and passes the smoke test
  (didOpen about 12.9 s); release with `-Xswiftc -cross-module-optimization` links (53.7 MB) and
  passes (didOpen 1496 ms, single run). Logs: `/home/hylo/wt/lsp-fix-wasm-debug.log`,
  `/home/hylo/wt/lsp-fix-wasm-release-cmo.log`, `/home/hylo/wt/lsp-fix-smoke-*.log`.

## Upstreaming assessment

**LanguageServerProtocol, trimming (`370956f`)**: very likely acceptable. It is small, has no
conditional compilation, and keeps behavior identical (on Darwin, the only conceivable difference
is U+200B, should CoreFoundation's set differ, which is irrelevant in a `Content-Length` header).
A maintainer might prefer a simpler space/tab-only trim, which HTTP-style headers would allow;
either is fine to propose.

**LanguageServerProtocol, snippets (`aa67d1a`)**: plausible but less certain. The `os(WASI)`
guard is a policy, not a capability check: the WASI SDK does have `NSRegularExpression`, so a
WASI user linking the full Foundation loses `Snippet`. That is unavoidable without changing
`Snippet`'s public `NSRange`-based API, and no compile-time condition can detect an
essentials-only link. Upstream may prefer a rewrite of `Snippet` without `NSRegularExpression`
and `NSRange` (an API break), or a package trait (needs tools-version 6.1, the package is 5.8).
Propose it together with the trimming commit, explaining the WebAssembly size motivation.

**JSONRPC (`75bc8ce`)**: very likely acceptable. It fixes an outright compile failure on WASI,
uses the same condition as swift-corelibs-foundation for the API in question, and is a no-op
everywhere else. It is a cleaner choice than the previous `os(WASI)` patch because it keeps the
code where a WASI SDK with Dispatch provides `readabilityHandler`.

**BigInt (`7edfb70`)**: likely acceptable. It removes a Foundation-only call instead of hiding
API, so the `Decimal` conversions keep working everywhere, and it is a small, self-contained
change backed by the existing tests. Guarding the conversion instead was rejected: on Linux and
WASI both `Foundation` and `FoundationEssentials` can be imported, so any `canImport` guard is
either always true or removes public API from Linux; only `os(WASI)` would work, at the cost of
removing the API for WASI users who do link Foundation. A follow-up upstream could switch BigInt
to `import FoundationEssentials` where available, which would catch such references at compile
time.
