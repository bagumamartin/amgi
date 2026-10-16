// EPUBReaderInjection.js
//
// Injected at document-end into every EPUB chapter the paginated reader
// loads. Responsibilities:
//   1. Wrap text-node runs in <span class="amgi-tok"> tokens. Tokenisation
//      uses three regimes:
//        - Hangul runs (consecutive Hangul codepoints = one token)
//        - CJK + kana per-codepoint
//        - Latin word boundaries (\b\w+\b)
//   2. Paginate: <body> is a multi-column container of page-wide columns and
//      a page is shown by translating it (rev 4, "Pagination" below). The
//      page shown, the page count and the words on screen are reported to
//      the host; nothing scrolls.
//   3. After each page change (debounced 250ms), report pageIndex +
//      progressFraction (pageIndex / max(pageCount-1, 1)).
//   4. On click of a tokenised span, capture the surrounding sentence
//      (split on [.!?。！？\n]) and post it to the host.
//   5. Report the live selection (wordSelection) so the host can add the
//      reader's actions to its selection menu.

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
  //   1. `cfi`    - character offset into the chapter text (see below)
  //   2. `path`   - child-index path from <body> to the anchored element
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

  // ---------------------------------------------------------------------------
  // Chapter text: the one basis every stored offset uses
  //
  // `cfi`, mark ranges, and anchor resolution all count characters along the
  // same string: every text node under <body>, in document order, minus
  // scripts, styles, and the page furniture this script adds. Tokenisation
  // only splits text nodes, it never adds or drops characters, so offsets
  // survive a re-tokenisation. They used to disagree — anchors counted from
  // their own paragraph, marks counted word tokens only, and resolution
  // counted raw text — so a mark landed wherever its paragraph offset fell
  // in the chapter, not on the words it was made from.
  // ---------------------------------------------------------------------------

  var SKIP_TEXT_TAGS = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1 };

  function isChapterTextNode(node) {
    var p = node.parentNode;
    while (p && p !== document.body) {
      if (p.nodeType === 1) {
        if (SKIP_TEXT_TAGS[p.tagName]) { return false; }
        if (p.hasAttribute('data-amgi-running-head')
            || p.hasAttribute('data-amgi-page-number')) { return false; }
      }
      p = p.parentNode;
    }
    return !!p;
  }

  function chapterTextNodes() {
    var nodes = [];
    if (!document.body) { return nodes; }
    var walker = document.createTreeWalker(
      document.body,
      NodeFilter.SHOW_TEXT,
      {
        acceptNode: function (node) {
          return isChapterTextNode(node)
            ? NodeFilter.FILTER_ACCEPT
            : NodeFilter.FILTER_REJECT;
        }
      }
    );
    var n;
    while ((n = walker.nextNode())) { nodes.push(n); }
    return nodes;
  }

  function chapterText(nodes) {
    var parts = [];
    for (var i = 0; i < nodes.length; i++) { parts.push(nodes[i].nodeValue || ''); }
    return parts.join('');
  }

  // Chapter offset of a DOM position, or null when it is not chapter text.
  function chapterOffsetOf(node, offsetInNode, nodes) {
    nodes = nodes || chapterTextNodes();
    if (node && node.nodeType !== 3) {
      // An element position: the first chapter text at or after it.
      var child = node.childNodes && node.childNodes[offsetInNode || 0];
      var target = child || node;
      var consumedBefore = 0;
      for (var k = 0; k < nodes.length; k++) {
        var rel = target.compareDocumentPosition(nodes[k]);
        if (nodes[k] === target
            || (rel & Node.DOCUMENT_POSITION_FOLLOWING)
            || (rel & Node.DOCUMENT_POSITION_CONTAINED_BY)) {
          return consumedBefore;
        }
        consumedBefore += (nodes[k].nodeValue || '').length;
      }
      return null;
    }
    var consumed = 0;
    for (var i = 0; i < nodes.length; i++) {
      if (nodes[i] === node) {
        return consumed + Math.min(offsetInNode || 0, (node.nodeValue || '').length);
      }
      consumed += (nodes[i].nodeValue || '').length;
    }
    return null;
  }

  // The text node and in-node offset at a chapter offset.
  function chapterPositionAt(offset, nodes) {
    nodes = nodes || chapterTextNodes();
    var consumed = 0;
    for (var i = 0; i < nodes.length; i++) {
      var len = (nodes[i].nodeValue || '').length;
      if (offset < consumed + len) {
        return { node: nodes[i], offset: offset - consumed };
      }
      consumed += len;
    }
    if (nodes.length) {
      var last = nodes[nodes.length - 1];
      return { node: last, offset: (last.nodeValue || '').length };
    }
    return null;
  }

  function rangeForChapterOffsets(start, end, nodes) {
    nodes = nodes || chapterTextNodes();
    var from = chapterPositionAt(start, nodes);
    var to = chapterPositionAt(Math.max(start, end), nodes);
    if (!from || !to) { return null; }
    var range = document.createRange();
    try {
      range.setStart(from.node, from.offset);
      range.setEnd(to.node, to.offset);
      return range;
    } catch (e) {
      return null;
    }
  }

  function collapseSpace(text) {
    return (text || '').replace(/\s+/g, ' ').trim();
  }

  // Finds `needle` in the chapter text, tolerant of whitespace differences
  // (a selection's string and the DOM's text nodes disagree on line breaks).
  // With `near`, the occurrence closest to that offset wins, so a repeated
  // word resolves to the copy the mark was made on; otherwise the first.
  // Returns {start, end} in chapter offsets, or null.
  function findInChapter(needle, near, text) {
    var wanted = collapseSpace(needle);
    if (!wanted) { return null; }
    if (typeof text !== 'string') { text = chapterText(chapterTextNodes()); }

    // Collapse the haystack the same way, remembering where each collapsed
    // character came from so a hit maps back to real offsets.
    var collapsed = '';
    var origin = [];
    var inSpace = false;
    for (var i = 0; i < text.length; i++) {
      var ch = text[i];
      if (/\s/.test(ch)) {
        if (!inSpace && collapsed.length) {
          collapsed += ' ';
          origin.push(i);
        }
        inSpace = true;
      } else {
        collapsed += ch;
        origin.push(i);
        inSpace = false;
      }
    }

    var best = -1;
    var bestDistance = Infinity;
    var at = collapsed.indexOf(wanted);
    while (at >= 0) {
      if (typeof near !== 'number') { best = at; break; }
      var distance = Math.abs(origin[at] - near);
      if (distance < bestDistance) { best = at; bestDistance = distance; }
      at = collapsed.indexOf(wanted, at + 1);
    }
    if (best < 0) { return null; }
    var lastIndex = best + wanted.length - 1;
    return { start: origin[best], end: origin[lastIndex] + 1 };
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

  // `precise`, when given, is the exact DOM position the anchor starts at
  // (a selection's start); otherwise the start of `span`.
  function buildAnchor(span, container, tokenText, precise) {
    var full = container.innerText || '';
    var anchor = {
      cfi: null,
      path: null,
      quote: '',
      contextBefore: null,
      contextAfter: null
    };

    var located = precise || textNodeAndOffsetFor(span);
    if (located) {
      var element = located.node.nodeType === 3 ? located.node.parentNode : located.node;
      var path = elementPath(document.body, element);
      if (path) { anchor.path = path; }
      var cfi = chapterOffsetOf(located.node, located.offset);
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
      // A press on the selection is the start of a drag, not a tap on a word:
      // no tint, or it would end up in the drag preview.
      var selection = window.getSelection();
      if (selection && !selection.isCollapsed && selection.containsNode(node, true)) { return; }
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

    // The selection as the host's message carries it, or null when there is
    // none. Also exposed as `__amgiDescribeSelection`, so a menu item can read
    // the live selection instead of a report that trails the handles.
    function describeSelection() {
      var selection = window.getSelection();
      if (!selection || selection.isCollapsed || selection.rangeCount === 0) {
        return null;
      }
      var text = (selection.toString() || '').trim();
      if (!text) { return null; }

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
        (token && token.getAttribute('data-token')) || text,
        { node: range.startContainer, offset: range.startOffset }
      );
      // `text` is trimmed; move the offset past the whitespace it dropped so
      // `cfi` points at the first selected character.
      var raw = selection.toString() || '';
      if (typeof anchor.cfi === 'number') {
        anchor.cfi += raw.length - raw.replace(/^\s+/, '').length;
      }

      // Where the selection sits on screen, so the host can tell a touch on
      // the selection (lifting it to drag, or moving a handle) from a page
      // swipe. Viewport coordinates, which are the web view's own.
      var rects = [];
      var list = range.getClientRects();
      for (var i = 0; i < list.length && rects.length < 40; i++) {
        var r = list[i];
        if (r.width > 0 && r.height > 0) { rects.push([r.left, r.top, r.width, r.height]); }
      }

      return {
        token: token
          ? (token.getAttribute('data-token') || token.textContent || '')
          : text,
        selection: text,
        rects: rects,
        sentence: anchor.quote || text,
        anchor: {
          cfi: anchor.cfi,
          path: anchor.path,
          quote: anchor.quote || text,
          contextBefore: anchor.contextBefore,
          contextAfter: anchor.contextAfter
        }
      };
    }
    window.__amgiDescribeSelection = describeSelection;

    function report() {
      timer = null;
      var message = describeSelection();
      if (!message) {
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
      if (message.selection === lastText) { return; }
      lastText = message.selection;
      try {
        window.webkit.messageHandlers.wordSelection.postMessage(message);
      } catch (e) { /* host detached */ }
    }

    document.addEventListener('selectionchange', function () {
      if (timer) { window.clearTimeout(timer); }
      // 120ms: long enough to coalesce a drag, short enough that the menu
      // still feels attached to the gesture.
      timer = window.setTimeout(report, 120);
    });

    // A right-click must not wait out the debounce: macOS builds the context
    // menu from the last report, and the right-click may itself have just
    // selected the word under the pointer.
    document.addEventListener('contextmenu', function () {
      if (timer) { window.clearTimeout(timer); }
      report();
    }, true);
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
      // A finished card: a quiet dotted underline, so a page you have mined
      // shows it without looking highlighted.
      '.amgi-tok[data-amgi-mark="card"] {',
      '  text-decoration: underline dotted var(--amgi-card, #3b82f6);',
      '  text-decoration-thickness: 2px;',
      '  text-underline-offset: 3px;',
      '}',
      // A draft waiting for its other side: hollow and dashed, the visual
      // "something started here" that a tap resumes.
      '.amgi-tok[data-amgi-mark="cardDraft"] {',
      '  border-bottom: 1.5px dashed var(--amgi-card, #3b82f6);',
      '  background: rgba(59, 130, 246, 0.08);',
      '  border-radius: 2px;',
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

    var nodes = chapterTextNodes();
    var text = chapterText(nodes);

    var applied = 0;
    for (var i = 0; i < marks.length; i++) {
      var mark = marks[i];
      if (!mark) { continue; }
      var start = typeof mark.start === 'number' ? mark.start : null;
      var end = typeof mark.end === 'number' ? mark.end : null;
      var kind = (mark.kind === 'bookmark' || mark.kind === 'card' || mark.kind === 'cardDraft')
        ? mark.kind
        : 'highlight';

      // With the marked text in hand, trust the offset only if the text is
      // really there. Anchors stored before offsets were chapter-wide counted
      // from their own paragraph; this re-finds them by text, near where the
      // offset points, instead of painting the wrong words.
      var markText = typeof mark.text === 'string' ? mark.text : '';
      if (markText && collapseSpace(markText)) {
        if (start !== null) { end = start + markText.length; }
        var here = start !== null
          ? collapseSpace(text.substring(start, end))
          : '';
        if (here !== collapseSpace(markText)) {
          var found = findInChapter(markText, start, text);
          if (found) {
            start = found.start;
            end = found.end;
          }
        }
      }
      if (start === null || end === null || end <= start) { continue; }

      var consumed = 0;
      var matched = false;
      for (var t = 0; t < nodes.length; t++) {
        var node = nodes[t];
        var nodeStart = consumed;
        var nodeEnd = consumed + (node.nodeValue || '').length;
        consumed = nodeEnd;
        if (nodeEnd <= start || nodeStart >= end) { continue; }
        var token = node.parentNode;
        if (!token || !token.classList || !token.classList.contains('amgi-tok')) { continue; }
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
    var index = firstTokenOnOrAfter(state.page);
    if (index >= tokenList.length) { return null; }
    var token = tokenList[index];
    if (pageOfRect(token.getBoundingClientRect()) !== state.page) { return null; }
    var text = token.getAttribute('data-token') || token.textContent || '';
    var anchor = buildAnchor(token, token.closest('p, li, div, section, body') || document.body, text);
    return {
      pageIndex: state.page,
      cfi: anchor.cfi,
      path: anchor.path,
      quote: anchor.quote || text,
      contextBefore: anchor.contextBefore,
      contextAfter: anchor.contextAfter
    };
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
      // The page carries its number alone, as a printed book does; "X of Y"
      // is the chrome's job when it is up.
      number.textContent = String(state.page);
    }
  };

  // Host-callable: the reader's chrome is up (or not). Its title row and
  // page count replace the page's running head and number in place.
  window.__amgiSetChromeVisible = function (visible) {
    document.documentElement.setAttribute('data-amgi-chrome', visible ? '1' : '0');
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
    var needle = collapseSpace(request.quote);
    if (!needle) { return null; }
    var nodes = chapterTextNodes();
    var found = findInChapter(needle, null, chapterText(nodes));
    if (!found) { return null; }

    var at = chapterPositionAt(found.start, nodes);
    var element = at && at.node.parentNode;
    if (!element) {
      return { cfi: found.start, path: null, quote: needle, contextBefore: null, contextAfter: null };
    }
    var token = element.closest ? element.closest('.amgi-tok') : null;
    var container = element.closest
      ? (element.closest('p, li, div, section, body') || document.body)
      : document.body;
    var built = buildAnchor(
      token || element,
      container,
      (token && token.getAttribute('data-token')) || needle,
      at
    );
    return {
      cfi: found.start,
      path: built.path,
      quote: needle,
      contextBefore: built.contextBefore,
      contextAfter: built.contextAfter
    };
  };

  // Host-callable: resolve a stored anchor back to a live range and scroll it
  // into view. Mirrors the native resolution order — exact offset, then DOM
  // path, then quote search — and returns the strategy that succeeded so the
  // caller can tell "restored exactly" from "restored by text search".
  window.__amgiResolveAnchor = function (anchor) {
    if (!anchor) { return null; }
    var body = document.body;

    var nodes = chapterTextNodes();
    var text = chapterText(nodes);

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

    var range = null;
    var strategy = 'none';
    // The offset is checked against the quote: an anchor stored before
    // offsets were chapter-wide counted from its own paragraph, and would
    // otherwise "resolve" exactly — to the wrong place.
    var quoted = anchor.quote ? findInChapter(anchor.quote, anchor.cfi, text) : null;
    if (typeof anchor.cfi === 'number' && anchor.cfi >= 0
        && (!quoted || (anchor.cfi >= quoted.start && anchor.cfi <= quoted.end))) {
      range = rangeForChapterOffsets(anchor.cfi, anchor.cfi + 1, nodes);
      if (range) { strategy = 'offset'; }
    }
    // A path is only trusted when the quote cannot be found: old anchors
    // stored it from their paragraph rather than from <body>, so it would
    // land on some other element just as confidently.
    if (!range && !quoted && anchor.path) {
      range = rangeForPath(anchor.path);
      if (range) { strategy = 'path'; }
    }
    if (!range && quoted) {
      range = rangeForChapterOffsets(quoted.start, quoted.end, nodes);
      if (range) { strategy = 'quote'; }
    }
    if (!range) { return null; }

    var rect = range.getBoundingClientRect();
    if (rect && rect.width > 0) {
      // Go to the page the match is on — always a whole page. This used to
      // centre the match on screen, which left the reader stranded between
      // two pages, half of each showing, after every resume or jump.
      state.count = measurePages();
      setPage(pageOfRect(rect));
      reportPageInfo();
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

  // ---------------------------------------------------------------------------
  // Pagination (rev 4): pages are a transform, never a scroll.
  //
  // <body> is the multi-column container: one page-wide column per page,
  // laid out side by side. Showing page N moves the whole body left by N page
  // widths with a CSS transform. Nothing scrolls — <html> clips — so there is
  // no scroll offset for UIKit and WebKit to disagree about, which is what
  // left the text on one page while the page counter said another.
  //
  // The page shown is `state.page`, set only by `showPage`. Every answer about
  // what is on screen is measured from the laid-out words themselves, so the
  // host can check that the page painted is the page it asked for.
  // ---------------------------------------------------------------------------

  // `anchor` is the first word on the page shown, taken when the page is
  // set — before any later re-flow — so a re-flow can return to it.
  var state = { page: 0, count: 1, anchor: 0 };
  var tokenList = document.getElementsByClassName('amgi-tok');

  function pageWidth() {
    return window.innerWidth || document.documentElement.clientWidth || 1;
  }

  // CSS sizes the page from these; they follow the viewport WebKit is using.
  function syncPageVars() {
    var r = document.documentElement;
    var w = window.innerWidth || r.clientWidth || 0;
    var h = window.innerHeight || r.clientHeight || 0;
    if (w > 0) r.style.setProperty('--page-width', w + 'px');
    if (h > 0) r.style.setProperty('--page-height', h + 'px');
  }

  function applyTransform() {
    if (!document.body) { return; }
    var x = -state.page * pageWidth();
    document.body.style.setProperty('transform', 'translate3d(' + x + 'px, 0, 0)', 'important');
  }

  // Which page a viewport rect is on, with the current transform undone.
  function pageOfRect(rect) {
    var w = pageWidth();
    return Math.max(0, Math.floor((rect.left + state.page * w + 1) / w));
  }

  // The number of pages: wherever the last laid-out content ends.
  function measurePages() {
    var body = document.body;
    if (!body) { return 1; }
    var range = document.createRange();
    range.selectNodeContents(body);
    var rect = range.getBoundingClientRect();
    var w = pageWidth();
    var right = rect.right + state.page * w;
    if (!(rect.width > 0) || !isFinite(right)) { return 1; }
    return Math.max(1, Math.floor((right - 1) / w) + 1);
  }

  // The first token at or after the start of page `page`, by binary search
  // over the tokens, which are laid out in reading order across the columns.
  function firstTokenOnOrAfter(page) {
    var lo = 0, hi = tokenList.length;
    while (lo < hi) {
      var mid = (lo + hi) >> 1;
      var rect = tokenList[mid].getBoundingClientRect();
      if (rect.width === 0 && rect.height === 0) {
        // Not laid out (inside display:none): skip forward linearly.
        var probe = mid + 1;
        while (probe < hi && tokenList[probe].getBoundingClientRect().width === 0) { probe++; }
        if (probe >= hi) { hi = mid; continue; }
        rect = tokenList[probe].getBoundingClientRect();
        if (pageOfRect(rect) < page) { lo = probe + 1; } else { hi = mid; }
        continue;
      }
      if (pageOfRect(rect) < page) { lo = mid + 1; } else { hi = mid; }
    }
    return lo;
  }

  // What is actually on screen: the page, the page count, and the indices of
  // the first and last word tokens painted on it.
  function pageState() {
    var first = firstTokenOnOrAfter(state.page);
    var next = firstTokenOnOrAfter(state.page + 1);
    var hasText = first < tokenList.length
      && pageOfRect(tokenList[first].getBoundingClientRect()) === state.page;
    return {
      page: state.page,
      count: state.count,
      first: hasText ? first : null,
      last: hasText ? next - 1 : null
    };
  }
  window.__amgiPageState = pageState;

  function reportPageInfo() {
    try {
      window.webkit.messageHandlers.pageInfo.postMessage({
        pageIndex: state.page,
        pageCount: state.count
      });
    } catch (e) { /* host detached */ }
    reportProgress();
    return { pageIndex: state.page, pageCount: state.count };
  }

  var progressTimer = null;
  function reportProgress() {
    if (progressTimer) clearTimeout(progressTimer);
    progressTimer = setTimeout(function () {
      var fraction = state.count <= 1
        ? 1
        : Math.min(1, Math.max(0, state.page / (state.count - 1)));
      try {
        window.webkit.messageHandlers.progress.postMessage({
          pageIndex: state.page,
          pageCount: state.count,
          progressFraction: fraction
        });
      } catch (e) { /* host detached */ }
    }, 250);
  }

  function setPage(page) {
    state.page = Math.max(0, Math.min(state.count - 1, page | 0));
    applyTransform();
    state.anchor = firstTokenOnOrAfter(state.page);
  }

  // Two frames — the transform committed, then painted. A page that is not
  // on screen gets no frames at all, so a timeout stands in for them rather
  // than leave the host waiting.
  function nextFrames() {
    return new Promise(function (resolve) {
      var done = false;
      function finish() { if (!done) { done = true; resolve(); } }
      requestAnimationFrame(function () { requestAnimationFrame(finish); });
      setTimeout(finish, 120);
    });
  }

  // Re-measures after the layout changed (size, typography, a late image or
  // font) and keeps the reader on the same words, not the same page number:
  // after a re-flow, page 12 is somewhere else.
  function relayout() {
    syncPageVars();
    var keep = state.anchor;
    state.count = measurePages();
    var target = state.page;
    if (keep < tokenList.length) {
      target = pageOfRect(tokenList[keep].getBoundingClientRect());
    }
    setPage(target);
    // The page the words landed on starts somewhere before them; the words
    // the reader was at stay the anchor, not that page's first word.
    state.anchor = keep;
    reportPageInfo();
    return state.count;
  }

  // Host-callable: shows a page and resolves once it has been painted, with
  // what is actually on screen. `-1` is the last page.
  window.__amgiShowPage = function (page) {
    state.count = measurePages();
    setPage(page < 0 ? state.count - 1 : page);
    reportProgress();
    return nextFrames().then(pageState);
  };

  // Host-callable, synchronous forms used by the Mac reader.
  window.__amgiScrollToPage = function (page) {
    state.count = measurePages();
    setPage(page < 0 ? state.count - 1 : page);
    reportPageInfo();
  };

  window.__amgiScrollToFraction = function (fraction) {
    state.count = measurePages();
    var last = Math.max(0, state.count - 1);
    var safe = Number.isFinite(fraction) ? Math.min(1, Math.max(0, fraction)) : 0;
    setPage(Math.round(safe * last));
    reportPageInfo();
  };

  window.__amgiRelayout = relayout;

  // Nothing may scroll: a selection dragged past the page edge would
  // otherwise scroll the clipped document and shift every page by a sliver.
  function installScrollGuard() {
    function reset() {
      var r = document.documentElement;
      if (r.scrollLeft !== 0) { r.scrollLeft = 0; }
      if (r.scrollTop !== 0) { r.scrollTop = 0; }
      if (document.body && (document.body.scrollLeft !== 0 || document.body.scrollTop !== 0)) {
        document.body.scrollLeft = 0;
        document.body.scrollTop = 0;
      }
    }
    document.addEventListener('scroll', reset, { passive: true, capture: true });
    window.addEventListener('scroll', reset, { passive: true });
  }

  // Late arrivals change the layout: images that load and fonts that finish.
  function installLayoutWatchers() {
    var pending = null;
    function soon() {
      if (pending) { clearTimeout(pending); }
      pending = setTimeout(function () { pending = null; relayout(); }, 60);
    }
    document.addEventListener('load', function (e) {
      if (e.target && e.target.tagName === 'IMG') { soon(); }
    }, true);
    if (document.fonts && document.fonts.ready) {
      document.fonts.ready.then(soon);
    }
    window.addEventListener('resize', function () {
      ensureViewportMeta();
      soon();
    });
  }

  function boot() {
    ensureViewportMeta();
    syncPageVars();
    ensureMarkStyle();
    ensureRunningFurniture();
    try { tokenise(document.body); } catch (e) { /* ignore */ }
    installTapHandler();
    installSelectionReporter();
    installScrollGuard();
    installLayoutWatchers();
    // Columns are not laid out synchronously on first paint in some books.
    relayout();
    setTimeout(relayout, 50);
    setTimeout(relayout, 300);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot, { once: true });
  } else {
    boot();
  }
})();
