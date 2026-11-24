#!/usr/bin/env python3
"""Build the file list for the out-of-context FPGA synthesis of the PULP cluster.

Vivado's source scanner elaborates every module that no other file
instantiates, with default parameters, as a candidate top. The simulation file
list holds many such modules (verification IPs, unused variants, the HWPE
engines), and on that set the scanner does not converge and exhausts the
machine memory. This script keeps only the files reachable from the
accelerator wrapper, so that the wrapper is the only top.

Reachability is by identifier: a file is kept when it defines a module,
interface, package or program whose name appears in a file already kept. That
over-approximates (it follows generate branches that are not taken), which is
safe: such modules are instantiated, so they are never top candidates.
"""
import re
import sys
from pathlib import Path

SWAP = {
    "tech_cells_generic/src/rtl/tc_sram.sv": "tech_cells_generic/src/fpga/tc_sram_xilinx.sv",
    "tech_cells_generic/src/rtl/tc_clk.sv": "tech_cells_generic/src/fpga/tc_clk_xilinx.sv",
}
DEF_RE = re.compile(r"^\s*(?:module|macromodule|interface|package|program)\s+(?:automatic\s+|static\s+)?(\w+)", re.M)
TOKEN_RE = re.compile(r"[A-Za-z_]\w*")
COMMENT_RE = re.compile(r"//[^\n]*|/\*.*?\*/", re.S)


COND_RE = re.compile(r"^\s*`(ifdef|ifndef|elsif|else|endif)\b\s*(\w*)")


def clean(text):
    """Drop comments and the branches that synthesis does not see.

    Only conditions on the SYNTHESIS macro are resolved (Vivado defines it).
    Branches of any other condition are all kept.
    """
    out, stack = [], []  # stack entries: True/False for SYNTHESIS conditions, None otherwise
    for line in COMMENT_RE.sub(" ", text).splitlines():
        m = COND_RE.match(line)
        if m:
            kind, name = m.groups()
            if kind in ("ifdef", "ifndef"):
                stack.append((kind == "ifdef") if name == "SYNTHESIS" else None)
            elif kind == "else" and stack:
                stack[-1] = None if stack[-1] is None else not stack[-1]
            elif kind == "elsif" and stack:
                stack[-1] = None
            elif kind == "endif" and stack:
                stack.pop()
            continue
        if all(c is not False for c in stack):
            out.append(line)
    return "\n".join(out)


def main():
    acc_root = Path(sys.argv[1]).resolve()
    top = sys.argv[2]
    out = Path(sys.argv[3])
    vendor = acc_root / "vendor"

    excl = [re.compile(l.strip()) for l in (acc_root / "scripts/ooc_exclude.txt").read_text().splitlines()
            if l.strip() and not l.startswith("#")]

    incdirs, files = [], []
    for line in (acc_root / "pulp_cluster_rtl.sverilog").read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("+incdir+"):
            incdirs += [str(vendor / d) for d in line[len("+incdir+"):].split("+") if d]
            continue
        if line in SWAP:
            files.append(vendor / SWAP[line])
            continue
        if any(r.search(line) for r in excl):
            continue
        files.append(vendor / line)
    wrapper = sorted((acc_root / "hw/src" / top).glob("*.sv"))

    defs, tokens, owner = {}, {}, {}
    for f in files + wrapper:
        text = clean(f.read_text(errors="replace"))
        defs[f] = set(DEF_RE.findall(text))
        tokens[f] = set(TOKEN_RE.findall(text))
        for d in defs[f]:
            owner.setdefault(d, []).append(f)

    keep = set(wrapper)
    # files that define no design unit only carry macros or typedefs for later files
    keep |= {f for f in files if not defs[f]}
    work = list(keep)
    while work:
        f = work.pop()
        for name in tokens[f] & owner.keys():
            for g in owner[name]:
                if g not in keep:
                    keep.add(g)
                    work.append(g)

    ordered = [f for f in files if f in keep] + wrapper
    used = set()
    for f in ordered:
        used |= {t for t in tokens[f] if t not in defs[f]}
    orphans = sorted(d for f in ordered for d in defs[f] if d not in used)
    dups = sorted(d for d, fs in owner.items() if len([f for f in fs if f in keep]) > 1)

    out.write_text("".join("+incdir+%s\n" % d for d in incdirs) + "".join("%s\n" % f for f in ordered))
    print("flist: %d of %d files kept, %d include dirs" % (len(ordered), len(files) + len(wrapper), len(incdirs)))
    print("unreferenced design units (top candidates): %s" % " ".join(orphans))
    print("design units defined more than once: %s" % (" ".join(dups) or "none"))


if __name__ == "__main__":
    main()
