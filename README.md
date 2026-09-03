# VisionAX

An isolated OpenCV wrapper for macOS: a **C engine** that does the vision work, a
**Swift layer** that is the native interface onto it, a **bench app** to watch what
the engine sees, and a **harvester** that builds the training data for the classifier
that names what it finds.

Canny edge detection over a screenshot produces a top-down, traversable tree of
bounding boxes in **exactly the shape of Mary's AXTree** — the same `AXNodeSnapshot` /
`AXWindowSnapshot` value tree, so a detected tree and a walked accessibility tree are
interchangeable to a consumer. An on-device classifier then names each box with an AX
role, which is what turns a box into something Mary can act on.

Roles are only ever taken from a closed vocabulary Mary already understands, and a box
the classifier is unsure about keeps `VXRegion`. That is deliberate: `VXRegion`
categorizes as `.other`, and Mary drops `.other` nodes from every roster and draws none
of them — so an unsure guess costs her nothing, while a confident wrong role is
something she will click. `label` and `subrole` stay nil, because this pipeline has no
evidence for either.

**VisionAX does not import Mary.** The AXTree model is replicated here, in
`Sources/VisionAX/Accessibility/`, as this package's own files.

## Layout

| Target | What it is |
|---|---|
| `CVisionAX` | The engine. `include/visionax.h` is a pure-C header — the only public surface. Everything behind it is C++: `Engine` (the extensible engine class), `CannyRegionDetector`, `RegionTreeBuilder`, and `visionax.cpp`, the `extern "C"` facade. |
| `VisionAX` | The Swift face: the replicated AXTree model plus its Codable form, and `VisionEngine`, which turns a `CGImage` into an `AXWindowSnapshot`. This is what Mary will depend on. |
| `VisionAXBench` | A macOS app: open a screenshot **or type a URL**, see the tree over it, the roles the classifier gave it, the raw Canny map, and the JSON. |
| `VisionAXWeb` | Rendering a page and asking its DOM what is on it: the seeded synthetic page generator, the WKWebView crawler, and the DOM walker. WebKit and nothing else, so the bench can use it without linking the permission-hungry half. |
| `VisionAXHarvestKit` | The lane that needs permission: a self-contained AX walker and ScreenCaptureKit capture for live apps, and the session that writes a dataset. |
| `VisionAXHarvest` | The app shell around the kit. Its own bundle id, so its Accessibility grant is independent of everything else. |
| `Training/` | A Python (uv) project that trains the classifier and exports it to the two ONNX graphs the C engine loads. |

OpenCV 4 and 5 removed the legacy C API, so "a C engine" here means **C++ internals
behind an `extern "C"` header** — the public header stays C-clean, and Swift imports
it as an ordinary module. Inference runs on ONNX Runtime's C API inside the same
engine, so one runtime serves every model that follows and Swift never sees a tensor.

## Building

```sh
git lfs pull                              # the trained model, if one is committed
swift build
swift test
./scripts/bench.sh                        # the bench, empty
./scripts/bench.sh ~/Desktop/shot.png     # open straight onto an image
./scripts/bench.sh --url news.ycombinator.com   # render a page and use that
./scripts/harvest.sh                      # the harvester's options
CONFIG=release ./scripts/bench.sh
```

Nothing needs to be installed first. OpenCV arrives as a prebuilt static
`opencv2.xcframework` (`yeatse/opencv-spm`, pinned to **4.13.0**, checksum-verified by
SwiftPM), and ONNX Runtime as the official `pod-archive-onnxruntime-c-1.24.2.zip`
xcframework (macOS `arm64` + `x86_64`, CoreML and XNNPACK compiled in). The first
`swift build` downloads about 250 MB once.

**Use `./scripts/bench.sh`, not `swift run`.** The bench's `Info.plist` is linked
into the Mach-O (`-sectcreate __TEXT __info_plist`), which is what gives the bare
`.build` binary a bundle identity; `main.swift` then sets `.regular` activation so it
is a real foreground app with a Dock icon. The script also passes your image the one
way that works (below). Same recipe as Mary's `scripts/sand.sh`.

The bench takes its image as `--image <path>` (the script converts a bare path for
you). **Never pass a bare path directly to the binary**: AppKit reads unflagged argv
entries as documents to open, and an app with no registered document type answers by
opening nothing at all — event loop up, zero windows, indistinguishable from a hang.

## The JSON

`AXTreeJSON` encodes with the house settings — sorted keys, unescaped slashes,
ISO-8601 dates, trailing newline. Rects are flat `{x, y, width, height}` (Mary's
`AXFrameRect` spelling), never `CGRect`'s nested `origin`/`size`. A nil frame omits
the key. `subtreeCount` is written for readers but **recomputed from `children` on
decode**, so it cannot drift.

```json
{
  "frame" : { "height" : 600, "width" : 800, "x" : 0, "y" : 0 },
  "id" : 1,
  "isMain" : true,
  "isMinimized" : false,
  "isTruncated" : false,
  "root" : {
    "category" : "window",
    "children" : [
      {
        "category" : "other",
        "children" : [ ],
        "frame" : { "height" : 60, "width" : 720, "x" : 40, "y" : 40 },
        "id" : 3,
        "isEnabled" : true,
        "isFocused" : false,
        "role" : "VXRegion",
        "subtreeCount" : 1
      }
    ],
    "frame" : { "height" : 600, "width" : 800, "x" : 0, "y" : 0 },
    "id" : 1,
    "isEnabled" : true,
    "isFocused" : false,
    "role" : "AXWindow",
    "subtreeCount" : 5
  },
  "title" : "sample-screenshot.png"
}
```

`Tests/VisionAXTests/Fixtures/sample-axtree.json` is that document in full, and a
test decodes it.

## Coordinates

Every frame is in **input-image pixel space, top-left origin** — the same orientation
AX reports in, which is why no flip appears anywhere in this package. The root node's
frame is the image's own bounds.

A caller placing these on a screen divides by the screenshot's backing scale: a 2×
Retina capture reports 3840×2160 pixels for a 1920×1080 point desktop. VisionAX does
not guess that scale, because the image alone does not carry it.

## How a region becomes a node

1. **`CannyRegionDetector`** — to gray, optional Gaussian blur, `Canny`, optional
   morphological close (seals one-pixel gaps so a box's outline reads as one loop),
   `findContours`, `boundingRect` per contour.
   `findContours`' own hierarchy is *not* used: on an edge map it describes edge
   loops, not UI containment.
2. **Filter and dedup** — drop anything under `min_width`/`min_height`, then drop a
   box that duplicates a larger kept one, by IoU or by all four edges landing within
   `merge_slack`. A stroked rectangle yields an outer and an inner contour; without
   this every box on screen would arrive doubled.
3. **`RegionTreeBuilder`** — a box's parent is the **smallest** kept box that contains
   it (within `containment_slack`); partial overlaps become siblings, never a parent.
   Siblings are sorted by Mary's roster reading rule: a row band by `midY`, then left
   to right. The tree is flattened pre-order under a walk budget with Mary's
   `AXTreeWalker` semantics — a node **at** `max_depth` is kept and its children
   withheld, and exactly `max_nodes` nodes are emitted before the cut. Either sets
   `isTruncated`.

Every knob is exposed in `CannyOptions` and on the bench's parameter strip, because
defaults tuned on synthetic rectangles over-segment real screenshots — text
especially. Tuning them against real captures is what the bench is for.

For reference, one 1920×1080 desktop capture at the defaults: 2,377 contours in,
978 nodes out, tree depth 5, about 40 ms, ~400 KB of JSON.

## Opening a URL in the bench

**Open URL…** renders a page with the same crawler the harvester runs on, uses the
screenshot as the open image, and keeps the page's DOM as ground truth. So one window
shows what the detector proposed, what the classifier called it, and what was actually
there — over any page on the web, without harvesting anything to disk.

The web view is offscreen, so no browser window appears. The status bar reports live
**proposal recall** ("truth 48/84 proposed"), re-matched on every run, which means the
Canny sliders move it in real time. That makes the bench a tuning instrument rather
than a viewer, and it immediately shows how much page layout matters:

| Page | Proposal recall |
|---|---|
| Synthetic corpus | 84% |
| MDN article | 57% |
| Hacker News | 5% |

Hacker News is the worst case found so far and is worth understanding rather than
averaging away: it is a dense table of small text where a title and its domain sit a
few pixels apart, so the morphological close that correctly merges a word's strokes
also merges neighbouring links into a single box. Every proposal overlaps several real
elements and matches none of them at IoU 0.5.

## The classifier

`VisionEngine.detectAndClassify(in:title:using:)` runs Canny, then names every region.
A model is two ONNX graphs plus a JSON sidecar:

```
region-classifier.json            the spec: vocabulary, preprocessing, thresholds
region-classifier.backbone.onnx   image  -> stride-8 feature map
region-classifier.head.onnx       features + N boxes -> N probability rows
```

**Two graphs, not one.** A 1080p screenshot yields around a thousand boxes, and two
7×7×128 RoIAlign crops each is hundreds of megabytes of activations. The backbone runs
once per image and the head runs in chunks over its output, so memory is bounded
without recomputing features. It is also the seam a CoreML backbone would need later:
`RoiAlign` has no CoreML kernel, so a single fused graph would be partitioned in the
middle by the runtime rather than at a boundary anyone chose.

**Swift parses the spec; C never does.** The C engine takes a struct of numbers and has
no idea what a role is called, so a retrained model can add a class without touching
C++. In exchange, Swift validates what C cannot: that every role is one Mary acts on
(`AXNodeCategory.category(role:) != .other`), and that the tensor names match what
`Classifier.cpp` binds by.

**Preprocessing is a contract.** `Training/visionax_train/preprocess.py` and
`Sources/CVisionAX/ClassifierPreprocess.cpp` must produce identical tensors — same
`INTER_AREA` resize, same mean-colour padding, same per-axis box scaling, same
`floor(x + 0.5)` rounding. `RegionClassifierTests.matchesPythonExactly` runs the C++
path against probabilities Python computed and fails if they drift.

## Training

```sh
cd Training && uv sync
uv run vxtrain stats ../Dataset
uv run vxtrain train --dataset ../Dataset --out runs/r1
uv run vxtrain eval --run runs/r1 --dataset ../Dataset
uv run vxtrain calibrate --run runs/r1 --dataset ../Dataset
uv run vxtrain export --run runs/r1 --out ../Sources/VisionAX/Resources/Models
uv run vxtrain parity --spec ../Sources/VisionAX/Resources/Models/region-classifier.json \
    --dataset ../Dataset --run runs/r1
```

`calibrate` fits a temperature on the validation split and picks the smallest
confidence whose non-`none` answers are right 90% of the time. That threshold ships in
the spec, so serving never has to guess it. The metric to read first is not accuracy —
on a corpus that is half `none` a constant predictor scores well — but macro-F1 and
the confident-and-wrong rate, which is how often the model would hand Mary a role for
something that is not an element.

### Where the first baseline actually stands

Trained on 1,494 harvested web samples (1,280 synthetic pages, 214 real URLs), 8 epochs,
16 trainable classes. Measured on a held-out 15% split, grouped by page so no page
appears on both sides:

| | |
|---|---|
| macro-F1 | 0.541 |
| top-1 | 0.826 |
| category accuracy | 0.835 |
| confident-and-wrong | 1.9% |
| torch ↔ ONNX Runtime | max Δprob 4.9e-06, 0 argmax disagreements |

Per role, the shape of it matters more than the average. `AXButton` 0.910, `AXCheckBox`
0.872, `AXRadioButton` 0.822, `AXStaticText` 0.741. Precision is high almost everywhere
(1.000 for cells, images, pop-ups, text areas, sliders) and recall is what is missing —
the model is **conservative**, which is the right direction to be wrong in, because an
unnamed box costs Mary nothing and a wrongly named one gets clicked.

Two classes score zero: `AXHeading` and `AXToolbar`. A heading is text that happens to
be larger, and nothing in a 7×7 crop plus box geometry separates the two reliably.

**The known weakness is the corpus, not the architecture.** Everything above was
harvested from web pages, and it shows: run the model on a desktop screenshot of an
editor and a PDF viewer and it reports about a hundred `AXLink`s where there are
essentially none. `AXLink` has the worst precision of any class (0.487) because links
are everywhere on the web and nowhere in native UI. Seven roles
(`AXComboBox`, `AXTab`, `AXMenuItem`, `AXDisclosureTriangle`, `AXList`, `AXTable`,
`AXScrollArea`) had too few examples to train at all and were folded into `none`.

The fix is the app-harvest lane, which is built and untested only because it needs a
one-time Accessibility and Screen Recording grant that has to be given by hand. Native
captures are what will supply the missing roles and teach the model that a link is rare
outside a browser.

## Harvesting

```sh
./scripts/harvest.sh --web-synthetic 300 --viewports 1280x800,1440x900 \
    --schemes light,dark --scrolls 2 --out Dataset --quit-when-done
./scripts/harvest.sh --web-urls Sources/VisionAXHarvestKit/Resources/Seeds/urls.txt \
    --out Dataset --quit-when-done
./scripts/harvest.sh --app com.apple.Safari --record --interval 3 --out Dataset
```

Two sources, one dataset format. The **web** lane renders a page in a WKWebView and
asks the DOM what is on it; it needs no permissions, and a seeded generator supplies
class balance the real web does not. The **app** lane pairs a ScreenCaptureKit capture
with this package's own AX walk, which is the path to native controls and to anything
that is not a web page at all; it needs Accessibility and Screen Recording, granted to
`nyc.rao.visionax.harvest` alone.

Every run prints a **proposal recall** table — what fraction of the real elements Canny
proposed a box for, by role and by size. That number is the ceiling on the whole
pipeline: a classifier can only name boxes the detector produced, so a role at 20%
recall is capped at 20% however good the model gets. Read it before blaming the model.

The app lane captures, walks, and captures **again**, discarding the sample if the
window changed in between. An AX walk takes hundreds of milliseconds and anything that
animates in that window moves the boxes out from under the pixels — a corruption
nothing downstream could detect, because the sample would look perfectly well formed.

## Adding an engine capability

The seam is deliberately four steps, in this order:

1. Declare the C types and the `vx_engine_*` function in `include/visionax.h`.
2. Add the method to `visionax::Engine` (`Engine.hpp`/`Engine.cpp`), with the real
   work in its own `.hpp`/`.cpp` pair beside it.
3. Wire the `extern "C"` facade in `visionax.cpp` — argument checks, `cv::Mat`
   wrapping, malloc'd outputs freed through a matching `vx_*_free`, and no exception
   crossing the boundary.
4. Add the Swift call on `VisionEngine`, returning the package's own value types.
5. If it needs a model, ship it under `Sources/VisionAX/Resources/Models` and read its
   spec in Swift — never in C.

## The media lane

`readMediaControls` finds a video player's transport in a screenshot — the progress
track, the row of controls, and what each glyph depicts — without knowing what site it
is looking at. What it relies on is the layout every player shares: a thin two-tone track
across the bottom of the picture, and a row of evenly sized glyphs beneath it spanning
its width, with play at the left end and full screen at the right.

```swift
let reading = try engine.readMediaControls(in: frame, previous: frameJustBefore)
reading.playback          // .playing / .paused / .unknown
reading.witnesses         // ["picture moved (0.199)"] — WHY it says that
reading.playPause?.frame  // where to click
reading.progress?.fraction
```

**It reports witnesses, not a verdict dressed as one.** Whether a video is playing is
decided from three independent observations — the picture moved between two frames, the
progress fraction advanced, the clock advanced — and `witnesses` names the ones that
actually spoke. A glyph is only the tiebreak, because a button says what pressing it
would *do*, which is one frame behind whatever just happened.

The glyph silhouettes are **drawn, not shipped**: twelve shapes in `MediaGlyphs.cpp`,
compared by mask overlap after both candidate and template are normalised to the same box.
There is no model to download and the lane works with no classifier installed at all.

Two environment variables make tuning it repeatable, and both are off by default:
`VISIONAX_MEDIA_TRACE=1` prints which gate refused each candidate, and the `readFile`
and `dumpRows` tests in `RowDumpTests` read any image off disk (`VISIONAX_MEDIA_FILE`).
Real captures live in `Tests/VisionAXTests/Fixtures/media/`; every fix so far came from
adding one and watching it fail first.

## The page map

`scene.pageMap()` turns a perception into the thing a consumer acts on: rows with a
frame, a role, what they afford, a label, and **where that label came from**.

It does not go through `roster`. The roster drops any node the classifier did not name
and any node with no words inside it, which on a page of search results is nearly all of
them — measured, a results page read as four chrome buttons. The map keeps those rows and
reports its confidence instead.

Three sources, joined before anything is classified:

| Source | What it finds |
|---|---|
| Canny regions | Anything with an edge |
| `TextLines.proposals` | Boxes with no edge at all. A result title is an anchor around a heading: no border, no fill, nothing for an edge detector to find, and perfectly legible to recognition |
| `PageGrouping` | Which rows belong together, and in what order |

**The text union runs at harvest time too** (`HarvestSession.record`), through the same
function. A proposal the model meets only at inference is a proposal it was never trained
on, and it answers `none` for exactly the rows that matter.

**Grouping is geometry.** Bands of boxes that share a line; bands merged with whatever
sits close under them, judged against the neighbouring gap rather than a threshold; runs
of similar bands at a regular pitch become a list, which is what makes "the first one"
mean anything. Cards, forms, toolbars and overlays fall out of the same pass.

**The label ladder** is classifier → words inside → words beside it (fields only, since a
button labels itself) → a drawn icon → `"button 3"`. Every row keeps a name and records
which rung produced it, so a consumer can tell a read name from a position.

### The icon bank

`IconGlyphs.cpp` draws twenty-two interface icons — search, close, menu, chevrons, add,
more, share, microphone, bell, account, star, heart, delete, done, settings, home, filter,
cart, download — and matches a candidate by **blurred correlation**, not silhouette
overlap.

That is a measured choice. Overlap alone scored a magnifier drawn with a 3px stroke at
0.28 against the same magnifier drawn with a 4px stroke, *below* a cross at 0.30, and read
a checkmark as a magnifier: two icons of the same shape barely overlap when their strokes
differ by a pixel, because a stroke is mostly edge. Softening each mask into a field and
correlating them scores every independently drawn icon in the test fixture between 0.79
and 0.996, with a blank button at 0.0 and the floor at 0.55.

It is a fallback rung, never an oracle: an icon under the floor keeps its position and is
still pressable as "button 4".

## Benchmarks

Measured with `Tests/VisionAXTests/BenchmarkTests.swift` over real captures taken from a
live browser, each 900×752 at 1×. M4 Max, debug build. Median of seven.

    VISIONAX_BENCH=/dir/of/pngs swift test --filter benchmarkOnePipelineCall   # the package as a unit
    VISIONAX_BENCH=/dir/of/pngs swift test --filter benchmarkTheLanes          # each lane on its own

### One pipeline call, entry to exit

The number to quote for this package. `perceive()` records its own phases, so the
breakdown comes from inside the call rather than from invoking the lanes separately —
timed from outside, the parts add up to more than the whole, because each call rebuilds
the image buffer, the union is invisible, and the classifier appears to pay for a
conversion the detector already did. The phases always sum to the total; whatever they do
not name shows as `other`.

**A page read** — `lanes: [.regions, .text]` with a classifier, then `pageMap()`:

```
  crop + buffer      2.3ms     1%     BGRA once, shared by every lane
  text             124.0ms    56%     accurate recognition over the whole crop
  detect             3.5ms     2%     Canny → region tree
  union text         2.0ms     1%     text lines added as proposals
  classify          88.0ms    40%     ResNet18 backbone + head, 200 boxes
  icons              0.7ms     0%     the drawn bank, over wordless boxes only
  other              0.0ms     0%
  TOTAL            220.5ms   100%
  pageMap()          3.0ms            grouping, label ladder, dedup
  ────────────────────────
  ENTRY→EXIT       223.5ms            → 91 rows, 9 actionable, 63 text runs
```

**A media read** — `lanes: [.media, .text]`, no classifier:

```
  crop + buffer      2.2ms     6%
  media             23.5ms    66%     band scan, control blobs, glyph match
  clock             10.0ms    28%     the bar strip alone, magnified 3×
  other              0.0ms     0%
  TOTAL             35.8ms   100%
  ENTRY→EXIT        35.9ms            → transport found
```

Across the four captures:

| Capture | Page read | Media read |
|---|---|---|
| article | 244 ms | 50 ms |
| results | 224 ms | 47 ms |
| watch (playing) | 224 ms | 49 ms |
| watch (paused, transport up) | 212 ms | 36 ms |

**Two lanes, two orders of magnitude apart, and that is the design.** A page read is
~220 ms and is dominated by two things — accurate text at 55–60% and the classifier at
~40%. A media read is ~40 ms because it asks for neither: the glyphs are drawn rather
than learned, and the only text it reads is the clock inside a bar it has already found.
That is what lets a transport be driven interactively and re-read to prove it moved.

**Detection is not the cost, and neither is the map.** Canny is 3–30 ms depending on what
the page draws, the text union is ~2 ms, the icon bank under 1 ms on a page and 10 ms on
one full of wordless controls, and grouping plus the label ladder plus deduplication is
2–6 ms. Everything this package added this cycle is inside the noise of the two lanes it
already had.

### Each lane on its own

Useful when tuning one of them; the totals do not compose, for the reason above.

| Stage | Article | Results | Watch | Notes |
|---|---|---|---|---|
| detect (Canny) | 6 ms | 7 ms | 40 ms | 182 / 201 / 973 nodes |
| text, fast | 33 ms | 25 ms | 16 ms | 34 / 49 / 9 runs |
| text, accurate | 150 ms | 150 ms | 83 ms | 37 / 63 / 14 runs |
| classify | 99 ms | 105 ms | 113 ms | 181 / 200 / 972 boxes |
| media, one frame | 27 ms | 30 ms | 45 ms | |
| media, two frames | 38 ms | 38 ms | 47 ms | the motion witness costs ~10 ms |
| icon bank | 3 ms | 3 ms | 4 ms | 6 / 6 / 103 boxes |

What the numbers say:

- **Accurate recognition is over half the page read**, and it is worth it: on the results
  page it found 63 runs against fast's 49 — 29% more words for the label ladder, on the
  page type the browsing lane exists for. The media lane keeps the fast pass, where the
  strip is magnified first and the answer is four digits.
- **The classifier costs about the same whatever the page.** 181 boxes and 972 boxes both
  land near 100 ms, because one backbone pass over the image dominates and the head runs
  the boxes in chunks. Adding text-line proposals roughly doubled the box count for
  almost nothing.

At 2× the pixels (the same page upscaled to 1834×1504 — an approximation of a retina
capture, not a faithful one) detection rises to 33 ms, classification to 277 ms as the
detector proposes 731 boxes instead of 200, and a page read to 545 ms.

### One whole round trip

The lane table above is what perception costs. What a person waits for is the whole act,
and no lane contains it: resolve the browser → read its shell through Accessibility →
claim the stage → look → resolve the phrase → press → wait for the shell → look again →
judge. Mary's `mary-web-probe --roundtrip "<phrase>"` timestamps the engine's own events,
so the breakdown below is measured rather than assembled from parts.

Pressing a link on a live Wikipedia article, in Safari:

```
      0ms  +   0ms  resolved Safari
    258ms  + 258ms  read the shell — Ski touring - Wikipedia
    859ms  + 601ms  looked — 58 rows, 52 named, 16 groups
   1212ms  + 354ms  clicked Slovenščina
   2677ms  +1465ms  looked again — 45 rows, 32 named, 13 groups
   2678ms  +   0ms  receipt — the page became Turno smučanje - Wikipedija
   2678ms  ── whole act
```

| Act | Whole trip | Receipt it earned |
|---|---|---|
| Press a link that navigates | 2.7 s | `navigation` — the strongest |
| Press a control that does not navigate (opens a menu) | 3.3 s | `targetChanged` |
| Press a phrase that fits two rows | 0.85 s | refused, naming both, nothing pressed |
| Search the web and open a result | 5.7 s | `navigation`, of which 1.7 s is the search page loading |

Where the time goes, and what is worth knowing about it:

- **A shell read through Accessibility is 250 ms**, and an act pays for two or three of
  them. That is an exhaustive AX snapshot each time, and it is the cheapest thing to
  improve next.
- **A press that does NOT navigate costs more than one that does**, which is the opposite
  of the intuition: a navigating shell moves on the first poll, while a still one is asked
  twice more before it is believed. An earlier version polled the full budget either way
  and measured 6.4 s for the same act — four seconds spent waiting for a navigation that
  was never coming.
- **The search flow reads the results page twice**, once to choose which result and once
  inside the press that opens it, costing about 800 ms. That is deliberate: every command
  resolves against a reading taken a moment before it acts, and a press that trusted a
  roster fetched by somebody else is exactly the class of bug this lane exists to avoid.

### The retrained classifier

Trained on the expanded corpus — 3,534 samples, 2,000 newly generated with results pages,
media grids, icon bars, players, menus, pagination and consent walls in the vocabulary,
plus real pages crawled from `Training/seeds/browse-urls.txt`, and with text-line
proposals present at harvest time so the head is asked about the boxes it will be asked
about in service.

| | Shipped before | Retrained | Why it matters |
|---|---|---|---|
| macro-F1 | 0.712 | **0.770** | |
| `AXLink` precision | 0.49 | **0.941** | The defect: body text offered as links. An article page went from 16 pressable rows, mostly sentences, to 3 real controls |
| `AXRow` recall | — (0 of 1,736 proposed) | **0.821** | A class the corpus had none of; product cards and result rows now read as rows |
| `AXTextField` recall | 0.49 | **0.728** | A results page now has a field `fill_in_page` can reach, which it did not before |
| Affordance top-1 (marginal) | — | **0.974** | What the page map actually decides on |
| ONNX parity | — | max \|Δprob\| 2e-06, **0 argmax disagreements** | |

Calibration chose `min_confidence` 0.05 at 0.933 precision over 51,080 boxes.

**The best epoch was the first**, and macro-F1 fell over the three that followed
(0.770 → 0.622 → 0.476 → 0.626) while the loss kept dropping. Early stopping kept the
right checkpoint, but a run whose best epoch is its first is undertrained rather than
finished — the learning rate or the warmup is wrong for a corpus this size, and there is
more here than has been taken.

**It trades recall for precision, and that needed a change on the consuming side.** The
retrained model stopped calling body text a link — the point — and in the same pass
stopped calling some real controls anything at all: a "9 languages" button that had been
pressed live went from offered to invisible. Mary's resolver now reaches past what the
map offers when a person names something exactly, on the grounds that whoever said it can
see the screen; the receipt still decides whether the press did anything.

### Quality

| Measure | Number |
|---|---|
| Proposal recall, synthetic (2,000 pages) | 83.5%, from 75.7% before text-line proposals |
| Proposal recall, real (150 harvested samples) | 72.7%, from 62.1% |
| Icon bank, independently drawn glyphs | every one recognized, 0.79–0.996; a blank button scores 0.000 against a floor of 0.72 |
| Live results page | 89 rows, 89% carrying a name something wrote, 18 pressable |
| Live article page | 50 rows, 78% named, 16 pressable |
| Live watch page | 273 rows, 9% named, 38 pressable — a page that is mostly picture, and the media lane's job rather than the map's |

## Consuming from Mary

Mary reaches this package **through Frigate**, which hosts the ML surfaces it takes from
one place. Frigate declares the dependency and re-exports it as `FrigateVision`; Mary's
machine layer names that product and nothing else:

```swift
// in Frigate/Package.swift, inside `#if !os(Linux)`
.package(path: "../VisionAX")
.target(name: "FrigateVision",
        dependencies: [.product(name: "VisionAX", package: "VisionAX")])

// in Mary/Package.swift — MaryComputerUse, the one target with the edge
.product(name: "FrigateVision", package: "Frigate")
```

```swift
import FrigateVision   // VisionAX, whole
```

Consuming it directly (`.package(path: "../VisionAX")`, `import VisionAX`) still works and
is what the bench and harvester in this repository do. Two things a consumer should know
either way: the resource bundle is named for THIS package
(`VisionAX_VisionAX.bundle`, so a copied `.app` must carry it — see
`RegionClassifier.bundled(searching:)`), and the first build needs network for the ONNX
Runtime and OpenCV artifacts.

```swift
let engine = try VisionEngine()

// One look, in whichever lanes you want, with the map back to the screen.
let scene = try engine.perceive(
    image: capture,
    projection: ScreenProjection(origin: window.origin, pixelsPerPoint: measuredScale),
    lanes: [.media, .text],
    previous: captureJustBefore)

scene.media?.playPause.map { scene.screenPoint(of: $0) }   // global screen points
scene.hitTest(screenPoint: cursor)                          // smallest box under a point
scene.roster(pid: pid, appName: "Safari", windowTitle: title)
```

**The projection is the caller's to supply, and its scale must be MEASURED** —
`image.width / window.frame.width` after the capture, not assumed. An image does not carry
its own density, and a 2× guess on a 1× display puts every click at half the distance from
the window's corner. A region of interest is expressed as a crop, and the crop moves the
projection rather than the frames, so a sub-detection still lands correctly on screen.

```swift
// Boxes only.
let detection = try engine.detectRegions(in: screenshot, title: "Safari")

// Boxes with AX roles, when a model is bundled.
if let classifier = try RegionClassifier.bundled() {
    let named = try engine.detectAndClassify(
        in: screenshot, title: "Safari", using: classifier)
}
```

`RegionClassifier.bundled()` looks in the host app's own `Contents/Resources` before it
touches `Bundle.module`, and that order matters: SwiftPM's generated accessor calls
`fatalError` when the resource bundle is not beside the executable, so reaching for it
first would TRAP inside a copied `.app` rather than return nil. An app bundle should still
copy `VisionAX_VisionAX.bundle` into `Contents/Resources`; without it the classifier is
simply absent, which the media lane survives and the element lane reports by name.
