"use strict";

(() => {
  const content = () => document.getElementById("content");
  const darkQuery = window.matchMedia("(prefers-color-scheme: dark)");
  const themeIDPattern = /^[a-z0-9-]+$/;

  // The light/dark theme pair (S2). Initialized from theme-boot's query so a scheme flip
  // before any `setThemes` call still picks the right one.
  function initialThemePair() {
    const params = new URLSearchParams(location.search);
    const theme = params.get("theme");
    const darkTheme = params.get("darkTheme");
    const light = theme && themeIDPattern.test(theme) ? theme : (document.documentElement.dataset.theme || "dawn");
    const dark = darkTheme && themeIDPattern.test(darkTheme) ? darkTheme : light;
    return { light, dark };
  }
  let themePair = initialThemePair();

  function pickTheme(pair) {
    return darkQuery.matches && pair.dark ? pair.dark : pair.light;
  }

  // Rendered mermaid SVG keyed by diagram source, so unchanged diagrams never re-render.
  const svgCache = new Map();
  let renderCounter = 0;
  let mermaidSignature = null;

  function log(message) {
    try { window.webkit.messageHandlers.log.postMessage(String(message)); } catch (_) {}
  }
  window.addEventListener("error", (e) => log(`${e.message} @${e.filename}:${e.lineno}`));

  // Mermaid colours come from the active theme's CSS variables (see themes.css).
  function configureMermaid() {
    const theme = document.documentElement.dataset.theme || "dawn";
    const dark = darkQuery.matches;
    const signature = `${theme}/${dark ? "dark" : "light"}`;
    if (signature === mermaidSignature) return false;
    mermaidSignature = signature;

    const style = getComputedStyle(document.documentElement);
    const v = (name) => style.getPropertyValue(name).trim();
    const font = v("--font-body");
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: "strict",
      theme: "base",
      fontFamily: font,
      themeVariables: {
        darkMode: dark,
        background: v("--bg"),
        fontFamily: font,
        fontSize: "14px",
        primaryColor: v("--mm-node"),
        primaryTextColor: v("--mm-text"),
        primaryBorderColor: v("--mm-border"),
        secondaryColor: v("--mm-secondary"),
        secondaryTextColor: v("--mm-text"),
        secondaryBorderColor: v("--mm-border"),
        tertiaryColor: v("--mm-tertiary"),
        tertiaryTextColor: v("--mm-text"),
        tertiaryBorderColor: v("--mm-border"),
        lineColor: v("--mm-line"),
        textColor: v("--mm-text"),
        mainBkg: v("--mm-node"),
        nodeBorder: v("--mm-border"),
        clusterBkg: v("--mm-tertiary"),
        clusterBorder: v("--border"),
        edgeLabelBackground: v("--bg"),
        titleColor: v("--heading"),
        noteBkgColor: v("--mm-note"),
        noteTextColor: v("--mm-text"),
        noteBorderColor: v("--mm-border"),
        actorBkg: v("--mm-node"),
        actorBorder: v("--mm-border"),
        actorTextColor: v("--mm-text"),
        actorLineColor: v("--mm-line"),
        signalColor: v("--mm-text"),
        signalTextColor: v("--mm-text"),
        labelBoxBkgColor: v("--mm-node"),
        labelBoxBorderColor: v("--mm-border"),
        labelTextColor: v("--mm-text"),
        loopTextColor: v("--mm-text"),
        activationBkgColor: v("--mm-secondary"),
        activationBorderColor: v("--mm-border"),
        sequenceNumberColor: v("--bg"),
        pie1: v("--accent"),
        pie2: v("--hl-function"),
        pie3: v("--hl-string"),
        pie4: v("--hl-number"),
        pie5: v("--hl-type"),
        pie6: v("--link"),
        pieStrokeColor: v("--bg"),
        pieTitleTextColor: v("--heading"),
        pieSectionTextColor: v("--bg"),
        git0: v("--accent"),
        git1: v("--hl-function"),
        git2: v("--hl-string"),
        git3: v("--hl-number"),
      },
    });
    svgCache.clear();
    return true;
  }

  // Identity of a block ignoring source line numbers, which shift on every edit above it.
  function blockKey(el) {
    const clone = el.cloneNode(true);
    clone.removeAttribute("data-line");
    clone.querySelectorAll("[data-line]").forEach((n) => n.removeAttribute("data-line"));
    return clone.outerHTML;
  }

  function copyLineNumbers(from, to) {
    const src = [from, ...from.querySelectorAll("[data-line]")];
    const dst = [to, ...to.querySelectorAll("[data-line]")];
    for (let i = 0; i < src.length && i < dst.length; i++) {
      const line = src[i].getAttribute("data-line");
      if (line !== null) dst[i].setAttribute("data-line", line);
    }
  }

  function highlightCode(root) {
    root.querySelectorAll("pre > code[class*='language-']").forEach((code) => {
      const lang = code.className.replace(/^.*language-/, "").split(/\s/)[0];
      if (window.hljs && hljs.getLanguage(lang)) hljs.highlightElement(code);
    });
  }

  // MARK: Math
  //
  // The renderer emits `<span class="math-inline">`, `<span class="math-inline math-display">`
  // and `<div class="math-block" data-line="N">`, each holding only the escaped TeX. Nothing
  // here reads an attribute: the TeX comes from `textContent` and the display mode from the
  // class. `katex.render` replaces the element's children, so the TeX is never markup and
  // `innerHTML` is never set from it.

  // The frozen option set (S5-1). `trust: false` keeps \href, \url and \includegraphics from
  // producing links or images; `maxExpand` and `maxSize` bound a macro bomb. No `macros`
  // key at all, so no expansion of one expression's \def can leak into the next. Every call
  // spreads these into a fresh object and adds only `displayMode`.
  const mathOptions = Object.freeze({
    throwOnError: false,
    trust: false,
    strict: "ignore",
    maxExpand: 1000,
    maxSize: 50,
    output: "htmlAndMathml",
  });

  // S5-4: an expression longer than this stays as its source text, and only this many are
  // rendered per update; the rest stay as source too. Either way the element is marked done,
  // so the exporter's readiness check always terminates.
  const maxMathLength = 10000;
  const maxMathPerUpdate = 2000;

  // Written out per class: `:not()` binds to one compound selector, so ".math-inline,
  // .math-block:not(.math-done)" would leave every inline expression pending forever and
  // re-render it on each update.
  const pendingMathSelector = ".math-inline:not(.math-done), .math-block:not(.math-done)";

  function renderMath() {
    const pending = content().querySelectorAll(pendingMathSelector);
    let rendered = 0;
    for (const el of pending) {
      const tex = el.textContent;
      const displayMode = el.classList.contains("math-block") || el.classList.contains("math-display");
      // Marked before rendering, so a throw below can't leave the element pending.
      el.classList.add("math-done");
      if (tex.length > maxMathLength || rendered >= maxMathPerUpdate) {
        el.classList.add("math-skipped");
        continue;
      }
      rendered += 1;
      try {
        katex.render(tex, el, { ...mathOptions, displayMode });
      } catch (err) {
        // throwOnError:false already turns a parse error into KaTeX's own error text, so
        // this is for the rest. Keep the source visible and say why.
        el.classList.add("math-error");
        el.textContent = tex;
        el.setAttribute("title", String(err?.message ?? err).split("\n")[0]);
      }
    }
    return rendered;
  }

  async function renderMermaid(block, placeholderSVG) {
    const source = block.querySelector(".mermaid-source")?.textContent ?? "";
    const target = document.createElement("div");
    target.className = "mermaid-output";
    block.appendChild(target);

    const cached = svgCache.get(source);
    if (cached) {
      target.innerHTML = cached;
      block.classList.add("rendered");
      return;
    }
    // Keep the previous diagram on screen while the edited one renders (no flicker).
    if (placeholderSVG) {
      target.innerHTML = placeholderSVG;
      block.classList.add("rendered", "stale");
    }
    const id = `mermaid-${++renderCounter}`;
    try {
      const { svg } = await mermaid.render(id, source);
      svgCache.set(source, svg);
      // Typing inside a diagram produces many intermediate sources; keep only recent ones.
      if (svgCache.size > 64) svgCache.delete(svgCache.keys().next().value);
      if (!block.isConnected) return;
      target.innerHTML = svg;
      block.classList.add("rendered");
      block.classList.remove("stale", "error");
      block.removeAttribute("data-error");
    } catch (err) {
      if (!block.isConnected) return;
      block.classList.add("error");
      block.setAttribute("data-error", String(err?.message ?? err).split("\n")[0]);
      if (!placeholderSVG) block.classList.remove("rendered");
    } finally {
      document.getElementById(`d${id}`)?.remove();
    }
  }

  // MARK: Scroll sync
  //
  // Anchors map source lines to page offsets using the data-line attributes. Positions
  // between anchors are interpolated, so both panes line up within a paragraph.

  let anchors = null;
  let lineCount = 1;
  let suppressScrollUntil = 0;
  let lastSyncedLine = null;
  let scrollFrame = 0;

  function invalidateAnchors() {
    anchors = null;
  }

  function getAnchors() {
    if (anchors) return anchors;
    const offset = window.scrollY;
    const raw = [...content().querySelectorAll("[data-line]")].map((el) => ({
      line: Number(el.dataset.line),
      top: el.getBoundingClientRect().top + offset,
    }));
    raw.sort((a, b) => a.line - b.line || a.top - b.top);
    const list = [{ line: 1, top: 0 }];
    for (const a of raw) {
      const last = list[list.length - 1];
      if (a.line <= last.line || a.top < last.top) continue;
      list.push(a);
    }
    list.push({ line: lineCount + 1, top: document.documentElement.scrollHeight });
    anchors = list;
    return list;
  }

  function maxScroll() {
    return Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
  }

  function topForLine(line) {
    const list = getAnchors();
    for (let i = list.length - 2; i >= 0; i--) {
      const a = list[i], b = list[i + 1];
      if (line >= a.line) {
        const t = Math.min(1, (line - a.line) / Math.max(1, b.line - a.line));
        return a.top + t * (b.top - a.top);
      }
    }
    return 0;
  }

  function lineForTop(top) {
    const list = getAnchors();
    for (let i = list.length - 2; i >= 0; i--) {
      const a = list[i], b = list[i + 1];
      if (top >= a.top) {
        const t = Math.min(1, (top - a.top) / Math.max(1, b.top - a.top));
        return a.line + t * (b.line - a.line);
      }
    }
    return 1;
  }

  // Called by the app when the editor scrolls. `atEnd` pins the preview to its bottom.
  function scrollToLine(line, atEnd) {
    lastSyncedLine = { line, atEnd };
    const target = atEnd ? maxScroll() : Math.min(maxScroll(), topForLine(line));
    if (Math.abs(window.scrollY - target) < 1) return;
    suppressScrollUntil = performance.now() + 120;
    window.scrollTo(0, target);
  }

  function reapplySync() {
    if (lastSyncedLine) scrollToLine(lastSyncedLine.line, lastSyncedLine.atEnd);
  }

  window.addEventListener("scroll", () => {
    if (performance.now() < suppressScrollUntil) return;
    lastSyncedLine = null;  // the user took over; don't snap back on the next update
    if (scrollFrame) return;
    scrollFrame = requestAnimationFrame(() => {
      scrollFrame = 0;
      const atEnd = window.scrollY >= maxScroll() - 1;
      try {
        window.webkit.messageHandlers.scrollSync.postMessage({ line: lineForTop(window.scrollY), atEnd });
      } catch (_) {}
    });
  }, { passive: true });

  window.addEventListener("resize", () => {
    invalidateAnchors();
    reapplySync();
  });

  // Images and diagrams change heights after layout.
  document.addEventListener("load", (event) => {
    if (event.target.tagName === "IMG") {
      invalidateAnchors();
      reapplySync();
    }
  }, true);

  // MARK: Local images
  //
  // Images served from the document's folder can fail because the file is missing or because
  // the sandbox has no access to the folder yet; the latter gets a "grant access" button.

  const assetScheme = "marsdawn-asset:";
  let assetState = { needsAccess: false, grantLabel: "Grant Access…", missingLabel: "Image not found", blockedLabel: "Image needs folder access" };
  let retryCounter = 0;

  function placeholderFor(img) {
    const box = document.createElement("span");
    box.className = "image-placeholder";
    box.dataset.src = img.getAttribute("src");
    box.dataset.alt = img.getAttribute("alt") || "";
    const title = img.getAttribute("title");
    if (title) box.dataset.title = title;
    const label = document.createElement("span");
    label.className = "image-placeholder-label";
    const raw = box.dataset.src.replace(/^[^/]*\/\/[^/]*\//, "").replace(/\?.*$/, "");
    let name = raw;
    try { name = decodeURIComponent(raw); } catch (_) {}
    label.textContent = `${assetState.needsAccess ? assetState.blockedLabel : assetState.missingLabel}: ${name}`;
    box.appendChild(label);
    if (assetState.needsAccess) {
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = assetState.grantLabel;
      button.addEventListener("click", () => {
        try { window.webkit.messageHandlers.assetAccess.postMessage({}); } catch (_) {}
      });
      box.appendChild(button);
    }
    return box;
  }

  document.addEventListener("error", (event) => {
    const img = event.target;
    if (img.tagName !== "IMG") return;
    const src = img.getAttribute("src") || "";
    if (src.startsWith(assetScheme)) {
      img.replaceWith(placeholderFor(img));
      invalidateAnchors();
    } else if (remoteState.blocked && isRemote(src)) {
      img.replaceWith(remotePlaceholderFor(img));
      invalidateAnchors();
    }
  }, true);

  // MARK: Remote images
  //
  // The page's CSP blocks https images unless the app loaded it with remote images allowed.
  // Blocked images become quiet placeholders and a bar offers to load them all.

  let remoteState = { blocked: true, message: "", buttonLabel: "", placeholderLabel: "" };

  function isRemote(src) {
    return /^https?:/i.test(src);
  }

  function remotePlaceholderFor(img) {
    const box = document.createElement("span");
    box.className = "image-placeholder remote";
    const label = document.createElement("span");
    label.className = "image-placeholder-label";
    let host = "";
    try { host = new URL(img.getAttribute("src")).host; } catch (_) {}
    label.textContent = `${remoteState.placeholderLabel}${host ? ": " + host : ""}`;
    if (img.getAttribute("alt")) label.title = img.getAttribute("alt");
    box.appendChild(label);
    return box;
  }

  function hasRemoteImages() {
    return [...content().querySelectorAll("img")].some((img) => isRemote(img.getAttribute("src") || ""))
      || content().querySelector(".image-placeholder.remote") !== null;
  }

  function refreshRemoteBar() {
    const bar = document.getElementById("remote-images-bar");
    if (!bar) return;
    const show = remoteState.blocked && hasRemoteImages();
    if (show && !bar.firstChild) {
      const text = document.createElement("span");
      text.textContent = remoteState.message;
      bar.append(text);
      // Hosts that can't load remote images (e.g. Quick Look) pass no button label.
      if (remoteState.buttonLabel) {
        const button = document.createElement("button");
        button.type = "button";
        button.textContent = remoteState.buttonLabel;
        button.addEventListener("click", () => {
          try { window.webkit.messageHandlers.loadRemoteImages.postMessage({ scrollY: window.scrollY }); } catch (_) {}
        });
        bar.append(button);
      }
    }
    if (bar.hidden === show) {
      bar.hidden = !show;
      invalidateAnchors();
    }
  }

  function setRemoteImageState(state) {
    remoteState = state;
    const bar = document.getElementById("remote-images-bar");
    if (bar) bar.replaceChildren();
    refreshRemoteBar();
  }

  function retryImages() {
    retryCounter += 1;
    for (const box of content().querySelectorAll(".image-placeholder")) {
      const img = document.createElement("img");
      img.setAttribute("alt", box.dataset.alt);
      if (box.dataset.title) img.setAttribute("title", box.dataset.title);
      const src = box.dataset.src.replace(/\?.*$/, "");
      img.setAttribute("src", `${src}?retry=${retryCounter}`);
      box.replaceWith(img);
    }
  }

  function setAssetState(state) {
    assetState = state;
    retryImages();
  }

  // Every tag in RawHTMLSafety.swift's `neutralizedRawHTMLTags`, plus `meta` (a refresh navigates)
  // and `base` (changes how relative URLs resolve).
  const blockedElements = "link, meta, base, iframe, frame, object, embed, portal, fencedframe";

  function update(html, lines) {
    if (lines) lineCount = lines;
    invalidateAnchors();
    const root = content();
    const template = document.createElement("template");
    template.innerHTML = html;
    // Defence in depth for RawHTMLSafety.swift: drop every element that can open a connection or
    // a nested document before anything reaches the page. Template content is inert, so none of
    // these has loaded anything yet.
    template.content.querySelectorAll(blockedElements).forEach((el) => el.remove());
    const incoming = [...template.content.children];

    // Pool existing blocks by key so unchanged ones (and their rendered diagrams) are reused.
    const pool = new Map();
    const staleSVGs = [];
    for (const el of [...root.children]) {
      const key = el._mdKey;
      if (!pool.has(key)) pool.set(key, []);
      pool.get(key).push(el);
    }

    const fragment = document.createDocumentFragment();
    const fresh = [];
    for (const el of incoming) {
      const key = blockKey(el);
      const reusable = pool.get(key);
      if (reusable && reusable.length) {
        const existing = reusable.shift();
        copyLineNumbers(el, existing);
        fragment.appendChild(existing);
      } else {
        el._mdKey = key;
        fresh.push(el);
        fragment.appendChild(el);
      }
    }
    for (const leftovers of pool.values()) {
      for (const el of leftovers) {
        if (el.classList.contains("mermaid-block")) {
          const svg = el.querySelector(".mermaid-output")?.innerHTML;
          if (svg) staleSVGs.push(svg);
        }
      }
    }

    root.replaceChildren(fragment);

    refreshRemoteBar();
    const renders = [];
    for (const el of fresh) {
      highlightCode(el);
      const blocks = el.classList.contains("mermaid-block") ? [el] : el.querySelectorAll(".mermaid-block");
      for (const block of blocks) renders.push(renderMermaid(block, staleSVGs.shift()));
    }
    // Synchronous, and only over elements the pool didn't reuse: math whose source hasn't
    // changed keeps the KaTeX output it already has.
    renderMath();
    reapplySync();
    pendingWork = Promise.allSettled(renders);
    if (renders.length) {
      Promise.allSettled(renders).then(() => {
        invalidateAnchors();
        reapplySync();
      });
    }
  }

  // Redraw diagrams in place (keeps scroll position); old SVGs stay visible until replaced.
  function rerenderDiagrams() {
    for (const block of content().querySelectorAll(".mermaid-block")) {
      const output = block.querySelector(".mermaid-output");
      const previous = output?.innerHTML;
      output?.remove();
      renderMermaid(block, previous).then(() => {
        invalidateAnchors();
        reapplySync();
      });
    }
  }

  function refreshTheme() {
    invalidateAnchors();
    if (configureMermaid()) rerenderDiagrams();
  }

  function setTheme(theme) {
    setThemes(theme, theme);
  }

  // Stores a separate light and dark theme (S2); an invalid or missing dark id falls back to
  // the light id. Sets `data-theme` to whichever one matches the current color scheme.
  function setThemes(light, dark) {
    if (!themeIDPattern.test(light)) return;
    const validDark = dark && themeIDPattern.test(dark) ? dark : light;
    themePair = { light, dark: validDark };
    document.documentElement.dataset.theme = pickTheme(themePair);
    refreshTheme();
  }

  darkQuery.addEventListener("change", () => {
    document.documentElement.dataset.theme = pickTheme(themePair);
    refreshTheme();
  });

  document.addEventListener("DOMContentLoaded", () => {
    configureMermaid();
  });

  // Resolves once the diagrams from the latest update have rendered (or failed).
  let pendingWork = Promise.resolve();
  async function idle() {
    await pendingWork;
    return content().children.length;
  }

  function restoreScroll(y) {
    suppressScrollUntil = performance.now() + 120;
    window.scrollTo(0, y);
  }

  window.MarsDawn = { update, setTheme, setThemes, scrollToLine, setAssetState, setRemoteImageState, restoreScroll, idle };
})();
