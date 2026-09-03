"""Proves torch and ONNX Runtime agree, on the images the model will really see.

PIN: This is the test that catches an export that "worked". A graph can pass
     onnx.checker, load in ORT, return the right SHAPE, and still be numerically off
     because the exporter quietly changed a sampling ratio or a padding rule. The only
     thing that settles it is running both on real pixels and comparing probabilities.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import torch

from .dataset import IGNORE_LABEL, load, split
from .model import RegionClassifier
from .preprocess import PreprocessSpec, prepare_boxes, prepare_image
from .roles import RoleTable

TOLERANCE = 1e-3


def run(spec_path: Path, dataset_root: Path, count: int = 20, run_dir: Path | None = None) -> float:
    import onnxruntime as ort

    spec_json = json.loads(spec_path.read_text())
    directory = spec_path.parent
    backbone_session = ort.InferenceSession(
        str(directory / spec_json["files"]["backbone"]), providers=["CPUExecutionProvider"])
    head_session = ort.InferenceSession(
        str(directory / spec_json["files"]["head"]), providers=["CPUExecutionProvider"])

    run_dir = run_dir or (Path("runs") / "r1")
    checkpoint = torch.load(run_dir / "best.pt", map_location="cpu", weights_only=False)
    config = checkpoint["config"]
    net = RegionClassifier(len(checkpoint["roles"]), config)
    net.load_state_dict(checkpoint["model"])
    net.eval()

    table = RoleTable.load(dataset_root)
    examples = load(dataset_root, table,
                    positive=float(config["positive_iou"]),
                    floor=float(config["ignore_floor"]))
    _, val = split(examples, float(config["val_fraction"]), int(config["seed"]))
    spec = PreprocessSpec.from_json(spec_json["preprocess"])

    worst = 0.0
    disagreements = 0
    compared = 0
    for example in val[:count]:
        try:
            image = example.load_image()
        except FileNotFoundError:
            continue
        keep = np.flatnonzero(example.labels != IGNORE_LABEL)[:256]
        if keep.size == 0:
            continue
        prepared = prepare_image(image, spec)
        rois = prepare_boxes(example.boxes[keep], prepared)

        with torch.no_grad():
            reference = torch.softmax(
                net(torch.from_numpy(prepared.tensor), torch.from_numpy(rois)), dim=1).numpy()

        features = backbone_session.run(["features"], {"image": prepared.tensor})[0]
        probs = head_session.run(["probs"], {"features": features, "boxes": rois})[0]

        worst = max(worst, float(np.max(np.abs(probs - reference))))
        disagreements += int(np.sum(probs.argmax(axis=1) != reference.argmax(axis=1)))
        compared += keep.size

    print(f"parity over {compared} boxes: max |dprob| {worst:.2e}, "
          f"{disagreements} argmax disagreements")
    if worst > TOLERANCE:
        raise SystemExit(f"torch and ORT disagree by {worst:.2e} (limit {TOLERANCE})")
    return worst
