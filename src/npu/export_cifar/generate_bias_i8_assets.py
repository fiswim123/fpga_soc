import argparse
import copy
import json
import os
from collections import OrderedDict

try:
    import torch
except ModuleNotFoundError as exc:
    raise SystemExit(
        "PyTorch is required to read the checkpoint and fuse Conv+BN bias. "
        "Run this script in the same Python environment used for CIFAR export/training."
    ) from exc


FUSED_LAYERS = (
    {
        "name": "conv1",
        "bias_name": "features.0.bias",
        "output_scale_name": "conv1",
    },
    {
        "name": "conv2",
        "bias_name": "features.4.bias",
        "output_scale_name": "conv2",
    },
    {
        "name": "fc",
        "bias_name": "classifier.2.bias",
        "output_scale_name": "logits",
    },
)


def int_to_twos_hex(value, bits):
    ivalue = int(value)
    if ivalue < 0:
        ivalue = (1 << bits) + ivalue
    return f"{ivalue & ((1 << bits) - 1):0{bits // 4}x}"


def load_state_dict(checkpoint_path):
    checkpoint = torch.load(checkpoint_path, map_location="cpu")
    if isinstance(checkpoint, dict) and "model" in checkpoint:
        state_dict = checkpoint["model"]
        meta = {
            key: value
            for key, value in checkpoint.items()
            if key != "model"
        }
        meta["state_dict_key"] = "model"
    elif isinstance(checkpoint, dict) and "state_dict" in checkpoint:
        state_dict = checkpoint["state_dict"]
        meta = {
            key: value
            for key, value in checkpoint.items()
            if key != "state_dict"
        }
        meta["state_dict_key"] = "state_dict"
    else:
        state_dict = checkpoint
        meta = {"state_dict_key": None}

    cleaned = OrderedDict()
    for key, value in state_dict.items():
        if key.startswith("module."):
            key = key[len("module."):]
        cleaned[key] = value.detach().cpu() if hasattr(value, "detach") else value
    return cleaned, meta


def fuse_conv_bn_weight(conv_w, conv_b, bn_w, bn_b, bn_mean, bn_var, bn_eps):
    if conv_b is None:
        conv_b = torch.zeros(conv_w.shape[0], dtype=conv_w.dtype)
    scale = bn_w / torch.sqrt(bn_var + bn_eps)
    fused_w = conv_w * scale.reshape(-1, 1, 1, 1)
    fused_b = (conv_b - bn_mean) * scale + bn_b
    return fused_w.detach().cpu(), fused_b.detach().cpu()


def make_fused_state_dict(state_dict, bn_eps):
    fused = OrderedDict()
    w0, b0 = fuse_conv_bn_weight(
        state_dict["features.0.weight"],
        state_dict.get("features.0.bias"),
        state_dict["features.1.weight"],
        state_dict["features.1.bias"],
        state_dict["features.1.running_mean"],
        state_dict["features.1.running_var"],
        bn_eps,
    )
    w4, b4 = fuse_conv_bn_weight(
        state_dict["features.4.weight"],
        state_dict.get("features.4.bias"),
        state_dict["features.5.weight"],
        state_dict["features.5.bias"],
        state_dict["features.5.running_mean"],
        state_dict["features.5.running_var"],
        bn_eps,
    )
    fused["features.0.bias"] = b0
    fused["features.4.bias"] = b4
    fused["classifier.2.bias"] = state_dict["classifier.2.bias"].detach().cpu()
    return fused


def quantize_bias_i8_tensor(tensor, output_scale):
    raw = torch.round(tensor.detach().cpu().to(torch.float64) * float(output_scale)).to(torch.int64)
    clipped = torch.clamp(raw, -128, 127).to(torch.int32)
    sat_mask = (raw < -128) | (raw > 127)
    return raw, clipped, int(sat_mask.sum().item())


def write_memh(path, values, bits):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    flat = values.detach().cpu().reshape(-1).tolist()
    with open(path, "w", encoding="ascii") as f:
        for value in flat:
            f.write(int_to_twos_hex(value, bits))
            f.write("\n")


def relpath(path, start):
    return os.path.relpath(os.path.abspath(path), start=os.path.abspath(start)).replace(os.sep, "/")


def update_manifest(manifest, asset_dir, out_dir, checkpoint_path, checkpoint_meta, stats):
    derived = copy.deepcopy(manifest)
    derived["source_manifest"] = relpath(os.path.join(asset_dir, "manifest.json"), out_dir)
    derived["source_asset_dir"] = relpath(asset_dir, out_dir)
    derived["source_checkpoint_for_bias_i8"] = relpath(checkpoint_path, out_dir)
    derived["checkpoint_meta_for_bias_i8"] = checkpoint_meta
    derived["bias_variant"] = "int8_output"
    derived["bias_i8_stats"] = stats

    for layer in derived.get("layers", []):
        name = layer.get("name")
        if name not in stats:
            continue
        layer["bias_file"] = f"{name}_bias_i8.memh"
        layer["bias_domain"] = "int8_output"
        layer["postprocess"] = "q_out = clamp((acc >> shift) + bias_i8, -128, 127); left shift if shift < 0"

    return derived


def parse_args():
    parser = argparse.ArgumentParser(
        description="Generate derived INT8 output-domain bias assets without modifying the original export."
    )
    parser.add_argument("--asset-dir", default="export_cifar/cifar10_int8_pow2_fused")
    parser.add_argument("--checkpoint", default="export_cifar/checkpoint/tiny_cifar10_5x5.pth")
    parser.add_argument("--out-dir", default="export_cifar/cifar10_int8_pow2_fused_bias_i8")
    parser.add_argument("--bn-eps", type=float, default=1e-5)
    parser.add_argument("--check-only", action="store_true", help="print stats without writing derived assets")
    return parser.parse_args()


def main():
    args = parse_args()
    manifest_path = os.path.join(args.asset_dir, "manifest.json")
    with open(manifest_path, "r", encoding="utf-8") as f:
        manifest = json.load(f)

    state_dict, checkpoint_meta = load_state_dict(args.checkpoint)
    fused = make_fused_state_dict(state_dict, args.bn_eps)

    stats = OrderedDict()
    for layer in FUSED_LAYERS:
        name = layer["name"]
        output_scale_name = layer["output_scale_name"]
        output_scale = manifest["scales"][output_scale_name]["scale"]
        raw, bias_i8, sat_count = quantize_bias_i8_tensor(fused[layer["bias_name"]], output_scale)
        raw_min = int(raw.min().item())
        raw_max = int(raw.max().item())
        max_abs = int(torch.max(torch.abs(raw)).item())
        count = int(raw.numel())
        stats[name] = {
            "file": f"{name}_bias_i8.memh",
            "count": count,
            "output_scale_name": output_scale_name,
            "output_scale": float(output_scale),
            "sat_count": sat_count,
            "max_abs": max_abs,
            "raw_range": [raw_min, raw_max],
        }
        print(
            f"{name}: count={count} output_scale={float(output_scale):g} "
            f"sat_count={sat_count}/{count} max_abs={max_abs} raw_range=[{raw_min},{raw_max}]"
        )

        if not args.check_only:
            write_memh(os.path.join(args.out_dir, f"{name}_bias_i8.memh"), bias_i8, bits=8)

    if args.check_only:
        print("check-only: no files written")
        return

    os.makedirs(args.out_dir, exist_ok=True)
    derived_manifest = update_manifest(
        manifest=manifest,
        asset_dir=args.asset_dir,
        out_dir=args.out_dir,
        checkpoint_path=args.checkpoint,
        checkpoint_meta=checkpoint_meta,
        stats=stats,
    )
    out_manifest_path = os.path.join(args.out_dir, "manifest_bias_i8.json")
    with open(out_manifest_path, "w", encoding="utf-8") as f:
        json.dump(derived_manifest, f, indent=2)
    print(f"Manifest: {out_manifest_path}")


if __name__ == "__main__":
    main()
