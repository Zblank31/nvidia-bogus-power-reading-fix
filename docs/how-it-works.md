# How it works, and how we found it

This document details the research behind the [README](../README.en.md): what we measured, what we assume, the keys we tried (including the useless ones) and the traps we met on the way.

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
clock event reason "SW Power Cap": clock at the minimum (210 MHz), fan in "safe" mode (50 %)
```

The fix (`RmPmgrPmuOverride=1`) removes the middle stage for that card: no more PMU power management, hence no more reading (`N/A`) and no more cap.

## 2. What is measured, what is assumed

Measured:

- The power reading: 389 to 402 W at idle, 407 to 422 W under load, with the card at 210 MHz (so really drawing very little). The wall meter showed 272 W for the whole PC.
- "SW Power Cap" active 100 % of the time under load, 3.4 TFLOPS versus ~25 for the healthy twin card.
- The BIOS: a full dump (999,424 bytes) byte-identical to the published reference for this model (SHA-256 `a562c94ac025992997238502edcfcb38f0e172483224882650ea56939c801f60`).
- The same behaviour with three driver versions, in an OCuLink dock and then on the motherboard.
- With the key: `power.draw` is `N/A`, "SW Power Cap" is gone, the performance states are dynamic (P0, P2, P5, P8), we measure 19.4 TFLOPS, the memory is at its normal clock, and the computation results are identical to the healthy card's.

Assumed, without proof:

- The origin is hardware: a sense channel stuck at full scale (≈ 393 W = 163.84 mV ÷ 5 mΩ × 12 V, the constant value observed). We did not open the card.
- The key switches off the PMU's power management. That is what its name and its effects suggest (the power reading disappears, so does the cap), not documentation.
- The lower real clock (~1335 MHz) comes from a voltage that is no longer managed. To be checked.

## 3. The driver's registry keys

The `nvidia` kernel module accepts two parameters:

- `NVreg_RegistryDwords="KEY=value;KEY=value"` for all cards;
- `NVreg_RegistryDwordsPerDevice="pci=0000:09:00.0;KEY=value;KEY=value;"` for one card, designated by its PCI address (domain:bus:device.function).

These keys are passed to the driver and to the card's firmware. They are not officially documented: you find the names in the driver (there are hundreds) and you discover what they do by trying them.

Two practical lessons:

1. The module is often loaded from the initramfs, before the root disk is mounted. An `options nvidia …` line in `/etc/modprobe.d` is then only seen at boot if the initramfs is rebuilt (`update-initramfs -u`). Our first series of trials fell into that trap: the driver saw no option and everything looked like no effect. Always check that the driver received the option: `grep RegistryDwordsPerDevice /proc/driver/nvidia/params`.
2. A hot reload re-reads `/etc/modprobe.d`. After `rmmod nvidia…`, a `modprobe nvidia` picks the file up without touching the initramfs. That is what lets you try a setting in 45 seconds without rebooting, at the price of closing the desktop (see [`research/`](../research/)).

## 4. The trials

### Series 1: invalid

Same plan as series 2, but without rebuilding the initramfs: the driver received no option. Nothing to learn from it, except the lesson of §3.

### Series 2: the "obvious" keys, one per reboot

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

The values we tried read as 2-bit fields: 85 (`01010101`) sets all fields to 1, 170 (`10101010`) sets them all to 2, and the other values isolate one field or remove one.

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

Conclusion: only the field in bits 0-1 matters, and only with the value 2. The other fields, alone or added, change nothing, and neither do the other keys combined with it.

### Fast series: the driver reloaded between trials

| setting | received | displayed load clock | TFLOPS | cap active % | state |
|---|---|---|---|---|---|
| (none) | – | 210 MHz | 3.42 | 100 | P2 |
| `RmPmgrPmuOverride=1` | yes | 1995 MHz | 19.43 | 0 | P2 |

The series stopped there (success criterion: clock ≥ 1000 MHz), so the seventeen other planned settings were not tried. Raw data: [`data/`](../data/).

## 5. The `RmPerfLimitsOverride=2` trap

With `=2` (or `=170`, `=162`, `=138`, `=42`), "SW Power Cap" disappears, the clock goes from 210 to 420 MHz and the throughput doubles (6.9 TFLOPS). It looks like a win. But:

- the performance state stays at P8, the lowest, even under load, and the memory stays at 405 MHz instead of 9251 MHz;
- the performance-state keys we planned to try on top of it (`DisableDynamicPstate`, `RMForcePstate`, `PerfLevelSrc`, `RMDisablePStates`…) were finally not tested: the series stopped at the first success, with another key;
- the most plausible reading is that this setting does not "lift" the cap, it stops the application of performance states and limits. The card stays in its boot state. That is worse than before for any workload that depends on memory (AI, for instance).

## 6. The key that works: `RmPmgrPmuOverride=1`

The card gets a normal behaviour back: P0, P2, P5 or P8 depending on the load, boost up to ~2 GHz displayed, memory at its clock, and no cap. In exchange: no power reading (`N/A`), no power limit, and a fan reading in error.

Only the value `1` was tried.

## 7. Displayed clock, real clock

`nvidia-smi` gives the requested clock. `tools/sondeclk` measures what the SMs deliver: it counts clock cycles (`clock64`) over an interval of the global timer (`globaltimer`), inside a compute kernel that occupies the whole card.

| card | displayed (nvidia-smi) | real (sondeclk) | TFLOPS | results checksum |
|---|---|---|---|---|
| Palit RTX 3080, healthy (capped at 319 W) | 1905-1920 MHz | 1917-1938 MHz | 25.0 | `c1a800a176215af3` |
| Fixed RTX 3080 LHR | 1980-1995 MHz | 1335-1366 MHz | 19.4 | `c1a800a176215af3` |

Both cards compute exactly the same thing (same checksum): the fixed card is slower, not wrong. Data: [`data/sondeclk-both-gpus.txt`](../data/sondeclk-both-gpus.txt).

## 8. Power at the wall

| state | whole PC + monitor |
|---|---|
| idle (both cards in P8, a browser open) | 329 W |
| fixed card at full load (19.3 TFLOPS) for 2 min | 515 W |

The extra 186 W at the wall make 150 to 170 W for the card (power-supply efficiency ~90 %, one CPU core busy with the test). That is about 115 GFLOPS/W, versus ~78 for the healthy card (25 TFLOPS at 319 W).

## 9. Reproducing, and going further

- Measure: `tools/gpuload` (load), `tools/sondeclk` (real clock), `tools/charge_longue.sh` (supervised load with a temperature cut-off). No CUDA toolkit needed, a C compiler is enough (`make -C tools`).
- Try other keys: `research/reload-trials.sh`. Read its warning first: it stops the desktop.
- Leads we did not follow: the keys whose names evoke current-sense calibration (`RmPmgrIsense…Override`), a sweep of `nvidia-smi -lgc` with `sondeclk`, measuring the core voltage, and inspecting the card around the sense shunts (solder joints, traces, signs of a "shunt mod" by the previous owner).
