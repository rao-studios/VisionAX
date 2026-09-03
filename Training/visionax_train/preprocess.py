"""The preprocessing contract, shared by training, export and parity checking.

WHAT: image -> normalized CHW tensor; boxes -> [N,5] RoIAlign rois.
OUT:  the exact operations Sources/CVisionAX/ClassifierPreprocess.cpp performs.
PIN:  THIS FILE AND ITS C++ TWIN MUST AGREE TO THE LAST BIT. A model trained on
      PIL-resized pixels and served on cv::INTER_AREA-resized pixels is a model that
      quietly loses a few points of accuracy with nothing in any log to say why.
      Three details carry that agreement and none of them are incidental:
        * rounding is floor(x + 0.5), spelled out, because Python's round() is
          banker's rounding and C++'s lround is not;
        * padding is the mean colour, which normalizes to exactly 0.0, so both sides
          allocate zeros and fill a corner rather than computing a pad value;
        * boxes scale per axis (W'/W, H'/H), because rounding each side independently
          makes one shared scale wrong by up to half a pixel on the other axis.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

import cv2
import numpy as np

# ImageNet statistics: the backbone is pretrained, so these are not free parameters.
DEFAULT_MEAN = (0.485, 0.456, 0.406)
DEFAULT_STD = (0.229, 0.224, 0.225)


@dataclass(frozen=True)
class PreprocessSpec:
    """Everything the runtime needs to reproduce training-time pixels."""

    long_side: int = 1600
    pad_multiple: int = 32
    interpolation: str = "area"
    pad_value: str = "mean"
    channel_order: str = "rgb"
    mean: tuple[float, float, float] = DEFAULT_MEAN
    std: tuple[float, float, float] = DEFAULT_STD

    def to_json(self) -> dict:
        return {
            "long_side": self.long_side,
            "pad_multiple": self.pad_multiple,
            "interpolation": self.interpolation,
            "pad_value": self.pad_value,
            "channel_order": self.channel_order,
            "mean": list(self.mean),
            "std": list(self.std),
        }

    @staticmethod
    def from_json(raw: dict) -> "PreprocessSpec":
        return PreprocessSpec(
            long_side=int(raw["long_side"]),
            pad_multiple=int(raw["pad_multiple"]),
            interpolation=raw.get("interpolation", "area"),
            pad_value=raw.get("pad_value", "mean"),
            channel_order=raw.get("channel_order", "rgb"),
            mean=tuple(raw["mean"]),
            std=tuple(raw["std"]),
        )


@dataclass
class PreparedImage:
    """Normalized pixels plus the geometry needed to place boxes on them."""

    tensor: np.ndarray  # float32 [1, 3, padded_height, padded_width]
    scale_x: float
    scale_y: float
    resized_width: int
    resized_height: int
    padded_width: int
    padded_height: int


def _round_half_up(value: float) -> int:
    """floor(x + 0.5) — the one rounding both languages spell identically."""
    return int(math.floor(value + 0.5))


def resized_size(width: int, height: int, long_side: int) -> tuple[int, int]:
    """The resized dimensions. Never upscales: long_side is a ceiling, not a target."""
    if long_side <= 0:
        return width, height
    longest = max(width, height)
    if longest <= long_side:
        return width, height
    scale = long_side / longest
    return max(1, _round_half_up(width * scale)), max(1, _round_half_up(height * scale))


def padded_size(width: int, height: int, multiple: int) -> tuple[int, int]:
    if multiple <= 1:
        return width, height
    return (
        int(math.ceil(width / multiple)) * multiple,
        int(math.ceil(height / multiple)) * multiple,
    )


def prepare_image(rgb: np.ndarray, spec: PreprocessSpec) -> PreparedImage:
    """`rgb` is uint8 HxWx3 in RGB order. Returns the tensor the backbone consumes."""
    if rgb.ndim != 3 or rgb.shape[2] != 3 or rgb.dtype != np.uint8:
        raise ValueError(f"expected uint8 HxWx3 RGB, got {rgb.shape} {rgb.dtype}")

    height, width = rgb.shape[:2]
    new_width, new_height = resized_size(width, height, spec.long_side)
    if (new_width, new_height) != (width, height):
        # INTER_AREA is the only interpolation that averages the pixels it discards,
        # which is what keeps a one-pixel border visible after a 2x downscale.
        resized = cv2.resize(rgb, (new_width, new_height), interpolation=cv2.INTER_AREA)
    else:
        resized = rgb

    pad_width, pad_height = padded_size(new_width, new_height, spec.pad_multiple)

    # Zeros ARE the mean colour once normalized, so the padding costs no arithmetic
    # and, more importantly, cannot disagree with the C++ side about a fill value.
    tensor = np.zeros((1, 3, pad_height, pad_width), dtype=np.float32)
    pixels = resized.astype(np.float32) / 255.0
    for channel in range(3):
        plane = (pixels[:, :, channel] - spec.mean[channel]) / spec.std[channel]
        tensor[0, channel, :new_height, :new_width] = plane

    return PreparedImage(
        tensor=tensor,
        scale_x=new_width / width,
        scale_y=new_height / height,
        resized_width=new_width,
        resized_height=new_height,
        padded_width=pad_width,
        padded_height=pad_height,
    )


def prepare_boxes(boxes_xywh: np.ndarray, prepared: PreparedImage) -> np.ndarray:
    """Image-pixel xywh -> RoIAlign rois [N,5] = (batch, x0, y0, x1, y1), resized space.

    Deliberately neither rounded nor clipped: RoIAlign samples at sub-pixel positions,
    and the head clamps the context box itself.
    """
    boxes = np.asarray(boxes_xywh, dtype=np.float32).reshape(-1, 4)
    rois = np.zeros((boxes.shape[0], 5), dtype=np.float32)
    rois[:, 1] = boxes[:, 0] * prepared.scale_x
    rois[:, 2] = boxes[:, 1] * prepared.scale_y
    rois[:, 3] = (boxes[:, 0] + boxes[:, 2]) * prepared.scale_x
    rois[:, 4] = (boxes[:, 1] + boxes[:, 3]) * prepared.scale_y
    return rois
