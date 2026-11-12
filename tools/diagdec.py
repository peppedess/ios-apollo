#!/usr/bin/env python3
"""Decode the QCA6390 firmware's F3 diag messages captured on MHI channel 5.

The kernel prints each DIAG packet as `SWEET DIAG: <n> bytes: <hex>`. Qualcomm's terse extended message
(command 0x92) carries the addresses of its format and file strings instead of the strings themselves;
both live in the firmware image, so the log only becomes readable with amss20.bin beside it.

    tools/diagdec.py recon/wlan/amss20.bin /tmp/sweetlog.txt
"""

import re
import struct
import sys


def load_image(path):
    data = open(path, "rb").read()
    segments = []
    phoff, = struct.unpack_from("<I", data, 28)
    phentsize, phnum = struct.unpack_from("<HH", data, 42)
    for i in range(phnum):
        _, offset, vaddr, _, filesz, _, _, _ = struct.unpack_from("<8I", data, phoff + i * phentsize)
        if filesz:
            segments.append((vaddr, filesz, offset))
    return data, segments


def read_string(data, segments, addr, limit=240):
    for vaddr, filesz, offset in segments:
        if vaddr <= addr < vaddr + filesz:
            start = offset + (addr - vaddr)
            end = data.find(b"\0", start, start + limit)
            if end < 0:
                end = start + limit
            return data[start:end].decode("latin1")
    return None


def format_message(fmt, args):
    out, n = "", 0
    i = 0
    while i < len(fmt):
        if fmt[i] == "%" and i + 1 < len(fmt):
            j = i + 1
            while j < len(fmt) and fmt[j] in "-+ #0123456789.lhz":
                j += 1
            if j < len(fmt):
                conv = fmt[j]
                if conv == "%":
                    out += "%"
                    i = j + 1
                    continue
                value = args[n] if n < len(args) else 0
                n += 1
                if conv in "dui":
                    out += str(value if value < 0x80000000 else value - 0x100000000)
                elif conv in "xX":
                    out += ("%x" if conv == "x" else "%X") % value
                elif conv == "c":
                    out += chr(value & 0x7F)
                else:
                    out += "%#x" % value
                i = j + 1
                continue
        out += fmt[i]
        i += 1
    return out


def decode(packet, data, segments):
    if len(packet) < 20:
        return None
    cmd = packet[0]
    if cmd not in (0x79, 0x92):
        return None
    nargs = packet[2]
    line, ss_id = struct.unpack_from("<HH", packet, 12)
    args = []
    off = 20
    for _ in range(nargs):
        if off + 4 > len(packet):
            break
        args.append(struct.unpack_from("<I", packet, off)[0])
        off += 4
    if cmd == 0x92:
        if off + 8 > len(packet):
            return None
        fmt_ptr, file_ptr = struct.unpack_from("<II", packet, off)
        fmt = read_string(data, segments, fmt_ptr)
        src = read_string(data, segments, file_ptr)
    else:
        rest = packet[off:].split(b"\0")
        fmt = rest[0].decode("latin1") if rest else None
        src = rest[1].decode("latin1") if len(rest) > 1 else None
    if not fmt:
        return None
    where = "%s:%d" % (src.split("/")[-1], line) if src else "line %d" % line
    return "[ss %d %s] %s" % (ss_id, where, format_message(fmt, args))


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 1
    data, segments = load_image(sys.argv[1])
    for raw in re.findall(r"SWEET DIAG: \d+ bytes: ([0-9a-f]+)", open(sys.argv[2], errors="ignore").read()):
        packet = bytes.fromhex(raw)
        text = decode(packet, data, segments)
        print(text if text else "raw %s" % raw[:64])
    return 0


if __name__ == "__main__":
    sys.exit(main())
