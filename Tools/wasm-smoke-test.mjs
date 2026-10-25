// Runs hylo-language-server-wasm under node's WASI as a browser worker would, printing each answer
// and failing unless every request is answered without error.
//
// Usage: node Tools/wasm-smoke-test.mjs <hylo-language-server-wasm.wasm> <standard library>
//
// The standard library is a directory whose `.hylo` files are its sources, such as the resource
// bundle of a native build (e.g. `.build/debug/Hylo_StandardLibrary.bundle`), which contains the
// generated integer types beside hylo-new's `StandardLibrary/Sources`.

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
  const p = lsp.lsp_alloc(bytes.length);
  new Uint8Array(lsp.memory.buffer, p, bytes.length).set(bytes);
  return [p, bytes.length];
}

/** Returns the messages answering `message`, logging them with the time taken. */
function send(message) {
  const start = performance.now();
  const n = lsp.lsp_handle(...argument(JSON.stringify({ jsonrpc: '2.0', ...message })));
  const answer = new TextDecoder().decode(new Uint8Array(lsp.memory.buffer, lsp.lsp_output(), n));
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

const responses = answers.flat().filter((m) => m.id !== undefined);
const failures = responses.filter((m) => m.error !== undefined || m.result === null);
console.log(`total ${(performance.now() - start).toFixed(0)} ms, ` +
            `memory ${lsp.memory.buffer.byteLength / 2 ** 20} MiB`);
if (responses.length !== 3 || failures.length !== 0) {
  console.error('FAILED');
  process.exit(1);
}
