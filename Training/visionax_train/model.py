"""The classifier: one backbone pass per image, one head pass per box.

WHAT: Backbone (image -> stride-8 features) + Head (features + boxes -> logits).
OUT:  two ONNX graphs, exported separately by export.py.
PIN:  THE SPLIT IS NOT AN OPTIMISATION, IT IS THE ARCHITECTURE. A screenshot yields
      ~1,000 boxes and two 7x7x128 RoIAlign crops each; fused into one graph that is
      hundreds of megabytes of activations and cannot be chunked without recomputing
      the backbone. Splitting also puts the CoreML seam in the right place for later:
      RoiAlign has no CoreML kernel, so a single graph would be partitioned in the
      middle by the runtime rather than by us.
      The head reads the image extent from the FEATURE MAP's own shape, so one export
      serves every screenshot size. Reading it from a Python int would bake the export
      resolution in and be wrong everywhere else, silently.
"""

from __future__ import annotations

import torch
import torch.nn as nn
import torch.nn.functional as F
from torchvision.models import ResNet18_Weights, resnet18
from torchvision.ops import roi_align

from .head_ops import context_boxes, geometry_features, padded_extent

GEOMETRY_FEATURES = 8


class Backbone(nn.Module):
    """ImageNet ResNet-18 cut at layer3, with layer2 and layer3 fused at stride 8.

    Stride 8 matters: at 16, a 24px checkbox is one and a half cells and RoIAlign has
    nothing to interpolate between. The layer3 branch is what supplies the context a
    7x7 crop of a small box would otherwise lack.
    """

    def __init__(self, channels: int = 128, pretrained: bool = True):
        super().__init__()
        weights = ResNet18_Weights.IMAGENET1K_V1 if pretrained else None
        net = resnet18(weights=weights)
        self.stem = nn.Sequential(net.conv1, net.bn1, net.relu, net.maxpool)
        self.layer1 = net.layer1     # stride 4
        self.layer2 = net.layer2     # stride 8,  128ch
        self.layer3 = net.layer3     # stride 16, 256ch
        self.lateral8 = nn.Conv2d(128, channels, 1)
        self.lateral16 = nn.Conv2d(256, channels, 1)
        self.smooth = nn.Conv2d(channels, channels, 3, padding=1)
        self.out_channels = channels

    def forward(self, image: torch.Tensor) -> torch.Tensor:
        x = self.stem(image)
        x = self.layer1(x)
        c8 = self.layer2(x)
        c16 = self.layer3(c8)
        merged = self.lateral8(c8) + F.interpolate(
            self.lateral16(c16), scale_factor=2.0, mode="nearest")
        return self.smooth(merged)


class Head(nn.Module):
    """Two RoIAlign crops and the box's geometry, into one classifier."""

    def __init__(
        self,
        class_count: int,
        channels: int = 128,
        roi_size: int = 7,
        stride: int = 8,
        context_scale: float = 2.0,
        dropout: float = 0.2,
        softmax: bool = False,
    ):
        super().__init__()
        self.roi_size = roi_size
        self.stride = stride
        self.context_scale = context_scale
        self.softmax = softmax

        crop = channels * roi_size * roi_size
        self.box_fc = nn.Sequential(nn.Linear(crop, 256), nn.ReLU(inplace=True))
        self.context_fc = nn.Sequential(nn.Linear(crop, 256), nn.ReLU(inplace=True))
        self.geometry_fc = nn.Sequential(nn.Linear(GEOMETRY_FEATURES, 32), nn.ReLU(inplace=True))
        self.classify = nn.Sequential(
            nn.Linear(256 + 256 + 32, 256), nn.ReLU(inplace=True),
            nn.Dropout(dropout), nn.Linear(256, class_count))

    def forward(self, features: torch.Tensor, boxes: torch.Tensor) -> torch.Tensor:
        width, height = padded_extent(features, self.stride, boxes.dtype)
        context = context_boxes(boxes, self.context_scale, width, height)
        scale = 1.0 / self.stride
        size = (self.roi_size, self.roi_size)

        # sampling_ratio=0 and aligned=True: the exporter rewrites any other sampling
        # ratio to 0 silently, so training with one would serve a different model.
        box_crop = roi_align(features, boxes, size, scale, 0, True).flatten(1)
        context_crop = roi_align(features, context, size, scale, 0, True).flatten(1)

        merged = torch.cat([
            self.box_fc(box_crop),
            self.context_fc(context_crop),
            self.geometry_fc(geometry_features(boxes, width, height)),
        ], dim=1)
        logits = self.classify(merged)
        return torch.softmax(logits, dim=1) if self.softmax else logits


class RegionClassifier(nn.Module):
    """Training-time wrapper; the two halves are exported separately."""

    def __init__(self, class_count: int, config: dict):
        super().__init__()
        channels = int(config.get("feature_channels", 128))
        self.backbone = Backbone(channels=channels)
        self.head = Head(
            class_count=class_count,
            channels=channels,
            roi_size=int(config.get("roi_size", 7)),
            stride=int(config.get("stride", 8)),
            context_scale=float(config.get("context_scale", 2.0)),
            dropout=float(config.get("dropout", 0.2)))

    def forward(self, image: torch.Tensor, boxes: torch.Tensor) -> torch.Tensor:
        return self.head(self.backbone(image), boxes)
