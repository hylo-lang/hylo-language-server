# Hylo Language Server

Language server for the [Hylo](https://github.com/hylo-lang/hylo) programming language.

The [Hylo VSCode extension](https://github.com/hylo-lang/vscode-hylo) dynamically downloads the LSP binaries for the current OS and architecture. Currently, we support Linux, macOS, and Windows, amd64 (x64) and aarch64 (arm64).

## Supported IDEs
We currently support Neovim and VSCode, but eventually we plan to add support for many more. If you'd like to add support for another IDE, please open an issue or join our [Slack](https://hylo-lang.slack.com/).

## Features

The Hylo language server currently supports the following LSP features:

- Go to definition
- Diagnostics
- Document highlight (for highlighting names referring to the same entity as the cursor)
- Document symbols (for showing the outline of the document)
- Hover (currently only shows the type, needs to be improved)
- Find references
- Rename
- Semantic tokens (used for semantic syntax highlighting)

### Custom commands
Custom commands are available through the `executeCommand` LSP request.

#### `givens`
Lists the givens (the available implicit context) at the cursor position.

Arguments:
- `0`: `LSP.Location` - the location of the cursor

Returns:
- `string[]` - the list of stringified givens at the cursor position

## Developing

The project only requires Swift 6.3 and NodeJS for the VSCode extension. You can use the development container to set up a development environment easily.

To build and install a local dev version of the LSP + VSCode extension that has the LSP executables bundled:

```sh
./dev-build-and-install-vscode-extension.sh
```

To test out a released version of the LSP together with your latest local changes to the VSCode extension, you can use the following script:

```sh
./release-build-and-install-vscode-extension.sh
```

### WebAssembly

`hylo-language-server-wasm` runs the server in a browser worker. It is a WebAssembly reactor
declared only when `HYLO_LSP_WASM` is set, built with a WebAssembly Swift SDK and hylo-new's
toolset, which links FoundationEssentials instead of Foundation:

```sh
HYLO_LSP_WASM=1 swift build --product hylo-language-server-wasm \
  --swift-sdks-path <directory of the SDK> --swift-sdk swift-6.4.0-RELEASE_wasm \
  --toolset hylo-new/foundation-essentials.toolset.json
```

A release build, like those of the native server, also optimizes across modules: add
`-c release -Xswiftc -cross-module-optimization`.

Three dependencies must be patched, because they use Foundation APIs that FoundationEssentials or
WebAssembly lack. The patches are provided separately, as patch files to be proposed upstream;
until they are merged, apply them to clones and use these with
`swift package edit <dependency> --path <clone>`:

- JSONRPC: builds `DataChannel+StdioPipe.swift`, which uses `FileHandle.readabilityHandler`, only
  if `canImport(Dispatch)`.
- LanguageServerProtocol: trims the header values in `MessageFraming` with the standard library
  instead of `trimmingCharacters(in:)`, and leaves `Snippet`, which uses `NSRegularExpression`,
  out of WASI builds.
- BigInt, used by the front end: computes the integral part in the `Decimal` initializers with
  `BigUInt` arithmetic instead of `NSDecimalRound`.

The host of the driver calls `lsp_init` once with the standard library (a JSON object mapping
the URI of each source to its text), then `lsp_handle` with each JSON-RPC message from the
client, which returns the length of a JSON array of the messages to send back, at the address
`lsp_output` returns. Both take their argument in memory returned by `lsp_alloc`, which they free;
`lsp_free` frees such memory that is passed to neither.

`Tools/wasm-smoke-test.mjs` hosts a build of the driver under Node's WASI, opens a document and
checks its diagnostics, hover and symbols. It takes the standard library from the resource bundle
of a native build, which holds the generated integer types beside hylo-new's
`StandardLibrary/Sources`. On Linux x86-64, after a native debug build and the build above:

```sh
node Tools/wasm-smoke-test.mjs \
  .build/out/Products/Debug-webassembly-wasm32/hylo-language-server-wasm.wasm \
  .build/out/Products/Debug-linux-x86_64/Hylo_StandardLibrary.bundle
```

### Code formatting
The project uses `swift-format` bundled by the Swift toolchain to enforce a consistent code style.

- Use `./format.sh` to format the code.
- Use `./lint.sh` to check the code.

## Publishing
To publish a new release, push a tag to the repository of the form `vX.Y.Z`.

```
git tag v0.0.17
git push origin v0.0.17
```

The VSCode extension automatically downloads the latest LSP binary release from GitHub releases.
