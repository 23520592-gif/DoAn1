# Dual-Core Ibex RISC-V with Directory-Based MESI Cache Coherence and Crossbar

Two [lowRISC Ibex](https://github.com/lowRISC/ibex) RISC-V cores, each with a private write-back L1 data cache, kept coherent by a **directory-based MESI protocol** and connected to a **2-bank line-interleaved crossbar**. Verified in simulation (Vivado xsim / Questa) from an isolated protocol test up to two real Ibex cores running software.

> **Note:** This is an academic project for learning and research on cache coherence. It is simulation-only, uses small blocking caches and a limited address range, and has no synthesis, timing or silicon results, so it is unlikely to be suitable for real-world use as is.

> Course project (Đồ án 1), University of Information Technology (UIT-VNU-HCM).
> Authors: Lê Đăng Huy, Bùi Hoàng Anh Huy · Advisor: Tạ Trí Đức

---

## Motivation

The starting point was a dual-core Ibex system on a shared bus with a round-robin arbiter (`shared_bus/`). It has two problems:

1. **Bandwidth bottleneck.** Every access is serialized through one bus.
2. **No cache coherence.** With private caches, one core can read stale data another core already overwrote.

This project replaces the shared-bus data path with a cache-coherent subsystem and keeps the original design as a baseline.

## Architecture

```
   ┌──────────┐                    ┌──────────┐
   │ Ibex #0  │                    │ Ibex #1  │      instr fetch: private IMEM
   └────┬─────┘                    └────┬─────┘      (does not go through cache)
        │ data (OBI-style)              │
   ┌────┴─────┐                    ┌────┴─────┐
   │ L1-D $   │                    │ L1-D $   │      write-back, write-allocate,
   │ (MESI)   │                    │ (MESI)   │      16 lines x 16 B, direct-mapped
   └─┬──┬──┬──┘                    └─┬──┬──┬──┘
     │  │  │ req / resp / snoop      │  │  │          permission network
     │  │  └──────────┐   ┌──────────┘  │  │
     │  │         ┌───┴───┴───┐         │  │
     │  │         │ Directory │  state, sharers, owner (NO data)
     │  │         └───────────┘         │  │
     │  └────────── 128-bit line ───────┘  │          data network
     └──────────────┐          ┌───────────┘
               ┌────┴──────────┴────┐
               │      Crossbar      │  per-bank round-robin, addr[4] interleave
               └────┬──────────┬────┘
                ┌───┴───┐  ┌───┴───┐
                │ Bank0 │  │ Bank1 │
                └───────┘  └───────┘
```

### Key design decision: split the permission network from the data network

The directory only exchanges **permissions** (GetS, GetM, PutM, Invalidate, Forward, acks). It never holds or forwards line data. Line fills and writebacks travel cache ↔ crossbar ↔ bank as 128-bit transfers.

If data flowed through the directory, the directory would serialize everything and the crossbar would add nothing. With the split, two cores can access two different banks in parallel while the directory still guarantees coherence.

### Components

| Module | Role |
|---|---|
| `ibex_coherence_pkg.sv` | Shared types: MESI states, request/response/snoop messages, geometry parameters |
| `ibex_l1_cache.sv` | Blocking L1-D cache FSM with separate phases for miss/fill, writeback and snoop service |
| `ibex_directory_controller.sv` | Permission-only directory, round-robin arbitration between cores, invalidate/forward/recall paths |
| `ibex_cache_bank_crossbar.sv` | M×S line-granular crossbar, per-bank round-robin, bank = `line_index[0]`, 1-cycle latency |
| `ibex_coh_subsystem.sv` | Wires 2 caches + directory + crossbar |
| `ibex_dualcore_top_v3.sv` | Two `ibex_top` cores + private IMEM + coherent subsystem |
| `perf_monitor.sv` | Bind-able performance counters (data transactions, snoops, contention, fairness) |

## Verification

Three levels, each one isolating a different class of bug:

| Level | Testbench | What is checked | Result |
|---|---|---|---|
| Protocol, isolated | `ibex_coherence_tb.sv` | 2 OBI ports, no real cores. read → read → write → read on one address. MESI goes I→E→S→M; Core 1 must read Core 0's value | PASS (`0x12345678`) |
| Subsystem + crossbar | directed test | Cross-core read-back through crossbar; second address mapped to bank 1 | PASS |
| Full system | `ibex_dualcore_v3_tb.sv` | 2 real Ibex cores run machine code. Core 0 stores `0xDEAD0000` to `0x20000`, Core 1 stores `0xCAFE0000` to `0x20004`, each then loads the other's word | PASS (reads `0xCAFE0000` / `0xDEAD0000`) |

### Performance counters (subsystem-level directed scenarios, Verilator)

Measured with `perf_monitor.sv` using hand-written traffic, **not** real-core workloads. Treat these as characterization of the coherence cost, not as benchmark results.

| Scenario | Cycles | Data txns | Snoops | Fairness (C0:C1) |
|---|---|---|---|---|
| True sharing (both cores write/read the same line) | 428 | 60 | 118 | 20 : 20 |
| Read-only sharing (line stays in S) | 166 | 23 | 4 | 11 : 10 |

True sharing costs roughly 30× more snoops than read-only sharing for a similar number of accesses, which is the expected invalidate ping-pong. Round-robin arbitration stays fair in both cases.

## Repository layout

```
.
├── rtl/
│   ├── coherence/          # the 5 coherence modules + perf_monitor
│   ├── top/                # ibex_dualcore_top_v3.sv
│   └── shared_bus/         # baseline: arbiter, decoder, monitor, shared SRAM, top_v2
├── tb/                     # ibex_coherence_tb, ibex_dualcore_v3_tb, shared-bus tb
├── sim/                    # ibex_v3.prj, add_waves.tcl, run.do
├── docs/                   # slides, waveforms
└── third_party/ibex/       # lowRISC Ibex (git submodule)
```

## Running the simulation (Vivado xsim)

Requirements: Vivado 2025.2 (any recent xsim should work), lowRISC Ibex checked out under `third_party/ibex`.

`sim/ibex_v3.prj` lists files in compile order (packages first). **Edit the absolute paths in it to match your checkout.**

```tcl
# from a Vivado Tcl shell
xvlog --relax -sv -prj ibex_v3.prj \
  -i <ibex>/rtl \
  -i <ibex>/vendor/lowrisc_ip/ip/prim/rtl \
  -i <ibex>/vendor/lowrisc_ip/ip/prim_generic/rtl \
  -i <ibex>/vendor/lowrisc_ip/dv/sv/dv_utils -L uvm

xelab --relax --debug typical --mt 2 -L xil_defaultlib -L uvm -L unisims_ver -L secureip \
  --snapshot v3_snap xil_defaultlib.ibex_dualcore_v3_tb xil_defaultlib.glbl

xsim v3_snap -R
```

Notes that cost us time:

- Ibex resets its PC to `{boot_addr[31:8], 8'h80}`, so the test program is loaded at `imem[32]` (PC `0x80`; Core 1 at `0x10080`).
- The Vivado GUI project flow computed a wrong simulation hierarchy (wrong top, missing files). Driving `xvlog`/`xelab`/`xsim` directly with a `.prj` avoided this.
- Do not open files under `*.sim/` in an editor while a simulation is running (Windows file lock makes `xelab` fail).
- xsim flattens generate-block hierarchy, so internal cache signals are not visible in its waveform. Questa (`sim/run.do`, `+acc`) keeps the hierarchy.

## Known limitations

- **Blocking caches.** One outstanding transaction per core, so throughput is bounded by miss latency.
- **Small direct-mapped L1** (16 lines). No replacement policy, no prefetch.
- **No address decoder.** Every data access goes through the cache. The directory/crossbar cover 256 lines × 16 B = 4 KiB; higher addresses wrap onto the same lines (the `0x2000x` test addresses rely on this wrap). Instruction fetch bypasses the cache.
- **No atomics.** Ibex is built as RV32IMC (no A extension), so software synchronization is flag-based, not spinlock-based.
- **Verification gaps.** Dirty-line eviction (PutM) and concurrent GetM from both cores to one line are not yet covered by dedicated tests. No formal verification. The disjoint-bank scenario (core 0 on bank 0, core 1 on bank 1) has not been characterized, so parallel-access gain from the crossbar is not yet quantified.
- Simulation only. No synthesis or timing results yet.

## Future work

Non-blocking caches, more cores/banks, MOESI, a shared L2, AXI-based interconnect, peripherals and an interrupt controller to turn this into a full SoC, and synthesis/timing/utilization numbers.

## Acknowledgements and license

Built on the [lowRISC Ibex](https://github.com/lowRISC/ibex) core (Apache-2.0). Add a `LICENSE` for your own RTL (Apache-2.0 keeps it consistent with Ibex).
