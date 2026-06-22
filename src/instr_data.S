# ============================================================
# CPU-driven DMA → NPU inference program
# Flow: configure DMA → DMA transfer DDR→NPU_RAM → trigger NPU → read result
#
# Memory map:
#   0x4000_0000  DDR (256KB, preloaded with image_data.dat)
#   0x0000_1000  NPU RAM (4KB, DMA destination)
#   0x0002_1000  DMA CSR
#   0x0003_0000  NPU CSR
#
# DMA CSR offsets:
#   0x00 CONTROL   [0]=go [1]=abort [9:2]=max_burst
#   0x08 STATUS    [16]=done [17]=error
#   0x20 SRC_ADDR_0
#   0x30 DST_ADDR_0
#   0x40 NUM_BYTES_0
#   0x50 CFG_0     [0]=wr_mode [1]=rd_mode [2]=enable
#
# NPU CSR offsets:
#   0x00 CTRL      [0]=start (triggers load→conv→fc pipeline)
#   0x04 STATUS    [0]=busy  [1]=done
#   0x20 PRED      [0]=valid [11:8]=class_id [23:16]=logit
# ============================================================

.section .text
.globl _start

_start:
    # ---- Step 1: Configure DMA descriptor ----
    li   s0, 0x00021000       # DMA CSR base

    # SRC_ADDR = 0x4000_0000 (DDR)
    li   t0, 0x40000000
    sw   t0, 0x20(s0)

    # DST_ADDR = 0x0000_1000 (NPU RAM)
    li   t0, 0x00001000
    sw   t0, 0x30(s0)

    # NUM_BYTES = 4096 (1024 pixels × 4 bytes)
    li   t0, 0x1000
    sw   t0, 0x40(s0)

    # CFG_0: enable=1, rd_mode=INCR(0), wr_mode=INCR(0) → bit[2]=1 → 0x04
    li   t0, 0x04
    sw   t0, 0x50(s0)

    # Verify CFG write
    lw   t1, 0x50(s0)
    li   t2, 0x04
    bne  t1, t2, fail

    # ---- Step 2: Start DMA ----
    # CONTROL: go=1 (bit[0]), max_burst=255 (bits[9:2])
    # (255 << 2) | 1 = 0x3FC | 0x01 = 0x3FD
    li   t0, 0x3FD
    sw   t0, 0x00(s0)

    # ---- Step 3: Poll DMA done ----
    # STATUS[16] = done
poll_dma:
    lw   t1, 0x08(s0)
    li   t2, 0x10000          # bit 16
    and  t3, t1, t2
    beq  t3, x0, poll_dma

    # Check DMA error: STATUS[17]
    li   t2, 0x20000          # bit 17
    and  t3, t1, t2
    bne  t3, x0, fail

    # ---- Step 4: Trigger NPU ----
    # NPU CTRL: write bit[0]=1 → triggers load_img → conv → FC pipeline
    li   s1, 0x00030000       # NPU CSR base
    li   t0, 0x01
    sw   t0, 0x00(s1)

    # ---- Step 5: Poll NPU done ----
    # NPU PRED[0] = result_valid (set when FC completes)
poll_npu:
    lw   t1, 0x20(s1)        # PRED register
    andi t2, t1, 0x01         # bit[0] = valid
    beq  t2, x0, poll_npu

    # ---- Step 6: Read result ----
    # class_id = PRED[11:8]
    srli t2, t1, 8
    andi s2, t2, 0x0F         # s2 = pred_class_id

    # logit = PRED[23:16] (sign-extended)
    srli t2, t1, 16
    andi s3, t2, 0xFF         # s3 = pred_logit (unsigned byte)

    # ---- Done: loop forever ----
done:
    jal  x0, done

fail:
    jal  x0, fail
