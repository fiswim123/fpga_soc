import argparse
import json
import os
from collections import OrderedDict

import torch
import torch.nn as nn

from export_pth_to_memh import fuse_conv_bn_weight, load_state_dict
from train_cifar10_5x5 import DEFAULT_CIFAR10_URL, MirrorCIFAR10, TinyCIFAR10_5x5


CIFAR10_MEAN = (0.4914, 0.4822, 0.4465)
CIFAR10_STD = (0.2023, 0.1994, 0.2010)
FUSED_LAYERS = (
    {
        "name": "conv1",
        "weight_name": "features.0.weight",
        "bias_name": "features.0.bias",
        "input_scale_name": "input",
        "output_scale_name": "conv1",
        "relu": True,
    },
    {
        "name": "conv2",
        "weight_name": "features.4.weight",
        "bias_name": "features.4.bias",
        "input_scale_name": "conv1",
        "output_scale_name": "conv2",
        "relu": True,
    },
    {
        "name": "fc",
        "weight_name": "classifier.2.weight",
        "bias_name": "classifier.2.bias",
        "input_scale_name": "conv2",
        "output_scale_name": "logits",
        "relu": False,
    },
)


def relative_path(path):
    return os.path.relpath(path, start=os.getcwd())


class ActivationCollector(nn.Module):
    def __init__(self, model, max_samples_per_layer=1048576, max_samples_per_batch=65536):
        super().__init__()
        self.model = model
        self.max_samples_per_layer = int(max_samples_per_layer)
        self.max_samples_per_batch = int(max_samples_per_batch)
        self.sample_counts = {"conv1": 0, "conv2": 0, "logits": 0}
        self.outputs = {"conv1": [], "conv2": [], "logits": []}
        self.handles = [
            model.features[1].register_forward_hook(self._save("conv1")),
            model.features[4].register_forward_hook(self._save("conv2")),
            model.classifier[2].register_forward_hook(self._save("logits")),
        ]

    def _save(self, name):
        def hook(_module, _inputs, output):
            remaining = self.max_samples_per_layer - self.sample_counts[name]
            if remaining <= 0:
                return

            values = output.detach().abs().reshape(-1).cpu()
            sample_count = min(values.numel(), self.max_samples_per_batch, remaining)
            if values.numel() > sample_count:
                indices = torch.linspace(0, values.numel() - 1, steps=sample_count).long()
                values = values.index_select(0, indices)
            else:
                values = values[:sample_count]

            self.outputs[name].append(values)
            self.sample_counts[name] += int(values.numel())

        return hook

    def close(self):
        for handle in self.handles:
            handle.remove()


def pow2_scale_from_tensor(tensor, percentile):
    values = tensor.detach().cpu().abs().reshape(-1).to(torch.float32)
    if values.numel() == 0:
        return 1.0, 0
    if percentile >= 100.0:
        ref = values.max().item()
    else:
        sorted_values, _ = torch.sort(values)
        index = int(round((percentile / 100.0) * (sorted_values.numel() - 1)))
        ref = sorted_values[index].item()
    if ref < 1e-12:
        return 1.0, 0
    scale = 127.0 / ref
    exp = int(round(torch.log2(torch.tensor(scale)).item()))
    return float(2.0**exp), exp


def quantize_int8_tensor(tensor, scale):
    return torch.clamp(torch.round(tensor.detach().cpu().to(torch.float64) * scale), -127, 127).to(torch.int32)


def quantize_bias_int32_tensor(tensor, input_scale, weight_scale):
    scale = float(input_scale) * float(weight_scale)
    return torch.round(tensor.detach().cpu().to(torch.float64) * scale).to(torch.int32)


def int_to_twos_hex(value, bits):
    ivalue = int(value)
    if ivalue < 0:
        ivalue = (1 << bits) + ivalue
    return f"{ivalue & ((1 << bits) - 1):0{bits // 4}x}"


def write_memh(path, tensor, bits):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    flat = tensor.detach().cpu().reshape(-1).tolist()
    with open(path, "w", encoding="ascii") as f:
        for value in flat:
            f.write(int_to_twos_hex(value, bits))
            f.write("\n")


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
    fused["features.0.weight"] = w0
    fused["features.0.bias"] = b0
    fused["features.4.weight"] = w4
    fused["features.4.bias"] = b4
    fused["classifier.2.weight"] = state_dict["classifier.2.weight"].detach().cpu()
    fused["classifier.2.bias"] = state_dict["classifier.2.bias"].detach().cpu()
    return fused


def build_fused_eval_model(state_dict, bn_eps):
    fused = make_fused_state_dict(state_dict, bn_eps)
    model = TinyCIFAR10_5x5()
    model.features = nn.Sequential(
        nn.Conv2d(3, 32, kernel_size=5, padding=2, bias=True),
        nn.ReLU(inplace=True),
        nn.MaxPool2d(kernel_size=2, stride=2),
        nn.Conv2d(32, 64, kernel_size=5, padding=2, bias=True),
        nn.ReLU(inplace=True),
        nn.MaxPool2d(kernel_size=2, stride=2),
    )
    model.classifier = nn.Sequential(
        nn.AdaptiveAvgPool2d((1, 1)),
        nn.Flatten(),
        nn.Linear(64, 10),
    )
    remapped = OrderedDict(
        {
            "features.0.weight": fused["features.0.weight"],
            "features.0.bias": fused["features.0.bias"],
            "features.3.weight": fused["features.4.weight"],
            "features.3.bias": fused["features.4.bias"],
            "classifier.2.weight": fused["classifier.2.weight"],
            "classifier.2.bias": fused["classifier.2.bias"],
        }
    )
    model.load_state_dict(remapped)
    return model.eval(), fused


def collect_activation_scales(model, data_dir, batch_size, num_workers, calib_batches, download, cifar10_url, device):
    import torchvision.transforms as transforms

    transform = transforms.Compose(
        [
            transforms.ToTensor(),
            transforms.Normalize(CIFAR10_MEAN, CIFAR10_STD),
        ]
    )
    dataset = MirrorCIFAR10(root=data_dir, train=True, download=download, transform=transform, url=cifar10_url)
    loader = torch.utils.data.DataLoader(
        dataset,
        batch_size=batch_size,
        shuffle=False,
        num_workers=num_workers,
        pin_memory=(device == "cuda"),
    )

    collector = ActivationCollector(model)
    model.to(device)
    with torch.no_grad():
        for batch_idx, (inputs, _targets) in enumerate(loader):
            if batch_idx >= calib_batches:
                break
            model(inputs.to(device, non_blocking=True))
    collector.close()

    result = {}
    for name, values in collector.outputs.items():
        if not values:
            raise ValueError(f"No activation samples collected for {name}")
        result[name] = torch.cat(values, dim=0)
    return result


def parse_args():
    parser = argparse.ArgumentParser(description="Export fused TinyCIFAR10_5x5 parameters as INT8 with pow2 scales.")
    parser.add_argument("--checkpoint", default="./checkpoint/tiny_cifar10_5x5.pth")
    parser.add_argument("--out-dir", default="./cifar10_int8_pow2_fused")
    parser.add_argument("--data-dir", default="./data")
    parser.add_argument("--batch-size", type=int, default=256)
    parser.add_argument("--num-workers", type=int, default=2)
    parser.add_argument("--calib-batches", type=int, default=16)
    parser.add_argument("--input-scale-exp", type=int, default=5)
    parser.add_argument("--weight-percentile", type=float, default=100.0)
    parser.add_argument("--act-percentile", type=float, default=99.9)
    parser.add_argument("--bn-eps", type=float, default=1e-5)
    parser.add_argument("--download", action="store_true", help="download CIFAR-10 if missing")
    parser.add_argument("--enable-cudnn", action="store_true")
    parser.add_argument("--cifar10-url", default=DEFAULT_CIFAR10_URL)
    return parser.parse_args()


def main():
    args = parse_args()
    device = "cuda" if torch.cuda.is_available() else "cpu"
    if device == "cuda" and not args.enable_cudnn:
        torch.backends.cudnn.enabled = False

    state_dict, checkpoint_meta = load_state_dict(args.checkpoint)
    model, fused = build_fused_eval_model(state_dict, args.bn_eps)
    activations = collect_activation_scales(
        model=model,
        data_dir=args.data_dir,
        batch_size=args.batch_size,
        num_workers=args.num_workers,
        calib_batches=args.calib_batches,
        download=args.download,
        cifar10_url=args.cifar10_url,
        device=device,
    )

    input_scale_exp = int(args.input_scale_exp)
    scales = {"input": {"scale": float(2.0**input_scale_exp), "exp": input_scale_exp}}
    for name in ("conv1", "conv2", "logits"):
        scale, exp = pow2_scale_from_tensor(activations[name], args.act_percentile)
        scales[name] = {"scale": scale, "exp": exp}

    os.makedirs(args.out_dir, exist_ok=True)
    manifest = {
        "model": "TinyCIFAR10_5x5_int8_pow2_bn_fused",
        "source_checkpoint": relative_path(args.checkpoint),
        "checkpoint_meta": checkpoint_meta,
        "quant_mode": "signed_int8_pow2_shift_only",
        "input_preprocess": {
            "layout": "NCHW_RGB",
            "shape": [3, 32, 32],
            "mean": list(CIFAR10_MEAN),
            "std": list(CIFAR10_STD),
            "quant": "q = clamp(round(((pixel/255 - mean) / std) * input_scale), -127, 127)",
        },
        "pool": {"type": "maxpool2x2", "after": ["conv1", "conv2"]},
        "gap": {"type": "avg_8x8", "input_scale_name": "conv2", "output_scale_name": "conv2"},
        "scales": scales,
        "layers": [],
    }

    for layer in FUSED_LAYERS:
        weight = fused[layer["weight_name"]]
        bias = fused[layer["bias_name"]]
        weight_scale, weight_exp = pow2_scale_from_tensor(weight, args.weight_percentile)
        input_scale = scales[layer["input_scale_name"]]["scale"]
        input_exp = scales[layer["input_scale_name"]]["exp"]
        output_exp = scales[layer["output_scale_name"]]["exp"]
        weight_q = quantize_int8_tensor(weight, weight_scale)
        bias_q = quantize_bias_int32_tensor(bias, input_scale, weight_scale)
        shift = int(input_exp + weight_exp - output_exp)

        prefix = layer["name"]
        weight_file = f"{prefix}_weight_i8.memh"
        bias_file = f"{prefix}_bias_acc_i32.memh"
        write_memh(os.path.join(args.out_dir, weight_file), weight_q, bits=8)
        write_memh(os.path.join(args.out_dir, bias_file), bias_q, bits=32)

        manifest["layers"].append(
            {
                "name": layer["name"],
                "source_weight": layer["weight_name"],
                "source_bias": layer["bias_name"],
                "weight_file": weight_file,
                "bias_file": bias_file,
                "weight_shape": list(weight.shape),
                "bias_shape": list(bias.shape),
                "weight_scale": float(weight_scale),
                "weight_scale_exp": int(weight_exp),
                "input_scale_name": layer["input_scale_name"],
                "output_scale_name": layer["output_scale_name"],
                "requant_shift": shift,
                "requant_mul": 1,
                "relu": bool(layer["relu"]),
                "bias_domain": "int32_accumulator",
                "postprocess": "q_out = clamp((acc + bias_acc) >> shift, -128, 127); left shift if shift < 0",
            }
        )
        print(
            f"exported {prefix}: weight={tuple(weight.shape)} 2^{weight_exp}, "
            f"bias={tuple(bias.shape)}, shift={shift}"
        )

    manifest_path = os.path.join(args.out_dir, "manifest.json")
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
    print(f"Done. Exported INT8 pow2 fused assets to {args.out_dir}")
    print(f"Manifest: {manifest_path}")


if __name__ == "__main__":
    main()
