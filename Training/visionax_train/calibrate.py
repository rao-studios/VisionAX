"""Turns raw softmax into a threshold that means something.

PIN: A softmax maximum is not a probability of being right; it is systematically
     overconfident. Temperature scaling fixes the scale with one parameter fitted on
     validation, and only then is a threshold meaningful. The threshold is chosen for
     PRECISION, not F1, because the two errors are not symmetric here: a missed label
     leaves a region as VXRegion and Mary ignores it, while a wrong label is something
     she will click.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import torch

from .dataset import load, split
from .evaluate import collect
from .model import RegionClassifier
from .preprocess import PreprocessSpec
from .roles import RoleTable

TARGET_PRECISION = 0.9


@torch.no_grad()
def logits_and_truth(net, examples, spec, device):
    """Raw logits, kept unsoftmaxed so a temperature can be fitted to them."""
    from .dataset import IGNORE_LABEL
    from .preprocess import prepare_boxes, prepare_image
    net.eval()
    all_logits, all_truth = [], []
    for example in examples:
        try:
            image = example.load_image()
        except FileNotFoundError:
            continue
        keep = np.flatnonzero(example.labels != IGNORE_LABEL)
        if keep.size == 0:
            continue
        prepared = prepare_image(image, spec)
        rois = prepare_boxes(example.boxes[keep], prepared)
        logits = net(torch.from_numpy(prepared.tensor).to(device),
                     torch.from_numpy(rois).to(device))
        all_logits.append(logits.cpu())
        all_truth.append(torch.from_numpy(example.labels[keep]))
    if not all_logits:
        return torch.zeros(0, 1), torch.zeros(0, dtype=torch.long)
    return torch.cat(all_logits), torch.cat(all_truth)


def fit_temperature(logits: torch.Tensor, truth: torch.Tensor) -> float:
    temperature = torch.nn.Parameter(torch.ones(1) * 1.0)
    optimizer = torch.optim.LBFGS([temperature], lr=0.05, max_iter=80)
    criterion = torch.nn.CrossEntropyLoss()

    def closure():
        optimizer.zero_grad()
        loss = criterion(logits / temperature.clamp(min=0.05), truth)
        loss.backward()
        return loss

    optimizer.step(closure)
    return float(temperature.detach().clamp(min=0.05))


def run(run_dir: Path, dataset_root: Path) -> dict:
    checkpoint = torch.load(run_dir / "best.pt", map_location="cpu", weights_only=False)
    config = checkpoint["config"]
    table = RoleTable.load(dataset_root)
    examples = load(dataset_root, table,
                    positive=float(config["positive_iou"]),
                    floor=float(config["ignore_floor"]))
    train_split, val = split(examples, float(config["val_fraction"]), int(config["seed"]))
    from .train import apply_folding, rare_classes
    folded, _ = rare_classes(train_split, table, int(config["min_class_count"]))
    apply_folding(val, table, folded)

    device = torch.device("cpu")
    net = RegionClassifier(len(checkpoint["roles"]), config)
    net.load_state_dict(checkpoint["model"])
    net.to(device)
    spec = PreprocessSpec(long_side=int(config["long_side"]),
                          pad_multiple=int(config["pad_multiple"]))

    logits, truth = logits_and_truth(net, val, spec, device)
    if logits.numel() == 0:
        raise SystemExit("no validation boxes to calibrate on")

    temperature = fit_temperature(logits, truth)
    probability = torch.softmax(logits / temperature, dim=1).numpy()
    predicted = probability.argmax(axis=1)
    confidence = probability.max(axis=1)
    truth_np = truth.numpy()

    # The smallest threshold whose confident, non-`none` answers are right 90% of the
    # time. Nothing lower is safe to publish to Mary.
    chosen, achieved = 1.0, 0.0
    for candidate in np.arange(0.05, 1.0, 0.01):
        mask = (confidence >= candidate) & (predicted != 0)
        if mask.sum() < 20:
            continue
        precision = float(np.mean(predicted[mask] == truth_np[mask]))
        if precision >= TARGET_PRECISION:
            chosen, achieved = float(candidate), precision
            break

    result = {"temperature": temperature, "min_confidence": chosen,
              "precision_at_threshold": achieved,
              "target_precision": TARGET_PRECISION,
              "validation_boxes": int(truth_np.size)}
    (run_dir / "calibration.json").write_text(json.dumps(result, indent=2))
    print(f"temperature {temperature:.3f}  min_confidence {chosen:.2f}  "
          f"precision {achieved:.3f} over {truth_np.size} boxes")
    return result
