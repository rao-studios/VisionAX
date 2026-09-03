"""The training loop.

PIN: One image per forward pass, gradients accumulated over `images_per_step`. That is
     not a limitation being worked around — it is exactly the shape the exported graph
     runs in (one image, N boxes), so nothing about batching can differ between
     training and serving.

     BALANCE ONCE, NOT TWICE. The sampler already caps `none` and draws evenly across
     the classes present in an image, so weighting the loss by inverse frequency ON TOP
     of that corrects the same imbalance a second time. Tried, and it diverged inside
     two epochs: top-1 fell from 0.725 to 0.042 as the model learned to answer with
     rare classes everywhere. `class_weight_power` is therefore 0 by default — the
     sampler is the balancing mechanism, and the loss just reports what it sees.
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn

from .dataset import IGNORE_LABEL, Example, class_histogram, load, split
from .model import RegionClassifier
from .preprocess import PreprocessSpec, prepare_boxes, prepare_image
from .roles import RoleTable
from .sampling import choose, jitter, photometric


def device_for() -> torch.device:
    """Where to train.

    PIN: CPU, NOT MPS, AND THAT IS MEASURED. This model is a ResNet18 over a ~1600px
         image plus two RoIAlign crops per box, and on an M4 Max that shape runs 28x
         SLOWER on the GPU than on the CPU: 5.02s per image against 0.18s, timed with
         `Training/tools/device_bench.py`. A full epoch is four hours on MPS and nine
         minutes on CPU. The cause is in the small-op traffic around RoIAlign — a bare
         matmul is the same speed on both, and roi_align's forward alone is 10x slower
         on MPS — so it is not that the GPU is busy or unavailable.
         VXTRAIN_DEVICE overrides, because the day this stops being true it should be
         one environment variable to check rather than a patch.
    """
    requested = os.environ.get("VXTRAIN_DEVICE", "").strip().lower()
    if requested:
        return torch.device(requested)
    return torch.device("cpu")


def rare_classes(examples: list[Example], table: RoleTable, minimum: int):
    """Which classes are too rare to learn, decided on the TRAINING split alone.

    A class seen twice cannot be learned, but it can absolutely be predicted with high
    confidence on the strength of two examples — which is the failure that reaches Mary.
    """
    counts = class_histogram(examples, table)
    folded = [role for index, role in enumerate(table.roles)
              if index != 0 and counts.get(role, 0) < minimum]
    return folded, counts


def apply_folding(examples: list[Example], table: RoleTable, folded: list[str]) -> None:
    """Rewrites the named classes to `none`.

    PIN: THE SET COMES FROM TRAIN AND IS APPLIED TO VAL UNCHANGED. Re-deriving it from
    the validation split — which is smaller, so more classes look rare there — folds
    away exactly the classes the model does worst on and reports a macro-F1 several
    points higher than the truth. Measured: 0.712 that way against 0.60 done properly.
    """
    indices = [table.index(role) for role in folded if table.index(role) is not None]
    if not indices:
        return
    for example in examples:
        example.labels[np.isin(example.labels, indices)] = 0


def class_weights(examples: list[Example], class_count: int, power: float) -> torch.Tensor:
    """counts^-power, normalized. `power` 0 gives uniform weights, which is the
    default: the sampler is what balances, and doing it twice diverges.

    A class with no examples at all still gets weight 0, so a folded class cannot be
    predicted into existence by label smoothing.
    """
    counts = np.zeros(class_count, dtype=np.float64)
    for example in examples:
        for label in example.labels:
            if label != IGNORE_LABEL:
                counts[label] += 1
    if power <= 0:
        weights = np.ones(class_count, dtype=np.float64)
    else:
        weights = np.power(np.maximum(counts, 1.0), -power)
        weights = weights / weights.mean()
    weights[counts == 0] = 0.0
    return torch.tensor(weights, dtype=torch.float32)


def run(dataset_root: Path, out_dir: Path, config: dict) -> Path:
    torch.manual_seed(int(config["seed"]))
    rng = np.random.default_rng(int(config["seed"]))
    out_dir.mkdir(parents=True, exist_ok=True)

    table = RoleTable.load(dataset_root)
    examples = load(dataset_root, table,
                    positive=float(config["positive_iou"]),
                    floor=float(config["ignore_floor"]))
    if not examples:
        raise SystemExit(f"no usable samples in {dataset_root}")

    train_set, val_set = split(examples, float(config["val_fraction"]), int(config["seed"]))
    folded, counts = rare_classes(train_set, table, int(config["min_class_count"]))
    apply_folding(train_set, table, folded)
    apply_folding(val_set, table, folded)

    print(f"train {len(train_set)} images, val {len(val_set)} images")
    print("class counts:", {k: v for k, v in counts.items() if v})
    if folded:
        print(f"folded into none (fewer than {config['min_class_count']}): {', '.join(folded)}")

    spec = PreprocessSpec(long_side=int(config["long_side"]),
                          pad_multiple=int(config["pad_multiple"]))
    device = device_for()
    net = RegionClassifier(table.class_count, config).to(device)
    weights = class_weights(
        train_set, table.class_count, float(config.get("class_weight_power", 0.0))).to(device)
    criterion = nn.CrossEntropyLoss(
        weight=weights, label_smoothing=float(config["label_smoothing"]))

    optimizer = torch.optim.AdamW([
        {"params": net.backbone.parameters(), "lr": float(config["backbone_lr"])},
        {"params": net.head.parameters(), "lr": float(config["head_lr"])},
    ], weight_decay=float(config["weight_decay"]))
    epochs = int(config["epochs"])
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=epochs)

    best = -1.0
    best_path = out_dir / "best.pt"
    history = []
    # HOW MANY EPOCHS OF NO IMPROVEMENT BEFORE STOPPING. The previous run's history has
    # macro-F1 peaking at epoch 6 of 8 and falling after — training past the peak costs
    # half an hour an epoch and produces a worse checkpoint than the one already saved.
    patience = int(config.get("patience", 3))
    stale = 0

    for epoch in range(epochs):
        net.train()
        order = rng.permutation(len(train_set))
        total_loss, seen, started = 0.0, 0, time.time()
        optimizer.zero_grad(set_to_none=True)

        for step, index in enumerate(order):
            example = train_set[index]
            try:
                image = photometric(example.load_image(), rng)
            except FileNotFoundError:
                continue

            boxes = jitter(example.boxes, rng)
            picked = choose(example.labels, int(config["boxes_per_image"]),
                            float(config["none_fraction"]), rng)
            if picked.size == 0:
                continue

            prepared = prepare_image(image, spec)
            rois = prepare_boxes(boxes[picked], prepared)
            logits = net(
                torch.from_numpy(prepared.tensor).to(device),
                torch.from_numpy(rois).to(device))
            targets = torch.from_numpy(example.labels[picked]).to(device)
            loss = criterion(logits, targets) / float(config["images_per_step"])
            loss.backward()

            # detach: keeping the graph alive for a running total pins every
            # intermediate activation of the epoch.
            total_loss += float(loss.detach()) * float(config["images_per_step"])
            seen += 1
            if (step + 1) % int(config["images_per_step"]) == 0:
                torch.nn.utils.clip_grad_norm_(net.parameters(), 5.0)
                optimizer.step()
                optimizer.zero_grad(set_to_none=True)

        # Only if the epoch ended mid-accumulation: stepping on zeroed gradients would
        # still apply AdamW's decay for no reason.
        if len(order) % int(config["images_per_step"]) != 0:
            torch.nn.utils.clip_grad_norm_(net.parameters(), 5.0)
            optimizer.step()
        optimizer.zero_grad(set_to_none=True)
        scheduler.step()

        from .evaluate import evaluate
        report = evaluate(net, val_set, table, spec, device)
        affordance = report.get("affordance") or {}
        history.append({"epoch": epoch, "loss": total_loss / max(1, seen),
                        "macro_f1": report["macro_f1"], "top1": report["top1"],
                        "affordance_top1": affordance.get("top1", 0.0)})
        print(f"epoch {epoch + 1}/{epochs}  loss {total_loss / max(1, seen):.4f}  "
              f"macroF1 {report['macro_f1']:.3f}  top1 {report['top1']:.3f}  "
              f"afford {affordance.get('top1', 0.0):.3f}  "
              f"{time.time() - started:.0f}s")

        if report["macro_f1"] > best:
            best = report["macro_f1"]
            stale = 0
            torch.save({"model": net.state_dict(), "config": config,
                        "roles": list(table.roles), "macro_f1": best}, best_path)
        else:
            stale += 1
            if stale >= patience:
                print(f"stopping early: {patience} epochs without improving on {best:.3f}")
                break

    (out_dir / "history.json").write_text(json.dumps(history, indent=2))
    (out_dir / "folded.json").write_text(json.dumps(
        {"folded": folded, "counts": counts}, indent=2))
    print(f"best macro-F1 {best:.3f} -> {best_path}")
    return best_path
