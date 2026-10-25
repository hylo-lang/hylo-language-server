// Runs hylo-language-server-wasm under node's WASI as a browser worker would, printing each answer
// and failing unless every request is answered without error, the document analyzes without
// diagnostics, the hover on the call of `twice` gives its type, and the document's symbols are
// `twice` and `main`.
//
// Usage: node Tools/wasm-smoke-test.mjs <hylo-language-server-wasm.wasm> <standard library>
//
// The standard library is a directory whose `.hylo` files are its sources, such as the resource
// bundle of a native build (e.g. `.build/debug/Hylo_StandardLibrary.bundle`), which contains the
// generated integer types beside hylo-new's `StandardLibrary/Sources`.

import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { WASI } from 'node:wasi';

const [module, library] = process.argv.slice(2);

const wasi = new WASI({ version: 'preview1', args: [module] });
const { instance } = await WebAssembly.instantiate(readFileSync(module), wasi.getImportObject());
wasi.initialize(instance);
const lsp = instance.exports;

/** Returns memory from `lsp_alloc` holding the UTF-8 encoding of `text`, and its length. */
function argument(text) {
  const bytes = new TextEncoder().encode(text);
  const address = lsp.lsp_alloc(bytes.length);
  new Uint8Array(lsp.memory.buffer, address, bytes.length).set(bytes);
  return [address, bytes.length];
}

/** Returns the messages answering `message`, logging them with the time taken. */
function send(message) {
  const start = performance.now();
  const length = lsp.lsp_handle(...argument(JSON.stringify({ jsonrpc: '2.0', ...message })));
  const answer = new TextDecoder().decode(
    new Uint8Array(lsp.memory.buffer, lsp.lsp_output(), length));
  console.log(`${message.method} (${(performance.now() - start).toFixed(0)} ms): ${answer}`);
  return JSON.parse(answer);
}

/** Returns the paths of the `.hylo` files under `directory`. */
function sources(directory) {
  return readdirSync(directory, { recursive: true })
    .filter((f) => f.endsWith('.hylo'))
    .map((f) => resolve(join(directory, f)));
}

const start = performance.now();
const standardLibrary = Object.fromEntries(
  sources(library).map((f) => [pathToFileURL(f).href, readFileSync(f, 'utf8')]));
lsp.lsp_init(...argument(JSON.stringify(standardLibrary)));

const uri = 'file:///smoke/main.hylo';
const text = 'fun twice(x: Int) -> Int { x + x }\npublic fun main() { let _ = twice(21) }\n';
const position = { line: 1, character: 30 };

const answers = [
  send({ id: 1, method: 'initialize',
         params: { processId: null, rootUri: null, capabilities: {} } }),
  send({ method: 'initialized', params: {} }),
  send({ method: 'textDocument/didOpen',
         params: { textDocument: { uri, languageId: 'hylo', version: 0, text } } }),
  send({ id: 2, method: 'textDocument/hover', params: { textDocument: { uri }, position } }),
  send({ id: 3, method: 'textDocument/documentSymbol', params: { textDocument: { uri } } }),
];

const messages = answers.flat();
const responses = messages.filter((m) => m.id !== undefined);
const errors = responses.filter((m) => m.error !== undefined).map((m) => m.error);
const diagnostics = messages
  .filter((m) => m.method === 'textDocument/publishDiagnostics' && m.params.uri === uri)
  .map((m) => m.params.diagnostics);
const hover = responses.find((m) => m.id === 2)?.result?.contents;
const symbols = responses.find((m) => m.id === 3)?.result?.map((s) => s.name);
console.log(`total ${(performance.now() - start).toFixed(0)} ms, ` +
            `memory ${lsp.memory.buffer.byteLength / 2 ** 20} MiB`);
assert.equal(responses.length, 3, 'every request is answered');
assert.deepEqual(errors, [], 'no request fails');
assert.notEqual(diagnostics.length, 0, 'the diagnostics of the document are published');
assert.deepEqual(diagnostics.flat(), [], 'the document has no diagnostics');
assert.deepEqual(
  hover, ['```hylo\n[Void](let Int) let -> Int\n```', 'NameExpression'], 'hover');
assert.deepEqual(symbols, ['twice', 'main'], 'document symbols');
