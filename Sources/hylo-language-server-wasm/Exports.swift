import MessageDriver

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// The server, once `lsp_init` has been called.
nonisolated(unsafe) private var server: MessageServer?

/// The last answer of the server.
nonisolated(unsafe) private var answer = UnsafeMutableRawBufferPointer.allocate(
  byteCount: 1, alignment: 1)

/// Returns `n` bytes of memory for the host to write an argument into.
///
/// - Requires: `n >= 0`.
@_expose(wasm, "lsp_alloc")
@_cdecl("lsp_alloc")
public func allocate(_ n: Int32) -> UnsafeMutableRawPointer {
  precondition(n >= 0, "negative size")
  return UnsafeMutableRawPointer.allocate(byteCount: Int(max(n, 1)), alignment: 1)
}

/// Frees `p`, memory returned by `lsp_alloc` that the host did not pass to `lsp_init` or
/// `lsp_handle`, which free their argument themselves.
@_expose(wasm, "lsp_free")
@_cdecl("lsp_free")
public func deallocate(_ p: UnsafeMutableRawPointer) {
  p.deallocate()
}

/// Starts the server with the standard library described by the `n` bytes at `p`, which it frees.
///
/// The bytes are a JSON object mapping the URI of each source of the standard library to its text.
///
/// - Requires: `p` was returned by `lsp_alloc` for at least `n` bytes, and `n >= 0`.
@_expose(wasm, "lsp_init")
@_cdecl("lsp_init")
public func initialize(_ p: UnsafeMutableRawPointer, _ n: Int32) {
  server = MessageServer(standardLibrary: consume(p, n))
}

/// Answers the JSON-RPC message in the `n` bytes at `p`, which it frees, and returns the length of
/// the answer, which `lsp_output` returns.
///
/// The answer is a JSON array of the JSON-RPC messages to send to the client. Its length fits in
/// an `Int32`, because it fits in the 32-bit address space of WebAssembly.
///
/// - Requires: `lsp_init` has been called, `p` was returned by `lsp_alloc` for at least `n` bytes,
///   and `n >= 0`.
@_expose(wasm, "lsp_handle")
@_cdecl("lsp_handle")
public func handle(_ p: UnsafeMutableRawPointer, _ n: Int32) -> Int32 {
  precondition(server != nil, "lsp_handle called before lsp_init")
  let a = server!.handle(consume(p, n))
  answer.deallocate()
  answer = UnsafeMutableRawBufferPointer.allocate(byteCount: max(a.count, 1), alignment: 1)
  answer.copyBytes(from: a)
  return Int32(a.count)
}

/// Returns the address of the last answer of `lsp_handle`.
@_expose(wasm, "lsp_output")
@_cdecl("lsp_output")
public func output() -> UnsafeRawPointer {
  UnsafeRawPointer(answer.baseAddress!)
}

/// Returns the `n` bytes at `p`, freeing them.
///
/// - Requires: `n >= 0`.
private func consume(_ p: UnsafeMutableRawPointer, _ n: Int32) -> Data {
  precondition(n >= 0, "negative size")
  defer { p.deallocate() }
  return Data(bytes: p, count: Int(n))
}
