# VisionAX

The AX/A11Y interoperability scaffolding for pixel perception on macOS, and the pipeline
that trains the classifier it depends on.

A detected tree and a walked accessibility tree have to be interchangeable to a consumer:
the same `AXNodeSnapshot` / `AXWindowSnapshot` value tree, the same JSON, the same role
vocabulary. **VisionAXCore** is that shared shape — the data structures, the dataset
schema a harvester writes and a trainer reads, and the closed vocabulary of AX roles a
classifier may answer with. Beside it live the **tools** that build and tune a training
set, and the **training pipeline** that turns it into a model.

**The runtime is not here.** The C++ engine (OpenCV Canny regions, the ONNX Runtime role
classifier, the media and icon glyph banks), its Swift face (`VisionEngine`, `perceive`,
the page map) and the bundled model live in [Frigate](../Frigate), as its
`FrigateVisionAX` product and module, documented in
`Frigate/Sources/FrigateVisionAX/README.md`. That module re-exports VisionAXCore, so a
consumer writes `import FrigateVisionAX` and gets both.

Roles are only ever taken from a closed vocabulary Mary already understands, and a box
the classifier is unsure about keeps `VXRegion`. That is deliberate: `VXRegion`
categorizes as `.other`, and Mary drops `.other` nodes from every roster and draws none
of them — so an unsure guess costs her nothing, while a confident wrong role is
something she will click. `label` and `subrole` stay nil, because this pipeline has no
evidence for either.

**VisionAX does not import Mary.** The AXTree model is replicated here, in
`Sources/VisionAXCore/Accessibility/`, as this package's own files.

## Layout

| Where | Package | What it is |
|---|---|---|
| `Sources/VisionAXCore` | `VisionAX` (root) | The AX tree model and its Codable form (`Accessibility/`), the dataset schema and writer (`Dataset/`), the detector's option set (`Detector/CannyOptions`), and the role vocabulary (`Vocabulary/`). No dependencies. |
| `Tools/Sources/VisionAXWeb` | `VisionAXTools` | Rendering a page and asking its DOM what is on it: the seeded synthetic page generator, the WKWebView crawler, and the DOM walker. WebKit and VisionAXCore, nothing else. |
| `Tools/Sources/VisionAXHarvestKit` | `VisionAXTools` | The lane that needs permission: a self-contained AX walker and ScreenCaptureKit capture for live apps, and the session that writes a dataset. |
| `Tools/Sources/VisionAXHarvestApp` | `VisionAXTools` | The harvester app. Its own bundle id, so its Accessibility grant is independent of everything else. |
| `Tools/Sources/VisionAXBenchApp` | `VisionAXTools` | The bench: open a screenshot **or type a URL**, see the tree over it, the roles the classifier gave it, the raw Canny map, and the JSON. |
| `Training/` | — | A Python (uv) project that trains the classifier and exports it to the two ONNX graphs Frigate's engine loads. |

**Two packages, one repository.** The harvester proposes boxes with the runtime and the
bench runs it, and the runtime (in Frigate) depends on VisionAXCore — so the tools are a
second package, `Tools/Package.swift`, that depends on both this root package and
`../../Frigate`. Declaring them beside VisionAXCore would make the two packages depend on
each other.

## Building

```sh
swift build && swift test                      # VisionAXCore
swift test --package-path Tools                # the harvester's tests (builds Frigate's runtime)
./scripts/bench.sh                             # the bench, empty
./scripts/bench.sh ~/Desktop/shot.png          # open straight onto an image
./scripts/bench.sh --url news.ycombinator.com  # render a page and use that
./scripts/harvest.sh                           # the harvester's options
CONFIG=release ./scripts/bench.sh
```

VisionAXCore builds with nothing but Xcode. The tools resolve Frigate's graph: OpenCV
arrives as a prebuilt static `opencv2.xcframework` (`yeatse/opencv-spm`, pinned to
**4.13.0**) and ONNX Runtime as the official `pod-archive-onnxruntime-c-1.24.2.zip`
xcframework — about 250 MB once, on the first build. The bundled model is git-lfs in
Frigate; run `git lfs pull` there.

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

`Tests/VisionAXCoreTests/Fixtures/sample-axtree.json` is that document in full, and a
test decodes it.

## Coordinates

Every frame is in **input-image pixel space, top-left origin** — the same orientation
AX reports in, which is why no flip appears anywhere in this package. The root node's
frame is the image's own bounds.

A caller placing these on a screen divides by the screenshot's backing scale: a 2×
Retina capture reports 3840×2160 pixels for a 1920×1080 point desktop. Nothing here
guesses that scale, because the image alone does not carry it.

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

## The classifier, from this side

A model is two ONNX graphs plus a JSON sidecar — `region-classifier.json`,
`.backbone.onnx`, `.head.onnx` — exported from here into Frigate's
`Sources/FrigateVisionAX/Resources/Models`. How the runtime serves them is in Frigate's
`Sources/FrigateVisionAX/README.md`; what matters on this side:

**Preprocessing is a contract.** `Training/visionax_train/preprocess.py` and Frigate's
`Sources/CVisionAX/ClassifierPreprocess.cpp` must produce identical tensors — same
`INTER_AREA` resize, same mean-colour padding, same per-axis box scaling, same
`floor(x + 0.5)` rounding. Frigate's `RegionClassifierTests.matchesPythonExactly` runs the
C++ path against probabilities Python computed (the fixture comes from
`Training/tools/make_test_model.py`) and fails if they drift.

**The vocabulary is closed.** `RoleVocabulary.validated()` (VisionAXCore) refuses any role
that categorizes as `.other`, and the dataset's `roles.json` carries each role's Mary
category, written from `AXNodeCategory` in Swift — Python never keeps its own copy.

## Training

```sh
cd Training && uv sync
uv run vxtrain stats ../Dataset
uv run vxtrain train --dataset ../Dataset --out runs/r1
uv run vxtrain eval --run runs/r1 --dataset ../Dataset
uv run vxtrain calibrate --run runs/r1 --dataset ../Dataset
uv run vxtrain export --run runs/r1 --out ../../Frigate/Sources/FrigateVisionAX/Resources/Models
uv run vxtrain parity --spec ../../Frigate/Sources/FrigateVisionAX/Resources/Models/region-classifier.json \
    --dataset ../Dataset --run runs/r1
```

`export` writes the MLX backbone too — `region-classifier.backbone.safetensors`, converted
from the ONNX file it just wrote, never from the checkpoint, with that file's sha256 stamped
into it. Frigate runs it on Metal and refuses it when the stamp does not match the spec's
backbone, falling back to the ONNX backbone on CPU. `vxtrain export-mlx --spec <json>`
converts an existing export, and refuses any graph that is not exactly the `resnet18-fpn8`
backbone Frigate implements.

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

## Harvesting

```sh
./scripts/harvest.sh --web-synthetic 300 --viewports 1280x800,1440x900 \
    --schemes light,dark --scrolls 2 --out Dataset --quit-when-done
./scripts/harvest.sh --web-urls Tools/Sources/VisionAXWeb/Resources/Seeds/urls.txt \
    --out Dataset --quit-when-done
./scripts/harvest.sh --app com.apple.Safari --record --interval 3 --out Dataset
```

Two sources, one dataset format (VisionAXCore's `HarvestSample` and `DatasetWriter`). The
**web** lane renders a page in a WKWebView and asks the DOM what is on it; it needs no
permissions, and a seeded generator supplies class balance the real web does not. The
**app** lane pairs a ScreenCaptureKit capture with this package's own AX walk, which is the
path to native controls and to anything that is not a web page at all; it needs
Accessibility and Screen Recording, granted to `nyc.rao.visionax.harvest` alone.

Every run prints a **proposal recall** table — what fraction of the real elements Canny
proposed a box for, by role and by size. That number is the ceiling on the whole
pipeline: a classifier can only name boxes the detector produced, so a role at 20%
recall is capped at 20% however good the model gets. Read it before blaming the model.

The app lane captures, walks, and captures **again**, discarding the sample if the
window changed in between. An AX walk takes hundreds of milliseconds and anything that
animates in that window moves the boxes out from under the pixels — a corruption
nothing downstream could detect, because the sample would look perfectly well formed.

`Dataset/` at the repository root is ignored — a dataset is hundreds of MB of PNGs and is
reproducible from its seeds and URLs. The ignore rule is anchored (`/Dataset/`) so the
schema's own `Sources/VisionAXCore/Dataset/` stays tracked.
