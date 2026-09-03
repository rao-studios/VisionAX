"""Builds the deterministic fixture classifier the Swift tests run against.

WHAT: two tiny ONNX graphs with hand-set weights, a test image, and the exact
      probabilities they produce.
OUT:  Tests/VisionAXTests/Fixtures/tiny-classifier.{json,backbone.onnx,head.onnx,
      image.png,expected.json}
PIN:  NO TRAINING HAPPENS HERE, and that is the point. The runtime has to be provable
      before a real model exists, and a fixture whose answer is a known function of the
      input turns "the classifier works" into an arithmetic check. The weights make the
      answer depend only on mean colour: red -> AXButton, blue -> AXTextField, neither
      -> none. The image ships alongside so C++ and Python read identical pixels — the
      whole preprocessing contract is what this fixture is really testing.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import cv2
import numpy as np
import torch
import torch.nn as nn
from torchvision.ops import roi_align

import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from visionax_train.head_ops import context_boxes, geometry_features, padded_extent
from visionax_train.preprocess import PreprocessSpec, prepare_boxes, prepare_image

# The vocabulary, spelled here so a Swift test can assert it still equals
# RoleVocabulary.standard.roles. Two copies that are checked against each other are
# safe; two copies that are not are the thing the PIN in roles.py forbids.
ROLES = [
    "none", "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXCheckBox",
    "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXSlider", "AXTab", "AXMenuItem",
    "AXDisclosureTriangle", "AXImage", "AXHeading", "AXStaticText", "AXGroup", "AXList",
    "AXTable", "AXRow", "AXCell", "AXScrollArea", "AXToolbar",
]
BUTTON = ROLES.index("AXButton")
TEXT_FIELD = ROLES.index("AXTextField")

CHANNELS = 8
ROI_SIZE = 3
STRIDE = 8
CONTEXT_SCALE = 2.0
LONG_SIDE = 160  # forces a real 2x downscale of the 320x200 fixture image
PAD_MULTIPLE = 32
LOGIT_GAIN = 20.0
NONE_BIAS = 5.0


class TinyBackbone(nn.Module):
    """Average each 8x8 block, then undo the normalization so channels 0..2 are RGB
    back in 0..1. Nothing is learned; the point is a stride-8 map with a meaning a
    test can predict."""

    def __init__(self, spec: PreprocessSpec):
        super().__init__()
        self.pool = nn.AvgPool2d(STRIDE, STRIDE)
        self.project = nn.Conv2d(3, CHANNELS, kernel_size=1)
        weight = torch.zeros(CHANNELS, 3, 1, 1)
        bias = torch.zeros(CHANNELS)
        for channel in range(3):
            weight[channel, channel, 0, 0] = spec.std[channel]
            bias[channel] = spec.mean[channel]
        with torch.no_grad():
            self.project.weight.copy_(weight)
            self.project.bias.copy_(bias)

    def forward(self, image: torch.Tensor) -> torch.Tensor:
        return self.project(self.pool(image))


class TinyHead(nn.Module):
    """Two RoIAlign crops plus geometry into one fixed linear layer, then softmax."""

    def __init__(self):
        super().__init__()
        cells = ROI_SIZE * ROI_SIZE
        self.features = CHANNELS * cells * 2 + 8
        self.classify = nn.Linear(self.features, len(ROLES))
        weight = torch.zeros(len(ROLES), self.features)
        bias = torch.zeros(len(ROLES))
        # Only the BOX crop votes; the context crop and geometry are wired in with zero
        # weight so the graph still exercises them.
        per_cell = LOGIT_GAIN / cells
        for cell in range(cells):
            red = 0 * cells + cell
            blue = 2 * cells + cell
            weight[BUTTON, red] = per_cell
            weight[BUTTON, blue] = -per_cell
            weight[TEXT_FIELD, blue] = per_cell
            weight[TEXT_FIELD, red] = -per_cell
        bias[0] = NONE_BIAS
        with torch.no_grad():
            self.classify.weight.copy_(weight)
            self.classify.bias.copy_(bias)

    def forward(self, features: torch.Tensor, boxes: torch.Tensor) -> torch.Tensor:
        width, height = padded_extent(features, STRIDE, boxes.dtype)
        context = context_boxes(boxes, CONTEXT_SCALE, width, height)
        scale = 1.0 / STRIDE
        box_crop = roi_align(features, boxes, (ROI_SIZE, ROI_SIZE), scale, 0, True)
        context_crop = roi_align(features, context, (ROI_SIZE, ROI_SIZE), scale, 0, True)
        merged = torch.cat(
            [
                box_crop.flatten(1),
                context_crop.flatten(1),
                geometry_features(boxes, width, height),
            ],
            dim=1,
        )
        return torch.softmax(self.classify(merged), dim=1)


def fixture_image() -> np.ndarray:
    """320x200 RGB: a red block, a blue block, white everywhere else."""
    image = np.full((200, 320, 3), 255, dtype=np.uint8)
    image[16:64, 16:112] = (220, 30, 30)      # red   -> AXButton
    image[112:176, 176:272] = (30, 60, 220)   # blue  -> AXTextField
    return image


FIXTURE_BOXES = [
    [16, 16, 96, 48],    # the red block
    [176, 112, 96, 64],  # the blue block
    [128, 24, 48, 40],   # plain white -> none
]


def export(out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    spec = PreprocessSpec(long_side=LONG_SIDE, pad_multiple=PAD_MULTIPLE)
    backbone = TinyBackbone(spec).eval()
    head = TinyHead().eval()

    image = fixture_image()
    prepared = prepare_image(image, spec)
    tensor = torch.from_numpy(prepared.tensor)
    rois = torch.from_numpy(prepare_boxes(np.array(FIXTURE_BOXES, dtype=np.float32), prepared))

    with torch.no_grad():
        features = backbone(tensor)
        reference = head(features, rois).numpy()

    backbone_path = out / "tiny-classifier.backbone.onnx"
    head_path = out / "tiny-classifier.head.onnx"

    # PIN: dynamo=False. torchvision registers roi_align's ONNX symbolic only for the
    # legacy exporter; the dynamo path has no translation for it and fails outright.
    torch.onnx.export(
        backbone, (tensor,), str(backbone_path),
        input_names=["image"], output_names=["features"],
        dynamic_axes={"image": {2: "height", 3: "width"},
                      "features": {2: "feature_height", 3: "feature_width"}},
        opset_version=17, dynamo=False,
    )
    torch.onnx.export(
        head, (features, rois), str(head_path),
        input_names=["features", "boxes"], output_names=["probs"],
        dynamic_axes={"features": {2: "feature_height", 3: "feature_width"},
                      "boxes": {0: "boxes"}, "probs": {0: "boxes"}},
        opset_version=17, dynamo=False,
    )

    import onnx
    import onnxruntime as ort

    onnx.checker.check_model(onnx.load(str(backbone_path)))
    onnx.checker.check_model(onnx.load(str(head_path)))

    backbone_session = ort.InferenceSession(str(backbone_path), providers=["CPUExecutionProvider"])
    head_session = ort.InferenceSession(str(head_path), providers=["CPUExecutionProvider"])
    ort_features = backbone_session.run(["features"], {"image": prepared.tensor})[0]
    probs = head_session.run(["probs"], {"features": ort_features, "boxes": rois.numpy()})[0]

    drift = float(np.max(np.abs(probs - reference)))
    if drift > 1e-5:
        raise SystemExit(f"torch and ORT disagree by {drift}")

    predicted = [int(np.argmax(row)) for row in probs]
    if predicted != [BUTTON, TEXT_FIELD, 0]:
        raise SystemExit(f"fixture weights do not give the intended answer: {predicted}")

    cv2.imwrite(str(out / "tiny-classifier.image.png"), cv2.cvtColor(image, cv2.COLOR_RGB2BGR))

    spec_json = {
        "format": 1,
        "name": "tiny-classifier",
        "version": "fixture",
        "roles": ROLES,
        "files": {"backbone": backbone_path.name, "head": head_path.name},
        "io": {"image": "image", "features": "features", "boxes": "boxes", "probs": "probs"},
        "preprocess": spec.to_json(),
        "head": {"stride": STRIDE, "context_scale": CONTEXT_SCALE, "roi_size": ROI_SIZE},
        "runtime": {"max_boxes_per_run": 512, "intra_op_threads": 1},
        "min_confidence": 0.5,
        "sha256": {
            "backbone": hashlib.sha256(backbone_path.read_bytes()).hexdigest(),
            "head": hashlib.sha256(head_path.read_bytes()).hexdigest(),
        },
    }
    (out / "tiny-classifier.json").write_text(json.dumps(spec_json, indent=2, sort_keys=True) + "\n")

    expected = {
        "image": "tiny-classifier.image.png",
        "boxes": FIXTURE_BOXES,
        "expectedClassIndex": predicted,
        "expectedRole": [ROLES[i] for i in predicted],
        "probabilities": [[float(v) for v in row] for row in probs],
        "torchOrtDrift": drift,
    }
    (out / "tiny-classifier.expected.json").write_text(
        json.dumps(expected, indent=2, sort_keys=True) + "\n")

    verify_dynamic_shapes(backbone_session, head_session, spec)

    print(f"wrote fixtures to {out}")
    for box, index, row in zip(FIXTURE_BOXES, predicted, probs):
        print(f"  {box} -> {ROLES[index]:<14} p={row[index]:.6f}")
    print(f"  torch vs ORT max drift {drift:.3e}")


def verify_dynamic_shapes(backbone_session, head_session, spec: PreprocessSpec) -> None:
    """The exported graphs must accept an image size and a box count they never saw.

    PIN: THIS IS NOT PARANOIA. Tracing turns any shape read through a Python int into a
         constant, and a head that baked the export-time resolution still runs — it
         just returns wrong numbers for every other screenshot, with no error anywhere.
         A different size and a different box count is the only way to see it.
    """
    other = np.full((96, 448, 3), 255, dtype=np.uint8)
    other[8:56, 8:104] = (220, 30, 30)
    prepared = prepare_image(other, spec)
    features = backbone_session.run(["features"], {"image": prepared.tensor})[0]

    expected_shape = (1, CHANNELS, prepared.padded_height // STRIDE, prepared.padded_width // STRIDE)
    if features.shape != expected_shape:
        raise SystemExit(f"backbone ignored the input size: {features.shape} != {expected_shape}")

    for count in (1, 5):
        boxes = prepare_boxes(np.array([[8, 8, 96, 48]] * count, dtype=np.float32), prepared)
        probs = head_session.run(["probs"], {"features": features, "boxes": boxes})[0]
        if probs.shape != (count, len(ROLES)):
            raise SystemExit(f"head ignored the box count: {probs.shape}")
        if int(np.argmax(probs[0])) != BUTTON:
            raise SystemExit("the red block stopped reading as a button at another size")

    # Zero boxes: a screenshot can legitimately yield no proposals.
    empty = np.zeros((0, 5), dtype=np.float32)
    empty_probs = head_session.run(["probs"], {"features": features, "boxes": empty})[0]
    if empty_probs.shape != (0, len(ROLES)):
        raise SystemExit(f"head mishandled an empty batch: {empty_probs.shape}")
    print("  dynamic shapes verified (448x96 image, 1/5/0 boxes)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    export(parser.parse_args().out)
