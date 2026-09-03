"""The head's box arithmetic: context crops and geometry features.

PIN: SHARED BY THE FIXTURE MODEL AND THE REAL ONE, so the contract cannot fork. Every
     value here is computed INSIDE the graph from the feature map's own shape, which is
     what lets one exported head serve any image size. Reading the extent from Python
     ints instead would bake the export-time resolution into the model, and the failure
     would look like "the model is bad on large screenshots" rather than a shape bug.
"""

from __future__ import annotations

import torch


def padded_extent(features: torch.Tensor, stride: int, dtype: torch.dtype):
    """(width, height) of the image the features came from, as 0-d tensors.

    The shape tensor is born on the CPU even when the features are not, so it is moved
    explicitly — on MPS the mismatch is a hard error, and on a device where it is not,
    it would silently cost a synchronisation per box batch.
    """
    shape = torch._shape_as_tensor(features).to(features.device)
    width = shape[3].to(dtype) * stride
    height = shape[2].to(dtype) * stride
    return width, height


def context_boxes(rois: torch.Tensor, scale: float, width, height) -> torch.Tensor:
    """The same boxes grown about their centres and clamped to the image.

    The context crop is what tells a button from a table cell: the crop itself looks
    identical, and only the surroundings carry the difference.
    """
    batch = rois[:, 0:1]
    x0, y0, x1, y1 = rois[:, 1:2], rois[:, 2:3], rois[:, 3:4], rois[:, 4:5]
    cx = (x0 + x1) * 0.5
    cy = (y0 + y1) * 0.5
    half_w = (x1 - x0) * (0.5 * scale)
    half_h = (y1 - y0) * (0.5 * scale)
    zero = torch.zeros_like(cx)
    new_x0 = torch.clamp(torch.maximum(cx - half_w, zero), min=0)
    new_y0 = torch.maximum(cy - half_h, zero)
    new_x1 = torch.minimum(cx + half_w, width.to(cx.dtype).expand_as(cx))
    new_y1 = torch.minimum(cy + half_h, height.to(cy.dtype).expand_as(cy))
    return torch.cat([batch, new_x0, new_y0, new_x1, new_y1], dim=1)


def geometry_features(rois: torch.Tensor, width, height) -> torch.Tensor:
    """[N,8] — where the box is and what shape it is, independent of its pixels.

    A full-width 30px bar is a toolbar; the same pixels 80px wide in the middle of the
    page are a button. Size and position carry that, and no crop can.
    """
    x0, y0, x1, y1 = rois[:, 1:2], rois[:, 2:3], rois[:, 3:4], rois[:, 4:5]
    w = torch.clamp(x1 - x0, min=1e-3)
    h = torch.clamp(y1 - y0, min=1e-3)
    fw = width.to(x0.dtype).expand_as(x0)
    fh = height.to(y0.dtype).expand_as(y0)
    cx = (x0 + x1) * 0.5 / fw
    cy = (y0 + y1) * 0.5 / fh
    return torch.cat(
        [
            cx,
            cy,
            w / fw,
            h / fh,
            torch.log(w + 1.0),
            torch.log(h + 1.0),
            w / h,
            (w * h) / (fw * fh),
        ],
        dim=1,
    )
