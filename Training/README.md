# Training

Trains the region-role classifier VisionAX runs on-device, and exports it to the two
ONNX graphs `Sources/CVisionAX/Classifier.cpp` loads.

## Setup

```sh
uv sync            # creates Training/.venv from pyproject.toml
uv run vxtrain --help
```

The modules also run against an ambient interpreter that already has torch,
torchvision, onnx, onnxruntime, opencv and numpy — `PYTHONPATH=. python3 tools/...`.

## Why two graphs

`backbone.onnx` turns the image into a stride-8 feature map; `head.onnx` turns that map
plus N boxes into N probability rows. One fused graph would recompute the backbone for
every chunk of boxes, and a 1080p screenshot yields ~1,000 boxes — far more than fits
in one RoIAlign activation. The split is also the seam a CoreML backbone would need,
since `RoiAlign` is not a CoreML-supported operator and would otherwise partition the
graph in the middle.

## Export rules that are not optional

- `dynamo=False`, `opset_version=17`: torchvision registers `roi_align` symbolics only
  for the legacy exporter.
- `sampling_ratio=0` and `aligned=True`: the exporter silently rewrites a non-zero
  sampling ratio to 0, so training with anything else means serving a different model.
- `preprocess.py` is the contract with `ClassifierPreprocess.cpp`. Change one, change
  both, and let the parity test prove it.
