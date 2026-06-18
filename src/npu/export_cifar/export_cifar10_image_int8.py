import argparse
import json
import os
import pickle

import numpy as np


def relative_path(path):
    return os.path.relpath(path, start=os.getcwd())


def int8_hex(value):
    return f"{int(value) & 0xFF:02x}"


def write_memh(path, arr):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="ascii") as f:
        for value in arr.reshape(-1):
            f.write(int8_hex(value))
            f.write("\n")


def load_manifest(asset_dir):
    with open(os.path.join(asset_dir, "manifest.json"), "r", encoding="utf-8") as f:
        return json.load(f)


def load_cifar10_test(data_dir):
    path = os.path.join(data_dir, "cifar-10-batches-py", "test_batch")
    with open(path, "rb") as f:
        batch = pickle.load(f, encoding="latin1")
    images = batch["data"].reshape(-1, 3, 32, 32).astype(np.uint8)
    labels = np.array(batch["labels"], dtype=np.int64)
    return images, labels


def load_rgb_image(path):
    from PIL import Image

    image = Image.open(path).convert("RGB").resize((32, 32))
    arr = np.asarray(image, dtype=np.uint8)
    return arr.transpose(2, 0, 1)[None, :, :, :]


def quantize_images(images_u8, manifest):
    mean = np.array(manifest["input_preprocess"]["mean"], dtype=np.float64).reshape(1, 3, 1, 1)
    std = np.array(manifest["input_preprocess"]["std"], dtype=np.float64).reshape(1, 3, 1, 1)
    input_scale = float(manifest["scales"]["input"]["scale"])
    x = images_u8.astype(np.float64) / 255.0
    x = (x - mean) / std
    return np.clip(np.round(x * input_scale), -127, 127).astype(np.int8)


def parse_args():
    parser = argparse.ArgumentParser(description="Export CIFAR-10/RGB images as INT8 input .memh data.")
    parser.add_argument("--asset-dir", default="./cifar10_int8_pow2_fused", help="directory containing INT8 manifest.json")
    parser.add_argument("--data-dir", default="./data", help="CIFAR-10 data directory")
    parser.add_argument("--out-dir", default="./cifar10_image_int8", help="output directory")
    parser.add_argument("--image", help="optional RGB image path; resized to 32x32")
    parser.add_argument("--index", type=int, help="single CIFAR-10 test index")
    parser.add_argument("--start-index", type=int, default=0, help="first CIFAR-10 test index for batch export")
    parser.add_argument("--count", type=int, default=1, help="number of CIFAR-10 test images to export")
    parser.add_argument(
        "--combined",
        action="store_true",
        help="also write all exported images into images_q_i8.memh as one flat NCHW stream",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    manifest = load_manifest(args.asset_dir)
    labels = None

    if args.image:
        images_u8 = load_rgb_image(args.image)
        names = ["image"]
    else:
        images, labels_all = load_cifar10_test(args.data_dir)
        start = args.index if args.index is not None else args.start_index
        count = 1 if args.index is not None else args.count
        stop = start + count
        if start < 0 or stop > images.shape[0]:
            raise ValueError(f"export range [{start}, {stop}) is outside CIFAR-10 test size {images.shape[0]}")
        images_u8 = images[start:stop]
        labels = labels_all[start:stop]
        names = [f"test_{idx:05d}" for idx in range(start, stop)]

    images_q = quantize_images(images_u8, manifest)
    os.makedirs(args.out_dir, exist_ok=True)

    exported = []
    for i, name in enumerate(names):
        file_name = f"{name}_nchw_i8.memh"
        write_memh(os.path.join(args.out_dir, file_name), images_q[i])
        item = {
            "name": name,
            "file": file_name,
            "shape": [3, 32, 32],
            "layout": "CHW_RGB",
            "dtype": "int8_twos_complement_hex",
        }
        if labels is not None:
            item["label"] = int(labels[i])
        exported.append(item)
        print(f"exported {name}: {file_name}")

    if args.combined or len(names) > 1:
        write_memh(os.path.join(args.out_dir, "images_q_i8.memh"), images_q)

    out_manifest = {
        "source_asset_dir": relative_path(args.asset_dir),
        "source_manifest": relative_path(os.path.join(args.asset_dir, "manifest.json")),
        "input_scale": manifest["scales"]["input"],
        "input_preprocess": manifest["input_preprocess"],
        "image_count": len(names),
        "flat_order": "NCHW, then C-major CHW per image",
        "images": exported,
    }
    with open(os.path.join(args.out_dir, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(out_manifest, f, indent=2)

    print(f"Done. Exported {len(names)} INT8 image file(s) to {args.out_dir}")


if __name__ == "__main__":
    main()
