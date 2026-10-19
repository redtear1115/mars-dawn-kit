"use strict";

// The JSON and YAML tree page (kit #128). The host sends the document's text with
// `DataDocumentPreview.update(...)` through `callAsyncJavaScript`, and gets back one fixed string
// naming what the page now shows. Every limit comes from the `limits` argument, which the kit
// fills from its Swift constants; this file has no limit of its own.
//
// Rules this file keeps (security review F9, F11, F12): document text reaches the page only as
// text nodes (createElement / textContent / fixed class names); setAttribute only with the
// literal names aria-expanded, type and role; no id or name built from the document; parsed
// values are read with Array.isArray, Object.keys and Object.hasOwn only, never copied, coerced
// to strings or walked whole except by the one linear depth check; every exception is caught
// here, and nothing of the document is ever posted to the host.
(() => {
  // Captured once, before anything else runs.
  const yaml = globalThis.jsyaml;
  const isArray = Array.isArray;
  const keysOf = Object.keys;
  const hasOwn = Object.hasOwn;
  const numberToString = Number.prototype.toString;
  const now = () => performance.now();

  // MARK: Themes (the same model as preview.js: a light/dark pair picked by the appearance)

  const darkQuery = window.matchMedia("(prefers-color-scheme: dark)");
  const themeIDPattern = /^[a-z0-9]+(-[a-z0-9]+)*$/;
  const isThemeID = (id) => typeof id === "string" && id.length <= 32 && themeIDPattern.test(id);

  function initialThemePair() {
    const params = new URLSearchParams(location.search);
    const theme = params.get("theme");
    const darkTheme = params.get("darkTheme");
    const light = isThemeID(theme) ? theme : (document.documentElement.dataset.theme || "dawn");
    const dark = isThemeID(darkTheme) ? darkTheme : light;
    return { light, dark };
  }
  let themePair = initialThemePair();

  function pickTheme(pair) {
    return darkQuery.matches && pair.dark ? pair.dark : pair.light;
  }

  function setThemes(light, dark) {
    if (!isThemeID(light)) return;
    const validDark = isThemeID(dark) ? dark : light;
    themePair = { light, dark: validDark };
    document.documentElement.dataset.theme = pickTheme(themePair);
  }

  darkQuery.addEventListener("change", () => {
    document.documentElement.dataset.theme = pickTheme(themePair);
  });

  // MARK: Messages to the host (numbers or nothing; a host may register no handler)

  function postErrorPosition(line, column) {
    try { window.webkit.messageHandlers.dataError.postMessage({ line, column }); } catch (_) {}
  }

  function postShowSource() {
    try { window.webkit.messageHandlers.dataShowSource.postMessage(null); } catch (_) {}
  }

  // MARK: Limits and labels from the host

  const limitNames = [
    "maximumJSONBytes", "maximumYAMLBytes", "maximumAliases", "maximumDepth",
    "maximumTreeDepth", "autoExpandDepth", "maximumRenderedNodes", "autoExpandBudgetMilliseconds",
    "parseBudgetMilliseconds", "valueDisplayCharacters", "keyDisplayCharacters",
  ];

  // Every limit must be there as a whole number of at least 1, or nothing is drawn.
  function readLimits(input) {
    if (input === null || typeof input !== "object") return null;
    const limits = {};
    for (const name of limitNames) {
      const value = hasOwn(input, name) ? input[name] : undefined;
      if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 1) return null;
      limits[name] = value;
    }
    return limits;
  }

  const labelNames = [
    "itemCount", "itemCountOne", "showMore", "cycle", "expansionStopped", "tooComplex", "overCap",
    "invalidEncoding", "parseErrorAt", "parseError", "showSourceGuidance", "showSourceButton",
  ];

  function readLabels(input) {
    const labels = {};
    for (const name of labelNames) {
      const value = input !== null && typeof input === "object" && hasOwn(input, name) ? input[name] : undefined;
      labels[name] = typeof value === "string" ? value : "";
    }
    return labels;
  }

  let labels = readLabels(null);

  // Placeholders are filled by split/join with numbers or fixed words, never evaluated.
  function fill(template, pairs) {
    let text = template;
    for (const [token, value] of pairs) text = text.split(token).join(value);
    return text;
  }

  const count = (n) => numberToString.call(n);

  // MARK: DOM helpers (fixed tags and class names; text only through textContent)

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function button(className, text) {
    const node = element("button", className, text);
    node.setAttribute("type", "button");
    return node;
  }

  const root = () => document.getElementById("data");

  // What each button on the page does, by the button itself.
  let toggles = new WeakMap();
  let moreChildren = new WeakMap();
  let moreText = new WeakMap();
  let sourceButtons = new WeakSet();

  function freshView() {
    const view = root();
    view.replaceChildren();
    toggles = new WeakMap();
    moreChildren = new WeakMap();
    moreText = new WeakMap();
    sourceButtons = new WeakSet();
    return view;
  }

  // A state the tree can't be drawn in: what happened, and the way to the source view.
  function message(view, text, className) {
    const box = element("div", "data-message");
    box.append(element("p", className, text));
    box.append(element("p", "data-guidance", labels.showSourceGuidance));
    if (!showsSourceButton) {
      view.append(box);
      return;
    }
    const show = button("data-source-button", labels.showSourceButton);
    sourceButtons.add(show);
    box.append(show);
    view.append(box);
  }

  // MARK: Parsing

  // A js-yaml failure: one of the two limits (too complex), a position, or neither.
  function yamlFailure(error) {
    if (error instanceof RangeError) return { tooComplex: true };
    if (!(error instanceof yaml.YAMLException)) return {};
    const reason = error.reason;
    if (typeof reason === "string"
        && (reason.startsWith("nesting exceeded maxDepth") || reason.startsWith("aliases exceeded maxAliases"))) {
      return { tooComplex: true };
    }
    const mark = error.mark;
    if (mark !== null && typeof mark === "object"
        && Number.isSafeInteger(mark.line) && Number.isSafeInteger(mark.column) && mark.line >= 0 && mark.column >= 0) {
      return { line: mark.line + 1, column: mark.column + 1 };
    }
    return {};
  }

  function failed(format, failure) {
    if (failure.tooComplex) return { outcome: "tooComplex" };
    if (failure.line !== undefined) return { outcome: "parseError", format, line: failure.line, column: failure.column };
    return { outcome: "parseError", format };
  }

  // Whether `text` takes at most `limit` bytes as UTF-8, counted without encoding it.
  function utf8AtMost(text, limit) {
    let bytes = 0;
    for (let i = 0; i < text.length; i++) {
      const unit = text.charCodeAt(i);
      if (unit < 0x80) bytes += 1;
      else if (unit < 0x800) bytes += 2;
      else if (unit >= 0xD800 && unit <= 0xDBFF && i + 1 < text.length) {
        const next = text.charCodeAt(i + 1);
        if (next >= 0xDC00 && next <= 0xDFFF) { bytes += 4; i++; } else bytes += 3;
      } else bytes += 3;
      if (bytes > limit) return false;
    }
    return true;
  }

  // js-yaml counts the document itself as a level of maxDepth, so maxDepth N admits N - 1 nested
  // nodes (a scalar is a node). One more makes it admit exactly maximumDepth, as the tree does.
  const parserDepth = (limits) => limits.maximumDepth + 1;

  function parseJSON(text, limits) {
    const body = text.charCodeAt(0) === 0xFEFF ? text.slice(1) : text;
    try {
      return { outcome: "ok", roots: [JSON.parse(body)] };
    } catch (error) {
      if (error instanceof RangeError) return { outcome: "tooComplex" };
    }
    // JSON.parse gives no position. js-yaml's scanner finds one, on input small enough for it;
    // if it accepts the text (YAML takes things JSON doesn't), there is no position to give, and
    // what it parsed is never shown.
    if (!utf8AtMost(text, limits.maximumYAMLBytes)) return { outcome: "parseError", format: "JSON" };
    try {
      yaml.parseEvents(text, { maxDepth: parserDepth(limits) });
    } catch (error) {
      return failed("JSON", yamlFailure(error));
    }
    return { outcome: "parseError", format: "JSON" };
  }

  function parseYAML(text, limits) {
    const start = now();
    let events;
    try {
      events = yaml.parseEvents(text, { maxDepth: parserDepth(limits) });
    } catch (error) {
      return failed("YAML", yamlFailure(error));
    }
    if (!isArray(events) || now() - start > limits.parseBudgetMilliseconds) {
      return { outcome: "tooComplex" };
    }
    let documents;
    try {
      documents = yaml.constructFromEvents(events, {
        source: text, schema: yaml.CORE_SCHEMA, json: false, maxAliases: limits.maximumAliases,
      });
    } catch (error) {
      return failed("YAML", yamlFailure(error));
    }
    if (!isArray(documents) || now() - start > limits.parseBudgetMilliseconds) return { outcome: "tooComplex" };
    return { outcome: "ok", roots: documents };
  }

  // MARK: Values

  const isContainer = (value) => value !== null && typeof value === "object";

  // Object keys, computed once per object however many aliases lead to it.
  let keyCache = new WeakMap();
  function childKeys(value) {
    let keys = keyCache.get(value);
    if (keys === undefined) {
      keys = keysOf(value);
      keyCache.set(value, keys);
    }
    return keys;
  }

  function childCount(value) {
    return isArray(value) ? value.length : childKeys(value).length;
  }

  function childAt(value, index) {
    if (isArray(value)) return value[index];
    const key = childKeys(value)[index];
    return hasOwn(value, key) ? value[key] : null;
  }

  // Whether any path from a root nests deeper than `maximum` nodes (a scalar counts as a level,
  // as in js-yaml's maxDepth). Each distinct container is walked once and its height kept, so
  // aliases to one container cost one walk; an alias back to an ancestor (a cycle) ends the path.
  function nestsDeeperThan(roots, maximum) {
    const heights = new Map();
    const onPath = new Set();
    for (const top of roots) {
      if (!isContainer(top)) continue;
      if (maximum < 1) return true;
      const stack = [{ value: top, index: 0, count: childCount(top), height: 0 }];
      onPath.add(top);
      while (stack.length > 0) {
        const frame = stack[stack.length - 1];
        if (frame.index < frame.count) {
          const child = childAt(frame.value, frame.index++);
          if (!isContainer(child)) {
            if (stack.length + 1 > maximum) return true;
            if (frame.height < 1) frame.height = 1;
            continue;
          }
          if (onPath.has(child)) continue;
          const known = heights.get(child);
          if (known !== undefined) {
            if (stack.length + known > maximum) return true;
            if (frame.height < known) frame.height = known;
            continue;
          }
          if (stack.length + 1 > maximum) return true;
          onPath.add(child);
          stack.push({ value: child, index: 0, count: childCount(child), height: 0 });
        } else {
          stack.pop();
          onPath.delete(frame.value);
          const height = frame.height + 1;
          heights.set(frame.value, height);
          if (stack.length > 0 && stack[stack.length - 1].height < height) stack[stack.length - 1].height = height;
        }
      }
    }
    return false;
  }

  // The same question for valid JSON, read off its text: no value is visited and nothing is
  // allocated. A string (key or value) or other scalar inside d containers is at depth d + 1; a
  // key is never deeper than its value, so counting keys changes nothing.
  function jsonTextNestsDeeperThan(text, maximum) {
    let depth = 0;
    for (let i = 0; i < text.length; i++) {
      const unit = text.charCodeAt(i);
      if (unit === 0x22) {
        if (depth + 1 > maximum) return true;
        for (i++; i < text.length; i++) {
          const inner = text.charCodeAt(i);
          if (inner === 0x5C) i++;
          else if (inner === 0x22) break;
        }
      } else if (unit === 0x5B || unit === 0x7B) {
        depth++;
        if (depth > maximum) return true;
      } else if (unit === 0x5D || unit === 0x7D) {
        depth--;
      } else if (unit !== 0x20 && unit !== 0x0A && unit !== 0x0D && unit !== 0x09 && unit !== 0x2C && unit !== 0x3A
                 && unit !== 0xFEFF && depth + 1 > maximum) {
        return true;
      }
    }
    return false;
  }

  // MARK: The tree

  // One drawn row per visit (an alias drawn twice is two visits). A budget is spent one row at
  // a time; once it is out of rows or time, nothing more is drawn in that pass.
  function makeBudget(limits) {
    return { left: limits.maximumRenderedNodes, deadline: now() + limits.autoExpandBudgetMilliseconds, stopped: false };
  }

  function spend(budget) {
    if (budget.left <= 0 || now() > budget.deadline) {
      budget.stopped = true;
      return false;
    }
    budget.left -= 1;
    return true;
  }

  // Truncated to `limit` UTF-16 units, never between the halves of a surrogate pair.
  function cut(text, limit) {
    if (text.length <= limit) return text;
    let end = limit;
    const unit = text.charCodeAt(end - 1);
    if (unit >= 0xD800 && unit <= 0xDBFF) end -= 1;
    return text.slice(0, end);
  }

  function keyNode(key, limits) {
    if (key === null) return null;
    const shown = typeof key === "number" ? count(key) : cut(key, limits.keyDisplayCharacters);
    const text = typeof key === "string" && shown.length < key.length ? shown + "…" : shown;
    return element("span", typeof key === "number" ? "data-key data-index" : "data-key", text);
  }

  function appendKey(row, key, limits) {
    const node = keyNode(key, limits);
    if (node === null) return;
    row.append(node);
    row.append(element("span", "data-punct", ": "));
  }

  function scalarNode(value, limits) {
    switch (typeof value) {
      case "string": {
        const span = element("span", "data-value data-string");
        const state = { span, text: value, shown: 0, limit: limits.valueDisplayCharacters, button: null };
        showMoreText(state);
        return state;
      }
      case "number":
        return { span: element("span", "data-value data-number", count(value)) };
      case "boolean":
        return { span: element("span", "data-value data-bool", value ? "true" : "false") };
      default:
        return { span: element("span", "data-value data-null", "null") };
    }
  }

  // Shows the next chunk of a long string, with a button for the rest.
  function showMoreText(state) {
    const next = state.shown === 0 ? cut(state.text, state.limit) : cut(state.text, state.shown + state.limit);
    state.shown = next.length;
    const rest = state.text.length - state.shown;
    state.span.textContent = "\"" + next + (rest > 0 ? "…" : "\"");
    if (rest > 0) {
      if (state.button === null) {
        state.button = button("data-more", "");
        moreText.set(state.button, state);
      }
      state.button.textContent = fill(labels.showMore, [["{n}", count(rest)]]);
    } else if (state.button !== null) {
      state.button.remove();
      state.button = null;
    }
  }

  function isAncestor(record, value) {
    for (let at = record; at !== null; at = at.parent) {
      if (at.value === value) return true;
    }
    return false;
  }

  // Draws one row for `value` under `parent` (a container's record), or nothing when the budget
  // is spent. Returns the new container's record when it is one that may be opened.
  function drawRow(parent, key, value, limits, budget, documentRow) {
    if (!spend(budget)) return undefined;
    const row = element("div", documentRow ? "data-node data-document" : "data-node");
    if (isContainer(value) && isAncestor(parent, value)) {
      row.classList.add("data-leaf");
      appendKey(row, key, limits);
      row.append(element("span", "data-cycle", labels.cycle));
      parent.group.append(row);
      return null;
    }
    if (!isContainer(value)) {
      row.classList.add("data-leaf");
      appendKey(row, key, limits);
      const scalar = scalarNode(value, limits);
      row.append(scalar.span);
      if (scalar.button) row.append(scalar.button);
      parent.group.append(row);
      return null;
    }
    const list = isArray(value);
    const toggle = button("data-toggle");
    toggle.setAttribute("aria-expanded", "false");
    appendKey(toggle, key, limits);
    const items = childCount(value);
    toggle.append(element("span", "data-punct", list ? "[" : "{"));
    const size = items === 1 ? labels.itemCountOne : labels.itemCount;
    toggle.append(element("span", "data-count", fill(size, [["{n}", count(items)]])));
    toggle.append(element("span", "data-punct", list ? "]" : "}"));
    const group = element("div", "data-children");
    group.setAttribute("role", "group");
    group.hidden = true;
    row.append(toggle, group);
    parent.group.append(row);
    const record = { value, parent, depth: parent.depth + 1, group, toggle, next: 0, count: items, opened: false, more: null };
    toggles.set(toggle, record);
    return record;
  }

  // Draws `record`'s next children, as many as the budget allows, with a button for the rest.
  // Containers among them are queued for opening when `queue` is given (the automatic pass).
  function openChildren(record, limits, budget, queue) {
    record.opened = true;
    if (record.toggle) {
      record.toggle.setAttribute("aria-expanded", "true");
      record.group.hidden = false;
    }
    if (record.more !== null) {
      record.more.remove();
      record.more = null;
    }
    while (record.next < record.count) {
      const index = record.next;
      const key = record.documents ? null : (isArray(record.value) ? index : childKeys(record.value)[index]);
      const drawn = drawRow(record, key, childAt(record.value, index), limits, budget, record.documents);
      if (drawn === undefined) break;
      record.next += 1;
      if (drawn !== null && queue !== null && drawn.depth <= limits.autoExpandDepth) queue.push(drawn);
    }
    if (record.next < record.count) {
      record.more = button("data-more", fill(labels.showMore, [["{n}", count(record.count - record.next)]]));
      moreChildren.set(record.more, record);
      record.group.append(record.more);
    }
  }

  // The automatic pass: levels 1 to autoExpandDepth open, breadth first, until the budget is out.
  function drawTree(view, roots, limits) {
    const panel = element("div", "data-panel");
    view.append(panel);
    const top = { value: roots, parent: null, depth: 0, group: panel, toggle: null, next: 0, count: roots.length, opened: false, more: null, documents: true };
    const budget = makeBudget(limits);
    const queue = [top];
    for (let head = 0; head < queue.length && !budget.stopped; head++) {
      openChildren(queue[head], limits, budget, queue);
    }
    if (!budget.stopped) return "rendered";
    view.insertBefore(element("p", "data-notice", labels.expansionStopped), panel);
    return "capped";
  }

  let currentLimits = null;
  // Whether states without a tree offer the source-view button (a host without one says no).
  let showsSourceButton = true;

  // On the document: this script runs in <head>, before #data exists.
  document.addEventListener("click", (event) => {
    try {
      const target = event.target instanceof Element ? event.target.closest("button") : null;
      if (target === null || currentLimits === null) return;
      if (sourceButtons.has(target)) {
        postShowSource();
        return;
      }
      const text = moreText.get(target);
      if (text !== undefined) {
        showMoreText(text);
        return;
      }
      const rest = moreChildren.get(target);
      if (rest !== undefined) {
        openChildren(rest, currentLimits, makeBudget(currentLimits), null);
        return;
      }
      const record = toggles.get(target);
      if (record === undefined) return;
      if (!record.opened) {
        // One level per click, under the same budget as the automatic pass.
        openChildren(record, currentLimits, makeBudget(currentLimits), null);
      } else {
        const open = record.group.hidden;
        record.group.hidden = !open;
        record.toggle.setAttribute("aria-expanded", open ? "true" : "false");
      }
    } catch (_) {}
  });

  // MARK: Updates

  let latestSequence = -Infinity;
  let shownOutcome = null;

  function draw(kind, state, text, limits) {
    const view = freshView();
    keyCache = new WeakMap();
    const format = kind === "json" ? "JSON" : "YAML";
    if (state === "overCap") {
      const cap = kind === "json" ? limits.maximumJSONBytes : limits.maximumYAMLBytes;
      // In MB (MiB) rounded down to two decimals, so "larger than {size} MB" stays true:
      // 16 MiB is 16, 384 KiB is 0.37.
      const size = count(Math.floor(cap / 10485.76) / 100);
      message(view, fill(labels.overCap, [["{size}", size]]), "data-message-text");
      return "overCap";
    }
    if (state === "invalidEncoding") {
      message(view, labels.invalidEncoding, "data-error");
      return "invalidEncoding";
    }
    if (state !== "ok" || typeof text !== "string") return "failed";
    const parsed = kind === "json" ? parseJSON(text, limits) : parseYAML(text, limits);
    if (parsed.outcome === "parseError") {
      if (parsed.line !== undefined) {
        message(view, fill(labels.parseErrorAt, [["{format}", format], ["{line}", count(parsed.line)], ["{column}", count(parsed.column)]]), "data-error");
        postErrorPosition(parsed.line, parsed.column);
      } else {
        message(view, fill(labels.parseError, [["{format}", format]]), "data-error");
      }
      return "parseError";
    }
    const tooDeep = parsed.outcome === "ok" && (kind === "json"
      ? jsonTextNestsDeeperThan(text, limits.maximumTreeDepth)
      : nestsDeeperThan(parsed.roots, limits.maximumTreeDepth));
    if (parsed.outcome !== "ok" || tooDeep) {
      message(view, labels.tooComplex, "data-message-text");
      return "tooComplex";
    }
    return drawTree(view, parsed.roots, limits);
  }

  // The page function's whole contract: one fixed string back, whatever happens. An update
  // older than the one on screen changes nothing and answers with what is on screen.
  function render(input) {
    try {
      if (input === null || typeof input !== "object") return "failed";
      const sequence = input.sequence;
      if (typeof sequence !== "number" || !Number.isFinite(sequence)) return "failed";
      if (sequence < latestSequence) return shownOutcome === null ? "failed" : shownOutcome;
      const limits = readLimits(input.limits);
      const kind = input.kind === "json" || input.kind === "yaml" ? input.kind : null;
      if (limits === null || kind === null) return "failed";
      latestSequence = sequence;
      labels = readLabels(input.labels);
      showsSourceButton = input.showsSourceButton !== false;
      currentLimits = limits;
      let outcome;
      try {
        outcome = draw(kind, input.state, input.text, limits);
      } catch (error) {
        // Anything unforeseen (a stack overflow included) is shown as too complex.
        const view = freshView();
        message(view, labels.tooComplex, "data-message-text");
        outcome = error instanceof RangeError ? "tooComplex" : "failed";
      }
      shownOutcome = outcome;
      return outcome;
    } catch (_) {
      return "failed";
    }
  }

  Object.defineProperty(window, "MarsDawnData", {
    value: Object.freeze({ render, setThemes }),
    writable: false,
    configurable: false,
    enumerable: false,
  });
})();
