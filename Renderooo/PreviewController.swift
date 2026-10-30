import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// One per window: owns the web view, watches the file, re-renders, edits, finds, prints and exports.
@MainActor
final class PreviewController: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: WKWebView

    @Published private(set) var toc: [TOCItem] = []
    /// A standalone Mermaid file: shown on an infinite pan/zoom canvas.
    @Published private(set) var isCanvas = false
    @Published private(set) var canvasZoom: Double = 1

    // Visual editing of the selected node (standalone diagram files).
    @Published private(set) var selectedNode: NodeDetails?
    @Published var labelDraft = "" {
        didSet { if !settingDraft { scheduleLabelEdit() } }
    }
    @Published private(set) var focusLabelToken = 0
    private var settingDraft = false
    private var labelEditWorkItem: DispatchWorkItem?
    private var fillEditWorkItem: DispatchWorkItem?
    private var visualUndo: [String] = []
    private var visualRedo: [String] = []
    @Published var sidebarVisibility: NavigationSplitViewVisibility =
        UserDefaults.standard.bool(forKey: Preferences.showTOCKey) ? .all : .detailOnly {
        didSet {
            // New windows open the way the last one was left.
            UserDefaults.standard.set(sidebarVisibility != .detailOnly, forKey: Preferences.showTOCKey)
        }
    }

    // Editing (opt-in; the window is a read-only viewer until the user asks to edit).
    @Published private(set) var isEditing = false
    @Published private(set) var hasUnsavedChanges = false
    @Published private(set) var saveError: String?
    @Published private(set) var diskChangedWhileEditing = false
    @Published var editorFraction: CGFloat = 0.5
    weak var editorTextView: NSTextView?

    // Find in preview.
    @Published var isFindBarVisible = false
    @Published var findQuery = ""
    @Published private(set) var findStatus = ""
    @Published private(set) var findFocusToken = 0

    private let schemeHandler: LocalSchemeHandler
    private(set) var fileURL: URL?
    private(set) var sourceText = ""
    private var diskText = "" // what we last read from or wrote to disk
    private var watcher: FileWatcher?
    private var pageLoaded = false
    private var pendingScrollY: Double?
    private var renderGeneration = 0
    private var lastBody = ""
    /// One in-memory data store for all windows, so later windows reuse its processes.
    static let sharedDataStore = WKWebsiteDataStore.nonPersistent()
    /// A page load is underway; content that is ready before it finishes waits here.
    private var loadInFlight = false
    private var pendingContent: String?
    private var preloadDiagramsOnLoad = false
    private var pageGeneration = 0
    private var mermaidLoading: Task<Bool, Never>?
    /// The current page shows diagrams from `DiagramCache` (Mermaid itself is loaded on demand).
    private var usingCachedDiagrams = false
    private var hasMermaid = false
    private var mermaidLoadedInPage = false
    private var elkLoadedInPage = false
    private var restoreMermaidAfterPrint = false
    private var reloadWorkItem: DispatchWorkItem?
    private var renderWorkItem: DispatchWorkItem?
    private var autosaveWorkItem: DispatchWorkItem?
    private var observations: [NSKeyValueObservation] = []

    override init() {
        let handler = LocalSchemeHandler()
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: LocalSchemeHandler.scheme)
        // The page is static HTML: Markdown is rendered beforehand in JavaScriptCore.
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = Self.sharedDataStore
        config.suppressesIncrementalRendering = true
        let messages = WeakScriptMessageHandler()
        config.userContentController.add(messages, contentWorld: .defaultClient, name: MermaidSupport.messageHandlerName)

        schemeHandler = handler
        webView = PreviewWKWebView(frame: .zero, configuration: config)
        super.init()
        messages.target = self

        webView.navigationDelegate = self
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground") // no white flash in Dark Mode
        webView.pageZoom = UserDefaults.standard.pageZoom

        let defaults = UserDefaults.standard
        observations = [
            defaults.observe(\.loadRemoteImages, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.reloadPage() }
            },
            defaults.observe(\.pageZoom, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.applyZoomMode() }
            },
            // Light/Dark switch (system or View ▸ Appearance): CSS follows by itself, diagrams need a redraw.
            NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in
                    guard let self, self.hasMermaid, self.pageLoaded else { return }
                    await self.renderMermaid()
                }
            },
        ]
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationWillTerminate(_:)),
            name: NSApplication.willTerminateNotification, object: nil
        )
    }

    @objc private func applicationWillTerminate(_ notification: Notification) {
        commitPendingEdits()
        saveIfNeeded(synchronously: true)
    }

    // MARK: - Content

    func show(text: String, fileURL: URL?) {
        let previousURL = self.fileURL
        guard fileURL != previousURL || !pageLoaded else { return }
        self.fileURL = fileURL

        if fileURL != previousURL {
            watcher = fileURL.map { url in
                FileWatcher(url: url) { [weak self] in self?.scheduleReloadFromDisk() }
            }
        }
        if previousURL != nil, fileURL != nil, !hasUnsavedChanges {
            // Document was moved/renamed: base URL for relative images changed, and the
            // on-disk text may be newer than the snapshot SwiftUI handed us.
            reloadFromDisk(force: true, fullPage: true)
        } else if previousURL == nil {
            sourceText = text
            diskText = text
            // Start the web view's process now with an empty page, in parallel with rendering
            // (and, for diagrams, start loading Mermaid as soon as that page is up).
            let isDiagram = MermaidFile.renderableMarkdown(text, fileURL: fileURL).isDiagram
            if isDiagram != isCanvas {
                isCanvas = isDiagram
                applyZoomMode()
            }
            let source = MermaidFile.renderableMarkdown(text, fileURL: fileURL).markdown
            if let ready = MarkdownRenderer.shared.readyResult(for: source) {
                // Usually the case: the document was rendered while its window was being built.
                renderGeneration += 1
                toc = ready.toc
                hasMermaid = ready.hasMermaid
                loadPage(body: ready.html)
            } else {
                loadShell(preloadDiagrams: MermaidSupport.mightHaveDiagrams(text, fileURL: fileURL))
                render(fullPage: false)
            }
        } else {
            render(fullPage: true)
        }
    }

    /// ⌘R: re-read the file and re-render, keeping the scroll position.
    func reload() {
        if hasUnsavedChanges {
            render(fullPage: false)
        } else {
            reloadFromDisk(force: true, fullPage: false)
        }
    }

    private func scheduleReloadFromDisk() {
        reloadWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.reloadFromDisk(force: false, fullPage: false)
        }
        reloadWorkItem = item
        // Coalesce the burst of events editors produce for a single save.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.075, execute: item)
    }

    private func reloadFromDisk(force: Bool, fullPage: Bool) {
        guard let url = fileURL else { return }
        Task {
            guard let newText = await Self.readText(at: url) else { return }
            guard force || newText != self.diskText else { return } // includes our own saves
            self.diskText = newText
            if self.hasUnsavedChanges {
                // Never silently throw away typing; let the user choose.
                self.diskChangedWhileEditing = true
                return
            }
            self.setSourceText(newText)
            self.render(fullPage: fullPage)
        }
    }

    private static func readText(at url: URL) async -> String? {
        let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
        return data.map(MarkdownDocument.decode)
    }

    /// Updates the model and, when editing, the editor, keeping the caret where it was.
    private func setSourceText(_ text: String) {
        // Text came from disk (another app): earlier visual edits no longer apply to it.
        visualUndo.removeAll()
        visualRedo.removeAll()
        sourceText = text
        hasUnsavedChanges = false
        if let editor = editorTextView, editor.string != text {
            let selection = editor.selectedRange()
            editor.string = text
            let length = (text as NSString).length
            editor.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        }
    }

    private func render(fullPage: Bool) {
        renderGeneration += 1
        let generation = renderGeneration
        let (source, isDiagram) = MermaidFile.renderableMarkdown(sourceText, fileURL: fileURL)
        Task {
            let result = await MarkdownRenderer.shared.render(source)
            guard generation == self.renderGeneration else { return } // a newer render superseded us
            if self.toc != result.toc { self.toc = result.toc }
            self.hasMermaid = result.hasMermaid
            // Switching between document and canvas layout needs a fresh page.
            let modeChanged = isDiagram != self.isCanvas
            if modeChanged {
                self.isCanvas = isDiagram
                self.applyZoomMode()
            }
            if fullPage || modeChanged {
                self.loadPage(body: result.html)
            } else if !self.pageLoaded {
                if self.loadInFlight {
                    // The shell page is still loading: it picks this up when it finishes.
                    self.pendingContent = result.html
                    self.lastBody = result.html
                    self.schemeHandler.pageHTML = self.makePage(body: result.html)
                } else {
                    self.loadPage(body: result.html)
                }
            } else {
                if result.hasMermaid {
                    await self.updateWithDiagrams(result.html)
                } else {
                    await self.replaceContent(with: result.html)
                }
                if self.isFindBarVisible { await self.updateFindCount() }
            }
        }
    }

    private func makePage(body: String) -> Data {
        Data(HTMLPage.make(
            body: body,
            title: fileURL?.lastPathComponent ?? "Markdown",
            allowRemoteImages: UserDefaults.standard.loadRemoteImages,
            canvas: isCanvas
        ).utf8)
    }

    /// Documents use page zoom and pinch-magnification; the canvas zooms itself.
    private func applyZoomMode() {
        webView.allowsMagnification = !isCanvas
        webView.pageZoom = isCanvas ? 1 : UserDefaults.standard.pageZoom
        if isCanvas { webView.magnification = 1 }
    }

    /// View-menu zoom commands on the canvas: "in", "out", "fit", "actual".
    func canvasCommand(_ name: String) {
        guard isCanvas else { return }
        Task {
            _ = try? await webView.callAsyncJavaScript(
                "if (window.ZQ) ZQ.command(name); return true;", arguments: ["name": name], in: nil, contentWorld: .defaultClient
            )
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if let zoom = body["zoom"] as? Double {
            canvasZoom = zoom
        }
        if body.keys.contains("selected") {
            nodeSelected(body["selected"] as? String)
        }
        if let svg = body["cacheSVG"] as? String, let source = body["source"] as? String {
            DiagramCache.write(.init(svg: svg, layout: body["layout"] as? String ?? "dagre"), source: source,
                               dark: body["dark"] as? Bool ?? false, canvas: body["canvas"] as? Bool ?? false)
        }
        if let id = body["editText"] as? String {
            nodeSelected(id)
            focusLabelToken += 1
        }
    }

    private func loadPage(body: String) {
        lastBody = body
        // Previously drawn diagrams come straight from the cache: no engine load, no layout pass.
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let cachedBody = hasMermaid ? DiagramCache.bodyWithCachedDiagrams(body, dark: dark, canvas: isCanvas) : nil
        usingCachedDiagrams = cachedBody != nil
        let page = makePage(body: cachedBody ?? body)
        schemeHandler.pageHTML = page
        let html = String(decoding: page, as: UTF8.self)
        let directory = fileURL?.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory
        pageLoaded = false
        loadInFlight = true
        pendingContent = nil
        pageGeneration += 1
        mermaidLoadedInPage = false
        elkLoadedInPage = false
        mermaidLoading = nil
        configureDiagramScripts()
        // Hand WebKit the page directly; the base URL keeps relative images and anchors working.
        webView.loadHTMLString(html, baseURL: LocalSchemeHandler.pageURL(forDirectory: directory))
    }

    /// Which diagram engines WebKit injects into the next page (at document start).
    private var injectedScripts: (enhance: Bool, mermaid: Bool, elk: Bool) = (false, false, false)

    private func configureDiagramScripts() {
        let diagrams = MermaidSupport.mightHaveDiagrams(sourceText, fileURL: fileURL)
        // Cached diagrams only need the small interaction layer; Mermaid loads if an edit needs it.
        let wantMermaid = diagrams && !usingCachedDiagrams
        let wantELK = wantMermaid && MermaidSupport.needsELK(sourceText)
        let wantEnhance = diagrams && usingCachedDiagrams
        guard (wantEnhance, wantMermaid, wantELK) != injectedScripts else { return }
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        if wantEnhance, let script = MermaidSupport.enhanceUserScript { controller.addUserScript(script) }
        if wantMermaid, let script = MermaidSupport.mermaidUserScript {
            controller.addUserScript(script)
            if wantELK, let elk = MermaidSupport.elkUserScript { controller.addUserScript(elk) }
        }
        injectedScripts = (wantEnhance, wantMermaid, wantELK)
    }

    /// Math can appear in a live edit of a page that had none: add KaTeX's styles then.
    private static let addKatexCSSIfNeeded = """
        if (katexCSS && !document.getElementById('katex-css')) {
            const style = document.createElement('style');
            style.id = 'katex-css';
            style.textContent = katexCSS;
            document.head.appendChild(style);
        }

        """

    /// Empty page in the document's folder (so relative images resolve once content arrives).
    private func loadShell(preloadDiagrams: Bool) {
        loadPage(body: "")
        preloadDiagramsOnLoad = preloadDiagrams
    }

    /// Swaps the article's HTML without a navigation, so auto-reload keeps the scroll position.
    private func replaceContent(with body: String) async {
        lastBody = body
        schemeHandler.pageHTML = makePage(body: body)
        do {
            _ = try await webView.callAsyncJavaScript(
                Self.addKatexCSSIfNeeded + "document.getElementById('renderooo-content').innerHTML = html; return true;",
                arguments: ["html": body, "katexCSS": HTMLPage.needsMath(body) ? HTMLPage.katexStylesheet : ""],
                in: nil,
                contentWorld: .defaultClient
            )
        } catch {
            loadPage(body: body)
        }
    }

    /// Full reload (e.g. remote-image setting changed) that restores the scroll position.
    private func reloadPage() {
        guard pageLoaded else { return }
        Task {
            pendingScrollY = try? await webView.callAsyncJavaScript(
                "return window.scrollY;", arguments: [:], in: nil, contentWorld: .defaultClient
            ) as? Double
            loadPage(body: lastBody)
        }
    }

    /// Loads Mermaid (and ELK when there are flowcharts) into the page's app script world once.
    @discardableResult
    private func ensureMermaidLoaded() async -> Bool {
        // A preload may already be underway: wait for it rather than loading the scripts twice.
        if let running = mermaidLoading { _ = await running.value }
        let task = Task { await self.loadMermaidScripts() }
        mermaidLoading = task
        let ok = await task.value
        if mermaidLoading == task { mermaidLoading = nil }
        return ok
    }

    private func loadMermaidScripts() async -> Bool {
        let generation = pageGeneration
        if !mermaidLoadedInPage {
            guard let scripts = MermaidSupport.scripts else { return false }
            await evaluateInAppWorld(scripts)
            guard generation == pageGeneration else { return false } // page was replaced meanwhile
            mermaidLoadedInPage = true
        }
        if !elkLoadedInPage, MermaidSupport.needsELK(sourceText), let elk = MermaidSupport.elkScript {
            await evaluateInAppWorld(elk)
            guard generation == pageGeneration else { return false }
            elkLoadedInPage = true
        }
        return true
    }

    /// In-place update for documents with diagrams: drawn off-screen, then swapped in.
    private func updateWithDiagrams(_ body: String) async {
        lastBody = body
        schemeHandler.pageHTML = makePage(body: body)
        guard await ensureMermaidLoaded() else { return }
        do {
            _ = try await webView.callAsyncJavaScript(
                Self.addKatexCSSIfNeeded + "return await ZQ.update(html, false, canvas);",
                arguments: ["html": body, "canvas": isCanvas, "katexCSS": HTMLPage.needsMath(body) ? HTMLPage.katexStylesheet : ""],
                in: nil, contentWorld: .defaultClient
            )
        } catch {
            await replaceContent(with: body)
            await renderMermaid()
        }
    }

    private func renderMermaid(forceLight: Bool = false) async {
        guard await ensureMermaidLoaded() else { return }
        _ = try? await webView.callAsyncJavaScript(
            MermaidSupport.runScript, arguments: ["forceLight": forceLight, "canvas": isCanvas],
            in: nil, contentWorld: .defaultClient
        )
    }

    private func evaluateInAppWorld(_ source: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            webView.evaluateJavaScript(source, in: nil, in: .defaultClient) { _ in continuation.resume() }
        }
    }

    // MARK: - Editing

    func toggleEditing() {
        if isEditing {
            saveIfNeeded(overwritingDiskChanges: true)
            isEditing = false
            editorTextView = nil
            webView.window?.makeFirstResponder(webView)
        } else {
            widenWindowForEditing()
            isEditing = true
        }
    }

    /// Side-by-side editing needs room: grow narrow windows (to the right, staying on screen).
    private func widenWindowForEditing() {
        guard let window = webView.window, let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let target = min(1400, visible.width)
        guard window.frame.width < target - 40 else { return }
        var frame = window.frame
        frame.size.width = target
        frame.origin.x = min(frame.minX, visible.maxX - target)
        window.setFrame(frame, display: true, animate: true)
    }

    /// Called by the editor on every keystroke.
    func editorDidChange(_ text: String) {
        sourceText = text
        hasUnsavedChanges = text != diskText

        renderWorkItem?.cancel()
        let render = DispatchWorkItem { [weak self] in self?.render(fullPage: false) }
        renderWorkItem = render
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: render)

        autosaveWorkItem?.cancel()
        let save = DispatchWorkItem { [weak self] in self?.saveIfNeeded() }
        autosaveWorkItem = save
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: save)
    }

    /// ⌘S: save now, even if the file changed on disk meanwhile.
    func save() {
        saveIfNeeded(overwritingDiskChanges: true)
    }

    func saveIfNeeded(overwritingDiskChanges: Bool = false, synchronously: Bool = false) {
        autosaveWorkItem?.cancel()
        guard hasUnsavedChanges, let url = fileURL else { return }
        // Autosave never clobbers a version someone else wrote; the banner asks first.
        guard overwritingDiskChanges || !diskChangedWhileEditing else { return }

        let text = sourceText
        // Mark it saved before writing, so the file watcher sees our own write as nothing new.
        diskText = text
        hasUnsavedChanges = false
        diskChangedWhileEditing = false
        saveError = nil

        if synchronously {
            // App is quitting: no time for a background write, and nothing left to coordinate with.
            do { try Data(text.utf8).write(to: url) } catch { saveError = error.localizedDescription }
            return
        }
        // Coordinated, in-place write (keeps the file's inode, permissions, tags and xattrs), on a
        // background queue: the window's document answers the coordinator on the main thread, so
        // coordinating from the main thread deadlocks.
        Self.saveQueue.async { [weak self] in
            var writeError: Error?
            var coordinationError: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &coordinationError) { target in
                do { try Data(text.utf8).write(to: target) } catch { writeError = error }
            }
            guard let failure = writeError ?? coordinationError else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.saveError = failure.localizedDescription
                if self.sourceText == text { self.hasUnsavedChanges = true }
            }
        }
    }

    /// Saves run one at a time, in order.
    private static let saveQueue = DispatchQueue(label: "Renderooo.save", qos: .userInitiated)

    /// Quitting: let a save started by closing the last window finish before the process exits.
    /// Bounded, so a stuck file coordinator can't hang the quit.
    static func waitForPendingSaves(timeout: TimeInterval = 2) {
        let done = DispatchSemaphore(value: 0)
        saveQueue.async { done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }

    /// Conflict banner: discard local edits and take the version on disk.
    func useDiskVersion() {
        diskChangedWhileEditing = false
        setSourceText(diskText)
        render(fullPage: false)
    }

    /// Conflict banner: keep local edits and write them over the disk version.
    func keepMyEdits() {
        saveIfNeeded(overwritingDiskChanges: true)
    }

    // MARK: - Visual editing

    /// Visual edits are offered for standalone diagram files (the whole file is the diagram).
    var canEditVisually: Bool { isCanvas && fileURL != nil }

    private func nodeSelected(_ id: String?) {
        guard canEditVisually, let id, !id.isEmpty else {
            commitPendingEdits()
            selectedNode = nil
            return
        }
        if selectedNode?.id != id { commitPendingEdits() }
        if !mermaidLoadedInPage { Task { await ensureMermaidLoaded() } }
        let details = MermaidSourceEditor.details(of: id, in: sourceText)
        let sameNode = selectedNode?.id == id
        selectedNode = details
        if !sameNode || labelEditWorkItem == nil { setDraft(details.label) }
    }

    private func setDraft(_ text: String) {
        settingDraft = true
        labelDraft = text
        settingDraft = false
    }

    func deselectNode() {
        commitPendingEdits()
        selectedNode = nil
        Task {
            _ = try? await webView.callAsyncJavaScript(
                "document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' })); window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' })); return true;",
                arguments: [:], in: nil, contentWorld: .defaultClient
            )
        }
    }

    private func scheduleLabelEdit() {
        guard selectedNode != nil else { return }
        labelEditWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.applyLabelDraft() }
        labelEditWorkItem = item
        // Re-layout is not free on big diagrams: apply once typing pauses.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: item)
    }

    func applyLabelDraft() {
        labelEditWorkItem?.cancel()
        labelEditWorkItem = nil
        guard let node = selectedNode, labelDraft != node.label else { return }
        let draft = labelDraft
        applyVisualEdit { MermaidSourceEditor.setLabel(draft, of: node.id, in: $0) }
    }

    func setShape(_ shape: NodeShape) {
        guard let node = selectedNode, node.shape != shape else { return }
        applyLabelDraft()
        applyVisualEdit { MermaidSourceEditor.setShape(shape, of: node.id, in: $0) }
    }

    /// `hex` nil restores the default fill. `live` (colour wheel dragging) waits for a pause.
    func setFill(_ hex: String?, live: Bool = false) {
        guard let node = selectedNode else { return }
        fillEditWorkItem?.cancel()
        let apply = { [weak self] in
            guard let self, self.selectedNode?.fill?.lowercased() != hex?.lowercased() else { return }
            self.applyVisualEdit { MermaidSourceEditor.setFill(hex, of: node.id, in: $0) }
        }
        if live {
            let item = DispatchWorkItem(block: apply)
            fillEditWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
        } else {
            apply()
        }
    }

    private func commitPendingEdits() {
        if labelEditWorkItem != nil { applyLabelDraft() }
        fillEditWorkItem?.perform()
        fillEditWorkItem = nil
    }

    private func applyVisualEdit(_ transform: (String) -> String) {
        let before = sourceText
        let after = transform(before)
        guard after != before else { return }
        visualUndo.append(before)
        if visualUndo.count > 200 { visualUndo.removeFirst() }
        visualRedo.removeAll()
        commitSource(after)
    }

    var canUndoVisualEdit: Bool { !visualUndo.isEmpty }
    var canRedoVisualEdit: Bool { !visualRedo.isEmpty }

    func undoVisualEdit() {
        labelEditWorkItem?.cancel()
        labelEditWorkItem = nil
        guard let previous = visualUndo.popLast() else { return }
        visualRedo.append(sourceText)
        commitSource(previous)
    }

    func redoVisualEdit() {
        guard let next = visualRedo.popLast() else { return }
        visualUndo.append(sourceText)
        commitSource(next)
    }

    /// Writes a visual edit through: editor pane, file on disk, re-render, inspector.
    private func commitSource(_ text: String) {
        sourceText = text
        if let editor = editorTextView, editor.string != text {
            let selection = editor.selectedRange()
            editor.string = text
            editor.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        }
        hasUnsavedChanges = text != diskText
        saveIfNeeded(overwritingDiskChanges: true)
        render(fullPage: false)
        if let id = selectedNode?.id {
            let details = MermaidSourceEditor.details(of: id, in: text)
            selectedNode = details
            if labelEditWorkItem == nil { setDraft(details.label) }
        }
    }

    // MARK: - Find

    /// Routes ⌘F / ⌘G: the editor's own find bar when it has focus, otherwise the preview's.
    func handleFind(_ action: NSTextFinder.Action) {
        if let editor = editorTextView, editor.window?.firstResponder === editor {
            let sender = NSMenuItem()
            sender.tag = action.rawValue
            editor.performTextFinderAction(sender)
            return
        }
        switch action {
        case .nextMatch where !findQuery.isEmpty: findNext()
        case .previousMatch where !findQuery.isEmpty: findPrevious()
        default: showFindBar()
        }
    }

    func showFindBar() {
        isFindBarVisible = true
        findFocusToken += 1
        if !findQuery.isEmpty { Task { await updateFindCount() } }
    }

    func hideFindBar() {
        isFindBarVisible = false
        findStatus = ""
        webView.window?.makeFirstResponder(webView)
    }

    func findQueryChanged() {
        Task {
            // Start each new query from the top of the document.
            _ = try? await webView.callAsyncJavaScript(
                "window.getSelection().removeAllRanges(); return true;", arguments: [:], in: nil, contentWorld: .defaultClient
            )
            await find(backwards: false)
        }
    }

    func findNext() { Task { await find(backwards: false) } }
    func findPrevious() { Task { await find(backwards: true) } }

    private func find(backwards: Bool) async {
        guard !findQuery.isEmpty else {
            findStatus = ""
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        let result = try? await webView.find(findQuery, configuration: configuration)
        if result?.matchFound == true {
            await updateFindCount()
        } else {
            findStatus = "Not found"
        }
    }

    private func updateFindCount() async {
        guard !findQuery.isEmpty else {
            findStatus = ""
            return
        }
        let count = try? await webView.callAsyncJavaScript(
            """
            const text = document.getElementById('renderooo-content').innerText.toLowerCase();
            const q = query.toLowerCase();
            let n = 0, i = 0;
            while ((i = text.indexOf(q, i)) !== -1) { n++; i += q.length; }
            return n;
            """,
            arguments: ["query": findQuery], in: nil, contentWorld: .defaultClient
        ) as? Int
        switch count ?? 0 {
        case 0: findStatus = "Not found"
        case 1: findStatus = "1 match"
        case let n: findStatus = "\(n) matches"
        }
    }

    // MARK: - Navigation

    func scrollTo(id: String) {
        Task {
            _ = try? await webView.callAsyncJavaScript(
                "const el = document.getElementById(id); if (el) el.scrollIntoView({ block: 'start' }); return true;",
                arguments: ["id": id], in: nil, contentWorld: .defaultClient
            )
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        loadInFlight = false
        // Engines injected at document start are already loaded in this page.
        if injectedScripts.mermaid, MermaidSupport.mermaidUserScript != nil { mermaidLoadedInPage = true }
        if injectedScripts.elk, MermaidSupport.elkUserScript != nil { elkLoadedInPage = true }
        let scrollY = pendingScrollY
        pendingScrollY = nil
        let pending = pendingContent
        pendingContent = nil
        let preload = preloadDiagramsOnLoad
        preloadDiagramsOnLoad = false
        Task {
            if let pending {
                // Content was rendered while the page loaded: put it in place.
                if hasMermaid {
                    await updateWithDiagrams(pending)
                } else {
                    await replaceContent(with: pending)
                }
            } else if preload {
                // Content is still rendering: use the time to load Mermaid (and ELK).
                await ensureMermaidLoaded()
            } else if usingCachedDiagrams {
                _ = try? await webView.callAsyncJavaScript(
                    "return window.ZQ ? ZQ.adopt(canvas) : 0;", arguments: ["canvas": isCanvas], in: nil, contentWorld: .defaultClient
                )
            } else if hasMermaid {
                await renderMermaid()
            }
            if let scrollY {
                _ = try? await webView.callAsyncJavaScript(
                    "window.scrollTo(0, y); return true;", arguments: ["y": scrollY], in: nil, contentWorld: .defaultClient
                )
            }
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadPage(body: lastBody)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }

        guard navigationAction.navigationType == .linkActivated else {
            // Only our own page may load; block meta-refresh redirects (also to other local files) and the like.
            return LocalSchemeHandler.isPage(url) || url.scheme == "about" ? .allow : .cancel
        }

        switch url.scheme?.lowercased() {
        case LocalSchemeHandler.scheme:
            if LocalSchemeHandler.isPage(url) { return .allow } // in-page "#anchor"
            if let target = LocalSchemeHandler.fileURL(for: url) { openLocal(target, fragment: url.fragment) }
        case "file":
            openLocal(url.standardizedFileURL, fragment: url.fragment)
        case "http", "https", "mailto":
            NSWorkspace.shared.open(url) // default browser / mail app
        default:
            confirmOpenExternal(url) // smb:, vnc:, other apps' schemes: ask first
        }
        return .cancel
    }

    private func confirmOpenExternal(_ url: URL) {
        guard let window = webView.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Open this link in another app?"
        alert.informativeText = url.absoluteString
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open")
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn { NSWorkspace.shared.open(url) }
        }
    }

    private func openLocal(_ target: URL, fragment: String?) {
        if target == fileURL?.standardizedFileURL {
            if let fragment { scrollTo(id: fragment.removingPercentEncoding ?? fragment) }
            return
        }
        let isMarkdown = ["md", "markdown"].contains(target.pathExtension.lowercased())
            || MermaidFile.isMermaidFile(target)
            || (UTType(filenameExtension: target.pathExtension)?.conforms(to: .markdown) ?? false)
        if isMarkdown, FileManager.default.fileExists(atPath: target.path) {
            NSDocumentController.shared.openDocument(withContentsOf: target, display: true) { _, _, _ in }
        } else if FileManager.default.fileExists(atPath: target.path) {
            // Never launch arbitrary local files from a link; show them instead.
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } else {
            NSSound.beep()
        }
    }

    // MARK: - Print / Export

    func printDocument() {
        runPrintOperation(savingTo: nil)
    }

    func exportPDF() {
        guard let window = webView.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? "Document") + ".pdf"
        if let directory = fileURL?.deletingLastPathComponent() {
            panel.directoryURL = directory
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            // Let the save sheet finish closing before the print operation attaches its own.
            Task { @MainActor in self?.runPrintOperation(savingTo: url) }
        }
    }

    private func runPrintOperation(savingTo pdfURL: URL?) {
        guard let window = webView.window else { return }
        Task {
            // Paper is always light (see @media print); redraw diagrams in the light theme too.
            let isDark = webView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if hasMermaid, isDark {
                await renderMermaid(forceLight: true)
                restoreMermaidAfterPrint = true
            }

            let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
            info.horizontalPagination = .fit
            info.verticalPagination = .automatic
            info.isHorizontallyCentered = false
            info.isVerticallyCentered = false
            info.topMargin = 42
            info.bottomMargin = 42
            info.leftMargin = 42
            info.rightMargin = 42
            if let pdfURL {
                info.jobDisposition = .save
                info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL.rawValue] = pdfURL
            }

            let operation = webView.printOperation(with: info)
            operation.jobTitle = fileURL?.deletingPathExtension().lastPathComponent ?? "Markdown"
            operation.showsPrintPanel = pdfURL == nil
            operation.showsProgressPanel = true
            operation.view?.frame = webView.bounds // WKWebView prints blank pages without a frame
            operation.runModal(
                for: window, delegate: self,
                didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil
            )
        }
    }

    @objc private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard restoreMermaidAfterPrint else { return }
        restoreMermaidAfterPrint = false
        Task { await renderMermaid() }
    }

    func revealInFinder() {
        guard let fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}

/// WKUserContentController retains its handlers; this keeps it from retaining the controller.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
