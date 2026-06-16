.section .text
.globl _start
_start:
  li s0, 0x00021000       # DMA CSR base
  li t0, 0x40000000       # SRC
  sw t0, 0x20(s0)
  li t0, 0x00001000       # DST
  sw t0, 0x30(s0)
  li t0, 0x00001000       # NUM_BYTES = 4096
  sw t0, 0x40(s0)
  li t0, 0x00000004       # CFG
  sw t0, 0x50(s0)

  lw t1, 0x50(s0)
  li t2, 0x00000004
  bne t1, t2, fail

  # 一次性写入 go=1 且 max_burst=255
  li t0, 0x3FD       # (255 << 2) | 1 = 0x3FC | 0x1
  sw t0, 0x00(s0)

poll:
  lw t1, 0x08(s0)         # STATUS
  andi t2, t1, 0x1        # done bit
  beq t2, x0, poll

done:
  jal x0, done
fail:
  jal x0, fail