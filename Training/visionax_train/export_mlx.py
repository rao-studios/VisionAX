"""Converts the exported ONNX backbone into the MLX weights Frigate's VisionAX runs on Metal.

WHAT: <name>.backbone.onnx -> <name>.backbone.safetensors, and the spec gains
      files.backbone_mlx and sha256.backbone_mlx.
IN:   a spec written by `vxtrain export` — its files.backbone and sha256.backbone.
OUT:  the weights Frigate's Sources/FrigateVisionAX/Backbone/MLXRegionBackbone.swift loads.
PIN:  THE ONNX FILE IS THE SOURCE, NOT THE CHECKPOINT. BatchNorm is already folded into its
      convolutions, its weights are exactly what ONNX Runtime serves, and its sha256 is
      stamped into the output. Frigate refuses weights whose stamp is not the spec's backbone,
      so a retrain that skips this step falls back to CPU instead of serving a stale network.
      THE GRAPH MUST BE EXACTLY THE ONE FRIGATE IMPLEMENTS (resnet18-fpn8): the same op
      multiset and the same convolution table, node for node. Anything else is refused here,
      by name, rather than loaded there and wrong.
      Weights are transposed OIHW -> OHWI, MLX's convolution layout.
"""

from __future__ import annotations

import hashlib
import json
from collections import Counter
from pathlib import Path

import numpy as np

ARCH = "resnet18-fpn8"
FORMAT = "visionax-backbone-mlx/1"

EXPECTED_OPS = {"Conv": 18, "Relu": 13, "MaxPool": 1, "Add": 7, "Resize": 1, "Constant": 1}

# torch module path -> (kernel, stride, pad) of every convolution Frigate's net declares.
EXPECTED_CONVS = {
    "stem.0": (7, 2, 3),
    "layer1.0.conv1": (3, 1, 1),
    "layer1.0.conv2": (3, 1, 1),
    "layer1.1.conv1": (3, 1, 1),
    "layer1.1.conv2": (3, 1, 1),
    "layer2.0.conv1": (3, 2, 1),
    "layer2.0.conv2": (3, 1, 1),
    "layer2.0.downsample.0": (1, 2, 0),
    "layer2.1.conv1": (3, 1, 1),
    "layer2.1.conv2": (3, 1, 1),
    "layer3.0.conv1": (3, 2, 1),
    "layer3.0.conv2": (3, 1, 1),
    "layer3.0.downsample.0": (1, 2, 0),
    "layer3.1.conv1": (3, 1, 1),
    "layer3.1.conv2": (3, 1, 1),
    "lateral8": (1, 1, 0),
    "lateral16": (1, 1, 0),
    "smooth": (3, 1, 1),
}


class ConversionRefused(ValueError):
    """The graph is not the one Frigate implements, or the spec does not describe it."""


def module_path(node_name: str) -> str:
    """'/layer2/layer2.0/downsample/downsample.0/Conv' -> 'layer2.0.downsample.0'.

    The legacy exporter scopes each node by its module chain, and a Sequential's child
    repeats its parent's name as a prefix ('layer2', then 'layer2.0'); dropping the repeat
    recovers torch's own dotted path.
    """
    scopes = [scope for scope in node_name.strip("/").split("/")[:-1] if scope]
    parts: list[str] = []
    previous = ""
    for scope in scopes:
        if previous and scope.startswith(previous + "."):
            parts.append(scope[len(previous) + 1:])
        else:
            parts.append(scope)
        previous = scope
    return ".".join(parts)


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _attribute(node, name: str, default=None):
    import onnx

    for attribute in node.attribute:
        if attribute.name == name:
            return onnx.helper.get_attribute_value(attribute)
    return default


def _constant(graph, name: str, initializers: dict):
    from onnx import numpy_helper

    if name in initializers:
        return initializers[name]
    for node in graph.node:
        if node.op_type == "Constant" and name in node.output:
            for attribute in node.attribute:
                if attribute.name == "value":
                    return numpy_helper.to_array(attribute.t)
    return None


def convert(onnx_path: Path) -> dict[str, np.ndarray]:
    """The graph's convolution weights under MLX names, or ConversionRefused saying why."""
    import onnx
    from onnx import numpy_helper

    graph = onnx.load(str(onnx_path)).graph
    ops = dict(Counter(node.op_type for node in graph.node))
    if ops != EXPECTED_OPS:
        raise ConversionRefused(
            f"{onnx_path.name} is not the {ARCH} graph: its ops are {ops}, expected {EXPECTED_OPS}")
    inputs = [value.name for value in graph.input]
    outputs = [value.name for value in graph.output]
    if inputs != ["image"] or outputs != ["features"]:
        raise ConversionRefused(
            f"{onnx_path.name} binds {inputs} -> {outputs}; the engine binds ['image'] -> ['features']")

    initializers = {tensor.name: numpy_helper.to_array(tensor) for tensor in graph.initializer}
    tensors: dict[str, np.ndarray] = {}
    for node in graph.node:
        if node.op_type == "Conv":
            path = module_path(node.name)
            if path not in EXPECTED_CONVS:
                raise ConversionRefused(f"unexpected convolution {node.name!r} (module {path!r})")
            kernel, stride, pad = EXPECTED_CONVS[path]
            got = (list(_attribute(node, "kernel_shape", [])), list(_attribute(node, "strides", [1, 1])),
                   list(_attribute(node, "pads", [0, 0, 0, 0])))
            if got != ([kernel] * 2, [stride] * 2, [pad] * 4) \
                    or _attribute(node, "group", 1) != 1 \
                    or list(_attribute(node, "dilations", [1, 1])) != [1, 1]:
                raise ConversionRefused(
                    f"{path}: kernel/stride/pads {got}, expected {kernel}/{stride}/{pad}, ungrouped")
            if len(node.input) != 3:
                raise ConversionRefused(f"{path} has no bias — BatchNorm was not folded into it")
            if f"{path}.weight" in tensors:
                raise ConversionRefused(f"{path} appears twice")
            weight = initializers[node.input[1]]
            bias = initializers[node.input[2]]
            tensors[f"{path}.weight"] = np.ascontiguousarray(
                weight.transpose(0, 2, 3, 1), dtype=np.float32)
            tensors[f"{path}.bias"] = np.ascontiguousarray(bias, dtype=np.float32)
        elif node.op_type == "MaxPool":
            got = (list(_attribute(node, "kernel_shape", [])), list(_attribute(node, "strides", [])),
                   list(_attribute(node, "pads", [])), _attribute(node, "ceil_mode", 0))
            if got != ([3, 3], [2, 2], [1, 1, 1, 1], 0):
                raise ConversionRefused(f"the stem's max pool is {got}, not 3x3 / stride 2 / pad 1")
        elif node.op_type == "Resize":
            got = (_attribute(node, "mode"), _attribute(node, "coordinate_transformation_mode"),
                   _attribute(node, "nearest_mode"))
            if got != (b"nearest", b"asymmetric", b"floor"):
                raise ConversionRefused(f"the upsample is {got}, not nearest / asymmetric / floor")
            scales = _constant(graph, node.input[2] if len(node.input) > 2 else "", initializers)
            if scales is None or [float(value) for value in scales] != [1.0, 1.0, 2.0, 2.0]:
                raise ConversionRefused(f"the upsample scales are {scales}, not [1, 1, 2, 2]")

    missing = sorted(set(EXPECTED_CONVS) - {name.rsplit(".", 1)[0] for name in tensors})
    if missing:
        raise ConversionRefused(f"convolutions missing from {onnx_path.name}: {missing}")
    return tensors


def run(spec_path: Path) -> Path:
    """Writes <backbone>.safetensors beside the spec and records it in the spec."""
    from safetensors.numpy import save_file

    spec = json.loads(spec_path.read_text())
    directory = spec_path.parent
    onnx_path = directory / spec["files"]["backbone"]
    source_sha = _sha256(onnx_path)
    recorded = spec.get("sha256", {}).get("backbone")
    if recorded is not None and recorded != source_sha:
        raise ConversionRefused(
            f"{onnx_path.name} does not match the sha256 its spec records — export again")

    tensors = convert(onnx_path)
    out_name = onnx_path.name.removesuffix(".onnx") + ".safetensors"
    out_path = directory / out_name
    save_file(tensors, str(out_path), metadata={
        "format": FORMAT,
        "arch": ARCH,
        "source": onnx_path.name,
        "source_sha256": source_sha,
    })

    spec.setdefault("files", {})["backbone_mlx"] = out_name
    hashes = spec.setdefault("sha256", {})
    hashes["backbone"] = source_sha
    hashes["backbone_mlx"] = _sha256(out_path)
    spec_path.write_text(json.dumps(spec, indent=2, sort_keys=True) + "\n")

    parameters = sum(int(tensor.size) for tensor in tensors.values())
    print(f"exported {out_name}: {len(tensors)} tensors, {parameters:,} parameters, "
          f"from {onnx_path.name}")
    return out_path
