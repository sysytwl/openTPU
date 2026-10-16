"""The HBM memory path in Verilator (docs/plans/vu35p-hbm/03-m2-rtl.md 2.2): otpu_mem_ch's
accelerator native port and its XDMA AXI master, one otpu_native_axi3 per native port, in front of
otpu_hbm_model's two AXI3 slave ports -- the integration one HBM board channel has. Every case runs
with otpu_mem_ch RMW = 0 (the partial beat's byte enables go out as AXI WSTRB and the model merges)
and RMW = 1 (otpu_mem_ch read-modify-writes, the model sees whole beats only).

The directed build (DIR = 1) replaces the random accelerator with tb_hbmbdg_dir's fixed script:
full-beat writes and reads, partial writes preserving the old bytes, read-after-write and
write-after-read, the write-flag-read host protocol, and a read burst past the read credits. The
random builds reuse tb_memch's masters (tb_memch_nat and tb_memch_axi) over the scenarios below
(partial beats, read-back, resets are not wired here, shared/split regions, credit stress, stalls,
DRAM timing, ECC). +want_partial asserts the model saw partial WSTRB from RMW = 0 and none from
RMW = 1.
"""
import re

import pytest

from opentpu import rtlsim

SRC = [rtlsim.RTL / "shell/otpu_afifo.sv", rtlsim.RTL / "shell/otpu_mem_ch.sv",
       rtlsim.RTL / "shell/otpu_native_axi3.sv", rtlsim.TB / "otpu_hbm_model.sv",
       rtlsim.TB / "tb_memch.sv", rtlsim.TB / "tb_hbmbdg.sv"]

# random scenarios: plusargs over tb_memch's masters (see tb_memch.sv), +ntx 800 runs / bursts
SCEN = {
    "default": ["+ntx=800"],
    "seed2": ["+ntx=800", "+seed=2"],
    "hbmstall": ["+ntx=800", "+hbm_stall=60"],
    "hbmlat": ["+ntx=800", "+hbm_lat=40"],
    "hbmstalllat": ["+ntx=800", "+hbm_stall=30", "+hbm_lat=50"],
    "dram": ["+ntx=800", "+hbm_dram=1"],
    "ecc": ["+ntx=800", "+hbm_ecc=1", "+hbm_ecc_ce=10", "+hbm_ecc_ue=2"],
    "mstall70": ["+ntx=800", "+mstall=70"],
    "nogaps": ["+ntx=800", "+mstall=0", "+gapw=0", "+gapc=0"],
    "credstress": ["+ntx=800", "+cp=900", "+wpct=10", "+mstall=0", "+rbuf=256", "+gapc=0",
                   "+ppct=0"],
    "shared": ["+ntx=800", "+psh=40", "+psp=40"],
    "partial": ["+ntx=800", "+ppct=100", "+xfull=0"],
    "rawpart": ["+ntx=800", "+ppct=60", "+raw=60", "+wpct=60", "+xfull=20"],
    "seqrd": ["+ntx=800", "+seq=1", "+wpct=0"],
    "seqwr": ["+ntx=800", "+seq=1", "+wpct=100"],
    "seqmix": ["+ntx=800", "+seq=1", "+wpct=50"],
    "acc-only": ["+ntx=800", "+xdma_ntx=0"],
    "xdma-only": ["+ntx=800", "+acc0_ntx=0"],
}

RMW = [1, 0]


def _run(exe, args, timeout=3600):
    r = rtlsim.run_sim([str(exe)] + list(args), timeout=timeout)
    out = (r.stdout or "") + (r.stderr or "")
    m = re.search(r"^(PASS|FAIL|TIMEOUT)", out, re.M)
    return (m.group(1) if m else "ABORT"), out


@pytest.fixture(scope="module")
def exe(have_verilator):
    """The random build per RMW (a module fixture: built once, cached by rtlsim.build)."""
    return {rmw: rtlsim.build("tb_hbmbdg", SRC, {"RMW": rmw}) for rmw in RMW}


@pytest.fixture(scope="module")
def dir_exe(have_verilator):
    """The directed build per RMW (DIR = 1: tb_hbmbdg_dir instead of tb_memch_nat)."""
    return {rmw: rtlsim.build("tb_hbmbdg", SRC, {"RMW": rmw, "DIR": 1}) for rmw in RMW}


@pytest.mark.parametrize("name", list(SCEN))
@pytest.mark.parametrize("rmw", RMW)
def test_hbmbdg_random(exe, rmw, name):
    """tb_memch's masters over the HBM channel: every read checked against a byte shadow, every
    write counted exactly once (n_wdone / B), no protocol violation at the bridge or the model."""
    res, out = _run(exe[rmw], SCEN[name])
    assert res == "PASS", out[-3000:]


@pytest.mark.parametrize("rmw", RMW)
def test_hbmbdg_directed(dir_exe, rmw):
    """tb_hbmbdg_dir's fixed script over the native port (see the module header)."""
    res, out = _run(dir_exe[rmw], ["+xdma_ntx=0"])
    assert res == "PASS", out[-3000:]


@pytest.mark.parametrize("rmw", RMW)
def test_hbmbdg_partial_wstrb(exe, rmw):
    """The RMW distinction at the model's pins: with RMW = 0 a partial write reaches it with
    partial WSTRB (the merge fills the rest); with RMW = 1 every W beat's WSTRB is all ones."""
    res, out = _run(exe[rmw], ["+ntx=800", "+ppct=100", "+xfull=0", "+want_partial=1"])
    assert res == "PASS", out[-3000:]
