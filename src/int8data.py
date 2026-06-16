import random
images = 10000
N = images * 784  # bytes
out = "mnist.hex"

# 建议：设置随机种子以便复现结果
# random.seed(42) 

with open(out, "w") as f:
    for _ in range(N):
        # 生成 -128 到 127 之间的随机整数
        val_int8 = random.randint(-128, 127)
        
        # 转换为补码形式的十六进制 (00-FF)
        # 这一步对于负数至关重要，它将 -1 转换为 FF
        val_hex = val_int8 & 0xFF
        
        f.write(f"{val_hex:02x}\n")

print(f"Generated {out} with {N} bytes of int8 data (stored as hex).")