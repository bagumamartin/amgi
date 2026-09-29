// EPUBReaderInjection.js
//
// Injected at document-end into every EPUB chapter the paginated reader
// loads. Responsibilities:
//   1. Wrap text-node runs in <span class="amgi-tok"> tokens. Tokenisation
//      uses three regimes:
//        - Hangul runs (consecutive Hangul codepoints = one token)
//        - CJK + kana per-codepoint
//        - Latin word boundaries (\b\w+\b)
//   2. Report page count = Math.ceil(documentElement.scrollWidth /
//      window.innerWidth). <html> is the multi-column container and the
//      WKWebView's scrollable root; we never mutate body.style.width.
//   3. On scroll-end (debounced 250ms), report current pageIndex +
//      progressFraction (pageIndex / max(pageCount-1, 1)).
//   4. On click of a tokenised span, capture the surrounding sentence
//      (split on [.!?。！？\n]) and post a wordTap message.
//
// Posts to three message handlers: pageInfo, progress, wordTap.

(function () {
  'use strict';

  function isHangul(cp) {
    return (cp >= 0xAC00 && cp <= 0xD7AF) ||
           (cp >= 0x1100 && cp <= 0x11FF);
  }
  function isCJK(cp) {
    return (cp >= 0x3040 && cp <= 0x309F) || // Hiragana
           (cp >= 0x30A0 && cp <= 0x30FF) || // Katakana
           (cp >= 0x3400 && cp <= 0x9FFF);   // CJK Unified Ideographs
  }
  function isWordChar(ch) {
    return /[A-Za-z0-9_À-ɏЀ-ӿ]/.test(ch);
  }

  function segmentText(text) {
    const out = [];
    let buf = '';
    let bufKind = null;

    function flush() {
      if (buf.length === 0) return;
      out.push({ text: buf, isToken: bufKind === 'latin' || bufKind === 'hangul' });
      buf = '';
      bufKind = null;
    }

    for (let i = 0; i < text.length; ) {
      const cp = text.codePointAt(i);
      const ch = String.fromCodePoint(cp);
      const step = ch.length;

      if (isHangul(cp)) {
        if (bufKind !== 'hangul') flush();
        bufKind = 'hangul';
        buf += ch;
      } else if (isCJK(cp)) {
        flush();
        out.push({ text: ch, isToken: true });
      } else if (isWordChar(ch)) {
        if (bufKind !== 'latin') flush();
        bufKind = 'latin';
        buf += ch;
      } else {
        if (bufKind !== 'other') flush();
        bufKind = 'other';
        buf += ch;
      }
      i += step;
    }
    flush();
    return out;
  }

  function tokenise(root) {
    const skipTags = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1 };
    const walker = document.createTreeWalker(
      root,
      NodeFilter.SHOW_TEXT,
      {
        acceptNode(node) {
          let p = node.parentNode;
          while (p && p !== root) {
            if (p.nodeType === 1) {
              if (skipTags[p.tagName]) return NodeFilter.FILTER_REJECT;
              if (p.classList && p.classList.contains('amgi-tok')) return NodeFilter.FILTER_REJECT;
            }
            p = p.parentNode;
          }
          if (!node.nodeValue || !node.nodeValue.trim()) return NodeFilter.FILTER_REJECT;
          return NodeFilter.FILTER_ACCEPT;
        }
      }
    );

    const queue = [];
    let n;
    while ((n = walker.nextNode())) queue.push(n);

    for (const textNode of queue) {
      const segments = segmentText(textNode.nodeValue);
      if (segments.length === 1 && !segments[0].isToken) continue;
      const frag = document.createDocumentFragment();
      for (const seg of segments) {
        if (seg.isToken) {
          const span = document.createElement('span');
          span.className = 'amgi-tok';
          span.setAttribute('data-token', seg.text);
          span.textContent = seg.text;
          frag.appendChild(span);
        } else {
          frag.appendChild(document.createTextNode(seg.text));
        }
      }
      textNode.parentNode.replaceChild(frag, textNode);
    }
  }

  // ---------------------------------------------------------------------------
  // Source anchors
  //
  // A tap has to produce something that still points at the same words after
  // a re-extraction, a different device, or a typography change. A scroll
  // fraction cannot: it is a rendering, not a location. So each tap captures
  // three independent handles to the same text, and the native side resolves
  // them in order of precision:
  //
  //   1. `cfi`    - character offset in the container's rendered text
  //   2. `path`   - child-index path from the container to the text node
  //   3. `quote`  - the text itself plus surrounding context
  //
  // Tokenisation replaces text nodes with <span class="amgi-tok"> runs, which
  // is why `path` walks *element* children only: the element structure is
  // stable across tokenisation passes, the text-node indices are not.
  // ---------------------------------------------------------------------------

  var CONTEXT_CHARS = 32;
  var MAX_QUOTE_CHARS = 600;

  function isElement(node) {
    return !!node && node.nodeType === 1;
  }

  // Child-index path from `root` down to `node`, counting element children
  // only. Returns null when `node` is not a descendant of `root`.
  function elementPath(root, node) {
    var path = [];
    var current = node;
    while (current && current !== root) {
      var parent = current.parentNode;
      if (!parent) { return null; }
      var index = -1;
      for (var i = 0; i < parent.childNodes.length; i++) {
        if (parent.childNodes[i] === current) { index = i; break; }
      }
      if (index < 0) { return null; }
      // Count only element siblings so tokenisation-induced text nodes do
      // not shift the recorded path.
      var elementIndex = 0;
      for (var j = 0; j < index; j++) {
        if (isElement(parent.childNodes[j])) { elementIndex++; }
      }
      path.unshift(elementIndex);
      current = parent;
    }
    return current === root ? path : null;
  }

  // Character offset of `node`'s text within the container's rendered text,
  // measured the same way the reader measures progress (innerText), so the
  // two agree.
  function characterOffsetIn(container, node, offsetInNode) {
    var range = document.createRange();
    try {
      range.selectNodeContents(container);
      range.setEnd(node, offsetInNode);
      return range.toString().length;
    } catch (e) {
      return null;
    } finally {
      range.detach && range.detach();
    }
  }

  function textNodeAndOffsetFor(span) {
    // The tapped token is a leaf span, but be defensive: walk down to the
    // text node that actually contains the glyphs.
    var node = span;
    var offset = 0;
    while (node && node.nodeType !== Node.TEXT_NODE) {
      var found = null;
      for (var i = 0; i < (node.childNodes ? node.childNodes.length : 0); i++) {
        var child = node.childNodes[i];
        if (child.nodeType === Node.TEXT_NODE) { found = child; break; }
      }
      if (!found) { return null; }
      node = found;
    }
    return node ? { node: node, offset: offset } : null;
  }

  function buildAnchor(span, container, tokenText) {
    var full = container.innerText || '';
    var anchor = {
      cfi: null,
      path: null,
      quote: '',
      contextBefore: null,
      contextAfter: null
    };

    var located = textNodeAndOffsetFor(span);
    if (located) {
      var path = elementPath(container, located.node);
      if (path) { anchor.path = path; }
      var cfi = characterOffsetIn(container, located.node, located.offset);
      if (cfi !== null && cfi >= 0) { anchor.cfi = cfi; }
    }

    // Slice the quote out of the container text by document order of the
    // token spans. Using token order rather than `indexOf` keeps repeated
    // words pointing at the occurrence that was actually tapped.
    var tokens = Array.prototype.slice.call(
      container.querySelectorAll('.amgi-tok')
    );
    var ordinal = tokens.indexOf(span);
    var searchFrom = 0;
    var idx = -1;
    for (var i = 0; i <= Math.max(ordinal, 0); i++) {
      idx = full.indexOf(tokenText, searchFrom);
      if (idx < 0) { idx = full.indexOf(tokenText); break; }
      searchFrom = idx + tokenText.length;
    }
    if (idx < 0) { return anchor; }

    // Grow out to sentence boundaries for the human-readable quote.
    var TERMINATORS = /[.!?。！？\n]/;
    var start = idx;
    while (start > 0 && !TERMINATORS.test(full[start - 1])) {
      start--;
      if (idx - start > MAX_QUOTE_CHARS) { break; }
    }
    var end = idx + tokenText.length;
    while (end < full.length && !TERMINATORS.test(full[end])) {
      end++;
      if (end - idx > MAX_QUOTE_CHARS) { break; }
    }
    anchor.quote = full.substring(start, end + 1).trim();
    anchor.contextBefore = full.substring(Math.max(0, start - CONTEXT_CHARS), start).trim();
    anchor.contextAfter = full.substring(end + 1, end + 1 + CONTEXT_CHARS).trim();
    return anchor;
  }

  // `sentenceAround` used to back the click-to-lookup path. Lookup is now
  // driven by a selection, which goes through `installSelectionReporter`
  // and builds its own anchor, so this helper has no callers left.

  // ---------------------------------------------------------------------------
  // Selection, and what a tap is allowed to do
  //
  // A reader tap is not a lookup trigger. Apple Books does not open a
  // dictionary on a single tap, and neither should we: it turns ordinary
  // reading into a minefield where every word you brush past throws a sheet.
  //
  // The division of labour, matching the platform:
  //
  //   tap          press tint only, then nothing. The tap ends.
  //   long press   WebKit's own word selection + callout (Copy, Look Up,
  //                Share, Translate). We do not intercept it — the platform
  //                already does it better than we would, including the
  //                drag handles and the magnetic word snap.
  //   selection    when a non-collapsed selection exists we tell the host
  //                what was selected, so it can add the Anki actions to
  //                the system menu. The system menu is ours to extend, not
  //                to replace.
  // ---------------------------------------------------------------------------

  var PRESS_ATTR = 'data-amgi-pressed';

  function pressTintOn(target) {
    if (target && target.setAttribute) {
      target.setAttribute(PRESS_ATTR, '1');
    }
  }

  function pressTintOff(target) {
    if (target && target.removeAttribute) {
      target.removeAttribute(PRESS_ATTR);
    }
  }

  function tokenUnder(target) {
    var node = target;
    while (node && node.nodeType === 1) {
      if (node.classList && node.classList.contains('amgi-tok')) { return node; }
      node = node.parentNode;
    }
    return null;
  }

  // Press feedback only. Deliberately does not post anything: a tap that
  // opens a dictionary is the behaviour we are removing.
  function installTapHandler() {
    var pressed = null;

    function release() {
      if (!pressed) { return; }
      // Hold the tint briefly so a quick tap is still visible. The timeout
      // is cleared on the next press, so a fast double-tap cannot leave a
      // stale tint behind.
      var node = pressed;
      pressed = null;
      window.clearTimeout(release.timer);
      release.timer = window.setTimeout(function () {
        pressTintOff(node);
      }, 140);
    }

    document.addEventListener('touchstart', function (e) {
      var node = tokenUnder(e.target);
      if (!node) { return; }
      window.clearTimeout(release.timer);
      pressed = node;
      pressTintOn(node);
    }, { passive: true, capture: true });

    document.addEventListener('touchend', function (e) {
      pressTintOff(tokenUnder(e.target));
      release();
    }, { passive: true, capture: true });

    document.addEventListener('touchcancel', release, { passive: true, capture: true });

    // Mouse, for macOS and for iPad with a trackpad.
    document.addEventListener('mousedown', function (e) {
      var node = tokenUnder(e.target);
      if (!node) { return; }
      window.clearTimeout(release.timer);
      pressed = node;
      pressTintOn(node);
    }, { passive: true, capture: true });

    document.addEventListener('mouseup', function (e) {
      pressTintOff(tokenUnder(e.target));
      release();
    }, { passive: true, capture: true });

    // A drag (selection or scroll) must not leave a tint on the word the
    // finger happened to land on.
    document.addEventListener('touchmove', function (e) {
      if (pressed) {
        pressTintOff(pressed);
        pressed = null;
      }
    }, { passive: true, capture: true });

    // Swallow the click on a token. WebKit would otherwise use it to
    // collapse a selection we just made.
    document.addEventListener('click', function (e) {
      if (tokenUnder(e.target)) { e.stopPropagation(); }
    }, true);
  }

  // Reports a live selection to the host so it can extend the system menu
  // with the Anki actions. Debounced: WebKit fires `selectionchange` for
  // every caret move while the handles are dragged.
  function installSelectionReporter() {
    var timer = null;
    var lastText = '';

    function report() {
      timer = null;
      var selection = window.getSelection();
      if (!selection || selection.isCollapsed || selection.rangeCount === 0) {
        // Report the clearing too. The host needs to know a selection is
        // *gone* so a swipe begun right after is read as a page turn rather
        // than as the tail of a text selection.
        if (lastText) {
          lastText = '';
          try {
            window.webkit.messageHandlers.wordSelection.postMessage({
              token: '',
              selection: '',
              sentence: '',
              anchor: null
            });
          } catch (e) { /* host detached */ }
        }
        return;
      }
      var text = (selection.toString() || '').trim();
      if (!text || text === lastText) { return; }
      lastText = text;

      var range = selection.getRangeAt(0);
      var node = range.startContainer;
      var span = node.nodeType === 1 ? node : node.parentNode;
      var token = span && span.closest
        ? span.closest('.amgi-tok')
        : null;
      var container = span && span.closest
        ? span.closest('p, li, div, section, body')
        : document.body;
      container = container || document.body;

      var anchor = buildAnchor(
        token || span || container,
        container,
        (token && token.getAttribute('data-token')) || text
      );

      try {
        window.webkit.messageHandlers.wordSelection.postMessage({
          token: token
            ? (token.getAttribute('data-token') || token.textContent || '')
            : text,
          selection: text,
          sentence: anchor.quote || text,
          anchor: {
            cfi: anchor.cfi,
            path: anchor.path,
            quote: anchor.quote || text,
            contextBefore: anchor.contextBefore,
            contextAfter: anchor.contextAfter
          }
        });
      } catch (e) { /* host detached */ }
    }

    document.addEventListener('selectionchange', function () {
      if (timer) { window.clearTimeout(timer); }
      // 120ms: long enough to coalesce a drag, short enough that the menu
      // still feels attached to the gesture.
      timer = window.setTimeout(report, 120);
    });
  }

  // ---------------------------------------------------------------------------
  // Highlights and bookmarks
  //
  // Marks are applied as data attributes on the token spans rather than as
  // wrapper elements, so a re-tokenisation pass cannot nest marks inside
  // marks. `data-amgi-mark` holds the kind and `data-amgi-mark-id` the
  // annotation id, which is what lets native code remove exactly one mark
  // without a full re-render.
  // ---------------------------------------------------------------------------

  var MARK_STYLE_ID = '__amgi_marks_style';

  function ensureMarkStyle() {
    if (document.getElementById(MARK_STYLE_ID)) { return; }
    var style = document.createElement('style');
    style.id = MARK_STYLE_ID;
    style.textContent = [
      '.amgi-tok[data-amgi-mark="highlight"] {',
      '  background: var(--amgi-highlight, rgba(255, 214, 102, 0.45));',
      '  border-radius: 2px;',
      '  box-shadow: 0 1px 0 rgba(0, 0, 0, 0.12);',
      '}',
      '.amgi-tok[data-amgi-mark="bookmark"] {',
      '  border-bottom: 2px solid var(--amgi-bookmark, #c8811f);',
      '}',
      '.amgi-tok[data-amgi-mark] { cursor: default; }'
    ].join('\n');
    (document.head || document.documentElement).appendChild(style);
  }

  function clearMarks() {
    var marked = document.querySelectorAll('.amgi-tok[data-amgi-mark]');
    for (var i = 0; i < marked.length; i++) {
      marked[i].removeAttribute('data-amgi-mark');
      marked[i].removeAttribute('data-amgi-mark-id');
      marked[i].removeAttribute('data-amgi-mark-color');
    }
  }

  // Returns the number of marks actually applied, so native can tell a real
  // hit from a range that no longer exists after a re-extraction.
  window.__amgiApplyMarks = function (marks) {
    ensureMarkStyle();
    clearMarks();
    if (!marks || !marks.length) { return 0; }
    var tokens = document.querySelectorAll('.amgi-tok');
    if (!tokens.length) { return 0; }

    var applied = 0;
    for (var i = 0; i < marks.length; i++) {
      var mark = marks[i];
      if (!mark) { continue; }
      var start = typeof mark.start === 'number' ? mark.start : null;
      var end = typeof mark.end === 'number' ? mark.end : null;
      var kind = mark.kind === 'bookmark' ? 'bookmark' : 'highlight';
      if (start === null || end === null || end <= start) { continue; }

      // Offsets are measured across the concatenated token text, which is the
      // same basis the reader measures progress with, so the two agree.
      var consumed = 0;
      var matched = false;
      for (var t = 0; t < tokens.length; t++) {
        var token = tokens[t];
        var tokenStart = consumed;
        var tokenEnd = consumed + (token.textContent || '').length;
        consumed = tokenEnd;
        if (tokenEnd <= start || tokenStart >= end) { continue; }
        token.setAttribute('data-amgi-mark', kind);
        if (mark.id) { token.setAttribute('data-amgi-mark-id', String(mark.id)); }
        if (mark.color) { token.setAttribute('data-amgi-mark-color', String(mark.color)); }
        matched = true;
      }
      if (matched) { applied++; }
    }
    return applied;
  };

  // Host-callable: an anchor for wherever the reader currently is.
  //
  // A bookmark has to be captured without the user selecting anything, and
  // the only thing the page knows is the current viewport. So this anchors to
  // the first token of the visible page — which is a real, quotable position
  // — rather than to a scroll fraction, which is a rendering that changes with
  // typography, rotation, and device.
  window.__amgiCurrentAnchor = function () {
    var w = window.innerWidth || document.documentElement.clientWidth || 1;
    var left = document.documentElement.scrollLeft || 0;
    var page = Math.round(left / w);

    var tokens = document.querySelectorAll('.amgi-tok');
    if (!tokens.length) { return null; }

    // Walk the tokens accumulating the same character offset the anchors use,
    // stopping at the first token that actually paints inside the viewport.
    var offset = 0;
    for (var i = 0; i < tokens.length; i++) {
      var token = tokens[i];
      var text = token.getAttribute('data-token') || token.textContent || '';
      var rect = token.getBoundingClientRect();
      var inView = rect.width > 0
        && rect.right > left + 1
        && rect.left < left + w - 1;
      if (inView) {
        var anchor = buildAnchor(token, token.closest('p, li, div, section, body') || document.body, text);
        return {
          pageIndex: page,
          cfi: anchor.cfi !== null ? anchor.cfi : offset,
          path: anchor.path,
          quote: anchor.quote || text,
          contextBefore: anchor.contextBefore,
          contextAfter: anchor.contextAfter
        };
      }
      offset += text.length;
    }
    return null;
  };

  // Reports which mark, if any, sits under a point, so a tap on an
  // already-marked token can offer to remove it rather than silently starting
  // a second highlight over the first.
  window.__amgiMarkAt = function (x, y) {
    var range = document.caretRangeFromPoint(x, y);
    if (!range || !range.startContainer) { return null; }
    var node = range.startContainer;
    while (node && node !== document.body) {
      if (node.classList && node.classList.contains('amgi-tok')
          && node.getAttribute('data-amgi-mark')) {
        return {
          id: node.getAttribute('data-amgi-mark-id') || null,
          kind: node.getAttribute('data-amgi-mark')
        };
      }
      node = node.parentNode;
    }
    return null;
  };

  // ---------------------------------------------------------------------------
  // Running head and page number
  //
  // These live inside the document rather than in the native chrome, because
  // they are part of the page: set in the book's own face, sitting on the
  // page's own margins. Drawn natively they float above the text as separate
  // app UI, which is the difference between a book and a viewer for a book.
  //
  // `position: fixed` inside the multicol container keeps them still while
  // the columns slide past, so there is one page number for the page being
  // read instead of one per column.
  // ---------------------------------------------------------------------------

  var RUNNING_HEAD_ID = '__amgi_running_head';
  var PAGE_NUMBER_ID = '__amgi_page_number';

  function ensureRunningFurniture() {
    var doc = document;

    if (!doc.getElementById(RUNNING_HEAD_ID)) {
      var head = doc.createElement('div');
      head.id = RUNNING_HEAD_ID;
      head.setAttribute('data-amgi-running-head', '1');
      // aria-hidden: the host announces page changes itself, so VoiceOver
      // must not read the same number twice.
      head.setAttribute('aria-hidden', 'true');
      doc.body.appendChild(head);
    }

    if (!doc.getElementById(PAGE_NUMBER_ID)) {
      var number = doc.createElement('div');
      number.id = PAGE_NUMBER_ID;
      number.setAttribute('data-amgi-page-number', '1');
      number.setAttribute('aria-hidden', 'true');
      doc.body.appendChild(number);
    }
  }

  /// @param {{page:number, total:number, isTotalExact:boolean, head:string}} state
  window.__amgiSetPageFurniture = function (state) {
    if (!state) { return; }
    ensureRunningFurniture();
    var head = document.getElementById(RUNNING_HEAD_ID);
    var number = document.getElementById(PAGE_NUMBER_ID);
    if (head && typeof state.head === 'string') {
      head.textContent = state.head;
    }
    if (number) {
      // Only the page number belongs on the page, exactly as a printed book:
      // "96", not "96 of 4024". The total is a library fact rather than a
      // page fact, and it moves as the index fills in, so showing it here
      // would make the page appear to change on its own.
      number.textContent = String(state.page);
    }
  };

  // Host-callable: build an anchor for a quoted string the host already has.
  //
  // The macOS selection menu runs after WebKit has reported the selection as
  // a plain string, by which point the Range is gone. This recovers an anchor
  // for that text so a mark made from a long press is re-anchorable rather
  // than a bare quote. Resolves by exact text, preferring the *first* match,
  // which is the same occurrence a reader would mean by re-reading the quote.
  window.__amgiAnchorForQuote = function (request) {
    if (!request || !request.quote) { return null; }
    var needle = (request.quote || '').replace(/\s+/g, ' ').trim();
    if (!needle) { return null; }
    var body = document.body;
    var full = (body.innerText || '').replace(/\s+/g, ' ');

    var at = full.indexOf(needle);
    if (at < 0) { return null; }

    // Walk the token spans accumulating length, the same basis `cfi` uses.
    var tokens = document.querySelectorAll('.amgi-tok');
    var consumed = 0;
    for (var i = 0; i < tokens.length; i++) {
      var token = tokens[i];
      var start = consumed;
      var end = consumed + (token.textContent || '').length;
      consumed = end;
      if (end > at) {
        var container = token.closest('p, li, div, section, body') || body;
        var built = buildAnchor(token, container, token.getAttribute('data-token') || '');
        return {
          cfi: built.cfi !== null ? built.cfi : start,
          path: built.path,
          quote: needle,
          contextBefore: built.contextBefore,
          contextAfter: built.contextAfter
        };
      }
    }
    return { cfi: at, path: null, quote: needle, contextBefore: null, contextAfter: null };
  };

  // Host-callable: resolve a stored anchor back to a live range and scroll it
  // into view. Mirrors the native resolution order — exact offset, then DOM
  // path, then quote search — and returns the strategy that succeeded so the
  // caller can tell "restored exactly" from "restored by text search".
  window.__amgiResolveAnchor = function (anchor) {
    if (!anchor) { return null; }
    var body = document.body;
    var full = body.innerText || '';

    function rangeForOffsets(start, length) {
      // Walk text nodes accumulating length until the anchor's span is found.
      var walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT, null);
      var consumed = 0, node;
      while ((node = walker.nextNode())) {
        var len = (node.nodeValue || '').length;
        if (start >= consumed && start + length <= consumed + len) {
          var range = document.createRange();
          range.setStart(node, start - consumed);
          range.setEnd(node, start - consumed + length);
          return range;
        }
        consumed += len;
      }
      return null;
    }

    function rangeForPath(path) {
      if (!path || !path.length) { return null; }
      var node = body;
      for (var i = 0; i < path.length; i++) {
        var wanted = path[i];
        var seen = 0;
        var next = null;
        for (var j = 0; j < node.childNodes.length; j++) {
          if (!isElement(node.childNodes[j])) { continue; }
          if (seen === wanted) { next = node.childNodes[j]; break; }
          seen++;
        }
        if (!next) { return null; }
        node = next;
      }
      var range = document.createRange();
      try {
        range.selectNodeContents(node);
        return range;
      } catch (e) {
        return null;
      }
    }

    function rangeForQuote(quote) {
      if (!quote) { return null; }
      var needle = (quote || '').replace(/\s+/g, ' ').trim();
      if (!needle) { return null; }
      var haystack = full.replace(/\s+/g, ' ');
      var at = haystack.indexOf(needle);
      if (at < 0) { return null; }
      return rangeForOffsets(at, needle.length) || rangeForOffsets(at, quote.length);
    }

    var range = null;
    var strategy = 'none';
    if (typeof anchor.cfi === 'number' && anchor.cfi >= 0) {
      range = rangeForOffsets(anchor.cfi, (anchor.quote || '').length);
      if (range) { strategy = 'offset'; }
    }
    if (!range && anchor.path) {
      range = rangeForPath(anchor.path);
      if (range) { strategy = 'path'; }
    }
    if (!range) {
      range = rangeForQuote(anchor.quote);
      if (range) { strategy = 'quote'; }
    }
    if (!range) { return null; }

    var rect = range.getBoundingClientRect();
    if (rect && rect.width > 0) {
      // Centre the match horizontally inside the current column so the
      // restored position matches what the reader measures as progress.
      var w = window.innerWidth || document.documentElement.clientWidth || 1;
      var page = Math.round((document.documentElement.scrollLeft || 0) / w);
      var target = document.documentElement.scrollLeft
        + rect.left
        - (w / 2)
        + page * w;
      var maxOffset = Math.max(
        0,
        (document.documentElement.scrollWidth || w) - w
      );
      document.documentElement.scrollLeft = Math.max(
        0,
        Math.min(target, maxOffset)
      );
    }
    return { strategy: strategy, quote: anchor.quote || '' };
  };

  // Ensures a viewport meta tag is present so WKWebView uses
  // device-width as the CSS viewport. Without this, .mobile content mode
  // defaults to a ~980px viewport which breaks our column-width math
  // (we'd get 2+ columns per physical page).
  function ensureViewportMeta() {
    var meta = document.querySelector('meta[name="viewport"][data-amgi="reader"]');
    if (meta) return;
    meta = document.createElement('meta');
    meta.setAttribute('name', 'viewport');
    meta.setAttribute('content', 'width=device-width, initial-scale=1.0');
    meta.setAttribute('data-amgi', 'reader');
    var head = document.head || document.documentElement;
    head.insertBefore(meta, head.firstChild);
  }

  // JS owns --page-width / --page-height. Reading from window directly
  // means we always agree with the CSS viewport the browser is using,
  // regardless of what Swift thinks the scrollView bounds are.
  function syncPageVars() {
    var r = document.documentElement;
    var w = window.innerWidth || r.clientWidth || 0;
    var h = window.innerHeight || r.clientHeight || 0;
    if (w > 0) r.style.setProperty('--page-width', w + 'px');
    if (h > 0) r.style.setProperty('--page-height', h + 'px');
  }

  // <html> is the scroll container after the CSS rebuild — read scroll
  // offsets and widths from documentElement, not window.
  function measurePages() {
    const w = window.innerWidth || document.documentElement.clientWidth || 1;
    const scrollW = document.documentElement.scrollWidth || w;
    return Math.max(1, Math.ceil(scrollW / w));
  }

  function reportPageInfo() {
    const w = window.innerWidth || document.documentElement.clientWidth || 1;
    const pageCount = measurePages();
    const scrollLeft = document.documentElement.scrollLeft || 0;
    const pageIndex = Math.round(scrollLeft / w);
    try {
      window.webkit.messageHandlers.pageInfo.postMessage({
        pageIndex: pageIndex,
        pageCount: pageCount
      });
    } catch (e) { /* host detached */ }
    return { pageIndex, pageCount };
  }

  let progressTimer = null;
  // Emits progress only. UIScrollView is the single source of truth for
  // pageIndex / pageCount during a swipe; emitting pageInfo from here too
  // causes the host page counter to flicker (1 → 4 → 2) mid-gesture.
  function reportProgress() {
    if (progressTimer) clearTimeout(progressTimer);
    progressTimer = setTimeout(function () {
      const w = window.innerWidth || document.documentElement.clientWidth || 1;
      const pageCount = measurePages();
      const scrollLeft = document.documentElement.scrollLeft || 0;
      const pageIndex = Math.round(scrollLeft / w);
      const fraction = pageCount <= 1
        ? 1
        : Math.min(1, Math.max(0, pageIndex / (pageCount - 1)));
      try {
        window.webkit.messageHandlers.progress.postMessage({
          pageIndex: pageIndex,
          pageCount: pageCount,
          progressFraction: fraction
        });
      } catch (e) { /* host detached */ }
    }, 250);
  }

  // NOTE: there is deliberately no second `installTapHandler` here. An
  // earlier revision defined the tap handler twice — once in the selection
  // section and once here — and because function declarations hoist, the
  // later one silently replaced the earlier one. A single definition is the
  // only way a change to tap behaviour can be trusted to take effect.

  function installScrollHandler() {
    // <html> is the scroll container; document-level scroll fires for it.
    document.addEventListener('scroll', reportProgress, { passive: true });
    window.addEventListener('scroll', reportProgress, { passive: true });
  }

  function boot() {
    ensureViewportMeta();
    syncPageVars();
    ensureMarkStyle();
    ensureRunningFurniture();
    try { tokenise(document.body); } catch (e) { /* ignore */ }
    installTapHandler();
    installSelectionReporter();
    installScrollHandler();
    window.addEventListener('resize', function () {
      ensureViewportMeta();
      syncPageVars();
    });
    // Allow layout to settle before measuring; columns aren't laid out
    // synchronously on first paint in some EPUBs.
    setTimeout(reportPageInfo, 50);
    setTimeout(reportPageInfo, 300);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot, { once: true });
  } else {
    boot();
  }

  // Host-callable API for restoring a saved progress position.
  window.__amgiScrollToFraction = function (fraction) {
    const w = window.innerWidth || document.documentElement.clientWidth || 1;
    const scrollW = document.documentElement.scrollWidth || w;
    const pageCount = measurePages();
    const lastPage = Math.max(0, pageCount - 1);
    const safeFraction = Number.isFinite(fraction)
      ? Math.min(1, Math.max(0, fraction))
      : 0;
    const pageIndex = Math.max(0, Math.min(
      lastPage,
      Math.round(safeFraction * lastPage)
    ));
    const maxOffset = Math.max(0, scrollW - w);
    const target = Math.min(maxOffset, pageIndex * w);
    document.documentElement.scrollLeft = target;
    reportPageInfo();
  };

  window.__amgiScrollToPage = function (pageIndex) {
    const w = window.innerWidth || document.documentElement.clientWidth || 1;
    document.documentElement.scrollLeft = pageIndex * w;
    reportPageInfo();
  };

  // Host-callable: re-measure column layout after the viewport has been
  // resized or CSS custom properties have changed. Returns the freshly
  // computed page count so Swift can re-snap synchronously after the
  // evaluateJavaScript callback fires.
  window.__amgiRelayout = function () {
    ensureViewportMeta();
    syncPageVars();
    var pageCount = 1;
    try { pageCount = measurePages(); } catch (e) { /* ignore */ }
    reportPageInfo();
    return pageCount;
  };
})();
