# How it works, and how it was found

This document details the research behind the [README](../README.en.md): the chain of cause and effect, what is **measured** and what is only **assumed**, the keys that were tried (including the ones that do not work), and the traps met on the way.

## 1. The chain of cause and effect

```
faulty current-sense channel (hypothesis)
        │
        ▼
power reading ≈ 395 W all the time, even at idle
        │
        ▼
the card's power management sees "395 W > 320 W limit"
        │
        ▼
clock event reason "SW Power Cap" ──► clock at the minimum (210 MHz), fan in "safe" mode (50 %)
```

The fix (`RmPmgrPmuOverride=1`) cuts the middle stage **for that card**: no more PMU power management, hence no more reading (N/A) and no more cap.

## 2. What is measured, what is assumed

**Measured**

- Power reading: 389-402 W at idle, 407-422 W under load, with the card at 210 MHz (so really drawing very little). The wall meter showed 272 W for the whole PC.
- “SW Power Cap” active 100 % of the time under load; 3.4 TFLOPS versus ~25 for the healthy twin card.
- BIOS: full dump (999,424 bytes) byte-identical to the published reference for this model (SHA-256 `a562c94ac025992997238502edcfcb38f0e172483224882650ea56939c801f60`).
- Same behaviour with three driver versions, in an OCuLink dock then on the motherboard.
- With the key: `power.draw` = N/A, no more “SW Power Cap”, dynamic performance states (P0/P2/P5/P8), 19.4 TFLOPS, memory at its normal clock, computation results identical to the healthy card's.

**Assumed (unproven)**

- *The origin is hardware*: a sense channel stuck at full scale (≈ 393 W = 163.84 mV ÷ 5 mΩ × 12 V, the constant value observed). The card was not opened.
- *The key switches off the PMU's power management*: that is what its name and its effects suggest (the power reading disappears, so does the cap), not documentation.
- *The lower real clock (~1335 MHz) comes from an unmanaged voltage*: to be checked.

## 3. The driver's registry keys

The `nvidia` kernel module accepts two parameters:

- `NVreg_RegistryDwords="KEY=value;KEY=value"`: for **all** cards;
- `NVreg_RegistryDwordsPerDevice="pci=0000:09:00.0;KEY=value;KEY=value;"`: for **one** card, designated by its PCI address (domain:bus:device.function).

Keys are passed to the card's GSP firmware; the ones it does not know are silently ignored. They are not officially documented: you find them by name (the firmware knows hundreds of them) and by effect.

Two practical lessons:

1. **The module is often loaded from the initramfs**, before the root disk is mounted. An `options nvidia …` line in `/etc/modprobe.d` is then seen at boot **only if the initramfs is rebuilt** (`update-initramfs -u`). My first series of trials was **invalid** for that reason: the driver saw no option and everything looked “no effect”. Always check that the driver received the option: `grep RegistryDwordsPerDevice /proc/driver/nvidia/params`.
2. **A hot reload re-reads `/etc/modprobe.d`**: after `rmmod nvidia…`, a `modprobe nvidia` picks up the file without touching the initramfs. That is what makes it possible to try a setting in ~45 s without rebooting (at the cost of closing the desktop: see [`research/`](../research/)).

## 4. The trials

### Series 1: invalid

Same plan as series 2, but without rebuilding the initramfs: the driver received no option (“received” = NO). Nothing learnt, except the lesson of §3.

### Series 2: “obvious” keys, one per reboot

| setting | received | load clock MHz | TFLOPS | power cap active % |
|---|---|---|---|---|
| (none) | - | 210 | 3.43 | 100 |
| `RmPerfRatedTdpLimit=0` | yes | 210 | 3.41 | 100 |
| `RmPerfRatedTdpLimit=1` | yes | 210 | 3.40 | 100 |
| `RMDisablePerfIntersect=1` | yes | 210 | 3.44 | 100 |
| `RmPerfLimitsOverride=85` | yes | 210 | 3.46 | 100 |
| `RmPerfLimitsOverride=170` | yes | 420 | 6.93 | 0 |
| `RMUseSwI2c=1` | yes | 210 | 3.42 | 100 |
| `RMUsePmuSwI2c=1` | yes | 210 | 3.42 | 100 |
| `RMForceLockedClocksMode=1` | yes | 210 | 3.42 | 100 |
| `RmPmgrIsenseCheckIgnore=1` | yes | 210 | 3.42 | 100 |

Only `RmPerfLimitsOverride=170` changes anything, and it is not what it looks like (see §5).

### Series 3: dissecting `RmPerfLimitsOverride`

The value reads as four 2-bit fields (0 = default, 1 or 2 = force a flag to 0 or to 1, 3 = invalid).

| setting | received | load clock MHz | TFLOPS | power cap active % | P-state |
|---|---|---|---|---|---|
| (none) | - | 210 | 3.43 | 100 | P2 |
| `RmPerfLimitsOverride=170` | yes | 420 | 6.93 | 0 | P8 |
| `RmPerfLimitsOverride=2` | yes | 420 | 6.93 | 0 | P8 |
| `RmPerfLimitsOverride=8` | yes | 210 | 3.42 | 100 | P2 |
| `RmPerfLimitsOverride=32` | yes | 210 | 3.42 | 100 | P2 |
| `RmPerfLimitsOverride=128` | yes | 210 | 3.42 | 100 | P2 |
| `RmPerfLimitsOverride=168` | yes | 210 | 3.42 | 100 | P2 |
| `RmPerfLimitsOverride=162` | yes | 420 | 6.93 | 0 | P8 |
| `RmPerfLimitsOverride=138` | yes | 420 | 6.90 | 0 | P8 |
| `RmPerfLimitsOverride=42` | yes | 420 | 6.93 | 0 | P8 |
| `RmPerfLimitsOverride=170;RmPerfRatedTdpLimit=0` | yes | 420 | 6.93 | 0 | P8 |
| `RmPerfLimitsOverride=170;RMDisablePerfIntersect=1` | yes | 420 | 6.93 | 0 | P8 |
| `RmPerfLimitsOverride=170;RMForceLockedClocksMode=1` | yes | 420 | 6.93 | 0 | P8 |

Conclusion: **only the field in bits 0-1 matters**, and only with the value 2. The other fields, alone or added, change nothing; the other keys combined with it neither.

### Fast series: the driver reloaded between trials

| setting | received | displayed load clock | TFLOPS | cap active % | state |
|---|---|---|---|---|---|
| (none) | – | 210 MHz | 3.42 | 100 | P2 |
| `RmPmgrPmuOverride=1` | yes | **1995 MHz** | **19.43** | 0 | P2 |

The series stopped there (success criterion: clock ≥ 1000 MHz): the seventeen other planned settings were not tried. Raw data: [`data/`](../data/).

## 5. The `RmPerfLimitsOverride=2` trap

With `=2` (or `=170`, `=162`, `=138`, `=42`), “SW Power Cap” disappears, the clock goes from 210 to 420 MHz and the throughput doubles (6.9 TFLOPS): it looks like a win. But:

- the performance state stays **P8** (the lowest) **even under load**; memory stays at **405 MHz** instead of 9251 MHz;
- the performance-state keys we planned to try on top of it (`DisableDynamicPstate`, `RMForcePstate`, `PerfLevelSrc`, `RMDisablePStates`, …) were finally not tested: the series stopped at the first success, with another key;
- the most plausible reading: this setting does not “lift” the cap, it **stops the application of performance states and limits**. The card stays in its boot state. That is worse than before for any memory-bound workload (AI, for instance).

## 6. The key that works: `RmPmgrPmuOverride=1`

Observed: the card gets a normal behaviour back (P0/P2/P5/P8 depending on the load, boost up to ~2 GHz displayed, memory at its clock), without a cap. Price: no power reading (`N/A`), no power limit, fan reading in error.

Only the value `1` was tried.

## 7. Displayed clock versus real clock

`nvidia-smi` gives the **requested** clock. `tools/sondeclk` measures what the SMs **deliver**: it counts clock cycles (`clock64`) over an interval of the global timer (`globaltimer`), inside a compute kernel that occupies the whole card.

| card | displayed (nvidia-smi) | real (sondeclk) | TFLOPS | results checksum |
|---|---|---|---|---|
| Palit RTX 3080, healthy (capped at 319 W) | 1905-1920 MHz | 1917-1938 MHz | 25.0 | `c1a800a176215af3` |
| Fixed RTX 3080 LHR | 1980-1995 MHz | **1335-1366 MHz** | 19.4 | `c1a800a176215af3` |

Both cards compute exactly the same thing (same checksum): the fixed card is slower, not wrong. Data: [`data/sondeclk-both-gpus.txt`](../data/sondeclk-both-gpus.txt).

## 8. Power at the wall

| state | whole PC + monitor |
|---|---|
| idle (both cards in P8, a browser open) | 329 W |
| fixed card at full load (19.3 TFLOPS) for 2 min | 515 W |

+186 W at the wall ≈ **150-170 W** for the card (PSU efficiency ~90 %, one CPU core busy with the test). Efficiency: ~115 GFLOPS/W versus ~78 for the healthy card (25 TFLOPS at 319 W).

## 9. Reproduce, and go further

- Measure: `tools/gpuload` (load), `tools/sondeclk` (real clock), `tools/charge_longue.sh` (supervised load with a temperature cut-off). No CUDA toolkit: a C compiler is enough (`make -C tools`).
- Try other keys: `research/reload-trials.sh` (read the warning: it stops the desktop).
- Unexplored leads: the keys whose names evoke current-sense calibration (`RmPmgrIsense…Override`), a sweep of `nvidia-smi -lgc` with `sondeclk`, measuring the core voltage, a hardware inspection around the sense shunts (solder joints, traces, signs of a “shunt mod” by the previous owner).
