// Renderooo renderer glue. Runs inside a JavaScriptCore context (no DOM),
// never inside the preview web view. Exposes Renderooo.render(markdown) -> HTML.
(function () {
  "use strict";

  function escapeHtml(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }

  var LANGUAGE_ALIASES = { sh: "bash", zsh: "bash", shell: "bash", console: "bash", js: "javascript", ts: "typescript", yml: "yaml", objc: "objectivec", "c++": "cpp", py: "python", rb: "ruby", md: "markdown" };

  function highlight(code, info) {
    var lang = (info || "").trim().split(/\s+/)[0].toLowerCase();
    lang = LANGUAGE_ALIASES[lang] || lang;
    if (lang === "mermaid") {
      // Drawn later inside the preview (Mermaid needs a real DOM); the source stays visible until then.
      // Must start with "<pre" or markdown-it wraps it in another <pre><code>.
      return '<pre class="code-block mermaid-block" data-source="' + escapeHtml(code) + '"><code>' + escapeHtml(code) + "</code></pre>\n";
    }
    var body = null;
    if (lang && hljs.getLanguage(lang)) {
      try { body = hljs.highlight(code, { language: lang, ignoreIllegals: true }).value; } catch (e) { body = null; }
    }
    if (body === null) body = escapeHtml(code);
    var cls = lang ? ' class="hljs language-' + escapeHtml(lang) + '"' : ' class="hljs"';
    var label = lang ? '<span class="code-lang">' + escapeHtml(lang) + "</span>" : "";
    return '<pre class="code-block">' + label + "<code" + cls + ">" + body + "</code></pre>\n";
  }

  var md = markdownit({ html: true, linkify: true, typographer: false, highlight: highlight })
    .use(markdownitFootnote)
    // $inline$, $$display$$, $`inline`$ and ```math blocks, rendered to HTML by KaTeX right here.
    .use(texmath, { engine: katex, delimiters: ["dollars", "gitlab"], katexOptions: { throwOnError: false, output: "html" } });

  // GFM task lists: "- [ ] todo" / "- [x] done"
  var TASK_RE = /^\[([ xX])\](?=\s|$)\s?/;
  md.core.ruler.after("inline", "gfm-task-lists", function (state) {
    var tokens = state.tokens;
    for (var i = 2; i < tokens.length; i++) {
      var inline = tokens[i];
      if (inline.type !== "inline" || tokens[i - 1].type !== "paragraph_open" || tokens[i - 2].type !== "list_item_open") continue;
      var first = inline.children && inline.children[0];
      if (!first || first.type !== "text") continue;
      var m = TASK_RE.exec(first.content);
      if (!m) continue;
      first.content = first.content.slice(m[0].length);
      var box = new state.Token("html_inline", "", 0);
      box.content = '<input type="checkbox" class="task-list-item-checkbox" disabled' + (m[1] === " " ? "" : " checked") + "> ";
      inline.children.unshift(box);
      var item = tokens[i - 2];
      item.attrJoin("class", "task-list-item");
      for (var j = i - 3; j >= 0; j--) {
        var t = tokens[j];
        if ((t.type === "bullet_list_open" || t.type === "ordered_list_open") && t.level === item.level - 1) {
          t.attrSet("class", "contains-task-list");
          break;
        }
      }
    }
  });

  // GitHub alerts: "> [!NOTE]" etc.
  var ALERT_RE = /^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*$/i;
  md.core.ruler.after("gfm-task-lists", "gfm-alerts", function (state) {
    var tokens = state.tokens;
    for (var i = 0; i + 2 < tokens.length; i++) {
      if (tokens[i].type !== "blockquote_open" || tokens[i + 1].type !== "paragraph_open" || tokens[i + 2].type !== "inline") continue;
      var children = tokens[i + 2].children || [];
      if (!children.length || children[0].type !== "text") continue;
      var m = ALERT_RE.exec(children[0].content);
      if (!m) continue;
      var kind = m[1].toLowerCase();
      children.shift();
      if (children.length && (children[0].type === "softbreak" || children[0].type === "hardbreak")) children.shift();
      tokens[i].attrSet("class", "markdown-alert markdown-alert-" + kind);
      var title = new state.Token("html_block", "", 0);
      title.content = '<p class="markdown-alert-title">' + kind.charAt(0).toUpperCase() + kind.slice(1) + "</p>\n";
      tokens.splice(i + 1, 0, title);
      if (!children.length) {
        // The marker was the whole paragraph; hide the now-empty paragraph.
        tokens[i + 2].hidden = true;
        tokens[i + 4].hidden = true;
      }
    }
  });

  // Claude's Markdown export drops embedded diagrams and leaves "[embedded content: <title>]"
  // (written as "&#91;embedded content: …\]"). Show it as a notice instead of raw text.
  var EMBED_RE = /^\s*\[embedded content:\s*([\s\S]*?)\]\s*$/;
  md.core.ruler.after("gfm-alerts", "export-placeholders", function (state) {
    var tokens = state.tokens;
    for (var i = 0; i + 2 < tokens.length; i++) {
      if (tokens[i].type !== "paragraph_open" || tokens[i + 1].type !== "inline") continue;
      var children = tokens[i + 1].children || [];
      if (!children.every(function (c) { return c.type === "text" || c.type === "text_special"; })) continue;
      var m = EMBED_RE.exec(children.map(function (c) { return c.content; }).join(""));
      if (!m) continue;
      var box = new state.Token("html_block", "", 0);
      box.content = '<div class="export-placeholder"><p class="export-placeholder-title">Diagram not included in export</p>' +
        (m[1].trim() ? "<p>" + escapeHtml(m[1].trim()) + "</p>" : "") +
        "<p>Open the PDF export or the original doc to see it.</p></div>\n";
      tokens.splice(i, 3, box);
    }
  });

  // GitHub-style heading ids so "#some-heading" links work.
  md.core.ruler.push("heading-anchors", function (state) {
    var seen = Object.create(null);
    var toc = state.env.toc || (state.env.toc = []);
    var tokens = state.tokens;
    for (var i = 0; i < tokens.length; i++) {
      if (tokens[i].type !== "heading_open") continue;
      var text = (tokens[i + 1].children || [])
        .filter(function (c) { return c.type === "text" || c.type === "code_inline"; })
        .map(function (c) { return c.content; }).join("");
      var slug = text.trim().toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu, "").replace(/\s/g, "-");
      if (seen[slug] !== undefined) { seen[slug] += 1; slug += "-" + seen[slug]; } else { seen[slug] = 0; }
      tokens[i].attrSet("id", slug);
      toc.push({ level: Number(tokens[i].tag.slice(1)), text: text.trim(), id: slug });
    }
  });

  // YAML front matter is shown as a code block instead of a stray <hr>.
  var FRONT_MATTER_RE = /^---[ \t]*\r?\n([\s\S]*?)\r?\n(?:---|\.\.\.)[ \t]*(?:\r?\n|$)/;

  globalThis.Renderooo = {
    // Returns JSON: { html, toc: [{ level, text, id }], hasMermaid }
    render: function (src) {
      if (src.charCodeAt(0) === 0xfeff) src = src.slice(1);
      var prefix = "";
      var fm = FRONT_MATTER_RE.exec(src);
      if (fm) {
        prefix = '<div class="front-matter">' + highlight(fm[1], "yaml") + "</div>\n";
        src = src.slice(fm[0].length);
      }
      var env = {};
      var html = prefix + md.render(src, env);
      return JSON.stringify({ html: html, toc: env.toc || [], hasMermaid: html.indexOf('mermaid-block" data-source=') !== -1 });
    }
  };
})();
