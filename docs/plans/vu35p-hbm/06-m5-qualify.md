# M5 — Qualify, measure, document

Goal: the bitstream becomes a resting image the repo's own qualification accepts, the
HBM-specific observability is wired into the tools, and the board gets its doc page.

## 5.1 Qualification

The existing `tools/qual/qual.sh` is target-agnostic (it reads the card's CFG registers);
nothing should need changing except anything M1's dispatch list flagged. Run:

```sh
bash tools/qual/qual.sh <deploy> fast     # first
bash tools/qual/qual.sh <deploy> full     # after any MXU/VPU/memory-path RTL change
```

HBM-specific phases to watch in `$OUT/checks.txt` (see `docs/board.md` section 4 for the
full table):

1. **WAITW** (CAPS bit 31): host writes data then a flag while the card waits on the flag
   then reads the data — the write-visibility-through-the-switch test (2.1's ordering
   property). A timeout here is the `DRAIN=1` fix, nothing else.
2. **ECC**: counters (sec / ded since configuration) must be 0 — with ECC on, this reads
   the HBM IP's counters (4.0's tool), which `Board.scrub` clears after its zeros.
3. **Turnaround / `tools/rw_bench.py`**: fp4 weight streams beside 64 KiB stores and
   loads, data checked against the ISA simulator — the `mm+st`, `mm+ld`, `mm+dstep` rows
   are where the HBM switch's behaviour differs from LiteDRAM's; record them next to
   `docs/board.md` section 4's tables.
4. **Token-exact** in 6 configurations + long prompt + card-loop decode (CAPS bit 30):
   bit-identical logits vs the ISA simulator, per-position and resident.
5. **xdma errors in `dmesg`** since load: each a FAIL.

A `full` PASS (`QUAL DONE <deploy> ... : PASS`) is the milestone gate.

## 5.2 Observability into the tools

1. **`otpu-smi` DRAM counters**: today's boards derive GB/s from the accelerator's own
   beat counters; on this board read the HBM IP's per-MC bandwidth monitors (4.0's
   `otpu-hbm bw`) so `otpu-smi` shows real HBM GB/s per controller, and keep the
   accelerator's counters for the efficiency ratio.
2. **`otpu-diag`**: add/confirm an HBM stage (identifier, scratch, initialized, ECC
   counters) alongside the DDR4 one; the works/does-not-work matrix's diagnosis hints get
   HBM-region variants (region ↔ AXI port ↔ channel mapping from the address map).
3. **Lens / trace**: nothing new (the trace path is core-side); but record a decode
   trace on HBM — the DRAM-wait histogram should visibly change against the DDR3 boards
   (this is the "what does a 460 GB/s memory do to a DRAM-bound decode" datapoint).

## 5.3 Performance follow-ups (after the image qualifies)

Ordered by what the counters will say:

1. **Clock**: 100 MHz → 133.33 MHz+ (`CORE_MHZ`, the YPCB's even-divider rule for
   `TMEM_PMP` if enabled). HBM is not the bandwidth constraint the DDR3 was; the core's
   own Fmax is (as on the YPCB: WNS +0.032 ns at 133.33).
2. **`SEQ_WC` on** (WAITC, the production YPCB's config) once timing allows — it is
   `SEQ_WC = false` in M1 only for bring-up.
3. **`TMEM_URAM=1`** if block RAM binds two slices (M0.5's choice; `tmem_uram.xdc`
   already exists from BCU1525).
4. **More HBM AXI ports per channel** (the IP regenerates with more ports; the bridge
   gets a `NP` parameter; the two-port cross-port ordering story stays as-is per native
   port) — only if `rw_bench`/`MXU_STARVE` show the channels saturated (unlikely below
   133 MHz: one port is ~14.4 GB/s at 450 MHz against 6.4-8.5 GB/s of core traffic per
   channel).
5. **`RMW` off end-to-end** (already `RMW=0` on the HBM board? then: remove the bridge's
   RMW entirely and rely on the IP's — verify with `rw_bench` gathered stores and
   `otpu-diag --mem full`).
6. **S=2 model runs**: the two-slice programs (`board_config(S=2)`), MoE offload at
   Gen3 x16 (the `docs/offload.md` numbers should improve ~5x over Gen2 x8).

## 5.4 Documentation

1. `docs/<board>.md` — clone `docs/bcu1525.md`'s structure: the board table (M0.3),
   the accelerator on this board (slices/SLRs/clocks), pins (short: no memory pins),
   **the HBM subsystem** (IP config, address map, ECC, the bridge's contract), PCIe/BD,
   flow, resource estimate, phase status, day-one checklist, open items. Keep the
   measured-vs-projected discipline of the other docs.
2. `docs/targets.md`: add the row and, since this is the first `mem = "hbm"` target, the
   one-paragraph note on what HBM changes (no pins, no calibration firmware, AXI3 slave
   ports instead of a LiteDRAM native port).
3. `README.md` "What's next / More targets": add the board once it qualifies.
4. `docs/plans/vu35p-hbm/*`: append a "Status" line per file as milestones close (the
   repo's doc style keeps history in place).

## Deliverable

- `qual.sh full` PASS on the card;
- `otpu-smi` / `otpu-diag` / `otpu-hbm` showing HBM's own counters;
- `docs/<board>.md` merged, `docs/targets.md` row added;
- performance tables (decode/prefill tok/s, DRAM GB/s and efficiency) recorded next to
  the YPCB and BCU1525 numbers.
