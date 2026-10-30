# Porting Renderooo to Linux (Lubuntu) in Rust

This is a handoff for rebuilding Renderooo as a Linux app in Rust. The macOS (Swift) version is the reference implementation. When this document and the Swift code disagree, the code wins.

Read [README.md](README.md) first for the feature list. This document covers **how it works inside**, **what must stay the same**, and **what changes on Linux**.

## Status

- **Target:** Linux only (Lubuntu first).
- **Progress:** the latest iteration of the Linux port builds and runs on the Linux machine. It isn't on GitHub yet.

## Changes to carry over

Mac changes the Linux port must pick up, newest first. Most are web assets, so copying the file over is usually the whole job. Re-run the golden tests afterwards.

| Mac version | Change | Files | Port action |
|---|---|---|---|
| 1.0.1 | Closing the last window quits the app instead of leaving it in the Dock. A save started by that close finishes (up to 2 s) before the process exits. | `RenderoooApp.swift`, `PreviewController.swift` | Tauri already exits when the last window closes. Make sure the close-time save is flushed before exit. |
| 1.0.1 | Claude's Markdown export leaves `&#91;embedded content: <title>\]` where a diagram was. A paragraph that is only that placeholder now renders as a "Diagram not included in export" box. The same words inside other text are untouched. | `render.js`, `style.css` | Copy both files. Covered by `porting/golden/ClaudeExport.md.*` |

---

## 1. TL;DR

- **Most of the app is already portable.** About 85% of the behavior lives in web assets that carry over unchanged: `render.js`, `mermaid-enhance.js`, `style.css`, and the vendored markdown-it, highlight.js, KaTeX and Mermaid/ELK. The Swift side is glue: windows, file I/O, a file watcher, a custom URL scheme, a disk cache, and one pure-text module (`MermaidSourceEditor`).
- **Recommended stack:** Tauri 2 on WebKitGTK 4.1. Run the Markdown renderer in **rquickjs** (embedded QuickJS) on the Rust side, which mirrors the JavaScriptCore setup.
- **Hardest problem: the security model.** On macOS the preview page runs *no* JavaScript, while the app's own Mermaid code runs in an isolated WebKit "content world". Tauri doesn't expose that directly, so the port uses a nonce-based CSP as its baseline (section 5), with WebKitGTK's own script worlds as optional hardening.
- **Golden fixtures already exist** in [porting/golden/](porting/golden/). They capture the exact renderer output and visual-edit rewrites from the current app, so the port can be tested against them from day one.

---

## 2. Architecture today (macOS)

```
file ─▶ MarkdownDocument.decode (UTF-8 → UTF-16 BOM → Latin-1)
          │
          ├─ MermaidFile.renderableMarkdown: .mmd/.mermaid → wrap in a ```mermaid fence
          ▼
   MarkdownRenderer  ── JavaScriptCore, one context, serial queue, warmed at launch
          │              loads: markdown-it, highlight.js, footnote, katex, texmath, render.js
          │              calls: Renderooo.render(markdown) → JSON {html, toc, hasMermaid}
          ▼
   PreviewController (one per window)
          ├─ HTMLPage.make(): wraps body in a page with a strict CSP, inline CSS, KaTeX CSS if needed
          ├─ DiagramCache: swaps in cached SVGs for ```mermaid blocks when every one is cached
          ├─ WKWebView: page JS DISABLED; app scripts run in WKContentWorld.defaultClient
          │     injected: mermaid.min.js + mermaid-enhance.js (+ ELK if flowcharts) OR enhance-only (cached)
          ├─ LocalSchemeHandler: renderooo://local/<abs dir>/… (files next to doc), renderooo://app/… (bundle)
          ├─ FileWatcher: DispatchSource on the file; re-opens after delete/rename (atomic saves)
          ├─ Editing: NSTextView, debounced render (150 ms) + autosave (1 s), conflict banner
          └─ Visual editing: MermaidSourceEditor rewrites the source text → save → re-render
```

### Swift file → Rust/port module map

| Swift file | What it does | Port target |
|---|---|---|
| `RenderoooApp.swift` | App entry, prefs defaults, appearance, warm-up | `main.rs` + Tauri `Builder::setup`; prefs via `tauri-plugin-store` |
| `MarkdownDocument.swift` | Text decoding; `MermaidFile` (.mmd detection, fence wrapping) | `doc.rs`: pure Rust (`encoding_rs`) |
| `MarkdownRenderer.swift` (`MarkdownRenderer`) | JSC context, render, 4-entry recent cache | `renderer.rs`: rquickjs on a dedicated thread + channel |
| `MarkdownRenderer.swift` (`MermaidSupport`) | Which scripts to inject, regexes | `diagrams.rs` |
| `MarkdownRenderer.swift` (`HTMLPage`) | Page template + CSP | `page.rs` (**CSP changes, see section 5**) |
| `LocalSchemeHandler.swift` | `renderooo://` protocol | `register_asynchronous_uri_scheme_protocol` |
| `FileWatcher.swift` | Watch file, survive atomic saves | `notify` + debouncer, **watch the parent directory** |
| `DiagramCache.swift` | SVG cache keyed by SHA-256 | `cache.rs` (`sha2`, `dirs`) |
| `MermaidSourceEditor.swift` | Read/rewrite one node's label/shape/fill | `mermaid_edit.rs`: pure Rust, **test against golden JSON** |
| `PreviewController.swift` | Per-window state machine | `window_state.rs` + preview-webview glue |
| `PreviewScreen.swift` | SwiftUI chrome: TOC, split, find bar, inspector, zoom chip | HTML/CSS/JS in the chrome webview |
| `MarkdownEditor.swift` | NSTextView source editor | CodeMirror 6 (bundled, offline) in the chrome webview |
| `PreviewCommands.swift` | Menus + shortcuts + "make default" | Tauri menu API + `xdg-mime` default-app code |
| `PreviewWebView.swift` | Initial window size (≥860 wide, 980 tall) | `WindowBuilder` size |
| `Info.plist` | Document types / UTIs | `tauri.conf.json` `bundle.fileAssociations` + `.desktop`/MIME XML |
| `tools/MakeIcon.swift` | icon.png → .icns | `tauri icon icon.png` (makes the .png set) |

---

## 3. Recommended Rust architecture

**One OS window per document, with two webviews in it:**

1. **Chrome webview** (trusted, has IPC): TOC sidebar, find bar, editor (CodeMirror 6), node inspector, zoom chip, conflict/save-error banners.
2. **Preview webview** (untrusted content, minimal IPC): loads the rendered page from the custom protocol.

Tauri 2 multi-webview windows need the `unstable` feature (`Window::add_child`). If that proves flaky, the fallback is one webview with the preview in an `<iframe sandbox="allow-scripts">` (no `allow-same-origin`) that talks to the parent through `postMessage`. That fallback costs you native print, PDF and find on the preview alone, which is why the two-webview design is preferred.

**Crates:**

| Need | Crate |
|---|---|
| App shell, webviews, menus, protocol | `tauri` 2 (+ `unstable` feature for child webviews) |
| Renderer | `rquickjs` (QuickJS supports the `\p{L}` / `u` regexes render.js uses) |
| File watching | `notify` + `notify-debouncer-full` |
| Text decoding | `encoding_rs` |
| Cache hashing / dirs | `sha2`, `dirs` |
| Regex | `regex`, plus `fancy-regex` **only** where lookbehind is needed (see section 7) |
| Single instance (file double-clicks) | `tauri-plugin-single-instance` |
| Open URLs / reveal files | `tauri-plugin-opener` |
| Save dialog | `tauri-plugin-dialog` |
| Prefs | `tauri-plugin-store` |
| Window size/position restore | `tauri-plugin-window-state` |

**Renderer threading.** Keep it like Swift: one QuickJS runtime on one dedicated thread, loaded at startup ("warm-up"). Requests go in over a channel, and a small recent-results cache (4 entries, keyed by exact source text) bridges "prefetch while the window opens" and "first render". Load the scripts in **exactly** this order: `markdown-it.min`, `highlight.min`, `markdown-it-footnote.min`, `katex/katex.min`, `texmath`, `render`. Then call `globalThis.Renderooo.render(src)`, which returns a JSON string.

> **Performance risk:** QuickJS has no JIT. The macOS app renders a README in about 10 ms and a 10,000-line file in about 120 ms on JavaScriptCore. Benchmark `porting/golden/Workflow.mmd.input.md`, `Features.md.input.md` and a synthetic 10k-line file early. If QuickJS is too slow, the fallback is to render in a hidden app-only webview (V8/JSC) and pipe the JSON back. Output is identical either way.

---

## 4. Contracts to keep exactly

These are the interfaces between Rust, the bundled JS and the cache. Break one and features quietly stop working.

### 4.1 Renderer output (`render.js`)

`Renderooo.render(markdown) → JSON string`:
```json
{ "html": "...", "toc": [{ "level": 1, "text": "Title", "id": "title" }], "hasMermaid": true }
```
- A leading BOM (U+FEFF) is stripped. YAML front matter becomes `<div class="front-matter">` with a highlighted yaml block.
- Mermaid fences come out as `<pre class="code-block mermaid-block" data-source="ESCAPED"><code>ESCAPED</code></pre>`. **`DiagramCache` and `hasMermaid` both depend on that exact string.**
- Math present ⇔ the HTML contains `class="katex` (`HTMLPage.needsMath`).
- If rendering fails, fall back to `<pre class="code-block"><code>{escaped source}</code></pre>`, empty TOC, `hasMermaid: false`.

### 4.2 Page DOM

- `<article id="renderooo-content" class="markdown-body">` holds the body. Live updates replace its `innerHTML`, so scroll position survives.
- `<body class="zq-canvas">` for standalone diagram files.
- KaTeX CSS is inlined as `<style id="katex-css">` only when needed. Its `url(fonts/` references are rewritten to the app-resource URL. A live edit that introduces math adds that style tag on the fly.

### 4.3 App → page calls (all into the app's script context)

| Call | When |
|---|---|
| `ZQ.renderAll(forceLight, canvas)` | First draw; theme change; print (forceLight=true), then again after print |
| `ZQ.update(html, forceLight=false, canvas)` | Live reload/edit of a doc with diagrams (draws off-screen, then swaps; no flash) |
| `ZQ.adopt(canvas)` | Page loaded with **cached** SVGs: add arrows, interaction and canvas without Mermaid |
| `ZQ.command("in"\|"out"\|"fit"\|"actual")` | Canvas zoom menu items |
| `document.getElementById('renderooo-content').innerHTML = html` | Live update of a doc without diagrams |
| `window.scrollY` / `window.scrollTo(0,y)` | Keep scroll across full reloads |
| `el.scrollIntoView({block:'start'})` | TOC click, `#fragment` links |
| Dispatch `keydown` `Escape` on document + window | Inspector "deselect" |
| Find-count script (lowercased `innerText` indexOf loop) | Find bar "N matches" |

### 4.4 Page → app messages

`mermaid-enhance.js` calls `post(obj)`, which is hard-wired to `window.webkit.messageHandlers.renderooo.postMessage`. **Change that one function** (`mermaid-enhance.js` around line 430) to an IPC shim, e.g.:
```js
function post(message) {
  try {
    if (window.webkit && window.webkit.messageHandlers) window.webkit.messageHandlers.renderooo.postMessage(message);
    else if (window.__RENDEROOO_POST__) window.__RENDEROOO_POST__(message); // set by the port's injected bridge
  } catch (e) {}
}
```
Message shapes (any combination of keys can appear):

| Message | Meaning |
|---|---|
| `{ zoom: number }` | Canvas zoom changed → update the zoom chip |
| `{ selected: string \| null }` | Node selected/deselected → open/close inspector |
| `{ editText: string }` | Node double-clicked → select it and focus the label field |
| `{ cacheSVG, source, layout: "elk"\|"dagre", dark: bool, canvas: bool }` | Finished drawing → write to `DiagramCache` |

### 4.5 Diagram cache

- Key: `sha256("v1|" + engineFingerprint + "|" + ("dark"\|"light") + "|" + ("canvas"\|"doc") + "|" + source)` as lowercase hex; file `<key>.json` holding `{"svg": "...", "layout": "elk"\|"dagre"}`.
- `engineFingerprint` = sha256 over `"mermaid-enhance:<size>|mermaid.min:<size>|mermaid-layout-elk.min:<size>|"` followed by the full bytes of `mermaid-enhance.js`. Changing the JS therefore invalidates the cache automatically.
- Maximum 400 files; after each write, delete the oldest by mtime.
- On page load, if **every** mermaid block in the body has a cache hit, replace each with `<pre class="mermaid-block" data-source="…" data-layout="…">SVG</pre>`, inject only `mermaid-enhance.js`, and call `ZQ.adopt`. Otherwise inject Mermaid (+ ELK) and render normally. Mermaid is lazy-loaded later if the user selects a node.
- Location: `~/Library/Caches/Renderooo/diagrams` → Linux `~/.cache/Renderooo/diagrams` (via `dirs::cache_dir()`). **Add the OS to the key** (`"v1|linux|…"`): font metrics differ, so SVGs aren't portable.

### 4.6 Detection rules

- **Mermaid file:** extension `mmd` or `mermaid` (case-insensitive). `.mermaid` is always a diagram. `.mmd` is a diagram only if `looksLikeDiagram`: skip a leading `---` front-matter block, blank lines and `%%` lines (also trim BOM), then the first word (split on space, tab, `;`, `:`) must be one of the keywords in `MermaidFile.diagramKeywords`. Otherwise render as MultiMarkdown/Markdown.
- **Fence wrap:** fence = backticks × max(3, longest backtick run in text + 1), then `"{fence}mermaid\n{text}\n{fence}\n"`.
- **Might have diagrams:** mermaid file OR regex `(?m)^\s*(```+|~~~+)\s*mermaid\b`.
- **Needs ELK:** regex `(?m)^\s*(flowchart|graph)\b` on the source.

---

## 5. Security model (the part that changes most)

**Today:** `allowsContentJavaScript = false`, so the page itself can't run any script. The CSP has no `script-src` at all. The app's scripts run in `WKContentWorld.defaultClient`, an isolated world where the page can't see them. Untrusted Markdown with `<script>`, `onerror=`, `javascript:` links or meta-refresh does nothing.

**CSP today** (`HTMLPage.make`):
```
default-src 'none'; img-src renderooo: data: [https: http: if remote images on];
media-src (same); style-src 'unsafe-inline' renderooo:; font-src renderooo: data:;
frame-src 'none'; form-action 'none'
```

**Port plan:**
1. Generate a random **nonce per page load**. CSP becomes the above plus `script-src 'nonce-XYZ'` and `base-uri 'none'`. Inline handlers, `javascript:` URLs and un-nonced `<script>` in Markdown are all blocked.
2. Inject the app scripts as `<script nonce="XYZ" src="<app-resource-url>/mermaid.min.js">` (served by the protocol handler, so the 9 MB file isn't pushed through IPC), followed by the IPC bridge and `mermaid-enhance.js`. Alternatively use Tauri/wry initialization scripts, but **verify** whether WebKitGTK applies the page CSP to them.
3. Run Mermaid with `securityLevel: "strict"` (already set).
4. Give the preview webview a Tauri capability with **only** one command (e.g. `preview_event(json)`). It must not get filesystem, shell or opener permissions.
5. Keep the navigation policy (section 6.6): only the protocol's own page and `about:` may load; everything else is cancelled and routed.

**Optional hardening:** WebKitGTK can match macOS exactly. `WebKitSettings:enable-javascript-markup = false` blocks page scripts, while user scripts and `evaluate_javascript` in a named `WebKitScriptWorld` still run. Use it if it's easy to reach through `with_webview`, but keep the nonce CSP as the baseline.

**Check during the port:** Mermaid 11 / elkjs must run without `'unsafe-eval'`. Watch the console for CSP violations on the first ELK flowchart.

**Acceptance test:** open a `.md` containing `<script>document.body.innerHTML='PWNED'</script>`, `<img src=x onerror="document.title='PWNED'">` and `[x](javascript:alert(1))`. Nothing may happen.

---

## 6. Behavior details to preserve

### 6.1 Timings and limits

| What | Value |
|---|---|
| File-change coalescing before reload | 75 ms |
| Editor → preview re-render debounce | 150 ms |
| Editor autosave after last keystroke | 1 s |
| Inspector label edit → apply | 450 ms |
| Colour-picker live drag → apply | 250 ms |
| Visual undo/redo stack | 200 entries (whole-source snapshots) |
| File re-open retries after atomic save | 20 × 100 ms |
| Recent render results | 4 |
| Diagram cache | 400 entries |
| Page zoom | 0.5–3.0, step 0.1, persisted, shared by all windows |
| Canvas zoom | 0.05–8; ⌘0/fit uses max 2×; first view fits with max 1× |
| Window open size | grow to ≥860 wide, 980 tall (capped to screen) |
| Editor opens → widen window to | min(1400, screen width) |
| Print/PDF margins | 42 pt on all sides; horizontal fit, vertical auto pagination |

### 6.2 Render pipeline state machine

- **Render generation counter:** every render request bumps it, and results from older generations are dropped. Rapid typing must never show a stale render.
- **Fast open:** the document text is rendered on the renderer thread *while the window is being built* (prefetch). When the window is ready it takes the finished result. If it isn't ready yet, load an empty "shell" page first, so the webview process and Mermaid start in parallel, and drop the content in when it arrives.
- **Full page vs in-place:** use a full navigation on first load, on doc ↔ canvas mode switches, on file move/rename, and when the remote-images pref changes (restore scrollY). Everything else is an in-place swap.
- **Webview process crash** (WebKitGTK `web-process-terminated`): reload the last body.
- **Theme change:** CSS follows by itself, but diagrams must be redrawn (`ZQ.renderAll`).

### 6.3 Editing and saving (don't regress these)

- Documents open **read-only**. Editing is opt-in (⌘E). Editor undo history is private to the editor and must not mark anything "dirty" in the OS sense.
- Before writing, set `diskText = text` and clear the dirty flag. That way the file watcher sees the app's own write as "no change".
- **Autosave never overwrites someone else's change.** If the file changes on disk while there are unsaved edits, set `diskChangedWhileEditing` and show the banner ("Use disk version" / "Keep my edits"). ⌘S, stopping editing, visual edits and "Keep my edits" force-write.
- Write **in place** (truncate and write the same path, not temp+rename) to keep permissions, xattrs and tags. Saves are serialized on one background queue. If a save fails, show the error and re-mark dirty if the text hasn't changed since.
- On quit: commit pending inspector edits and save synchronously.
- Saved files are always UTF-8.

### 6.4 Visual editing (`.mmd` / `.mermaid` only)

- Only offered when the window is a canvas **and** has a file.
- Each edit takes the whole-source snapshot, applies a `MermaidSourceEditor` transform, pushes onto undo (clears redo), writes through to the editor pane if open, saves (forced), re-renders and refreshes the inspector.
- Undo/redo shortcuts go to visual edits only when no text field has focus. Otherwise they go to normal text undo.
- Text that arrives from disk clears both visual stacks.
- Swatches: `#FFFFFF #ECEEEF #E3EFE6 #E7F0FB #FFF8C5 #FDE2E1 #EFE6FB #3D6B5E #1F3A33 #0A2342 #F4D35E #E07A5F #5B7DB1 #6B7280` (two rows of seven), plus a custom colour and "Default".
- Text colour on fill: luminance `(0.299r + 0.587g + 0.114b)/255 < 0.55` → `#ffffff`, else `#1f2328`.

### 6.5 Find

- Case-insensitive, wraps around. A new query starts from the top (clear the selection first). The status shows "Not found" / "1 match" / "N matches" from the JS count over `#renderooo-content.innerText`.
- macOS uses `WKWebView.find`. **Port:** do it in JS inside the preview (`window.find()` works in WebKit) and keep the count script. `WebKitFindController` exists if needed.
- With the editor focused, ⌘F goes to the editor's own find (CodeMirror search panel).

### 6.6 Link handling (navigation policy)

- `#anchor` on the page: allow (in-page scroll).
- A protocol or `file:` URL that points at the **current** file: scroll to the fragment.
- Points at `.md`, `.markdown`, `.mmd`, `.mermaid` (exists): open in a Renderooo window. **If that file is already open, focus its window.**
- Points at another existing local file: **reveal it in the file manager. Never launch it.**
- Missing file: beep.
- `http(s)`, `mailto`: hand to the OS default handler. Any other scheme (`smb:`, `vnc:`, other apps' schemes): ask first ("Open this link in another app?").
- Not a user click (meta refresh etc.): only the preview page URL itself and `about:` may load, not other local files.

### 6.7 Printing / PDF

- Paper is always light (`@media print` in style.css). If the UI is dark and there are diagrams, redraw them with `forceLight=true` first, print, then redraw normally.
- PDF default name: `<doc name>.pdf`, in the doc's folder.

---

## 7. Gotchas when porting `MermaidSourceEditor`

Port it as pure Rust and drive it entirely from `porting/golden/mermaid-editor.json`.

- **Lookbehind:** `tokenRanges` uses `(?<![A-Za-z0-9_])ID(?![A-Za-z0-9_])`. The `regex` crate has no lookaround. Either match `ID` and check the neighbouring bytes by hand (simplest), or use `fancy-regex` for this one pattern.
- **Index model:** Swift uses grapheme `String.Index`. All the delimiters here (brackets, quotes, ids) are ASCII, so byte offsets in Rust are fine as long as you only slice at matched positions.
- **Meta lines** (`%%`, `style `, `classDef `, `class `, `linkStyle `, `click `, `direction `, `subgraph `, `end`, `flowchart`, `graph`) never count as node definitions.
- **Bracket table order matters:** longest openers first (`(((`, `([`, `[[`, `[(`, `((`, `{{`, `[/`, `[\`, `[`, `(`, `{`, `>`). Parallelograms accept either `/]` or `\]` as the closer.
- **Label encoding:** `"` ↔ `#quot;`, newline ↔ `<br/>` (decode also accepts `<br>`, `<br />`, `<BR>`, `<BR/>`). New labels are always written quoted.
- **Mermaid 11 expanded syntax** `id@{ shape: x, label: "y" }` is read and updated in place.
- **Style line:** one `style ID k:v,k:v` line per node, keys kept in their original order. Setting a fill sets `fill` + `color`. Clearing removes both and deletes the line if it becomes empty. New lines go at the end after trimming trailing blank lines, followed by one empty line.
- ⚠️ **CRLF bug (fix it, don't copy it):** the Swift code splits on `\n` only. On a CRLF file, `setFill` appends `style …\n` and leaves `\r` on the other lines, producing **mixed line endings** (see the `crlf` cases in the golden file). CRLF files still turn up on Linux (shared drives, files from other machines). In Rust: detect the file's line ending, normalize to `\n` for editing, and restore on write. Treat the golden `crlf` *setFill* outputs as known-bad and assert the corrected output instead.

---

## 8. macOS → Linux

| Concern | macOS (today) | Linux / Lubuntu |
|---|---|---|
| Webview | WKWebView | WebKitGTK 4.1 (`libwebkit2gtk-4.1-dev`, Ubuntu/Lubuntu 22.04+) |
| Custom scheme URL | `renderooo://local/<abs path>` | `renderooo://…` works |
| Page loading | `loadHTMLString(baseURL:)` | Navigate to the page URL on the protocol, serving `pageHTML` from memory (the Swift handler already supports this), so relative images resolve |
| Doc path in URL | `/Users/x/dir/` | `/home/x/dir/` |
| Isolated script world | `WKContentWorld` | Available (`WebKitScriptWorld`), optional |
| Dark mode | `NSApp.appearance` + `prefers-color-scheme` | LXQt isn't GTK, so system dark detection is unreliable; xdg-desktop-portal `color-scheme` may be missing |
| Fonts | `ui-monospace, "SF Mono", -apple-system` | Add `"DejaVu Sans Mono", "Noto Sans Mono", "Ubuntu Mono"` / `"Noto Sans", "DejaVu Sans"` |
| File watching | DispatchSource on the inode | inotify via `notify` |
| Atomic saves | re-open after rename | **Watch the parent dir**, filter by filename |
| In-place write | NSFileCoordinator | plain write |
| Multiple files / windows | one process, many windows | Each double-click starts a process, so **single-instance plugin** forwards args |
| Default app | `NSWorkspace.setDefaultApplication` (with confirm) | `xdg-mime default renderooo.desktop text/markdown text/vnd.mermaid` |
| File associations | Info.plist UTIs | `.desktop` `MimeType=text/markdown;text/x-markdown;text/vnd.mermaid;` + shared-mime-info XML for Mermaid (below) |
| Reveal in file manager | `activateFileViewerSelecting` | D-Bus `org.freedesktop.FileManager1.ShowItems` (PCManFM-Qt may not implement it), fallback: `xdg-open` the parent folder |
| Print | `NSPrintOperation` | `WebKitPrintOperation` (+ `GtkPrintSettings`) |
| Export PDF | print job → file | `WebKitPrintOperation` with output-uri, no dialog |
| Pinch zoom on canvas | `gesturestart`/`gesturechange` (Safari-only) | Touchpad pinch may become webview zoom. Disable and verify |
| Prefs | `UserDefaults` | `~/.config/Renderooo/…` |

Shared-mime-info file for Linux (`/usr/share/mime/packages/renderooo-mermaid.xml`, then `update-mime-database`):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="text/vnd.mermaid">
    <comment>Mermaid Diagram</comment>
    <sub-class-of type="text/plain"/>
    <glob pattern="*.mmd"/>
    <glob pattern="*.mermaid"/>
  </mime-type>
</mime-info>
```

**Theme recommendation:** don't rely on `prefers-color-scheme` alone. Put `data-theme="light|dark"` on `<html>` from Rust, and change the CSS's `@media (prefers-color-scheme: dark)` blocks into `:root[data-theme=dark]` selectors (keep the media query for system mode if you like). In `mermaid-enhance.js`, `renderAll`/`update` currently read `matchMedia(...)`. Pass `dark` in as an argument instead. Then View ▸ Appearance behaves the same everywhere, including on LXQt.

**Linux GPU quirk:** WebKitGTK can render blank or garbled output on some GPU drivers (notably NVIDIA). The common workaround is `WEBKIT_DISABLE_DMABUF_RENDERER=1` (or `WEBKIT_DISABLE_COMPOSITING_MODE=1`). Test on the target Lubuntu box.

---

## 9. Keyboard shortcuts (⌘ → Ctrl)

| Action | macOS | Linux proposal |
|---|---|---|
| Edit / Stop editing | ⌘E | Ctrl+E |
| Save | ⌘S | Ctrl+S |
| Find / Next / Prev | ⌘F / ⌘G / ⇧⌘G | Ctrl+F / F3 (+Ctrl+G) / Shift+F3 (+Ctrl+Shift+G) |
| TOC sidebar | ⌃⌘S | Ctrl+B (Ctrl+Shift+S usually means Save As) |
| Reload | ⌘R | Ctrl+R / F5 |
| Reveal | ⇧⌘R | Ctrl+Shift+R ("Show in folder") |
| Print / Export PDF | ⌘P / ⇧⌘E | Ctrl+P / Ctrl+Shift+E |
| Zoom fit / 100% / in / out | ⌘0 / ⌘1 / ⌘= / ⌘− | Ctrl+0 / Ctrl+1 / Ctrl+= (+Ctrl++) / Ctrl+− |
| Undo / Redo | ⌘Z / ⇧⌘Z | Ctrl+Z / Ctrl+Y and Ctrl+Shift+Z |
| Close window | ⌘W | Ctrl+W |
| New line in inspector label | ⌥Return | Shift+Enter |
| Canvas zoom at pointer | ⌘/⌥ + wheel, pinch | Ctrl + wheel. **Alt+wheel/drag is often taken by the window manager on LXQt/Openbox**, so treat Alt as best-effort |
| Canvas pan | Space+drag, drag empty, middle-drag, scroll | Same; on Linux `preventDefault` middle-click so it doesn't paste the primary selection |

The JS in `mermaid-enhance.js` checks `event.metaKey` for zoom. That stays harmless, and `ctrlKey` is already accepted.

---

## 10. Suggested order of work

1. **Skeleton:** Tauri app opens a file from argv, decodes it, and shows raw text. Add single-instance arg forwarding and file associations.
2. **Renderer:** rquickjs loads the six scripts and matches **every** `porting/golden/*.json` byte-for-byte (`cargo test`). Benchmark it.
3. **Preview webview + protocol + page template + nonce CSP.** Images next to the doc load. Pass the security acceptance test (section 5).
4. **File watcher** with atomic-save handling, debounced, keeping scroll position.
5. **Mermaid:** inject the scripts, add the IPC shim, `ZQ.renderAll`, canvas mode, theme switching.
6. **Diagram cache** (with the OS in the key).
7. **Chrome UI:** TOC, find, zoom chip, menus/shortcuts, appearance, remote-images toggle, page zoom.
8. **Editor** (CodeMirror 6): debounced render, autosave, conflict banner, save errors.
9. **Visual editing:** port `MermaidSourceEditor` against `mermaid-editor.json`, inspector, undo/redo, CRLF fix.
10. **Print / PDF / reveal / default-app.**
11. **Packaging:** `.deb` + AppImage; `tauri icon icon.png`.

---

## 11. Golden fixtures

| File | Produced by | Use |
|---|---|---|
| `porting/golden/<sample>.input.md` | `node tools/make-golden.js` | Exact Markdown passed to `Renderooo.render` (Mermaid files already fence-wrapped, so the wrapper logic is tested too) |
| `porting/golden/<sample>.json` | same | Expected `{html, toc, hasMermaid}` |
| `porting/golden/mermaid-editor.json` | `tools/MakeEditorGolden.swift` | `details` (label/shape/fill read-back), `edits` (setLabel/setShape/setFill outputs), `isDark` cases; `source` names a key in `sources` |

Regenerate on the Mac after changing the JS or the Swift editor:
```sh
node tools/make-golden.js [extra files…]
swiftc -parse-as-library Renderooo/MermaidSourceEditor.swift tools/MakeEditorGolden.swift -o build/MakeEditorGolden && build/MakeEditorGolden
```
`make-golden.js` loads the scripts into a bare V8 context, the same way JSC sees them (no DOM). Fields with a nil value (`fill`, `shape`, `arg` for "Default" fill) are **left out** of the editor JSON, so deserialize them as `Option`.

---

## 12. Things to decide (not settled by the Mac version)

- **Which files the protocol may serve.** On macOS, `renderooo://local/<any absolute path>` serves any readable file, not just the doc's folder. That's harmless there because the page can't run script, and it's what makes `../images/x.png` work. Keep parity, or restrict to the doc's folder tree plus its parents up to the home directory.
- **Bundle identifier.** macOS uses `local.zquig.md` (left over from the old name). Pick the Tauri `identifier` now. Changing it later resets prefs and associations.
- **Session restore.** macOS reopens the last documents on launch. Optional on Linux.
- **Licenses:** ship `Renderooo/Resources/vendor/*LICENSE*` and `katex/LICENSE.txt` with the app (elkjs is EPL-2.0, the rest MIT/BSD-3).
