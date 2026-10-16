#!/usr/bin/env python3
"""Offline checks of the ADM-PCIE-9H3 flow (no Vivado needed):
  - every Tcl script (vivado/, constraints/) is complete (balanced braces / quotes: tclsh `info complete`);
  - no package pin is placed twice across the XDCs, and each port is placed once;
  - with the top present (rtl/boards/admpcie9h3/otpu_fpga_top_admpcie9h3.sv), every XDC port exists
    on it with the same width.

There is no LiteDRAM core and no memory pins here: the 8 GB of HBM are in the package, reached
through the Xilinx HBM IP (the IP's own scoped XDC constrains HBM_REF_CLK_0/1).
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BOARD = HERE.parent
ROOT = BOARD.parent.parent
TOP = ROOT / "rtl/boards/admpcie9h3/otpu_fpga_top_admpcie9h3.sv"


def xdc_ports(path: Path) -> dict[str, str]:
    """port bit -> package pin / LOC"""
    out = {}
    for pin, braced, bare in re.findall(
        r"(?:PACKAGE_PIN|LOC) (\S+) \[get_ports (?:\{([^}]+)\}|(\S+?))\]", path.read_text()
    ):
        out[braced or bare] = pin
    return out


def widths(bits) -> dict[str, int]:
    w: dict[str, int] = {}
    for b in bits:
        m = re.fullmatch(r"(\w+)(?:\[(\d+)\])?", b)
        w[m[1]] = max(w.get(m[1], 0), int(m[2]) + 1 if m[2] else 1)
    return w


def main() -> int:
    bad = []
    for tcl in sorted((BOARD / "vivado").glob("*.tcl")) + sorted((BOARD / "constraints").glob("*.tcl")):
        r = subprocess.run(["tclsh"], input=f"set f [open {{{tcl}}}]; set s [read $f]; "
                           f"puts [info complete $s]", capture_output=True, text=True)
        ok = r.stdout.strip() == "1"
        print(f"tcl {tcl.name}: {'ok' if ok else 'INCOMPLETE ' + r.stderr}")
        if not ok:
            bad.append(tcl.name)
    pins: dict[str, str] = {}
    allports: dict[str, str] = {}
    for x in sorted((BOARD / "constraints").glob("*.xdc")):
        for port, pin in xdc_ports(x).items():
            if pin in pins:
                bad.append(f"{pin}: {pins[pin]} and {port}")
            if port in allports:
                bad.append(f"{port} placed twice")
            pins[pin] = port
            allports[port] = pin
    print(f"xdc: {len(allports)} port bits on {len(pins)} pins")
    if TOP.exists():
        src = TOP.read_text()
        hdr = src[src.index("module otpu_fpga_top_admpcie9h3"):src.index(");", src.index("module otpu_fpga_top_admpcie9h3"))]
        top = {m[4]: (int(m[2]) - int(m[3]) + 1 if m[2] else 1) for m in
               re.finditer(r"(input|output|inout)\s+(?:logic|wire)\s*(?:\[(\d+):(\d+)\])?\s*(\w+)", hdr)}
        for p, w in widths(allports).items():
            if top.get(p) != w:
                bad.append(f"{p}[{w}]: not a port of the top (top: {top.get(p)})")
    else:
        print(f"top: {TOP.relative_to(ROOT)} not written yet")
    for b in bad:
        print("FAIL", b)
    print("offline checks:", "FAIL" if bad else "ok")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
