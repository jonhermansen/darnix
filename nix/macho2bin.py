import struct
import sys
import os

macho = open(sys.argv[1], "rb").read()
outdir = sys.argv[2]

magic = struct.unpack_from("<I", macho, 0)[0]
assert magic == 0xFEEDFACF, f"Bad magic: {magic:#x}"
ncmds = struct.unpack_from("<I", macho, 16)[0]

segs = []
off = 32
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack_from("<II", macho, off)
    if cmd == 0x19:
        segname = macho[off + 8:off + 24].split(b"\0")[0].decode()
        vmaddr, vmsize, fileoff, filesize = struct.unpack_from(
            "<QQQQ", macho, off + 24
        )
        if vmsize > 0 and filesize > 0 and segname != "__PAGEZERO":
            segs.append((segname, vmaddr, vmsize, fileoff, filesize))
    off += cmdsize

base = min(s[1] for s in segs)
top = max(s[1] + s[2] for s in segs)
flat = bytearray(top - base)
for _, vmaddr, _, fileoff, filesize in segs:
    dest = vmaddr - base
    flat[dest:dest + filesize] = macho[fileoff:fileoff + filesize]

os.makedirs(outdir, exist_ok=True)
with open(os.path.join(outdir, "kernel.bin"), "wb") as f:
    f.write(flat)

entry_pc = 0
off = 32
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack_from("<II", macho, off)
    if cmd == 0x5:
        entry_pc = struct.unpack_from("<Q", macho, off + 0x110)[0]
        break
    off += cmdsize

entry_offset = entry_pc - base

with open(os.path.join(outdir, "entry_offset"), "w") as f:
    f.write(f"0x{entry_offset:x}\n")
with open(os.path.join(outdir, "virt_base"), "w") as f:
    f.write(f"0x{base:x}\n")
with open(os.path.join(outdir, "bin_size"), "w") as f:
    f.write(f"{len(flat)}\n")
