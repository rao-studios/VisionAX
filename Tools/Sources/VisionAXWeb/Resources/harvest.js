//
//  harvest.js
//  VisionAXHarvestKit
//
//  WHAT: Walks the rendered DOM and reports every element that occupies pixels,
//        with the AX role a screen reader would give it.
//  IN:   WebCrawler.evaluateJavaScript, then window.__vxHarvest(options)
//  OUT:  a JSON string -> DOMElementRecord -> GroundTruthElement
//  PIN:  THIS IS GROUND TRUTH, so a wrong answer here is worse than a missing one.
//        Three rules follow from that:
//          * geometry comes from getBoundingClientRect INTERSECTED with every
//            scrollable ancestor's box. An element scrolled out of its container has a
//            rect the size of the element and pixels nowhere near it;
//          * an element hidden UNDER something else is reported visible:false rather
//            than dropped, because a detector may legitimately want the negative, and
//            because silently dropping it would inflate proposal recall;
//          * where WebKit and Chromium disagree about a role, the mapping follows
//            WebKit (Safari is what Mary reads) — role=tab is AXRadioButton with an
//            AXTabButton subrole, and <summary> is AXButton, neither of which is what
//            the HTML tag name suggests.
//        The one deliberate departure from AX: <img> with no alt is reported as
//        AXImage even though WebKit ignores it, because the pixels ARE an image and
//        the classifier is looking at pixels.
//        Fourth rule, learned from a recall table: AN ELEMENT'S RECT IS WHAT IT PAINTS,
//        not its layout box. A block <h2> is the full width of the page while its words
//        occupy a fifth of that, and an edge detector can only ever propose the words.
//        Scoring the model against the layout box measures something unachievable and
//        drags the label onto a box that contains mostly background. So an element that
//        paints nothing of its own takes the union of what its descendants paint.
//

(function () {
  "use strict";

  var INTERACTIVE = {
    AXButton: 1, AXLink: 1, AXTextField: 1, AXTextArea: 1, AXCheckBox: 1,
    AXRadioButton: 1, AXPopUpButton: 1, AXComboBox: 1, AXSlider: 1,
    AXMenuItem: 1, AXDisclosureTriangle: 1, AXTab: 1
  };

  // ARIA role -> [AX role, subrole]. null means "walk the children, emit nothing".
  var ARIA = {
    button: ["AXButton", null],
    link: ["AXLink", null],
    textbox: ["AXTextField", null],
    searchbox: ["AXTextField", "AXSearchField"],
    checkbox: ["AXCheckBox", null],
    switch: ["AXCheckBox", null],
    menuitemcheckbox: ["AXCheckBox", null],
    radio: ["AXRadioButton", null],
    menuitemradio: ["AXRadioButton", null],
    combobox: ["AXComboBox", null],
    listbox: ["AXList", null],
    slider: ["AXSlider", null],
    // WebKit and Chromium both expose an ARIA tab as a radio button with a tab
    // subrole; AXTab is the native NSTabView role and does not appear in web content.
    tab: ["AXRadioButton", "AXTabButton"],
    menuitem: ["AXMenuItem", null],
    img: ["AXImage", null],
    image: ["AXImage", null],
    heading: ["AXHeading", null],
    list: ["AXList", null],
    table: ["AXTable", null],
    grid: ["AXTable", null],
    row: ["AXRow", null],
    cell: ["AXCell", null],
    gridcell: ["AXCell", null],
    columnheader: ["AXCell", null],
    rowheader: ["AXCell", null],
    toolbar: ["AXToolbar", null],
    navigation: ["AXGroup", null], main: ["AXGroup", null], banner: ["AXGroup", null],
    contentinfo: ["AXGroup", null], complementary: ["AXGroup", null],
    region: ["AXGroup", null], form: ["AXGroup", null], search: ["AXGroup", null],
    dialog: ["AXGroup", null], alertdialog: ["AXGroup", null], group: ["AXGroup", null],
    tablist: ["AXGroup", null], menu: ["AXGroup", null], menubar: ["AXGroup", null],
    presentation: null, none: null, separator: null, progressbar: null,
    spinbutton: null, option: null, listitem: null
  };

  var INPUT_ROLE = {
    button: ["AXButton", null], submit: ["AXButton", null],
    reset: ["AXButton", null], image: ["AXButton", null],
    checkbox: ["AXCheckBox", null], radio: ["AXRadioButton", null],
    range: ["AXSlider", null],
    text: ["AXTextField", null], email: ["AXTextField", null],
    url: ["AXTextField", null], tel: ["AXTextField", null],
    number: ["AXTextField", null],
    search: ["AXTextField", "AXSearchField"],
    password: ["AXTextField", "AXSecureTextField"],
    hidden: null,
    // Engines disagree on these; emitted but never used as a label.
    file: "ignore", color: "ignore", date: "ignore", time: "ignore",
    "datetime-local": "ignore", month: "ignore", week: "ignore"
  };

  var TAG_ROLE = {
    button: ["AXButton", null],
    textarea: ["AXTextArea", null],
    img: ["AXImage", null], picture: ["AXImage", null],
    canvas: ["AXImage", null], video: ["AXImage", null],
    h1: ["AXHeading", null], h2: ["AXHeading", null], h3: ["AXHeading", null],
    h4: ["AXHeading", null], h5: ["AXHeading", null], h6: ["AXHeading", null],
    ul: ["AXList", null], ol: ["AXList", null], menu: ["AXList", null],
    table: ["AXTable", null],
    tr: ["AXRow", null],
    td: ["AXCell", null], th: ["AXCell", null],
    // WebKit exposes a summary as a button. Chromium says AXDisclosureTriangle;
    // that role reaches the dataset from native app harvesting instead.
    summary: ["AXButton", null],
    details: ["AXGroup", null], fieldset: ["AXGroup", null], form: ["AXGroup", null],
    nav: ["AXGroup", null], main: ["AXGroup", null], header: ["AXGroup", null],
    footer: ["AXGroup", null], aside: ["AXGroup", null], section: ["AXGroup", null],
    article: ["AXGroup", null], dialog: ["AXGroup", null]
  };

  var SKIP = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1, HEAD: 1, META: 1, LINK: 1, TITLE: 1 };

  function intersect(a, b) {
    var x0 = Math.max(a.x0, b.x0), y0 = Math.max(a.y0, b.y0);
    var x1 = Math.min(a.x1, b.x1), y1 = Math.min(a.y1, b.y1);
    return { x0: x0, y0: y0, x1: Math.max(x0, x1), y1: Math.max(y0, y1) };
  }

  function fromRect(r) {
    return { x0: r.left, y0: r.top, x1: r.right, y1: r.bottom };
  }

  function isScrollable(style, el) {
    var oy = style.overflowY, ox = style.overflowX;
    var scrollY = (oy === "auto" || oy === "scroll") && el.scrollHeight > el.clientHeight + 1;
    var scrollX = (ox === "auto" || ox === "scroll") && el.scrollWidth > el.clientWidth + 1;
    return scrollY || scrollX;
  }

  function clips(style) {
    var v = ["visible"];
    return v.indexOf(style.overflow) < 0 || v.indexOf(style.overflowX) < 0 ||
           v.indexOf(style.overflowY) < 0;
  }

  function parseColorAlpha(value) {
    if (!value || value === "transparent") return 0;
    var m = value.match(/rgba?\(([^)]+)\)/);
    if (!m) return 1;
    var parts = m[1].split(",");
    return parts.length >= 4 ? parseFloat(parts[3]) : 1;
  }

  /// A plain div counts as a group only when it PAINTS something — a border or a
  /// background of its own. An invisible layout div has no box on screen, and calling
  /// it a group would teach the model to hallucinate containers around whitespace.
  function paintsABox(style) {
    if (parseColorAlpha(style.backgroundColor) > 0.05) return true;
    if (style.backgroundImage && style.backgroundImage !== "none") return true;
    var sides = ["borderTopWidth", "borderRightWidth", "borderBottomWidth", "borderLeftWidth"];
    for (var i = 0; i < sides.length; i++) {
      if (parseFloat(style[sides[i]]) >= 1 && parseColorAlpha(style.borderTopColor) > 0.05) {
        return true;
      }
    }
    return false;
  }

  var REPLACED = {
    img: 1, svg: 1, canvas: 1, video: 1, picture: 1, iframe: 1,
    input: 1, button: 1, select: 1, textarea: 1, progress: 1, meter: 1
  };

  /// Whether this element puts ink on the screen at its own box. A control does even
  /// with no CSS of its own — the platform draws it.
  function paintsOwnBox(el, style, tag) {
    if (REPLACED[tag]) return true;
    return paintsABox(style);
  }

  function roleFor(el, style) {
    var explicit = (el.getAttribute("role") || "").trim().split(/\s+/)[0].toLowerCase();
    if (explicit && Object.prototype.hasOwnProperty.call(ARIA, explicit)) {
      var mapped = ARIA[explicit];
      if (mapped === null) return null;
      if (explicit === "textbox" && el.getAttribute("aria-multiline") === "true") {
        return ["AXTextArea", null];
      }
      return mapped;
    }

    // Before the tag table: a <div> that scrolls is a scroll area whatever it is made of.
    if (isScrollable(style, el)) return ["AXScrollArea", null];

    var tag = el.tagName.toLowerCase();
    if (tag === "a") return el.hasAttribute("href") ? ["AXLink", null] : null;
    if (tag === "input") {
      var type = (el.getAttribute("type") || "text").toLowerCase();
      var byType = Object.prototype.hasOwnProperty.call(INPUT_ROLE, type)
        ? INPUT_ROLE[type] : ["AXTextField", null];
      return byType;
    }
    if (tag === "select") {
      return el.hasAttribute("multiple") ? ["AXList", null] : ["AXPopUpButton", null];
    }
    if (tag === "svg") {
      var box = el.getBoundingClientRect();
      if (box.width < 8 || box.height < 8) return null;
      if (el.closest("a,button,[role=button],[role=link]")) return null;
      return ["AXImage", null];
    }
    if (Object.prototype.hasOwnProperty.call(TAG_ROLE, tag)) return TAG_ROLE[tag];
    // A LIST ITEM THAT HOLDS SOMETHING TO PRESS IS A ROW. Emitting nothing for these is
    // why the corpus carried 1,736 rows and the detector proposed none of them: a search
    // result, a mail message and a menu entry are all this shape, and the model was
    // never shown one. A bare bullet in a paragraph is still nothing.
    if (tag === "li" || el.getAttribute("role") === "listitem" ||
        el.getAttribute("role") === "option") {
      var box = el.getBoundingClientRect();
      if (box.width < 24 || box.height < 24) return null;
      return el.querySelector("a,button,input,[role=button],[role=link]")
        ? ["AXRow", null]
        : null;
    }

    if ((tag === "div" || tag === "span" || tag === "section") && paintsABox(style)) {
      var r = el.getBoundingClientRect();
      if (r.width >= 24 && r.height >= 24) return ["AXGroup", null];
    }
    return null;
  }

  /// A FIELD'S PLACEHOLDER IS THE NAME A PERSON READS. It is what the label ladder's
  /// adjacent rung is guessing at from outside the box, and it was never in the corpus,
  /// so an empty search field carried no words at all.
  function placeholderOf(el) {
    if (!el.getAttribute) return null;
    var value = el.getAttribute("placeholder");
    return value ? String(value).replace(/\s+/g, " ").trim().slice(0, 120) : null;
  }

  /// What the control is currently doing, where it says so.
  function stateOf(el) {
    var state = [];
    if (!el.getAttribute) return state;
    if (el.checked === true || el.getAttribute("aria-checked") === "true") state.push("checked");
    if (el.selected === true || el.getAttribute("aria-selected") === "true") state.push("selected");
    if (el.getAttribute("aria-expanded") === "true" || el.open === true) state.push("expanded");
    if (el.getAttribute("aria-pressed") === "true") state.push("pressed");
    return state;
  }

  function textOf(el, cap) {
    var value = el.getAttribute("aria-label") || el.getAttribute("alt") ||
                el.getAttribute("title") || el.value ||
                (el.getAttribute && el.getAttribute("placeholder")) || el.innerText || "";
    value = String(value).replace(/\s+/g, " ").trim();
    return value.length > cap ? value.slice(0, cap) : value;
  }

  function hitsAt(el, x, y) {
    var stack = document.elementsFromPoint(x, y);
    if (!stack || stack.length === 0) return false;
    var top = stack[0];
    if (top === el) return true;
    if (el.contains && el.contains(top)) return true;
    if (top.contains && top.contains(el)) return true;
    return false;
  }

  /// Five samples rather than one: a centre point lands on a child's gap often enough
  /// that a single probe calls plainly visible elements hidden.
  function isVisiblyOnTop(el, clip) {
    var w = clip.x1 - clip.x0, h = clip.y1 - clip.y0;
    if (w <= 0 || h <= 0) return false;
    var points = [
      [clip.x0 + w * 0.5, clip.y0 + h * 0.5],
      [clip.x0 + w * 0.25, clip.y0 + h * 0.25],
      [clip.x0 + w * 0.75, clip.y0 + h * 0.25],
      [clip.x0 + w * 0.25, clip.y0 + h * 0.75],
      [clip.x0 + w * 0.75, clip.y0 + h * 0.75]
    ];
    var hits = 0;
    for (var i = 0; i < points.length; i++) {
      if (hitsAt(el, points[i][0], points[i][1])) hits += 1;
    }
    return hits >= 3;
  }

  window.__vxHarvest = function (options) {
    options = options || {};
    var maxElements = options.maxElements || 5000;
    var maxWalk = options.maxWalk || 50000;
    var maxText = options.maxText || 200;
    var dpr = window.devicePixelRatio || 1;

    var records = [];
    var walked = 0;
    var truncated = false;

    var viewportClip = { x0: 0, y0: 0, x1: window.innerWidth, y1: window.innerHeight };

    function add(el, role, subrole, ownRect, paints, depth, parent, isTextRun, text) {
      if (records.length >= maxElements) { truncated = true; return -1; }
      var index = records.length;
      records.push({
        el: el, role: role, subrole: subrole || null, text: text || null,
        own: ownRect, paints: paints, depth: depth, parent: parent,
        children: [], isTextRun: isTextRun, resolved: null
      });
      if (parent >= 0) records[parent].children.push(index);
      return index;
    }

    function textRuns(el, clip, depth, parent) {
      for (var node = el.firstChild; node; node = node.nextSibling) {
        if (node.nodeType !== 3) continue;
        if (!node.nodeValue || !node.nodeValue.trim()) continue;
        var range = document.createRange();
        range.selectNodeContents(node);
        var rects = range.getClientRects();
        if (!rects || rects.length === 0) continue;
        // The union of the run's line boxes: one <p> is one AXStaticText in AX, even
        // when it wraps across five lines.
        var union = null;
        for (var i = 0; i < rects.length; i++) {
          var r = fromRect(rects[i]);
          union = union === null ? r : {
            x0: Math.min(union.x0, r.x0), y0: Math.min(union.y0, r.y0),
            x1: Math.max(union.x1, r.x1), y1: Math.max(union.y1, r.y1)
          };
        }
        var clipped = intersect(union, clip);
        if (clipped.x1 - clipped.x0 < 1 || clipped.y1 - clipped.y0 < 1) continue;
        var text = node.nodeValue.replace(/\s+/g, " ").trim();
        // Text always paints: its rect IS its ink.
        add(el, "AXStaticText", null, clipped, true, depth + 1, parent, true,
            text.length > maxText ? text.slice(0, maxText) : text);
      }
    }

    function collect(el, clip, depth, parent) {
      if (walked >= maxWalk) { truncated = true; return; }
      walked += 1;
      if (!el.tagName || SKIP[el.tagName.toUpperCase()]) return;

      var style = window.getComputedStyle(el);
      if (style.display === "none") return;
      if (parseFloat(style.opacity) < 0.05) return;

      var hidden = style.visibility === "hidden";
      var tag = el.tagName.toLowerCase();
      var box = fromRect(el.getBoundingClientRect());
      var clipped = intersect(box, clip);
      var hasArea = (clipped.x1 - clipped.x0) >= 1 && (clipped.y1 - clipped.y0) >= 1;

      var myIndex = parent;
      if (!hidden && hasArea) {
        var mapped = roleFor(el, style);
        if (mapped === "ignore") {
          add(el, "AXGroup", null, clipped, true, depth, parent, false, textOf(el, maxText));
        } else if (mapped) {
          var emitted = add(el, mapped[0], mapped[1], clipped,
                            paintsOwnBox(el, style, tag), depth, parent, false,
                            textOf(el, maxText));
          if (emitted >= 0) myIndex = emitted;
        }
        textRuns(el, clipped, depth, myIndex);
      }

      var childClip = clips(style) ? intersect(box, clip) : clip;
      var children = el.children;
      for (var i = 0; i < children.length; i++) {
        collect(children[i], childClip, depth + 1, myIndex);
      }
      if (el.shadowRoot) {
        var shadow = el.shadowRoot.children;
        for (var j = 0; j < shadow.length; j++) {
          collect(shadow[j], childClip, depth + 1, myIndex);
        }
      }
    }

    /// An element that paints its own box keeps it; one that does not takes the union
    /// of everything its descendants paint. Post-order, so a child is always resolved
    /// before the parent that needs it.
    function resolve(index) {
      var record = records[index];
      if (record.resolved) return record.resolved;
      // Guard against a cycle that cannot happen in a tree but would hang if it did.
      record.resolved = record.own;
      if (record.paints) return record.resolved;

      var union = null;
      for (var i = 0; i < record.children.length; i++) {
        var child = resolve(record.children[i]);
        if (!child || child.x1 - child.x0 < 1 || child.y1 - child.y0 < 1) continue;
        union = union === null ? child : {
          x0: Math.min(union.x0, child.x0), y0: Math.min(union.y0, child.y0),
          x1: Math.max(union.x1, child.x1), y1: Math.max(union.y1, child.y1)
        };
      }
      if (union !== null) {
        // Never larger than the element's own box: a child may overflow, but the
        // element is still only where it is.
        record.resolved = intersect(union, record.own);
        record.paintsNothingItself = true;
      } else {
        // Paints nothing and contains nothing painted: it is not on screen in any
        // sense a detector could find.
        record.empty = true;
      }
      return record.resolved;
    }

    var elements = [];

    collect(document.body, viewportClip, 0, -1);
    for (var r = 0; r < records.length; r++) resolve(r);

    // Emit in collection order, so an index means the same thing before and after.
    for (var e = 0; e < records.length; e++) {
      var rec = records[e];
      var rect = rec.resolved || rec.own;
      var w = rect.x1 - rect.x0, h = rect.y1 - rect.y0;
      var el = rec.el;
      elements.push({
        index: e,
        role: rec.role,
        subrole: rec.subrole,
        text: rec.text,
        rect: {
          x: Math.round(rect.x0 * dpr), y: Math.round(rect.y0 * dpr),
          width: Math.round(w * dpr), height: Math.round(h * dpr)
        },
        interactive: !!INTERACTIVE[rec.role],
        enabled: !(el.disabled || el.getAttribute("aria-disabled") === "true"),
        depth: rec.depth,
        parent: rec.parent,
        // An element with no ink of its own and nothing painted inside it is not
        // something any detector could propose.
        visible: !rec.empty && w >= 1 && h >= 1 && isVisiblyOnTop(el, rect),
        tag: rec.isTextRun ? "#text" : (el.tagName ? el.tagName.toLowerCase() : null),
        ariaRole: el.getAttribute ? (el.getAttribute("role") || null) : null,
        inputType: el.getAttribute ? (el.getAttribute("type") || null) : null,
        href: el.getAttribute ? (el.getAttribute("href") || null) : null,
        placeholder: placeholderOf(el),
        state: stateOf(el)
      });
    }

    return JSON.stringify({
      dpr: dpr,
      viewport: { width: window.innerWidth, height: window.innerHeight },
      scrollX: window.scrollX, scrollY: window.scrollY,
      documentHeight: document.documentElement.scrollHeight,
      url: location.href,
      title: document.title,
      elements: elements,
      stats: { walked: walked, emitted: elements.length, truncated: truncated }
    });
  };
})();
