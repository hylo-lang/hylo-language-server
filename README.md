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

The project only requires Swift 6.2 and NodeJS for the VSCode extension. You can use the development container to set up a development environment easily.

To build and install a local dev version of the LSP + VSCode extension that has the LSP executables bundled:

```sh
./dev-build-and-install-vscode-extension.sh
```

To test out a released version of the LSP together with your latest local changes to the VSCode extension, you can use the following script:

```sh
./release-build-and-install-vscode-extension.sh
```
### Code formatting
The project uses `swift-format` bundled by the Swift toolchain to enforce a consistent code style.

- Use `./format.sh` to format the code.
- Use `./lint.sh` to check the code.
