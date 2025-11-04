# Hylo LSP

Proof of concept LSP server for the [Hylo](https://github.com/hylo-lang/hylo) programming language, including VS Code extension.

The [Hylo VSCode extension](https://github.com/koliyo/hylo-vscode-extension) dynamically downloads the LSP binaries for the current machine OS/architecture.

This is currently very early in development, and the project is being transitioned from the old frontend to the new one.

## Features

The Hylo LSP currently support the following LSP features:

- Semantic token
  - Syntax highlighting (works with new frontend)
- Document symbols
  - Document outline and navigate to local symbol (works with new frontend)
- Diagnostics
  - Errors and warnings reported by the compiler (works with new frontend)
- Definition
  - Jump to definition (worked with old frontend, now broken)

The LSP distribution currently includes a copy of the Hylo stdlib, until we have a reliable way of locating the local Hylo installation.

## Developer

You can use the development container to set up a development environment easily, but as of now, the project only requires Swift 6.2 and NodeJs.

To build and install a local dev version of the LSP + VSCode extension:

```sh
./build-and-install-vscode-extension.sh
```

### Command line tool

There is also a command line tool for interacting with the LSP backend. The command line tool is useful for debugging and testing new functionality. The LSP server is embedded in the client, which simplify debug launching and breakpoints.

Example usage:

```sh
swift run hylo-lsp-client semantic-token hylo/Examples/factorial.hylo
```
