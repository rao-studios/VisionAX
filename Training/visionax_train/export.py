"""Exports the trained model to the two ONNX graphs the C engine loads.

PIN: dynamo=False and opset 17, and neither is negotiable. torchvision registers
     roi_align's ONNX symbolic ONLY for the legacy TorchScript exporter — the
     torch.export path has no translation for it and fails outright — and `aligned=True`
     needs opset >= 16 to become coordinate_transformation_mode="half_pixel". The
     exporter also rewrites a non-zero sampling_ratio to 0 with nothing but a warning,
     which is why the head is trained with 0 in the first place.
"""

from __future__ import annotations

import hashlib
import json
import subprocess
from pathlib import Path

import numpy as np
import torch

from .model import Head, RegionClassifier
from .preprocess import PreprocessSpec
from .roles import AFFORDANCES, RoleTable

OPSET = 17


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _git_commit() -> str:
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"], text=True).strip()
    except Exception:
        return "unknown"


class _SoftmaxHead(torch.nn.Module):
    """The head with softmax folded in — C reads probabilities, not logits, so the
    argmax and the confidence come from the same numbers the calibration used."""

    def __init__(self, head: Head):
        super().__init__()
        self.head = head

    def forward(self, features: torch.Tensor, boxes: torch.Tensor) -> torch.Tensor:
        return torch.softmax(self.head(features, boxes), dim=1)


def run(run_dir: Path, out_dir: Path, name: str = "region-classifier",
        min_confidence: float | None = None) -> Path:
    checkpoint = torch.load(run_dir / "best.pt", map_location="cpu", weights_only=False)
    config = checkpoint["config"]
    roles = checkpoint["roles"]
    out_dir.mkdir(parents=True, exist_ok=True)

    net = RegionClassifier(len(roles), config)
    net.load_state_dict(checkpoint["model"])
    net.eval()

    spec = PreprocessSpec(long_side=int(config["long_side"]),
                          pad_multiple=int(config["pad_multiple"]))

    # Two shapes that are not multiples of each other, so a baked-in size shows up as
    # a mismatch rather than passing by luck.
    image = torch.zeros(1, 3, 512, 384)
    with torch.no_grad():
        features = net.backbone(image)
    boxes = torch.tensor([[0.0, 8.0, 8.0, 120.0, 60.0],
                          [0.0, 40.0, 20.0, 90.0, 44.0]], dtype=torch.float32)

    backbone_path = out_dir / f"{name}.backbone.onnx"
    head_path = out_dir / f"{name}.head.onnx"

    torch.onnx.export(
        net.backbone, (image,), str(backbone_path),
        input_names=["image"], output_names=["features"],
        dynamic_axes={"image": {2: "height", 3: "width"},
                      "features": {2: "feature_height", 3: "feature_width"}},
        opset_version=OPSET, dynamo=False)

    torch.onnx.export(
        _SoftmaxHead(net.head), (features, boxes), str(head_path),
        input_names=["features", "boxes"], output_names=["probs"],
        dynamic_axes={"features": {2: "feature_height", 3: "feature_width"},
                      "boxes": {0: "boxes"}, "probs": {0: "boxes"}},
        opset_version=OPSET, dynamo=False)

    import onnx
    import onnxruntime as ort

    onnx.checker.check_model(onnx.load(str(backbone_path)))
    onnx.checker.check_model(onnx.load(str(head_path)))

    # Prove the exported pair accepts a size and a box count it never saw, including
    # the empty batch a blank screenshot produces.
    backbone_session = ort.InferenceSession(str(backbone_path), providers=["CPUExecutionProvider"])
    head_session = ort.InferenceSession(str(head_path), providers=["CPUExecutionProvider"])
    other = np.zeros((1, 3, 640, 896), dtype=np.float32)
    other_features = backbone_session.run(["features"], {"image": other})[0]
    for count in (0, 1, 37):
        rois = np.zeros((count, 5), dtype=np.float32)
        rois[:, 3] = 50.0
        rois[:, 4] = 30.0
        probs = head_session.run(["probs"], {"features": other_features, "boxes": rois})[0]
        assert probs.shape == (count, len(roles)), f"head broke at {count} boxes: {probs.shape}"

    calibration = json.loads((run_dir / "calibration.json").read_text()) \
        if (run_dir / "calibration.json").exists() else {}
    threshold = min_confidence if min_confidence is not None \
        else float(calibration.get("min_confidence", 0.5))

    table = {
        "format": 1,
        "name": name,
        "version": _git_commit(),
        "roles": roles,
        "files": {"backbone": backbone_path.name, "head": head_path.name},
        "io": {"image": "image", "features": "features", "boxes": "boxes", "probs": "probs"},
        # THE GROUPING TRAVELS WITH THE MODEL. What a role affords is a decision about
        # this vocabulary, so shipping it beside the vocabulary keeps a consumer from
        # keeping its own copy — and a copy is what drifts. Only the roles this run
        # actually has are listed.
        "affordances": {
            name: [role for role in members if role in roles]
            for name, members in sorted(AFFORDANCES.items())
            if any(role in roles for role in members)
        },
        "preprocess": spec.to_json(),
        "head": {"stride": int(config["stride"]),
                 "context_scale": float(config["context_scale"]),
                 "roi_size": int(config["roi_size"])},
        "runtime": {"max_boxes_per_run": 512, "intra_op_threads": 4},
        "min_confidence": threshold,
        "sha256": {"backbone": _sha256(backbone_path), "head": _sha256(head_path)},
        "trained_on": checkpoint.get("trained_on", {}),
    }
    spec_path = out_dir / f"{name}.json"
    spec_path.write_text(json.dumps(table, indent=2, sort_keys=True) + "\n")
    print(f"exported {backbone_path.name}, {head_path.name}, {spec_path.name}")
    print(f"  min_confidence {threshold:.3f}  classes {len(roles)}")
    return spec_path
