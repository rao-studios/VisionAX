"""`vxtrain` — stats, train, eval, calibrate, export, parity."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import yaml


def _config(path: Path | None) -> dict:
    default = Path(__file__).resolve().parent.parent / "configs" / "default.yaml"
    return yaml.safe_load((path or default).read_text())


def main() -> None:
    parser = argparse.ArgumentParser(prog="vxtrain", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("stats", help="class histogram and proposal recall of a dataset")
    p.add_argument("dataset", type=Path)
    p.add_argument("--config", type=Path)

    p = sub.add_parser("train", help="train a classifier")
    p.add_argument("--dataset", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--config", type=Path)

    p = sub.add_parser("eval", help="score a trained run on its validation split")
    p.add_argument("--run", type=Path, required=True)
    p.add_argument("--dataset", type=Path, required=True)

    p = sub.add_parser("calibrate", help="fit a temperature and pick min_confidence")
    p.add_argument("--run", type=Path, required=True)
    p.add_argument("--dataset", type=Path, required=True)

    p = sub.add_parser("export", help="write the two ONNX graphs and the spec")
    p.add_argument("--run", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--name", default="region-classifier")

    p = sub.add_parser("parity", help="torch vs ONNX Runtime on real images")
    p.add_argument("--spec", type=Path, required=True)
    p.add_argument("--dataset", type=Path, required=True)
    p.add_argument("--run", type=Path)
    p.add_argument("--n", type=int, default=20)

    args = parser.parse_args()

    if args.command == "stats":
        from .dataset import class_histogram, load, split
        from .roles import RoleTable
        config = _config(args.config)
        table = RoleTable.load(args.dataset)
        examples = load(args.dataset, table,
                        positive=float(config["positive_iou"]),
                        floor=float(config["ignore_floor"]))
        train, val = split(examples, float(config["val_fraction"]), int(config["seed"]))
        print(f"{len(examples)} images  ({len(train)} train / {len(val)} val)")
        print(f"{sum(len(e.boxes) for e in examples)} proposals")
        counts = class_histogram(examples, table)
        width = max(len(k) for k in counts)
        for role, count in sorted(counts.items(), key=lambda kv: -kv[1]):
            if count:
                print(f"  {role:<{width}}  {count}")
        manifest = args.dataset / "manifest.json"
        if manifest.exists():
            runs = json.loads(manifest.read_text()).get("runs", [])
            for entry in runs:
                recall = entry.get("recall", {}).get("overall", {})
                if recall.get("total"):
                    print(f"  run {entry['id']}: proposal recall "
                          f"{recall['found']}/{recall['total']} "
                          f"({100 * recall['found'] / recall['total']:.1f}%)")

    elif args.command == "train":
        from .train import run
        run(args.dataset, args.out, _config(args.config))

    elif args.command == "eval":
        import torch
        from .dataset import load, split
        from .evaluate import evaluate, format_report
        from .model import RegionClassifier
        from .preprocess import PreprocessSpec
        from .roles import RoleTable
        from .train import device_for
        from .train import apply_folding, rare_classes
        checkpoint = torch.load(args.run / "best.pt", map_location="cpu", weights_only=False)
        config = checkpoint["config"]
        table = RoleTable.load(args.dataset)
        examples = load(args.dataset, table,
                        positive=float(config["positive_iou"]),
                        floor=float(config["ignore_floor"]))
        train_split, val = split(examples, float(config["val_fraction"]), int(config["seed"]))
        # The SAME folding training used, or this scores the model on classes it was
        # never taught and reports a macro-F1 that means nothing.
        folded, _ = rare_classes(train_split, table, int(config["min_class_count"]))
        apply_folding(val, table, folded)
        if folded:
            print(f"not trained (folded into none): {', '.join(folded)}\n")
        net = RegionClassifier(len(checkpoint["roles"]), config)
        net.load_state_dict(checkpoint["model"])
        device = device_for()
        net.to(device)
        spec = PreprocessSpec(long_side=int(config["long_side"]),
                              pad_multiple=int(config["pad_multiple"]))
        report = evaluate(net, val, table, spec, device)
        print(format_report(report))
        (args.run / "eval.json").write_text(json.dumps(report, indent=2))

    elif args.command == "calibrate":
        from .calibrate import run
        run(args.run, args.dataset)

    elif args.command == "export":
        from .export import run
        run(args.run, args.out, args.name)

    elif args.command == "parity":
        from .parity import run
        run(args.spec, args.dataset, args.n, args.run)
