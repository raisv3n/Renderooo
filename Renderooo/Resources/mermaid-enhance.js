// Renderooo diagram layer. Runs in the app's isolated script world (never as page JavaScript),
// after mermaid.min.js. Draws every Mermaid block with the house style, adds arrow/node
// highlighting, and — for standalone .mmd/.mermaid files — an infinite pan/zoom canvas.
(function () {
  "use strict";
  // Page elements with id/name "ZQ" also appear as window.ZQ in this world: check for our own object.
  if (window.ZQ && typeof window.ZQ.renderAll === "function") return;

  // ---------------------------------------------------------------- style

  var MONO = 'ui-monospace, "SF Mono", SFMono-Regular, Menlo, monospace';

  function mermaidConfig(dark, canvas) {
    var v = dark ? {
      darkMode: true, background: "#0d1117",
      primaryColor: "#161b22", primaryBorderColor: "#c9d1d9", primaryTextColor: "#e6edf3",
      secondaryColor: "#1c2330", tertiaryColor: "#161b22",
      lineColor: "#c9d1d9", textColor: "#e6edf3", mainBkg: "#161b22", nodeBorder: "#c9d1d9",
      edgeLabelBackground: "#30363d", clusterBkg: "#11161d", clusterBorder: "#3d444d", titleColor: "#e6edf3",
      noteBkgColor: "#2b2414", noteBorderColor: "#9e7a2e", noteTextColor: "#e6edf3",
      actorBkg: "#161b22", actorBorder: "#c9d1d9", actorTextColor: "#e6edf3", signalColor: "#c9d1d9", signalTextColor: "#e6edf3"
    } : {
      darkMode: false, background: "#ffffff",
      primaryColor: "#ffffff", primaryBorderColor: "#1f2328", primaryTextColor: "#1f2328",
      secondaryColor: "#eef6f2", tertiaryColor: "#ffffff",
      lineColor: "#1f2328", textColor: "#1f2328", mainBkg: "#ffffff", nodeBorder: "#1f2328",
      edgeLabelBackground: "#dfe2e6", clusterBkg: "#f6f8fa", clusterBorder: "#d0d7de", titleColor: "#1f2328",
      noteBkgColor: "#fff8c5", noteBorderColor: "#d4a72c", noteTextColor: "#1f2328",
      actorBkg: "#ffffff", actorBorder: "#1f2328", actorTextColor: "#1f2328", signalColor: "#1f2328", signalTextColor: "#1f2328"
    };
    v.fontFamily = MONO;
    v.fontSize = "13px";
    var fit = !canvas; // on the canvas diagrams keep their natural size; we zoom instead
    var elk = registerELK();
    return {
      startOnLoad: false,
      // ELK: layered layout with orthogonal routing, like mermaid.ai. Per-diagram front matter
      // (config: layout: dagre) still overrides this.
      layout: elk ? "elk" : "dagre",
      elk: { mergeEdges: false, nodePlacementStrategy: "BRANDES_KOEPF", cycleBreakingStrategy: "GREEDY_MODEL_ORDER", forceNodeModelOrder: false, considerModelOrder: "NODES_AND_EDGES" },
      securityLevel: "strict",
      theme: "base",
      themeVariables: v,
      fontFamily: MONO,
      flowchart: { curve: elk ? "linear" : "step", padding: 14, nodeSpacing: 46, rankSpacing: 56, htmlLabels: true, useMaxWidth: fit },
      sequence: { useMaxWidth: fit, mirrorActors: false },
      class: { useMaxWidth: fit }, state: { useMaxWidth: fit }, er: { useMaxWidth: fit },
      gantt: { useMaxWidth: fit }, journey: { useMaxWidth: fit }, pie: { useMaxWidth: fit },
      mindmap: { useMaxWidth: fit }, timeline: { useMaxWidth: fit }, gitGraph: { useMaxWidth: fit },
      quadrantChart: { useMaxWidth: fit }, xyChart: { useMaxWidth: fit }, requirement: { useMaxWidth: fit }
    };
  }

  /** Points of a plain "M x,y L x,y …" polyline, or null for anything curvier. */
  function polylinePoints(d) {
    if (!d || /[^MLml0-9.,\s-]/.test(d.replace(/e-?\d+/g, ""))) return null;
    var nums = d.match(/-?\d*\.?\d+(?:e-?\d+)?/g);
    if (!nums || nums.length < 4) return null;
    var pts = [];
    for (var i = 0; i + 1 < nums.length; i += 2) {
      var p = [parseFloat(nums[i]), parseFloat(nums[i + 1])];
      var last = pts[pts.length - 1];
      if (!last || Math.abs(last[0] - p[0]) > 0.01 || Math.abs(last[1] - p[1]) > 0.01) pts.push(p);
    }
    return pts;
  }

  /**
   * Dagre ends converging arrows on a box's top/bottom corner. Rebuild the last stretch so the
   * arrow enters the side of the box that faces the flow (left for LR, top for TD, …), orthogonally.
   */
  function snapEnd(pts, box, dir) {
    if (!box || pts.length < 2) return pts;
    var horizontal = dir === "LR" || dir === "RL";
    var room = 24; // keep a straight run before the box so the arrowhead shows
    var outside = {
      LR: function (p) { return p[0] < box.x0 - room; }, RL: function (p) { return p[0] > box.x1 + room; },
      TD: function (p) { return p[1] < box.y0 - room; }, BT: function (p) { return p[1] > box.y1 + room; }
    }[dir];
    if (!outside) return pts;
    var qi = -1;
    for (var i = pts.length - 1; i >= 0; i--) { if (outside(pts[i])) { qi = i; break; } }
    if (qi < 0) return pts;
    var q = pts[qi], tail;
    if (horizontal) {
      var inset = Math.min(10, (box.y1 - box.y0) / 3);
      var y = Math.min(Math.max(q[1], box.y0 + inset), box.y1 - inset);
      var sideX = dir === "LR" ? box.x0 : box.x1;
      if (Math.abs(y - q[1]) < 0.5) tail = [[sideX, y]];
      else {
        var mx = dir === "LR" ? sideX - Math.min(18, (sideX - q[0]) / 2) : sideX + Math.min(18, (q[0] - sideX) / 2);
        tail = [[mx, q[1]], [mx, y], [sideX, y]];
      }
    } else {
      var insetX = Math.min(10, (box.x1 - box.x0) / 3);
      var x = Math.min(Math.max(q[0], box.x0 + insetX), box.x1 - insetX);
      var sideY = dir === "TD" ? box.y0 : box.y1;
      if (Math.abs(x - q[0]) < 0.5) tail = [[x, sideY]];
      else {
        var my = dir === "TD" ? sideY - Math.min(18, (sideY - q[1]) / 2) : sideY + Math.min(18, (q[1] - sideY) / 2);
        tail = [[q[0], my], [x, my], [x, sideY]];
      }
    }
    return pts.slice(0, qi + 1).concat(tail);
  }

  /** Flow direction from the diagram header ("flowchart LR", "graph TD", …). */
  function flowDirection(source) {
    var m = /^\s*(?:flowchart|graph)\s+(LR|RL|TD|TB|BT)\b/m.exec(source || "");
    if (!m) return "TD";
    return m[1] === "TB" ? "TD" : m[1];
  }

  /** Bounding box of `node` in the coordinate space of `path`. */
  function boxIn(path, node) {
    try {
      var b = node.getBBox();
      var m = path.getCTM().inverse().multiply(node.getCTM());
      var xs = [], ys = [];
      [[b.x, b.y], [b.x + b.width, b.y], [b.x, b.y + b.height], [b.x + b.width, b.y + b.height]].forEach(function (c) {
        xs.push(m.a * c[0] + m.c * c[1] + m.e);
        ys.push(m.b * c[0] + m.d * c[1] + m.f);
      });
      return { x0: Math.min.apply(null, xs), y0: Math.min.apply(null, ys), x1: Math.max.apply(null, xs), y1: Math.max.apply(null, ys) };
    } catch (e) {
      return null;
    }
  }

  /** Orthogonal ("step") polyline → lines joined by small rounded corners. */
  function roundedPath(pts, radius) {
    var out = "M" + pts[0][0] + "," + pts[0][1];
    for (var j = 1; j < pts.length - 1; j++) {
      var a = pts[j - 1], b = pts[j], c = pts[j + 1];
      var inLen = Math.hypot(b[0] - a[0], b[1] - a[1]), outLen = Math.hypot(c[0] - b[0], c[1] - b[1]);
      var r = Math.min(radius, inLen / 2, outLen / 2);
      if (r < 0.5) { out += "L" + b[0] + "," + b[1]; continue; }
      var p1 = [b[0] - (b[0] - a[0]) / inLen * r, b[1] - (b[1] - a[1]) / inLen * r];
      var p2 = [b[0] + (c[0] - b[0]) / outLen * r, b[1] + (c[1] - b[1]) / outLen * r];
      out += "L" + p1[0] + "," + p1[1] + "Q" + b[0] + "," + b[1] + " " + p2[0] + "," + p2[1];
    }
    var end = pts[pts.length - 1];
    return out + "L" + end[0] + "," + end[1];
  }

  function shapeOf(node) {
    // Only snap onto rectangular boxes; diamonds and circles keep Mermaid's own endpoints.
    return node.querySelector(":scope > rect.basic, :scope > rect.label-container, :scope > rect") ? "rect" : "other";
  }

  var elkRegistered = false;
  function registerELK() {
    if (!elkRegistered && window.mermaidLayoutElk && mermaid.registerLayoutLoaders) {
      mermaid.registerLayoutLoaders(window.mermaidLayoutElk);
      elkRegistered = true;
    }
    return elkRegistered;
  }

  // ---------------------------------------------------------------- highlighting

  var EDGE_SELECTOR = "path.flowchart-link, path.relation, path.transition, path.er.relationshipLine, line.messageLine0, line.messageLine1, path.messageLine0, path.messageLine1";
  var selection = null; // { kind: "edge" | "node", el }

  /** [start, end] node names of a flowchart edge (Mermaid 10: LS-/LE- classes; 11: data-id "L_a_b_0"). */
  function edgeEnds(edge, nodesByName) {
    var start = null, end = null;
    edge.classList.forEach(function (c) {
      if (c.indexOf("LS-") === 0) start = c.slice(3);
      else if (c.indexOf("LE-") === 0) end = c.slice(3);
    });
    if (start && end) return [start, end];
    var m = /^L_(.+)_\d+$/.exec(edge.getAttribute("data-id") || "");
    if (!m) return [null, null];
    var body = m[1]; // node names may themselves contain "_": try every split
    for (var i = body.indexOf("_"); i !== -1; i = body.indexOf("_", i + 1)) {
      var a = body.slice(0, i), b = body.slice(i + 1);
      if (nodesByName[a] && nodesByName[b]) return [a, b];
    }
    return [null, null];
  }

  /** Route of an edge: Mermaid 11 stores the layout's orthogonal points in data-points. */
  function edgePoints(edge) {
    var raw = edge.getAttribute("data-points");
    if (raw) {
      try { return dedupe(JSON.parse(atob(raw)).map(function (p) { return [p.x, p.y]; })); } catch (e) {}
    }
    return polylinePoints(edge.getAttribute("d"));
  }

  /** The element that draws a node's outline (not its label). */
  function outlineElement(node) {
    var el = node.querySelector(":scope > .label-container, :scope > polygon, :scope > circle, :scope > ellipse, :scope > rect, :scope > path, :scope > g.label-container");
    if (el && el.tagName === "g") el = el.querySelector("path, polygon, rect, circle, ellipse");
    return el && el.getTotalLength ? el : null;
  }

  /** The node's outline as a polygon in `path`'s coordinate space (sampled, so any shape works). */
  function outlineIn(path, node) {
    var el = outlineElement(node);
    if (!el) return null;
    try {
      var m = path.getCTM().inverse().multiply(el.getCTM());
      var length = el.getTotalLength();
      if (!(length > 0)) return null;
      var samples = el.tagName === "rect" ? 4 : 96, poly = [];
      if (el.tagName === "rect") {
        var x = el.x.baseVal.value, y = el.y.baseVal.value, w = el.width.baseVal.value, h = el.height.baseVal.value;
        poly = [[x, y], [x + w, y], [x + w, y + h], [x, y + h]];
      } else {
        for (var i = 0; i < samples; i++) {
          var p = el.getPointAtLength(length * i / samples);
          poly.push([p.x, p.y]);
        }
      }
      return poly.map(function (c) { return [m.a * c[0] + m.c * c[1] + m.e, m.b * c[0] + m.d * c[1] + m.f]; });
    } catch (e) {
      return null;
    }
  }

  /**
   * Where the straight segment end→neighbour leaves the outline, measured along that segment.
   * Layout engines route as if every node were a box; this puts the end exactly on the real
   * diamond/circle/pill outline while keeping the segment perfectly horizontal or vertical.
   */
  function exitPoint(poly, end, neighbour) {
    var horizontal = Math.abs(end[1] - neighbour[1]) < 0.5, vertical = Math.abs(end[0] - neighbour[0]) < 0.5;
    if (!poly || (!horizontal && !vertical)) return null;
    var best = null;
    for (var i = 0; i < poly.length; i++) {
      var p = poly[i], q = poly[(i + 1) % poly.length], hit = null;
      if (horizontal) {
        var Y = end[1];
        if ((p[1] - Y) * (q[1] - Y) > 0 || p[1] === q[1]) continue;
        hit = [p[0] + (Y - p[1]) * (q[0] - p[0]) / (q[1] - p[1]), Y];
      } else {
        var X = end[0];
        if ((p[0] - X) * (q[0] - X) > 0 || p[0] === q[0]) continue;
        hit = [X, p[1] + (X - p[0]) * (q[1] - p[1]) / (q[0] - p[0])];
      }
      // The crossing nearest the neighbour is the side the edge actually leaves through.
      if (!best || dist(hit, neighbour) < dist(best, neighbour)) best = hit;
    }
    return best;
  }

  function dist(a, b) { return Math.hypot(a[0] - b[0], a[1] - b[1]); }

  function isAxis(a, b) {
    return Math.abs(a[0] - b[0]) < 0.5 || Math.abs(a[1] - b[1]) < 0.5;
  }

  /**
   * Mermaid moves an edge's first point onto a diamond's (or circle's) slanted outline, leaving a
   * short diagonal stub before the first bend. Extend the first straight leg back to the outline
   * instead, so the edge leaves the shape dead straight.
   */
  function straightenStart(pts, poly) {
    if (pts.length < 2) return pts;
    if (isAxis(pts[0], pts[1])) {
      var onOutline = exitPoint(poly, pts[0], pts[1]);
      if (onOutline) pts[0] = onOutline;
      return pts;
    }
    if (pts.length >= 3 && isAxis(pts[1], pts[2])) {
      var extended = exitPoint(poly, pts[1], pts[2]);
      if (extended) return [extended].concat(pts.slice(2));
    }
    // Fallback: replace the diagonal with a right-angle elbow.
    var a = pts[0], b = pts[1];
    var nextHorizontal = pts.length >= 3 ? Math.abs(b[1] - pts[2][1]) < 0.5 : true;
    var elbow = nextHorizontal ? [a[0], b[1]] : [b[0], a[1]];
    return [a, elbow].concat(pts.slice(1));
  }

  /** How far Mermaid 11 pulls a line back for its arrowhead (the tip extends past the line end). */
  var ARROW_INSET = 4;

  function dedupe(pts) {
    return pts.filter(function (p, i) { return i === 0 || dist(p, pts[i - 1]) > 0.01; });
  }

  /** Moves an end point `by` px back along its segment (towards the neighbouring point). */
  function trim(pts, atEnd, by) {
    if (!(by > 0.3) || pts.length < 2) return;
    var i = atEnd ? pts.length - 1 : 0, j = atEnd ? pts.length - 2 : 1;
    var len = dist(pts[i], pts[j]);
    if (len <= by) return;
    pts[i] = [pts[i][0] + (pts[j][0] - pts[i][0]) / len * by, pts[i][1] + (pts[j][1] - pts[i][1]) / len * by];
  }

  function decorate(svg, source, usesELK) {
    var dir = flowDirection(source);
    var nodesByName = {};
    svg.querySelectorAll("g.node").forEach(function (node) { nodesByName[nodeName(node)] = node; });
    svg.querySelectorAll(EDGE_SELECTOR).forEach(function (edge) {
      if (edge.tagName === "path" && edge.classList.contains("flowchart-link")) {
        var ends = edgeEnds(edge, nodesByName);
        edge.__zqEnds = ends;
        var pts = edgePoints(edge);
        if (pts && pts.length >= 2) {
          var source = ends[0] && nodesByName[ends[0]], target = ends[1] && nodesByName[ends[1]];
          // dagre ends converging arrows on box corners; ELK already picks the right side.
          if (!usesELK && target && shapeOf(target) === "rect") pts = snapEnd(pts, boxIn(edge, target), dir);
          // Start and end exactly on the real outline, with straight first/last legs (no kinks).
          pts = straightenStart(pts, source ? outlineIn(edge, source) : null);
          pts = straightenStart(pts.slice().reverse(), target ? outlineIn(edge, target) : null).reverse();
          // Arrowheads are drawn beyond the line's end; pull the line back so the tip meets the outline.
          if (edge.getAttribute("marker-end")) trim(pts, true, ARROW_INSET);
          if (edge.getAttribute("marker-start")) trim(pts, false, ARROW_INSET);
          if (pts.length >= 3) edge.setAttribute("d", roundedPath(pts, 8));
          else edge.setAttribute("d", "M" + pts[0][0] + "," + pts[0][1] + "L" + pts[1][0] + "," + pts[1][1]);
        }
      }
      // A wide, invisible twin under each arrow: easy to hover, and it draws the glow.
      var hit = edge.cloneNode(false);
      hit.removeAttribute("id");
      hit.removeAttribute("style");
      hit.removeAttribute("marker-start");
      hit.removeAttribute("marker-end");
      hit.removeAttribute("data-points");
      hit.setAttribute("class", "zq-hit");
      edge.parentNode.insertBefore(hit, edge);
      hit.__zqEdge = edge;
      edge.__zqHit = hit;
    });
  }

  function edgeFor(target) {
    if (!target || !target.closest) return null;
    if (target.__zqEdge) return target.__zqEdge;
    var edge = target.closest(EDGE_SELECTOR);
    return edge && edge.__zqHit ? edge : null;
  }

  function nodeFor(target) {
    return target && target.closest ? target.closest("g.node") : null;
  }

  function nodeName(node) {
    var m = /(?:^|-)flowchart-(.+)-\d+$/.exec(node.id || "");
    return m ? m[1] : node.getAttribute("data-id") || "";
  }

  function clearSelection() {
    document.querySelectorAll(".zq-selected, .zq-related").forEach(function (el) {
      el.classList.remove("zq-selected", "zq-related");
    });
    document.querySelectorAll(".zq-overlay").forEach(function (el) { el.remove(); });
    if (selection && selection.kind === "node") post({ selected: null });
    selection = null;
  }

  function selectEdge(edge) {
    clearSelection();
    edge.__zqHit.classList.add("zq-selected");
    selection = { kind: "edge", el: edge };
  }

  function selectNode(node) {
    clearSelection();
    var svg = node.ownerSVGElement;
    if (!svg) return;
    // Draw the outline on a top-level overlay: WebKit stops repainting a node's HTML label
    // when elements are added inside the node's own group.
    var ns = "http://www.w3.org/2000/svg";
    var overlay = document.createElementNS(ns, "g");
    overlay.setAttribute("class", "zq-overlay");
    svg.appendChild(overlay);
    var box = boxIn(overlay, node);
    if (box) {
      var outline = document.createElementNS(ns, "rect");
      outline.setAttribute("class", "zq-node-outline");
      outline.setAttribute("x", box.x0 - 6);
      outline.setAttribute("y", box.y0 - 6);
      outline.setAttribute("width", box.x1 - box.x0 + 12);
      outline.setAttribute("height", box.y1 - box.y0 + 12);
      overlay.appendChild(outline);
    }
    // Light up every arrow going into or out of this box.
    var name = nodeName(node);
    if (name) {
      svg.querySelectorAll(EDGE_SELECTOR).forEach(function (edge) {
        var ends = edge.__zqEnds;
        if (edge.__zqHit && ends && (ends[0] === name || ends[1] === name)) edge.__zqHit.classList.add("zq-related");
      });
    }
    selection = { kind: "node", el: node };
    post({ selected: name }); // the app shows its inspector for this node
  }

  var hovered = null;
  document.addEventListener("mouseover", function (event) {
    var edge = edgeFor(event.target);
    var hit = edge ? edge.__zqHit : null;
    if (hit === hovered) return;
    if (hovered) hovered.classList.remove("zq-hover");
    hovered = hit;
    if (hovered) hovered.classList.add("zq-hover");
  });

  // ---------------------------------------------------------------- canvas

  var canvas = {
    enabled: false,
    target: null,         // the diagram element we transform
    x: 0, y: 0, k: 1,
    placed: false,        // first view already set (keeps the view across live reloads)
    space: false,
    drag: null
  };

  function clampZoom(k) { return Math.min(8, Math.max(0.05, k)); }

  function apply() {
    if (!canvas.enabled) return;
    if (canvas.target) {
      canvas.target.style.transform = "translate(" + canvas.x + "px," + canvas.y + "px) scale(" + canvas.k + ")";
    }
    // The "+" grid moves and scales with the diagram, like an infinite sheet.
    var size = 24 * canvas.k;
    while (size < 14) size *= 2;
    while (size > 56) size /= 2;
    document.body.style.backgroundSize = size + "px " + size + "px";
    document.body.style.backgroundPosition = canvas.x + "px " + canvas.y + "px";
    report();
  }

  function post(message) {
    try { window.webkit.messageHandlers.renderooo.postMessage(message); } catch (e) {}
  }

  function report() {
    post({ zoom: canvas.k });
  }

  function zoomAt(clientX, clientY, factor) {
    var k = clampZoom(canvas.k * factor);
    factor = k / canvas.k;
    canvas.x = clientX - (clientX - canvas.x) * factor;
    canvas.y = clientY - (clientY - canvas.y) * factor;
    canvas.k = k;
    apply();
  }

  function contentSize() {
    var t = canvas.target;
    return t ? { w: t.offsetWidth, h: t.offsetHeight } : { w: 0, h: 0 };
  }

  function fit(maxZoom) {
    var size = contentSize();
    if (!size.w || !size.h) return;
    var vw = window.innerWidth, vh = window.innerHeight, margin = 48;
    var k = clampZoom(Math.min((vw - margin * 2) / size.w, (vh - margin * 2) / size.h, maxZoom));
    canvas.k = k;
    canvas.x = (vw - size.w * k) / 2;
    canvas.y = (vh - size.h * k) / 2;
    apply();
  }

  function setZoom(k) {
    zoomAt(window.innerWidth / 2, window.innerHeight / 2, k / canvas.k);
  }

  function attachCanvas(enabled) {
    canvas.enabled = enabled;
    document.body.classList.toggle("zq-canvas", enabled);
    if (!enabled) return;
    canvas.target = document.querySelector("#renderooo-content pre.mermaid-block:not(.code-block)");
    if (!canvas.target) { report(); return; }
    if (!canvas.placed) {
      canvas.placed = true;
      fit(1); // whole diagram in view, never blown up past 100% at first
    } else {
      apply();
    }
  }

  function isInteractive(target) {
    return !!(edgeFor(target) || nodeFor(target) || (target.closest && target.closest(".edgeLabel")));
  }

  window.addEventListener("wheel", function (event) {
    if (!canvas.enabled) return;
    event.preventDefault();
    if (event.ctrlKey || event.metaKey || event.altKey) {
      // Pinch arrives as ctrl+wheel; ⌘/⌥ + mouse wheel zoom at the pointer (Photoshop-style).
      var speed = event.ctrlKey ? 0.01 : 0.0025;
      zoomAt(event.clientX, event.clientY, Math.exp(-event.deltaY * speed));
    } else {
      canvas.x -= event.deltaX;
      canvas.y -= event.deltaY;
      apply();
    }
  }, { passive: false });

  // Safari-style pinch gestures (sent when the web view's own magnification is off).
  var gestureScale = 1;
  window.addEventListener("gesturestart", function (event) {
    if (!canvas.enabled) return;
    event.preventDefault();
    gestureScale = 1;
  });
  window.addEventListener("gesturechange", function (event) {
    if (!canvas.enabled) return;
    event.preventDefault();
    zoomAt(event.clientX, event.clientY, event.scale / gestureScale);
    gestureScale = event.scale;
  });

  window.addEventListener("keydown", function (event) {
    if (event.key === "Escape") clearSelection();
    if (!canvas.enabled || event.code !== "Space") return;
    event.preventDefault(); // no page scrolling: space is the hand tool
    if (!canvas.space) {
      canvas.space = true;
      document.body.classList.add("zq-hand");
    }
  });
  window.addEventListener("keyup", function (event) {
    if (event.code !== "Space") return;
    canvas.space = false;
    document.body.classList.remove("zq-hand");
  });
  window.addEventListener("blur", function () {
    canvas.space = false;
    document.body.classList.remove("zq-hand");
  });

  window.addEventListener("mousedown", function (event) {
    var interactive = isInteractive(event.target);
    if (canvas.enabled && (canvas.space || event.button === 1 || (event.button === 0 && !interactive))) {
      // Hand tool: space+drag anywhere, middle-drag, or drag on empty canvas.
      event.preventDefault();
      canvas.drag = { x: event.clientX, y: event.clientY, ox: canvas.x, oy: canvas.y, moved: false };
      document.body.classList.add("zq-panning");
    }
  });
  window.addEventListener("mousemove", function (event) {
    var drag = canvas.drag;
    if (!drag) return;
    var dx = event.clientX - drag.x, dy = event.clientY - drag.y;
    if (Math.abs(dx) + Math.abs(dy) > 3) drag.moved = true;
    canvas.x = drag.ox + dx;
    canvas.y = drag.oy + dy;
    apply();
  });
  window.addEventListener("mouseup", function () {
    if (!canvas.drag) return;
    canvas.justPanned = canvas.drag.moved;
    canvas.drag = null;
    document.body.classList.remove("zq-panning");
  });

  document.addEventListener("click", function (event) {
    if (canvas.justPanned) { canvas.justPanned = false; return; }
    if (canvas.space) return;
    var edge = edgeFor(event.target);
    if (edge) { selectEdge(edge); return; }
    var node = nodeFor(event.target);
    if (node && node.ownerSVGElement) { selectNode(node); return; }
    if (event.target.closest && event.target.closest("pre.mermaid-block svg, body.zq-canvas")) clearSelection();
  });

  document.addEventListener("dblclick", function (event) {
    var node = nodeFor(event.target);
    if (node && node.ownerSVGElement) {
      selectNode(node);
      post({ editText: nodeName(node) }); // jump to the inspector's text field
      return;
    }
    if (canvas.enabled && !isInteractive(event.target)) fit(2);
  });

  // ---------------------------------------------------------------- rendering

  // Theme and sizing of the render in progress (reported with each drawing for the cache).
  var renderContext = { dark: false, canvas: false };

  function layoutFor(source) {
    return elkRegistered && !/^\s*layout:\s*dagre/m.test(source) ? "elk" : "dagre";
  }

  /** Draws one block's diagram (or its error). Works on detached blocks too. */
  async function renderBlock(block, index) {
    var source = block.dataset.source;
    var id = "renderooo-diagram-" + Date.now() + "-" + index;
    try {
      var result = await mermaid.render(id, source);
      block.classList.remove("code-block", "mermaid-failed");
      block.innerHTML = result.svg;
      block.dataset.layout = layoutFor(source);
      // The app keeps finished drawings, so reopening shows them without redrawing.
      post({ cacheSVG: result.svg, source: source, layout: block.dataset.layout, dark: renderContext.dark, canvas: renderContext.canvas });
    } catch (error) {
      // Show what went wrong above the source instead of an empty space.
      var message = document.createElement("div");
      message.className = "mermaid-error";
      message.textContent = "Mermaid: " + ((error && error.message) || String(error));
      var code = document.createElement("code");
      code.textContent = source;
      block.classList.add("code-block", "mermaid-failed");
      block.replaceChildren(message, code);
    } finally {
      // On errors Mermaid leaves its scratch element (with a "bomb" graphic) in <body>.
      [document.getElementById("d" + id), document.getElementById(id)].forEach(function (leftover) {
        if (leftover && !leftover.closest("#renderooo-content")) leftover.remove();
      });
    }
  }

  function selectedNodeName() {
    return selection && selection.kind === "node" ? nodeName(selection.el) : null;
  }

  /** After diagrams are in the document: arrows, canvas, and the previous selection. */
  function finish(root, canvasMode, keep) {
    root.querySelectorAll("pre.mermaid-block svg").forEach(function (svg) {
      var block = svg.closest(".mermaid-block");
      decorate(svg, block.dataset.source, (block.dataset.layout || layoutFor(block.dataset.source)) === "elk");
    });
    attachCanvas(canvasMode);
    if (keep) {
      var again = Array.from(document.querySelectorAll("pre.mermaid-block svg g.node")).find(function (n) { return nodeName(n) === keep; });
      if (again) selectNode(again); else post({ selected: null });
    }
  }

  async function renderAll(forceLight, canvasMode) {
    var dark = !forceLight && window.matchMedia("(prefers-color-scheme: dark)").matches;
    renderContext = { dark: dark, canvas: canvasMode };
    mermaid.initialize(mermaidConfig(dark, canvasMode));
    // Keep the selected node selected across re-renders (live reload, visual edits, theme).
    var keep = selectedNodeName();
    hovered = null;
    selection = null;
    var blocks = Array.from(document.querySelectorAll(".mermaid-block"));
    for (var i = 0; i < blocks.length; i++) await renderBlock(blocks[i], i);
    finish(document, canvasMode, keep);
    return blocks.length;
  }

  /**
   * Replaces the document with new HTML (live reload, edits). Diagrams are drawn off-screen first,
   * so the old version stays visible until the new one is complete: no flash of source or blank.
   */
  async function update(html, forceLight, canvasMode) {
    var dark = !forceLight && window.matchMedia("(prefers-color-scheme: dark)").matches;
    renderContext = { dark: dark, canvas: canvasMode };
    mermaid.initialize(mermaidConfig(dark, canvasMode));
    var keep = selectedNodeName();
    var staging = document.createElement("div");
    staging.innerHTML = html;
    var blocks = Array.from(staging.querySelectorAll(".mermaid-block"));
    for (var i = 0; i < blocks.length; i++) await renderBlock(blocks[i], i);
    hovered = null;
    selection = null;
    document.querySelectorAll(".zq-overlay").forEach(function (el) { el.remove(); });
    document.getElementById("renderooo-content").replaceChildren.apply(
      document.getElementById("renderooo-content"), Array.from(staging.childNodes));
    finish(document, canvasMode, keep);
    return blocks.length;
  }

  window.ZQ = {
    renderAll: renderAll,
    update: update,
    /** Diagrams that arrived already drawn (from the cache): add arrows, canvas, interaction. */
    adopt: function (canvasMode) {
      finish(document, canvasMode, null);
      return document.querySelectorAll("pre.mermaid-block svg").length;
    },
    command: function (name) {
      if (!canvas.enabled) return;
      if (name === "fit") fit(2);
      else if (name === "actual") setZoom(1);
      else if (name === "in") setZoom(canvas.k * 1.25);
      else if (name === "out") setZoom(canvas.k / 1.25);
    }
  };
})();
