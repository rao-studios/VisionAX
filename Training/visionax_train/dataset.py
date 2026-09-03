"""Reads the harvested dataset into training tensors.

WHAT: Dataset/samples/*.json + images -> per-image (image, boxes, labels).
PIN:  LABELS ARE RECOMPUTED HERE from the IoUs the harvester stored, not read from
      its `label` field. That is what makes the matching thresholds a training
      hyper-parameter rather than a property frozen into the corpus — moving
      positive_iou means re-reading JSON, not re-crawling the web. The split is by
      ORIGIN, so every shot of one page (two viewports, two schemes, two scrolls)
      lands on the same side; splitting by sample would put near-identical images in
      both train and val and report an accuracy that does not exist.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np

from .roles import NONE_ROLE, RoleTable

IGNORE_LABEL = -1


@dataclass
class Example:
    sample_id: str
    image_path: Path
    boxes: np.ndarray      # [N,4] xywh, image pixels
    labels: np.ndarray     # [N]   class index, or IGNORE_LABEL
    group: str             # the origin every shot of one page shares

    def load_image(self) -> np.ndarray:
        bgr = cv2.imread(str(self.image_path), cv2.IMREAD_COLOR)
        if bgr is None:
            raise FileNotFoundError(self.image_path)
        return cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)


def _label_for(region: dict, roles_by_index: dict[int, str], positive: float, floor: float):
    """The same three-way decision ProposalMatcher makes, re-applied at a new threshold."""
    best = region.get("matchIoU", 0.0)
    if best < floor:
        return NONE_ROLE
    if best < positive:
        return None  # ignore
    matched = region.get("matchedElement")
    if matched is None or matched not in roles_by_index:
        return None
    role = roles_by_index[matched]
    second = region.get("secondIoU", 0.0)
    if second >= positive:
        other = region.get("secondElement")
        if other in roles_by_index and roles_by_index[other] != role:
            return None  # two strong matches that disagree
    return role


def load(root: Path, table: RoleTable, positive: float = 0.5, floor: float = 0.3) -> list[Example]:
    root = Path(root)
    examples: list[Example] = []
    for path in sorted((root / "samples").glob("*.json")):
        sample = json.loads(path.read_text())
        image_path = root / sample["imagePath"] if "imagePath" in sample else \
            root / "images" / f"{sample['id']}.png"
        if not image_path.exists():
            continue

        roles_by_index = {e["index"]: e["role"] for e in sample["elements"]}
        boxes, labels = [], []
        for region in sample["regions"]:
            rect = region["rect"]
            if rect["width"] < 1 or rect["height"] < 1:
                continue
            role = _label_for(region, roles_by_index, positive, floor)
            if role is None:
                index = IGNORE_LABEL
            else:
                resolved = table.index(role)
                # A role the model does not predict is background as far as it knows.
                index = resolved if resolved is not None else 0
            boxes.append([rect["x"], rect["y"], rect["width"], rect["height"]])
            labels.append(index)

        if not boxes:
            continue
        origin = sample.get("origin", {})
        group = origin.get("url") or origin.get("bundleID") or sample["id"]
        examples.append(Example(
            sample_id=sample["id"],
            image_path=image_path,
            boxes=np.asarray(boxes, dtype=np.float32),
            labels=np.asarray(labels, dtype=np.int64),
            group=group))
    return examples


def split(examples: list[Example], val_fraction: float, seed: int):
    """Group-wise, deterministic: the same page never straddles the split."""
    groups = sorted({e.group for e in examples})
    validation = set()
    for group in groups:
        digest = hashlib.sha1(f"{seed}:{group}".encode()).digest()
        if int.from_bytes(digest[:4], "big") / 0xFFFFFFFF < val_fraction:
            validation.add(group)
    train = [e for e in examples if e.group not in validation]
    val = [e for e in examples if e.group in validation]
    return train, val


def class_histogram(examples: list[Example], table: RoleTable) -> dict[str, int]:
    counts = {role: 0 for role in table.roles}
    ignored = 0
    for example in examples:
        for label in example.labels:
            if label == IGNORE_LABEL:
                ignored += 1
            else:
                counts[table.roles[label]] += 1
    counts["(ignored)"] = ignored
    return counts


def size_bucket(width: float, height: float) -> str:
    side = min(width, height)
    if side < 16:
        return "<16"
    if side < 32:
        return "16-32"
    if side < 64:
        return "32-64"
    return ">64"
