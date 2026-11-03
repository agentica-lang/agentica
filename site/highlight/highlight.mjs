import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import oniguruma from "vscode-oniguruma";
import textmate from "vscode-textmate";

const here = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const BLOCK = /<div class="?agc-code"?>(<div class="?highlight"?><pre[^>]*><code)[^>]*>([\s\S]*?)(<\/code><\/pre><\/div>)<\/div>/g;
const SIGNATURE = /<div class="?signature"?>(<div class="?highlight"?><pre[^>]*>)<code[^>]*>([\s\S]*?)(<\/code><\/pre><\/div>)<\/div>/g;
const CLASSES = [
  ["comment", "c"],
  ["constant.character.escape", "se"],
  ["punctuation.section.interpolation", "si"],
  ["string", "s"],
  ["punctuation.definition.string", "s"],
  ["constant.numeric", "m"],
  ["constant.language", "kc"],
  ["keyword.operator.logical", "k"],
  ["keyword.control", "k"],
  ["storage.type", "k"],
  ["entity.name.function", "nf"],
  ["entity.name", "nc"],
  ["support.type", "nc"],
  ["variable.other.constant", "no"],
  ["variable.other.enummember", "no"],
];

const used = new Set();
const ENTITIES = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" };

function decode(html) {
  return html
    .replace(/<[^>]*>/g, "")
    .replace(/&(#x[0-9a-f]+|#[0-9]+|[a-z]+);/gi, (entity, name) => {
      if (name[0] !== "#") {
        if (!(name in ENTITIES)) throw new Error(`unknown entity ${entity}`);
        return ENTITIES[name];
      }
      return String.fromCodePoint(name[1] === "x" || name[1] === "X" ? parseInt(name.slice(2), 16) : Number(name.slice(1)));
    });
}

function escape(text) {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function classOf(scopes) {
  for (let i = scopes.length - 1; i >= 0; i--) {
    if (scopes[i].startsWith("meta.embedded")) return null;
    const found = CLASSES.find(([prefix]) => scopes[i] === prefix || scopes[i].startsWith(`${prefix}.`));
    if (found) {
      used.add(found[0]);
      return found[1];
    }
  }
  return null;
}

function render(grammar, source) {
  let state = textmate.INITIAL;
  const lines = source.replace(/\n$/, "").split("\n");
  return lines
    .map((line) => {
      const result = grammar.tokenizeLine(line, state);
      state = result.ruleStack;
      return result.tokens
        .map((token) => {
          const text = escape(line.slice(token.startIndex, token.endIndex));
          const name = classOf(token.scopes);
          return name ? `<span class=${name}>${text}</span>` : text;
        })
        .join("");
    })
    .join("\n");
}

// Splits text at the top-level commas, not those inside brackets, parentheses or quotes.
function splitParams(text) {
  const parts = [];
  let depth = 0;
  let quote = false;
  let start = 0;
  for (let i = 0; i < text.length; i++) {
    const char = text[i];
    if (quote) quote = char !== '"' || text[i - 1] === "\\";
    else if (char === '"') quote = true;
    else if ("([{".includes(char)) depth++;
    else if (")]}".includes(char)) depth--;
    else if (char === "," && depth === 0) {
      parts.push(text.slice(start, i));
      start = i + 1;
    }
  }
  parts.push(text.slice(start));
  return parts;
}

// Index of the ")" that closes the "(" at `open`, or -1.
function closingParen(line, open) {
  let depth = 0;
  let quote = false;
  for (let i = open; i < line.length; i++) {
    const char = line[i];
    if (quote) quote = char !== '"' || line[i - 1] === "\\";
    else if (char === '"') quote = true;
    else if (char === "(") depth++;
    else if (char === ")" && --depth === 0) return i;
  }
  return -1;
}

const wrap = (name, text) => (text === "" ? "" : `<span class=${name}>${escape(text)}</span>`);

// A signature line is "Module.name(param: Type = default, ...) -> Type" (the module and the
// result are optional). It colors the module (m), the name (nf), the parameter names (s), the
// types (nc) and "->" (k) with the classes that the code blocks already use.
function renderSignatureLine(line) {
  const open = line.indexOf("(");
  const close = open < 0 ? -1 : closingParen(line, open);
  if (!/^[A-Za-z_][\w.<>?!]*$/.test(line.slice(0, Math.max(open, 0))) || close < 0) return null;
  const qualified = line.slice(0, open);
  const dot = qualified.lastIndexOf(".");
  const params = splitParams(line.slice(open + 1, close))
    .map((param) => {
      const found = param.match(/^(\s*)(\w+)(:\s*)?([\s\S]*)$/);
      if (!found) return escape(param);
      const [, space, name, colon = "", rest] = found;
      if (colon === "") return `${space}${wrap("s", name)}${escape(rest)}`;
      const [type, ...value] = rest.split(" = ");
      return `${space}${wrap("s", name)}${colon}${wrap("nc", type)}${value.length > 0 ? escape(` = ${value.join(" = ")}`) : ""}`;
    })
    .join(",");
  const tail = line.slice(close + 1);
  const arrow = tail.indexOf(" -> ");
  const result = arrow < 0 ? escape(tail) : `${escape(tail.slice(0, arrow))} ${wrap("k", "->")} ${wrap("nc", tail.slice(arrow + 4))}`;
  return `${wrap("m", qualified.slice(0, dot + 1))}${wrap("nf", qualified.slice(dot + 1))}(${params})${result}`;
}

function htmlFiles(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) return htmlFiles(path);
    return entry.name.endsWith(".html") ? [path] : [];
  });
}

async function loadGrammar() {
  const wasm = readFileSync(require.resolve("vscode-oniguruma/release/onig.wasm"));
  await oniguruma.loadWASM(wasm.buffer.slice(wasm.byteOffset, wasm.byteOffset + wasm.byteLength));
  const registry = new textmate.Registry({
    onigLib: Promise.resolve({
      createOnigScanner: (patterns) => new oniguruma.OnigScanner(patterns),
      createOnigString: (text) => new oniguruma.OnigString(text),
    }),
    loadGrammar: async () => JSON.parse(readFileSync(join(here, "agentica.tmLanguage.json"), "utf8")),
  });
  return registry.loadGrammar("source.agentica");
}

const site = process.argv[2];
if (!site) {
  console.error("usage: node highlight.mjs SITE_DIR");
  process.exit(2);
}
const grammar = await loadGrammar();
function fail(message) {
  console.error(`highlight: ${message}`);
  process.exit(1);
}

let blocks = 0;
let signatures = 0;
for (const file of htmlFiles(site)) {
  const html = readFileSync(file, "utf8");
  let index = 0;
  const out = html.replace(BLOCK, (_match, open, body, close) => {
    blocks++;
    index++;
    let source;
    try {
      source = decode(body);
    } catch (error) {
      fail(`${file}: block ${index}: ${error.message}`);
    }
    const colored = render(grammar, source);
    if (decode(colored) !== source.replace(/\n$/, "")) fail(`${file}: block ${index} changed its text`);
    return `${open} class=language-agentica data-lang=agentica>${colored}${close}`;
  });
  const signed = out.replace(SIGNATURE, (_match, open, body, close) => {
    signatures++;
    const colored = body.replace(/(<span class="?cl"?>)([^<]*)(<\/span>)/g, (_cell, start, text, end) => {
      const line = decode(text);
      if (line.trim() === "") return `${start}${text}${end}`;
      const rendered = renderSignatureLine(line.replace(/\n$/, ""));
      if (rendered === null) fail(`${file}: a signature block has a line of an unexpected shape: ${line}`);
      return `${start}${rendered}${line.endsWith("\n") ? "\n" : ""}${end}`;
    });
    if (decode(colored) !== decode(body)) fail(`${file}: a signature block changed its text`);
    return `<div class=signature>${open}<code class=language-signature data-lang=signature>${colored}${close}</div>`;
  });
  if (/class="?agc-code"?/.test(signed)) fail(`${file}: an agentica block has an unexpected shape`);
  if (signed !== html) writeFileSync(file, signed);
}
if (blocks === 0) fail(`no agentica code blocks found in ${site}`);
const unused = CLASSES.filter(([prefix]) => !used.has(prefix)).map(([prefix]) => prefix);
if (unused.length > 0) fail(`no token matched ${unused.join(", ")}: check the scope names in CLASSES`);
if (signatures === 0) fail(`no signature blocks found in ${site}`);
console.log(`highlight: ${blocks} agentica code blocks, ${signatures} signature blocks`);
