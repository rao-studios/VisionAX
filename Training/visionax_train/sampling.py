"""Which boxes a training step actually sees.

PIN: `none` is the majority class by a wide margin — most of what Canny proposes is
     not an element — and left alone it swallows the loss until the model answers
     `none` to everything and reports a fine top-1. Capping its share per step is what
     keeps the rare classes alive. Jitter models the other half of the problem: at
     inference the boxes come from Canny, whose idea of a button's edge is a pixel or
     two off from the DOM's, and a model trained only on exact boxes has never seen
     that.
"""

from __future__ import annotations

import numpy as np

from .dataset import IGNORE_LABEL


def choose(labels: np.ndarray, limit: int, none_fraction: float, rng: np.random.Generator):
    """Indices to train on this step: everything rare, `none` capped, ignores dropped."""
    keep = np.flatnonzero(labels != IGNORE_LABEL)
    if keep.size == 0:
        return keep

    positives = keep[labels[keep] != 0]
    negatives = keep[labels[keep] == 0]

    max_negatives = int(limit * none_fraction)
    if negatives.size > max_negatives:
        negatives = rng.choice(negatives, size=max_negatives, replace=False)

    room = limit - negatives.size
    if positives.size > room:
        # Balance within the positives too, so a page of 300 text runs and 2 sliders
        # does not spend the whole step on text.
        chosen: list[int] = []
        classes, counts = np.unique(labels[positives], return_counts=True)
        per_class = max(1, room // max(1, len(classes)))
        for klass in classes:
            pool = positives[labels[positives] == klass]
            take = min(len(pool), per_class)
            chosen.extend(rng.choice(pool, size=take, replace=False).tolist())
        leftover = room - len(chosen)
        if leftover > 0:
            rest = np.setdiff1d(positives, np.asarray(chosen, dtype=positives.dtype))
            if rest.size:
                chosen.extend(rng.choice(
                    rest, size=min(leftover, rest.size), replace=False).tolist())
        positives = np.asarray(chosen, dtype=keep.dtype)

    return np.concatenate([positives, negatives])


def jitter(boxes: np.ndarray, rng: np.random.Generator, amount: float = 0.04) -> np.ndarray:
    """Nudge each edge by up to `amount` of the box's size — Canny's slop, modelled."""
    if boxes.size == 0:
        return boxes
    out = boxes.astype(np.float32).copy()
    widths = out[:, 2:3]
    heights = out[:, 3:4]
    out[:, 0:1] += rng.uniform(-amount, amount, size=widths.shape) * widths
    out[:, 1:2] += rng.uniform(-amount, amount, size=heights.shape) * heights
    out[:, 2:3] *= 1.0 + rng.uniform(-amount, amount, size=widths.shape)
    out[:, 3:4] *= 1.0 + rng.uniform(-amount, amount, size=heights.shape)
    out[:, 2:4] = np.maximum(out[:, 2:4], 1.0)
    return out


def photometric(image: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    """Mild brightness and contrast only. No flips: a mirrored UI is not a UI, and a
    model taught that layouts mirror would lose the left-to-right priors that make a
    close button a close button."""
    if rng.random() < 0.5:
        return image
    brightness = rng.uniform(-24, 24)
    contrast = rng.uniform(0.88, 1.12)
    out = image.astype(np.float32) * contrast + brightness
    return np.clip(out, 0, 255).astype(np.uint8)
