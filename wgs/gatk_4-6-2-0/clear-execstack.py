#!/usr/bin/env python3
"""Clear the executable-stack flag on ELF shared objects under a directory.

Why this exists
---------------
conda-forge's `libtorch_cpu.so` (pytorch 2.1.0, pulled in for GATK's
NVScoreVariants) is built with its PT_GNU_STACK program header marked
Read+Write+**Execute** (`RWE`). At load time the dynamic loader asks the kernel
to make the thread stack executable to honor that flag. Stock Linux kernels
allow it; hardened kernels (and some container/CI kernels) refuse, and the
import dies with:

    ImportError: libtorch_cpu.so: cannot enable executable stack as shared
    object requires: Invalid argument

The executable-stack marker is spurious here, pytorch does not actually need an
executable stack, so we simply clear the PF_X (0x1) bit in the PT_GNU_STACK
header. That makes the library load on every kernel and changes nothing about
how it runs. We edit the ELF bytes directly (rather than depend on a
patchelf >= 0.18 with `--clear-execstack`) so this works with whatever tools are
present, and we run it with the conda env's *own* python, reading/writing ELF
headers imports nothing, so the broken `import torch` is never triggered.

Usage: clear-execstack.py <dir>   # scans <dir> recursively for *.so*
"""
import glob
import os
import struct
import sys

PT_GNU_STACK = 0x6474E551
PF_X = 0x1


def clear_execstack(path):
    """Clear PF_X on the PT_GNU_STACK header of a 64-bit ELF. Returns True if changed."""
    with open(path, "r+b") as f:
        d = f.read()
        if d[:4] != b"\x7fELF" or d[4] != 2:  # not a 64-bit ELF
            return None
        en = "<" if d[5] == 1 else ">"  # little/big endian
        e_phoff = struct.unpack_from(en + "Q", d, 0x20)[0]      # program-header table offset
        e_phentsize = struct.unpack_from(en + "H", d, 0x36)[0]  # size of one entry
        e_phnum = struct.unpack_from(en + "H", d, 0x38)[0]      # number of entries
        for i in range(e_phnum):
            off = e_phoff + i * e_phentsize
            if struct.unpack_from(en + "I", d, off)[0] == PT_GNU_STACK:
                # In a 64-bit ELF program header, p_flags immediately follows p_type.
                flags_off = off + 4
                flags = struct.unpack_from(en + "I", d, flags_off)[0]
                if flags & PF_X:
                    f.seek(flags_off)
                    f.write(struct.pack(en + "I", flags & ~PF_X))
                    return True
                return False
    return False


def main():
    root = sys.argv[1]
    fixed = 0
    skipped = 0
    for so in glob.glob(root + "/**/*.so*", recursive=True):
        if os.path.isfile(so) and not os.path.islink(so):
            # A single unreadable/unwritable/odd file must not abort the scan:
            # aborting would leave later libraries (notably libtorch_cpu.so)
            # unpatched while the caller still marks the build complete.
            try:
                if clear_execstack(so):
                    fixed += 1
            except OSError as e:
                skipped += 1
                sys.stderr.write("clear-execstack: skipped %s: %s\n" % (so, e))
    msg = "clear-execstack: cleared executable-stack flag on %d library(ies)" % fixed
    if skipped:
        msg += "; skipped %d unreadable file(s)" % skipped
    print(msg)


if __name__ == "__main__":
    main()
