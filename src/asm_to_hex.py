#!/usr/bin/env python3
"""
Simple RV32I assembler for instr_data.S → instr_data.dat
Only supports the subset needed for DMA+NPU control program.
"""

import sys, re

# Register name → number
REGS = {
    'x0':0,'zero':0, 'x1':1,'ra':1, 'x2':2,'sp':2, 'x3':3,'gp':3,
    'x4':4,'tp':4,  'x5':5,'t0':5, 'x6':6,'t1':6, 'x7':7,'t2':7,
    'x8':8,'s0':8,'fp':8, 'x9':9,'s1':9, 'x10':10,'a0':10, 'x11':11,'a1':11,
    'x12':12,'a2':12, 'x13':13,'a3':13, 'x14':14,'a4':14, 'x15':15,'a5':15,
    'x16':16,'a6':16, 'x17':17,'a7':17, 'x18':18,'s2':18, 'x19':19,'s3':19,
    'x20':20,'s4':20, 'x21':21,'s5':21, 'x22':22,'s6':22, 'x23':23,'s7':23,
    'x24':24,'s8':24, 'x25':25,'s9':25, 'x26':26,'s10':26, 'x27':27,'s11':27,
    'x28':28,'t3':28, 'x29':29,'t4':29, 'x30':30,'t5':30, 'x31':31,'t6':31,
}

def imm_to_bin(val, bits):
    """Convert signed integer to binary string of given width."""
    if val < 0:
        val = (1 << bits) + val
    return format(val & ((1 << bits) - 1), f'0{bits}b')

def encode_r(funct7, rs2, rs1, funct3, rd, opcode):
    return int(funct7 + imm_to_bin(rs2,5) + imm_to_bin(rs1,5) + funct3 + imm_to_bin(rd,5) + opcode, 2)

def encode_i(imm12, rs1, funct3, rd, opcode):
    return int(imm_to_bin(imm12,12) + imm_to_bin(rs1,5) + funct3 + imm_to_bin(rd,5) + opcode, 2)

def encode_s(imm12, rs2, rs1, funct3, opcode):
    b = imm_to_bin(imm12, 12)
    return int(b[0:7] + imm_to_bin(rs2,5) + imm_to_bin(rs1,5) + funct3 + b[7:12] + opcode, 2)

def encode_b(imm13, rs2, rs1, funct3, opcode):
    """imm13 is signed, must be multiple of 2"""
    b = imm_to_bin(imm13, 13)
    return int(b[0] + b[2:8] + imm_to_bin(rs2,5) + imm_to_bin(rs1,5) + funct3 + b[8:12] + b[1] + opcode, 2)

def encode_j(imm21, rd, opcode):
    """imm21 is signed, must be multiple of 2"""
    b = imm_to_bin(imm21, 21)
    return int(b[0] + b[10:20] + b[9] + b[1:9] + imm_to_bin(rd,5) + opcode, 2)

def encode_u(imm32, rd, opcode):
    """imm32 is the full 32-bit value; upper 20 bits are stored"""
    return int(imm_to_bin((imm32 >> 12) & 0xFFFFF, 20) + imm_to_bin(rd,5) + opcode, 2)

def assemble_line(line, labels, pc):
    """Assemble a single line, return 32-bit integer or None."""
    # Remove comments
    line = line.split('#')[0].strip()
    if not line or line.startswith('.'):
        return None

    # Check for label definition
    if ':' in line:
        parts = line.split(':', 1)
        line = parts[1].strip()
        if not line:
            return None

    # Parse instruction
    m = re.match(r'(\w+)\s*(.*)', line)
    if not m:
        return None
    op = m.group(1).lower()
    args = m.group(2).strip()

    def parse_reg(s):
        s = s.strip().lower()
        return REGS[s]

    def parse_imm(s):
        s = s.strip()
        # Check if it's a label reference
        if s in labels:
            return labels[s]
        if s.startswith('0x') or s.startswith('0X'):
            return int(s, 16)
        return int(s, 0)

    def parse_mem(s):
        """Parse offset(reg) format"""
        m2 = re.match(r'(-?\w+)\((\w+)\)', s.strip())
        if m2:
            return parse_imm(m2.group(1)), parse_reg(m2.group(2))
        return None, None

    if op == 'li':
        # li rd, imm → lui + addi (if needed)
        rd_s, imm_s = args.split(',', 1)
        rd = parse_reg(rd_s)
        imm = parse_imm(imm_s)
        # For simplicity, emit as two instructions stored as list
        # But we need single-line... use lui + addi
        # Actually li is a pseudo-instruction. We'll handle it specially.
        upper = (imm + 0x800) >> 12  # adjust for sign extension of lower 12 bits
        lower = imm - (upper << 12)
        if lower == 0:
            return encode_u(upper << 12, rd, '0110111')  # lui
        else:
            # Return tuple for two instructions
            return (encode_u(upper << 12, rd, '0110111'),  # lui
                    encode_i(lower & 0xFFF, rd, '000', rd, '0010011'))  # addi

    elif op == 'sw':
        # sw rs2, offset(rs1)
        parts = args.split(',', 1)
        rs2 = parse_reg(parts[0])
        off, rs1 = parse_mem(parts[1])
        return encode_s(off, rs2, rs1, '010', '0100011')

    elif op == 'lw':
        # lw rd, offset(rs1)
        parts = args.split(',', 1)
        rd = parse_reg(parts[0])
        off, rs1 = parse_mem(parts[1])
        return encode_i(off, rs1, '010', rd, '0000011')

    elif op == 'addi':
        parts = args.split(',')
        rd = parse_reg(parts[0])
        rs1 = parse_reg(parts[1])
        imm = parse_imm(parts[2])
        return encode_i(imm & 0xFFF, rs1, '000', rd, '0010011')

    elif op == 'andi':
        parts = args.split(',')
        rd = parse_reg(parts[0])
        rs1 = parse_reg(parts[1])
        imm = parse_imm(parts[2])
        return encode_i(imm & 0xFFF, rs1, '111', rd, '0010011')

    elif op == 'srli':
        parts = args.split(',')
        rd = parse_reg(parts[0])
        rs1 = parse_reg(parts[1])
        shamt = parse_imm(parts[2])
        return encode_i(shamt & 0x1F, rs1, '101', rd, '0010011')  # funct7=0 for srli

    elif op == 'and':
        parts = args.split(',')
        rd = parse_reg(parts[0])
        rs1 = parse_reg(parts[1])
        rs2 = parse_reg(parts[2])
        return encode_r('0000000', rs2, rs1, '111', rd, '0110011')

    elif op == 'bne':
        parts = args.split(',')
        rs1 = parse_reg(parts[0])
        rs2 = parse_reg(parts[1])
        target = parse_imm(parts[2])
        offset = target - pc
        return encode_b(offset, rs2, rs1, '001', '1100011')

    elif op == 'beq':
        parts = args.split(',')
        rs1 = parse_reg(parts[0])
        rs2 = parse_reg(parts[1])
        target = parse_imm(parts[2])
        offset = target - pc
        return encode_b(offset, rs2, rs1, '000', '1100011')

    elif op == 'jal':
        parts = args.split(',')
        if len(parts) == 1:
            # jal target (rd=ra implied)
            rd = 1  # ra
            target = parse_imm(parts[0])
        else:
            rd = parse_reg(parts[0])
            target = parse_imm(parts[1])
        offset = target - pc
        return encode_j(offset, rd, '1101111')

    elif op == 'j':
        # j label → jal x0, label
        target = parse_imm(args)
        offset = target - pc
        return encode_j(offset, 0, '1101111')

    else:
        print(f"Unknown instruction: {op} {args}", file=sys.stderr)
        return None

def assemble(filename):
    with open(filename, encoding='utf-8') as f:
        lines = f.readlines()

    # First pass: collect labels and expand li pseudo-instructions
    # We need to know PC for each instruction
    instructions = []  # list of (pc, line_text)
    labels = {}
    pc = 0

    for line in lines:
        orig = line
        line = line.split('#')[0].strip()
        if not line or line.startswith('.'):
            continue

        # Handle label
        if ':' in line:
            parts = line.split(':', 1)
            label = parts[0].strip()
            labels[label] = pc
            line = parts[1].strip()
            if not line:
                continue

        # Check if it's a li pseudo-instruction (generates 2 instructions)
        m = re.match(r'li\s+', line)
        if m:
            instructions.append((pc, line))
            pc += 8  # lui + addi = 2 instructions
        else:
            instructions.append((pc, line))
            pc += 4

    # Second pass: assemble
    result = []
    for pc, line in instructions:
        val = assemble_line(line, labels, pc)
        if val is None:
            continue
        if isinstance(val, tuple):
            result.append(val[0])
            result.append(val[1])
        else:
            result.append(val)

    return result

if __name__ == '__main__':
    infile = sys.argv[1] if len(sys.argv) > 1 else 'instr_data.S'
    outfile = sys.argv[2] if len(sys.argv) > 2 else 'instr_data.dat'

    words = assemble(infile)

    with open(outfile, 'w') as f:
        for w in words:
            f.write(f'{w:08x}\n')

    print(f"Assembled {len(words)} instructions → {outfile}")
    for i, w in enumerate(words):
        print(f"  [{i:2d}] 0x{w:08x}")
