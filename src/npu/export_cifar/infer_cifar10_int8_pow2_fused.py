import argparse
import json
import os

import numpy as np


CIFAR10_CLASSES = (
    "airplane",
    "automobile",
    "bird",
    "cat",
    "deer",
    "dog",
    "frog",
    "horse",
    "ship",
    "truck",
)


def twos_to_int(value, bits):
    sign = 1 << (bits - 1)
    mask = (1 << bits) - 1
    value = int(value) & mask
    return value - (1 << bits) if value & sign else value


def read_memh(path, bits, shape):
    values = []
    with open(path, "r", encoding="ascii") as f:
        for line in f:
            text = line.strip().lower()
            if not text:
                continue
            if text.startswith("0x"):
                text = text[2:]
            width = bits // 4
            if len(text) == width:
                values.append(twos_to_int(int(text, 16), bits))
            elif len(text) % width == 0:
                for start in range(0, len(text), width):
                    values.append(twos_to_int(int(text[start : start + width], 16), bits))
            else:
                raise ValueError(f"Bad .memh line width in {path}: {line!r}")

    dtype = np.int8 if bits == 8 else np.int32
    arr = np.array(values, dtype=dtype)
    expected = int(np.prod(shape))
    if arr.size != expected:
        raise ValueError(f"{path} has {arr.size} values, expected {expected}")
    return arr.reshape(shape)


def apply_shift(arr, shift):
    out = arr.astype(np.int64)
    if shift >= 0:
        return out >> shift
    return out << (-shift)


def requantize(acc, bias, shift, relu):
    out = apply_shift(acc.astype(np.int64) + bias.astype(np.int64), int(shift))
    out = np.clip(out, -128, 127).astype(np.int32)
    if relu:
        out = np.maximum(out, 0)
    return out.astype(np.int32)


def im2col_nchw(x, kh, kw, pad, stride):
    x_pad = np.pad(x, ((0, 0), (0, 0), (pad, pad), (pad, pad)), mode="constant")
    win = np.lib.stride_tricks.sliding_window_view(x_pad, (kh, kw), axis=(2, 3))
    win = win[:, :, ::stride, ::stride, :, :]
    n, c, out_h, out_w, _, _ = win.shape
    cols = win.transpose(0, 2, 3, 1, 4, 5).reshape(n * out_h * out_w, c * kh * kw)
    return cols.astype(np.int32), out_h, out_w


def conv2d_int8(x, weight, bias, shift, relu, pad=2, stride=1):
    n = x.shape[0]
    out_ch, in_ch, kh, kw = weight.shape
    cols, out_h, out_w = im2col_nchw(x, kh, kw, pad, stride)
    w_row = weight.reshape(out_ch, in_ch * kh * kw).astype(np.int32)
    acc = cols @ w_row.T
    out = requantize(acc, bias.reshape(1, out_ch), shift, relu)
    return out.reshape(n, out_h, out_w, out_ch).transpose(0, 3, 1, 2).astype(np.int32)


def maxpool2x2(x):
    n, c, h, w = x.shape
    x6 = x.reshape(n, c, h // 2, 2, w // 2, 2).transpose(0, 1, 2, 4, 3, 5)
    return x6.reshape(n, c, h // 2, w // 2, 4).max(axis=4).astype(np.int32)


def avgpool8x8_shift(x):
    summed = x.astype(np.int64).sum(axis=(2, 3))
    return (summed >> 6).astype(np.int32)


def linear_int8(x, weight, bias, shift, relu):
    acc = x.astype(np.int32) @ weight.astype(np.int32).T
    return requantize(acc, bias.reshape(1, -1), shift, relu)


def load_assets(asset_dir):
    with open(os.path.join(asset_dir, "manifest.json"), "r", encoding="utf-8") as f:
        manifest = json.load(f)

    layers = {}
    for layer in manifest["layers"]:
        name = layer["name"]
        layers[name] = {
            "weight": read_memh(
                os.path.join(asset_dir, layer["weight_file"]),
                bits=8,
                shape=layer["weight_shape"],
            ).astype(np.int32),
            "bias": read_memh(
                os.path.join(asset_dir, layer["bias_file"]),
                bits=32,
                shape=layer["bias_shape"],
            ).astype(np.int32),
            "shift": int(layer["requant_shift"]),
            "relu": bool(layer["relu"]),
        }

    return manifest, layers


def infer_batch(images_q, layers):
    x = images_q.astype(np.int32)
    x = conv2d_int8(x, layers["conv1"]["weight"], layers["conv1"]["bias"], layers["conv1"]["shift"], True)
    x = maxpool2x2(x)
    x = conv2d_int8(x, layers["conv2"]["weight"], layers["conv2"]["bias"], layers["conv2"]["shift"], True)
    x = maxpool2x2(x)
    x = avgpool8x8_shift(x)
    logits = linear_int8(x, layers["fc"]["weight"], layers["fc"]["bias"], layers["fc"]["shift"], False)
    return logits.astype(np.int32)


def load_image_manifest(image_int8_dir):
    manifest_path = os.path.join(image_int8_dir, "manifest.json")
    with open(manifest_path, "r", encoding="utf-8") as f:
        return json.load(f)


def load_images_from_manifest(image_int8_dir, image_manifest, image_index=None, max_samples=None):
    entries = image_manifest["images"]
    if image_index is not None:
        if image_index < 0 or image_index >= len(entries):
            raise ValueError(f"--image-index {image_index} is outside exported image count {len(entries)}")
        entries = [entries[image_index]]
    elif max_samples is not None:
        entries = entries[:max_samples]

    images = []
    labels = []
    names = []
    for entry in entries:
        shape = entry.get("shape", [3, 32, 32])
        image_q = read_memh(os.path.join(image_int8_dir, entry["file"]), bits=8, shape=shape)
        images.append(image_q.astype(np.int32))
        labels.append(entry.get("label"))
        names.append(entry.get("name", entry["file"]))

    return np.stack(images, axis=0), labels, names


def load_images_from_memh(path, count):
    shape = [count, 3, 32, 32]
    return read_memh(path, bits=8, shape=shape).astype(np.int32), [None] * count, [os.path.basename(path)]


def parse_args():
    parser = argparse.ArgumentParser(
        description="Run TinyCIFAR10_5x5 inference from exported INT8 pow2 fused weights and INT8 image data."
    )
    parser.add_argument("--asset-dir", default="./cifar10_int8_pow2_fused")
    parser.add_argument("--image-int8-dir", default="./cifar10_image_int8", help="directory from export_cifar10_image_int8.py")
    parser.add_argument("--image-int8", help="optional direct INT8 image .memh path")
    parser.add_argument("--image-count", type=int, default=1, help="number of images in --image-int8")
    parser.add_argument("--image-index", type=int, help="image index inside --image-int8-dir/manifest.json")
    parser.add_argument("--batch-size", type=int, default=256)
    parser.add_argument("--max-samples", type=int, default=None)
    parser.add_argument("--topk", type=int, default=3)
    return parser.parse_args()


def print_topk(logits, topk):
    order = np.argsort(logits[0])[::-1][:topk]
    for rank, cls in enumerate(order, start=1):
        print(f"Top {rank}: {CIFAR10_CLASSES[int(cls)]:10s} logit_q={int(logits[0, cls])} class_id={int(cls)}")


def main():
    args = parse_args()
    _manifest, layers = load_assets(args.asset_dir)

    if args.image_int8:
        images_q, labels, names = load_images_from_memh(args.image_int8, args.image_count)
    else:
        image_manifest = load_image_manifest(args.image_int8_dir)
        images_q, labels, names = load_images_from_manifest(
            args.image_int8_dir,
            image_manifest,
            image_index=args.image_index,
            max_samples=args.max_samples,
        )

    if args.image_index is not None or images_q.shape[0] == 1:
        logits = infer_batch(images_q[:1], layers)
        pred = int(np.argmax(logits[0]))
        print(f"Image: {names[0]}")
        print(f"Prediction: {CIFAR10_CLASSES[pred]} logit_q={int(logits[0, pred])} class_id={pred}")
        if labels[0] is not None:
            target = int(labels[0])
            print(f"Target:     {CIFAR10_CLASSES[target]} class_id={target}")
        print_topk(logits, args.topk)
        return

    total = images_q.shape[0]
    correct = 0
    seen = 0
    labeled = all(label is not None for label in labels)
    for start in range(0, total, args.batch_size):
        stop = min(start + args.batch_size, total)
        logits = infer_batch(images_q[start:stop], layers)
        pred = np.argmax(logits, axis=1)
        if labeled:
            correct += int(np.count_nonzero(pred == np.array(labels[start:stop], dtype=np.int64)))
        seen += stop - start
    if labeled:
        acc = 100.0 * correct / seen if seen else 0.0
        print(f"INT8 pow2 fused accuracy from INT8 images: {acc:.3f}% ({correct}/{seen})")
    else:
        print(f"Ran INT8 pow2 fused inference on {seen} INT8 image(s).")


if __name__ == "__main__":
    main()
