#!/usr/bin/env node
// Writes golden render fixtures for the Rust port: runs the bundled renderer scripts in a bare
// JS context (no DOM, same load order as MarkdownRenderer.swift) over Samples/ and saves
//   porting/golden/<name>.input.md  the exact Markdown handed to Renderooo.render
//   porting/golden/<name>.json      its result: { html, toc, hasMermaid }
// Usage: node tools/make-golden.js [more files…]
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const root = path.resolve(__dirname, "..");
const res = path.join(root, "Renderooo/Resources");
const scripts = [
  "vendor/markdown-it.min.js",
  "vendor/highlight.min.js",
  "vendor/markdown-it-footnote.min.js",
  "katex/katex.min.js",
  "vendor/texmath.js",
  "render.js",
];

const context = vm.createContext({});
context.globalThis = context;
for (const s of scripts) vm.runInContext(fs.readFileSync(path.join(res, s), "utf8"), context, { filename: s });

// Same rules as MermaidFile in MarkdownDocument.swift.
const KEYWORDS = new Set(["graph", "flowchart", "sequenceDiagram", "classDiagram", "classDiagram-v2", "stateDiagram",
  "stateDiagram-v2", "erDiagram", "journey", "gantt", "pie", "quadrantChart", "requirementDiagram", "gitGraph",
  "C4Context", "C4Container", "C4Component", "C4Dynamic", "C4Deployment", "mindmap", "timeline", "zenuml",
  "sankey-beta", "xychart-beta", "block-beta", "packet-beta", "architecture-beta", "kanban", "radar-beta"]);

function looksLikeDiagram(text) {
  let inFrontMatter = false, sawFirstLine = false;
  for (const raw of text.split("\n")) {
    const line = raw.replace(/^[\s﻿]+|[\s﻿]+$/g, "");
    if (line === "---") {
      if (!sawFirstLine || inFrontMatter) inFrontMatter = !inFrontMatter;
      sawFirstLine = true;
      continue;
    }
    sawFirstLine = sawFirstLine || line !== "";
    if (inFrontMatter || line === "" || line.startsWith("%%")) continue;
    const first = line.split(/[ \t;:]/).filter(Boolean)[0];
    return first ? KEYWORDS.has(first) : false;
  }
  return false;
}

function renderable(text, file) {
  const ext = path.extname(file).slice(1).toLowerCase();
  if (ext !== "mmd" && ext !== "mermaid") return text;
  if (ext === "mmd" && !looksLikeDiagram(text)) return text;
  const longest = Math.max(0, ...(text.match(/`+/g) || []).map((r) => r.length));
  const fence = "`".repeat(Math.max(3, longest + 1));
  return `${fence}mermaid\n${text}\n${fence}\n`;
}

const out = path.join(root, "porting/golden");
fs.mkdirSync(out, { recursive: true });
const samples = path.join(root, "Samples");
const files = fs.readdirSync(samples).filter((f) => /\.(md|markdown|mmd|mermaid)$/i.test(f)).map((f) => path.join(samples, f))
  .concat(process.argv.slice(2).map((f) => path.resolve(f)));

for (const file of files) {
  const input = renderable(fs.readFileSync(file, "utf8"), file);
  const result = JSON.parse(context.Renderooo.render(input));
  const name = path.basename(file);
  fs.writeFileSync(path.join(out, name + ".input.md"), input);
  fs.writeFileSync(path.join(out, name + ".json"), JSON.stringify(result, null, 2) + "\n");
  console.log(`${name}: ${result.html.length} chars html, ${result.toc.length} headings, mermaid=${result.hasMermaid}`);
}
