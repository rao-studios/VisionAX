"""What one training step costs, per device.

WHAT: The measurement behind `train.device_for`, kept so the choice can be re-checked
      rather than believed.
PIN:  MEASURED, NOT ASSUMED, AND IT REVERSED THE OBVIOUS ANSWER. "Use the GPU" is right
      for almost every model and wrong for this one: a ResNet18 over a ~1600px image
      with two RoIAlign crops per box runs 28x slower on MPS than on CPU on an M4 Max.
      A run left on MPS spends four hours on an epoch the CPU finishes in nine minutes,
      and it does it while looking busy — 3% CPU, blocked in waitUntilCompleted, no
      output until the epoch ends.

    uv run python tools/device_bench.py
"""

from __future__ import annotations

import time

import numpy as np
import torch

from visionax_train.model import RegionClassifier
from visionax_train.preprocess import PreprocessSpec, prepare_boxes, prepare_image

CONFIG = {"long_side": 1600, "pad_multiple": 32, "roi_size": 7, "stride": 8,
          "context_scale": 2.0, "feature_channels": 128, "dropout": 0.2}


def one_step(device: str, repeats: int = 5) -> float:
    spec = PreprocessSpec(long_side=CONFIG["long_side"], pad_multiple=CONFIG["pad_multiple"])
    image = (np.random.rand(752, 917, 3) * 255).astype("uint8")
    boxes = np.column_stack([
        np.random.randint(0, 700, 192), np.random.randint(0, 600, 192),
        np.full(192, 60), np.full(192, 30)]).astype("float32")

    net = RegionClassifier(23, CONFIG).to(device)
    optimizer = torch.optim.AdamW(net.parameters(), lr=1e-4)
    criterion = torch.nn.CrossEntropyLoss()
    prepared = prepare_image(image, spec)
    rois = prepare_boxes(boxes, prepared)
    targets = torch.randint(0, 23, (192,)).to(device)

    def step():
        logits = net(torch.from_numpy(prepared.tensor).to(device),
                     torch.from_numpy(rois).to(device))
        loss = criterion(logits, targets)
        loss.backward()
        # The sync the training loop really performs, so the number includes it.
        _ = float(loss.detach())
        optimizer.step()
        optimizer.zero_grad(set_to_none=True)

    for _ in range(2):
        step()
    if device == "mps":
        torch.mps.synchronize()
    started = time.time()
    for _ in range(repeats):
        step()
    if device == "mps":
        torch.mps.synchronize()
    return (time.time() - started) / repeats


def main() -> None:
    devices = ["cpu"]
    if torch.backends.mps.is_available():
        devices.append("mps")
    print(f"one training step, {CONFIG['long_side']}px long side, 192 boxes")
    for device in devices:
        seconds = one_step(device)
        print(f"  {device:<4} {seconds:.2f}s per image "
              f"→ {seconds * 2980 / 60:.0f} min for a 2,980-image epoch")


if __name__ == "__main__":
    main()
