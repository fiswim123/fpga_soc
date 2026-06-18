import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SIM_DIR = os.path.join(ROOT, "sim")
IMAGE_DATA_PATH = os.path.join(ROOT, "image_data.dat")
IMAGE_IM2COL_PATH = os.path.join(ROOT, "image.dat")


def twos_to_int(text, bits=8):
    value = int(text, 16)
    sign = 1 << (bits - 1)
    mask = (1 << bits) - 1
    value &= mask
    return value - (1 << bits) if value & sign else value


def int_to_hex(value, bits=8):
    return f"{int(value) & ((1 << bits) - 1):0{bits // 4}x}"


def read_memh_i8(path, expected_count):
    values = []
    with open(path, "r", encoding="ascii") as f:
        for line in f:
            text = line.strip().lower()
            if not text:
                continue
            if text.startswith("0x"):
                text = text[2:]
            if len(text) == 2:
                values.append(twos_to_int(text, 8))
            elif len(text) % 2 == 0:
                for start in range(0, len(text), 2):
                    values.append(twos_to_int(text[start : start + 2], 8))
            else:
                raise ValueError(f"Bad int8 memh line in {path}: {line!r}")
    if len(values) != expected_count:
        raise ValueError(f"{path} has {len(values)} values, expected {expected_count}")
    return values


def chw_value(chw, ch, h, w):
    return chw[ch * 32 * 32 + h * 32 + w]


def write_image_data(chw, path):
    with open(path, "w", encoding="ascii") as f:
        for h in range(32):
            for w in range(32):
                r = chw_value(chw, 0, h, w)
                g = chw_value(chw, 1, h, w)
                b = chw_value(chw, 2, h, w)
                f.write(f"{int_to_hex(r)}{int_to_hex(g)}{int_to_hex(b)}\n")


def write_image_im2col(chw, path):
    with open(path, "w", encoding="ascii") as f:
        for row in range(32 * 32):
            oh = row // 32
            ow = row % 32
            bytes_out = []
            for k in range(3 * 5 * 5):
                ch = k // 25
                rem = k % 25
                kh = rem // 5
                kw = rem % 5
                ih = oh + kh - 2
                iw = ow + kw - 2
                if ih < 0 or ih >= 32 or iw < 0 or iw >= 32:
                    value = 0
                else:
                    value = chw_value(chw, ch, ih, iw)
                bytes_out.append(int_to_hex(value))
            f.write("".join(bytes_out))
            f.write("\n")


def load_manifest(image_dir):
    with open(os.path.join(image_dir, "manifest.json"), "r", encoding="utf-8") as f:
        return json.load(f)


def select_entries(entries, start_index, count, image_index):
    if image_index is not None:
        if image_index < 0 or image_index >= len(entries):
            raise ValueError(f"--image-index {image_index} outside image count {len(entries)}")
        return [entries[image_index]]
    stop = min(start_index + count, len(entries))
    return entries[start_index:stop]


def run_cmd(cmd, cwd, timeout):
    proc = subprocess.run(
        cmd,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
    )
    return proc.returncode, proc.stdout


def parse_sim_output(output):
    passed = "===== PASS:" in output and "===== FAIL:" not in output
    pred_match = re.search(r"\[PRED\]\s+class_id=(\d+)\s+logit=(-?\d+)", output)
    pred = int(pred_match.group(1)) if pred_match else None
    logit = int(pred_match.group(2)) if pred_match else None
    return passed, pred, logit


def backup_file(path, backup_dir):
    backup = os.path.join(backup_dir, os.path.basename(path))
    shutil.copy2(path, backup)
    return backup


def main():
    parser = argparse.ArgumentParser(description="Replace image_data.dat/image.dat and run tb_npu_top over exported images.")
    parser.add_argument("--image-dir", default=os.path.join(ROOT, "export_cifar", "cifar10_image_int8"))
    parser.add_argument("--start-index", type=int, default=0)
    parser.add_argument("--count", type=int, default=10)
    parser.add_argument("--image-index", type=int)
    parser.add_argument("--compile", action="store_true", help="compile filelist.f before running simulations")
    parser.add_argument("--no-compile", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--keep-last", action="store_true", help="leave the final generated image_data.dat/image.dat in place")
    parser.add_argument("--timeout", type=int, default=120)
    args = parser.parse_args()

    manifest = load_manifest(args.image_dir)
    entries = select_entries(manifest["images"], args.start_index, args.count, args.image_index)
    if not entries:
        raise SystemExit("No images selected")

    with tempfile.TemporaryDirectory(prefix="npu_image_backup_") as backup_dir:
        image_data_backup = backup_file(IMAGE_DATA_PATH, backup_dir)
        image_im2col_backup = backup_file(IMAGE_IM2COL_PATH, backup_dir)
        try:
            if args.compile and not args.no_compile:
                code, out = run_cmd(["vlib", "work"], SIM_DIR, args.timeout)
                sys.stdout.write(out)
                if code != 0 and "Library already exists" not in out:
                    raise SystemExit(code)
                code, out = run_cmd(["vlog", "-sv", "-f", "filelist.f"], SIM_DIR, args.timeout)
                sys.stdout.write(out)
                if code != 0:
                    raise SystemExit(code)

            total = 0
            pass_count = 0
            labeled = 0
            correct = 0
            for entry in entries:
                image_path = os.path.join(args.image_dir, entry["file"])
                chw = read_memh_i8(image_path, 3 * 32 * 32)
                write_image_data(chw, IMAGE_DATA_PATH)
                write_image_im2col(chw, IMAGE_IM2COL_PATH)

                code, out = run_cmd(["vsim", "-c", "tb_npu_top", "-do", "run -all; quit"], SIM_DIR, args.timeout)
                passed, pred, logit = parse_sim_output(out)
                label = entry.get("label")
                is_correct = (pred == int(label)) if (pred is not None and label is not None) else None
                total += 1
                pass_count += 1 if passed and code == 0 else 0
                if is_correct is not None:
                    labeled += 1
                    correct += 1 if is_correct else 0

                status = "PASS" if passed and code == 0 else "FAIL"
                label_text = f" label={label}" if label is not None else ""
                pred_text = f" pred={pred} logit={logit}" if pred is not None else " pred=?"
                correct_text = f" correct={int(is_correct)}" if is_correct is not None else ""
                print(f"[{total:03d}] {status} {entry['name']}{label_text}{pred_text}{correct_text}")
                if not passed or code != 0:
                    print(out)

            print(f"Simulation PASS: {pass_count}/{total}")
            if labeled:
                acc = 100.0 * correct / labeled
                print(f"RTL predicted accuracy: {acc:.3f}% ({correct}/{labeled})")
        finally:
            if not args.keep_last:
                shutil.copy2(image_data_backup, IMAGE_DATA_PATH)
                shutil.copy2(image_im2col_backup, IMAGE_IM2COL_PATH)


if __name__ == "__main__":
    main()
