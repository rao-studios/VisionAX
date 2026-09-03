"""Metrics that mean something for Mary.

PIN: macro-F1, not accuracy. Accuracy on a corpus that is 60% `none` and 25%
     AXStaticText is a number a constant predictor scores well on. And the last metric
     here is the one that matters most in production: how often the model says
     something CONFIDENT and WRONG about a box that is not an element — because Mary
     will click that.
"""

from __future__ import annotations

import numpy as np
import torch

from .dataset import IGNORE_LABEL, size_bucket
from .preprocess import prepare_boxes, prepare_image
from .roles import affordance_groups


@torch.no_grad()
def collect(net, examples, spec, device, limit_boxes: int = 4000):
    net.eval()
    truths, predictions, confidences, buckets, rows = [], [], [], [], []
    for example in examples:
        try:
            image = example.load_image()
        except FileNotFoundError:
            continue
        keep = np.flatnonzero(example.labels != IGNORE_LABEL)[:limit_boxes]
        if keep.size == 0:
            continue
        prepared = prepare_image(image, spec)
        rois = prepare_boxes(example.boxes[keep], prepared)
        logits = net(torch.from_numpy(prepared.tensor).to(device),
                     torch.from_numpy(rois).to(device))
        probability = torch.softmax(logits, dim=1).cpu().numpy()
        predictions.append(probability.argmax(axis=1))
        confidences.append(probability.max(axis=1))
        rows.append(probability)
        truths.append(example.labels[keep])
        buckets.extend(size_bucket(w, h) for w, h in example.boxes[keep][:, 2:4])
    if not truths:
        return (np.zeros(0, int), np.zeros(0, int), np.zeros(0, float), [],
                np.zeros((0, 0), float))
    return (np.concatenate(truths), np.concatenate(predictions),
            np.concatenate(confidences), buckets, np.concatenate(rows))


def scores(truth: np.ndarray, predicted: np.ndarray, class_count: int):
    per_class = {}
    f1s = []
    for klass in range(class_count):
        tp = int(np.sum((predicted == klass) & (truth == klass)))
        fp = int(np.sum((predicted == klass) & (truth != klass)))
        fn = int(np.sum((predicted != klass) & (truth == klass)))
        precision = tp / (tp + fp) if tp + fp else 0.0
        recall = tp / (tp + fn) if tp + fn else 0.0
        f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
        per_class[klass] = {"precision": precision, "recall": recall, "f1": f1,
                            "support": int(np.sum(truth == klass))}
        if per_class[klass]["support"] > 0:
            f1s.append(f1)
    return per_class, float(np.mean(f1s)) if f1s else 0.0


def affordance_scores(truth, probabilities, table) -> dict:
    """How well the model answers the question Mary actually asks.

    PIN: THE MARGINAL, NOT A SECOND HEAD. Summing the probability of every role in a
         group is the same quantity a learned affordance head would predict, and it
         costs nothing to train. It also forgives the confusions that do not matter —
         a link read as a button is still something to press — which is why this number
         is far higher than macro-F1 and is the one the page map actually depends on.
    """
    groups = affordance_groups(table)
    if not groups or probabilities.size == 0:
        return {}
    names = ["none"] + sorted(groups)
    marginals = np.zeros((probabilities.shape[0], len(names)), dtype=float)
    claimed = np.zeros(probabilities.shape[1], dtype=bool)
    for position, name in enumerate(names[1:], start=1):
        indexes = groups[name]
        marginals[:, position] = probabilities[:, indexes].sum(axis=1)
        claimed[indexes] = True
    marginals[:, 0] = probabilities[:, ~claimed].sum(axis=1)

    def group_of(label: int) -> int:
        for position, name in enumerate(names[1:], start=1):
            if label in groups[name]:
                return position
        return 0

    truth_groups = np.array([group_of(int(label)) for label in truth])
    predicted_groups = marginals.argmax(axis=1)
    per_group, macro = scores(truth_groups, predicted_groups, len(names))
    return {
        "top1": float(np.mean(truth_groups == predicted_groups)),
        "macro_f1": macro,
        "per_group": {names[k]: v for k, v in per_group.items()},
    }


def evaluate(net, examples, table, spec, device, min_confidence: float = 0.5) -> dict:
    truth, predicted, confidence, buckets, probabilities = collect(
        net, examples, spec, device)
    if truth.size == 0:
        return {"macro_f1": 0.0, "top1": 0.0, "category_accuracy": 0.0,
                "unsafe_rate": 0.0, "per_class": {}, "by_size": {}, "affordance": {}}

    per_class, macro = scores(truth, predicted, table.class_count)
    top1 = float(np.mean(truth == predicted))

    # Category accuracy uses Swift's role->category table, shipped in roles.json, so it
    # cannot drift from what Mary actually does with a role.
    categories = np.array([table.category(i) for i in range(table.class_count)])
    category_accuracy = float(np.mean(categories[truth] == categories[predicted]))

    # The Mary-safety number: confident, non-`none`, and wrong about background.
    confident = confidence >= min_confidence
    unsafe = np.sum(confident & (predicted != 0) & (truth == 0))
    background = max(1, int(np.sum(truth == 0)))
    unsafe_rate = float(unsafe) / background

    by_size: dict[str, dict] = {}
    bucket_array = np.array(buckets)
    for name in ["<16", "16-32", "32-64", ">64"]:
        mask = bucket_array == name
        if not mask.any():
            continue
        _, bucket_macro = scores(truth[mask], predicted[mask], table.class_count)
        by_size[name] = {"macro_f1": bucket_macro, "count": int(mask.sum())}

    return {
        "macro_f1": macro,
        "top1": top1,
        "category_accuracy": category_accuracy,
        "unsafe_rate": unsafe_rate,
        "per_class": {table.roles[k]: v for k, v in per_class.items()},
        "by_size": by_size,
        "affordance": affordance_scores(truth, probabilities, table),
    }


def format_report(report: dict) -> str:
    lines = [
        f"macro-F1            {report['macro_f1']:.3f}",
        f"top-1               {report['top1']:.3f}",
        f"category accuracy   {report['category_accuracy']:.3f}",
        f"confident-and-wrong {report['unsafe_rate']:.4f}  (non-none predicted on background)",
        "",
        "  role                    P      R      F1     n",
    ]
    for role, scores_ in sorted(report["per_class"].items(),
                                key=lambda kv: -kv[1]["support"]):
        if scores_["support"] == 0:
            continue
        lines.append(f"  {role:<22} {scores_['precision']:.3f}  {scores_['recall']:.3f}  "
                     f"{scores_['f1']:.3f}  {scores_['support']}")
    affordance = report.get("affordance") or {}
    if affordance:
        lines.append("")
        lines.append(f"  affordance (marginals)  top-1 {affordance['top1']:.3f}  "
                     f"macro-F1 {affordance['macro_f1']:.3f}")
        for name, value in sorted(affordance["per_group"].items()):
            if value["support"] == 0:
                continue
            lines.append(f"  {name:<22} {value['precision']:.3f}  {value['recall']:.3f}  "
                         f"{value['f1']:.3f}  {value['support']}")
    if report["by_size"]:
        lines.append("")
        lines.append("  short side   macro-F1   n")
        for bucket, value in report["by_size"].items():
            lines.append(f"  {bucket:<12} {value['macro_f1']:.3f}      {value['count']}")
    return "\n".join(lines)
