# Renderooo

**A fast, native macOS viewer for Markdown and Mermaid files.** Double-click a `.md` file in Finder and it opens instantly as a clean, GitHub-style page. Double-click a `.mmd` file and the diagram opens on an infinite canvas, where you can restyle boxes by clicking them.

No Electron, no account, no network. Everything it needs is inside the app.

- macOS 13 Ventura or later · Apple silicon and Intel (universal)
- About 13 MB · MIT licensed

---

## Download

1. Get **`Renderooo-<version>-macOS.zip`** from the [latest release](https://github.com/raisv3n/Renderooo/releases/latest).
2. Unzip it and drag **Renderooo.app** into **Applications**.
3. Open it once (see the note below).

> **First launch:** Renderooo isn't notarized by Apple (that needs a paid developer account), so macOS blocks it the first time.
> Try to open it, then go to **System Settings ▸ Privacy & Security**, scroll down and click **Open Anyway**.
> Or, in Terminal:
> ```sh
> xattr -dr com.apple.quarantine /Applications/Renderooo.app
> ```
> If you'd rather not run an unnotarized download, [build it yourself](#build-from-source). It takes about a minute.

### Make it your default Markdown app

Use **Renderooo ▸ Make Renderooo the Default for Markdown & Mermaid** (macOS asks you to confirm). Or in Finder: select a `.md` file ▸ **Get Info** (⌘I) ▸ *Open with:* **Renderooo** ▸ **Change All…**

---

## What it does

### Reading Markdown
- **GitHub-flavored Markdown:** tables, task lists, strikethrough, autolinks, alerts (`> [!NOTE]`, `[!TIP]`, `[!WARNING]` …), heading anchors, YAML front matter
- **Footnotes** (`text[^1]` … `[^1]: note`)
- **Math** with KaTeX: `$inline$`, `$$display$$`, `` $`inline`$ `` and ```` ```math ```` blocks. Prices like "$5 and $10" stay plain text.
- **Syntax-highlighted code** in about 37 common languages
- **Mermaid diagrams** in ```` ```mermaid ```` blocks, redrawn for light and dark mode
- **Table of contents** sidebar built from the headings (⌃⌘S)
- **Find** (⌘F, ⌘G / ⇧⌘G) with a match count
- **Auto-reload:** save the file in any editor and the preview updates in place, keeping your scroll position
- Images next to the document just work (`![](images/a.png)`)
- **Print** (⌘P) and **Export as PDF** (⇧⌘E), always in a clean light theme
- **Appearance:** View ▸ Appearance ▸ System / Light / Dark

### Editing (optional)
Documents open **read-only**. Press **⌘E** to open the source beside a live preview.
- Changes save automatically about a second after you stop typing (⌘S saves right away).
- Files are saved in place, so Finder tags and permissions survive.
- If another app changes the file while you have unsaved edits, a banner asks which version to keep. Nothing is overwritten silently.

### Mermaid files (`.mmd`, `.mermaid`)
- Open on an **infinite canvas** with a moving "+" grid. Pan with Space+drag, drag on empty space, two-finger scroll or middle-drag. Zoom with pinch or ⌘/⌥ + scroll.
- **Arrow highlighting:** hover an arrow to make it glow, and click to pin it. Click a box to light up every arrow in or out of it. Esc clears.
- **Visual editing:** click a box to open the inspector (double-click jumps straight to its text). Change its **text**, **shape** (rectangle, rounded, pill, diamond, circle, hexagon, subroutine, database, parallelogram, flag) or **fill colour**. Text colour flips between dark and white automatically. Each change is written back into the Mermaid source as plain text and saved. ⌘Z / ⇧⌘Z undo and redo.
- House style for every diagram: white boxes with crisp borders and soft shadows, monospace labels, right-angle arrows with rounded bends. Flowcharts use the ELK layout engine (as on mermaid.ai).
- Syntax errors show Mermaid's message above the source instead of a blank space.
- `.mmd` is also MultiMarkdown's extension. A `.mmd` file is drawn as a diagram only if it starts with a diagram keyword (`flowchart`, `sequenceDiagram`, …); otherwise it renders as Markdown.

Try the files in [`Samples/`](Samples/) to see everything above.

---

## Keyboard shortcuts

| Action | Shortcut |
|---|---|
| Edit Markdown / Stop Editing | ⌘E |
| Save (while editing) | ⌘S |
| Find / Next / Previous | ⌘F / ⌘G / ⇧⌘G |
| Table of contents | ⌃⌘S |
| Reload | ⌘R |
| Zoom in / out | ⌘= / ⌘− (also pinch) |
| Actual size (documents) · Zoom to fit (canvas) | ⌘0 |
| Zoom to 100% (canvas) | ⌘1 |
| Undo / Redo visual edits (canvas) | ⌘Z / ⇧⌘Z |
| New line in a box label | ⌥Return |
| Print / Export as PDF | ⌘P / ⇧⌘E |
| Reveal in Finder | ⇧⌘R |

---

## Privacy and security

Markdown files can contain raw HTML, so Renderooo treats every document as untrusted:

- **The preview runs no JavaScript from the document.** Page scripts are disabled and the Content-Security-Policy has no script source. A `<script>` tag, an `onerror=` attribute or a `javascript:` link in a file does nothing.
- Markdown is converted to HTML *outside* the preview, in a private JavaScriptCore context. Mermaid needs a real browser, so it runs in the app's own isolated script world that page content can't reach, with Mermaid's `strict` security level.
- **Remote images are off by default**, so opening a file doesn't tell its author when or where you read it. Turn them on with View ▸ Load Remote Images.
- **Links:** `http(s)` and `mailto` open in your default apps. Other schemes (`smb:`, `vnc:`, other apps' links) ask first. Links to local files reveal them in Finder and never launch them. Links to other Markdown files open in Renderooo.
- The preview can't fetch scripts, styles, fonts, frames or forms from the network, and can't navigate away on its own.
- Nothing is sent anywhere. The only thing Renderooo writes besides your own files is a diagram cache in `~/Library/Caches/Renderooo`.

The app isn't sandboxed, on purpose: a sandboxed viewer could only read the file you opened, so images next to it wouldn't load. Hardened Runtime is on.

Found a security problem? Please [open an issue](https://github.com/raisv3n/Renderooo/issues).

---

## Build from source

You need the Xcode Command Line Tools (`xcode-select --install`). Full Xcode is optional.

```sh
git clone https://github.com/raisv3n/Renderooo.git
cd Renderooo
./build.sh                       # → build/Renderooo.app for this Mac
./build.sh --universal           # Apple silicon + Intel
./build.sh --universal --install # also copies to /Applications and registers it
```

With Xcode 15 or later: open `Renderooo.xcodeproj`, pick the **Renderooo** scheme and press ⌘R. It signs ad hoc, so no developer team is needed.

### Publishing a release

Releases are built and published by GitHub Actions ([`.github/workflows/release.yml`](.github/workflows/release.yml)). Push a version tag:

```sh
git tag v1.0.1
git push origin v1.0.1
```

The workflow builds the universal app on a macOS runner, zips it as `Renderooo-1.0.1-macOS.zip`, and creates the release with its SHA-256. Release notes come from `.github/release-notes/v1.0.1.md` if you write one, otherwise from the commit messages since the last tag.

To make a zip locally instead:

```sh
./build.sh --universal
ditto -c -k --keepParent build/Renderooo.app Renderooo-1.0.0-macOS.zip
```

---

## How it works

```
.md file ─▶ MarkdownDocument (FileDocument, read-only)
            │
            ▼
   MarkdownRenderer ── JavaScriptCore (warm-started at launch)
            │            markdown-it + highlight.js + footnotes + KaTeX (texmath) + render.js
            ▼ HTML + headings (table of contents)
   PreviewController ─▶ WKWebView  (page JavaScript disabled, strict CSP)
            ▲             └─ renderooo:// scheme serves the page and files beside the .md
   FileWatcher ─ change ─▶ re-render ─▶ swap the article's HTML in place
```

Why it's fast:
- The document is rendered on a background thread **while macOS is still building the window**. A typical README takes about 10 ms, and a 10,000-line file about 120 ms.
- Mermaid (and the 5 MB ELK layout engine) are loaded only for documents that contain diagrams. Their script files are read from disk at launch, in the background.
- **Diagram cache:** finished diagrams are kept in `~/Library/Caches/Renderooo/diagrams` (at most 400). Reopening a document shows them immediately, without loading Mermaid or running a layout.

### Project layout

```
├── Renderooo.xcodeproj/           Xcode project (target "Renderooo", macOS 13+)
├── build.sh                       Build without Xcode (swiftc + Command Line Tools)
├── icon.png                       App icon artwork (build.sh turns it into AppIcon.icns)
├── Renderooo/
│   ├── RenderoooApp.swift         App entry, DocumentGroup(viewing:), appearance, warm-up
│   ├── PreviewScreen.swift        Window layout: TOC sidebar, editor/preview split, find bar, inspector
│   ├── PreviewController.swift    Per-window web view: reload, editing/saving, find, links, print, PDF
│   ├── MarkdownRenderer.swift     JavaScriptCore renderer + HTML page/CSP template
│   ├── MarkdownDocument.swift     Document type, text decoding, Mermaid-file detection
│   ├── MarkdownEditor.swift       Source editor (NSTextView)
│   ├── MermaidSourceEditor.swift  Rewrites one node (label, shape, fill) in Mermaid source
│   ├── LocalSchemeHandler.swift   renderooo:// → page + files next to the document
│   ├── FileWatcher.swift          File watcher that survives editors' atomic saves
│   ├── DiagramCache.swift         On-disk cache of finished diagram SVGs
│   ├── PreviewCommands.swift      Menus and shortcuts
│   ├── PreviewWebView.swift       Web view host + initial window size
│   ├── Info.plist                 Document types (Markdown, Mermaid)
│   └── Resources/                 style.css, render.js, mermaid-enhance.js, vendor/, katex/
├── Samples/                       Example Markdown and Mermaid files
├── tools/                         Icon maker + golden-fixture generators
├── porting/golden/                Expected renderer and editor outputs (for the Rust port)
└── PORTING.md                     Notes for a Linux port in Rust
```

---

## Troubleshooting

- **"Renderooo can't be opened" / "Apple could not verify…"**: see [First launch](#download).
- **Renderooo isn't listed under "Open with":** re-register it:
  ```sh
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Renderooo.app
  ```
- **Setting the default from Terminal** (with [`duti`](https://github.com/moretension/duti)):
  ```sh
  duti -s local.zquig.md net.daringfireball.markdown viewer
  duti -s local.zquig.md local.zquig.mermaid viewer
  ```
  The bundle identifier is `local.zquig.md`, left over from the app's earlier name.
- **Images from the web don't show:** turn on View ▸ Load Remote Images.
- **A diagram is laid out differently from mermaid.ai:** add `config: { layout: dagre }` front matter to the diagram to use Mermaid's classic layout instead of ELK.

---

## Roadmap

A Linux version written in Rust is in progress. [PORTING.md](PORTING.md) has the architecture notes, and [`porting/golden/`](porting/golden/) holds test fixtures generated from this app.

## License

Renderooo is released under the [MIT License](LICENSE).

Bundled third-party code keeps its own license (included in the app and in `Renderooo/Resources`): markdown-it, markdown-it-footnote, markdown-it-texmath, KaTeX, Mermaid and @mermaid-js/layout-elk (MIT), highlight.js (BSD-3-Clause) and elkjs (Eclipse Public License 2.0).
