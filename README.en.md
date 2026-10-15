# My NVIDIA card is stuck at 210 MHz: a workaround for a bogus power reading

> **Tested on**: GALAX/KFA2 **RTX 3080 LHR 10 GB**, bought second-hand (ex-mining) · Linux (Ubuntu 26.04) · NVIDIA driver **615.71.09, open kernel modules**.
> Français : [README.md](README.md) · Video: *(link coming)*
>
> ⚠️ **One single card tested.** This is a workaround that disables a protection, not a repair. Read [“What it costs”](#4-what-it-costs-read-before-applying).

## In short

You have an NVIDIA card (often second-hand, ex-mining) that:

- shows an absurd power draw in `nvidia-smi`, **~400 W while doing nothing**;
- stays **stuck at 210 MHz** as soon as it gets work, with the clock event reason **“SW Power Cap”** active;
- keeps its fan **stuck at 50 %** even at 25 °C;
- and all of that **across several driver versions, several slots, and with the original BIOS**?

Then the card *believes* it draws far more than it does, and the driver firmware throttles it permanently. Here is a workaround that fits in **one line** of configuration:

```
options nvidia NVreg_RegistryDwordsPerDevice="pci=0000:09:00.0;RmPmgrPmuOverride=1;"
```

(adapt it with **your card's PCI address**; see the [step by step](#2-the-fix-step-by-step-linux)).

**On my card**: 210 → **1995 MHz** displayed, **3.4 → 19.4 TFLOPS** (×5.7), maximum temperature **44 °C** after two minutes at full load, about **160 W real** measured at the wall.

## Contents

1. [Am I affected?](#1-am-i-affected)
2. [The fix, step by step (Linux)](#2-the-fix-step-by-step-linux)
3. [Results on my card](#3-results-on-my-card)
4. [What it costs (read before applying)](#4-what-it-costs-read-before-applying)
5. [If it does not work](#5-if-it-does-not-work)
6. [How I found it](#6-how-i-found-it)
7. [Open questions](#7-open-questions)
8. [Contributing](#8-contributing)
9. [Disclaimer, license, credits](#9-disclaimer-license-credits)

## 1. Am I affected?

### The symptoms (all together)

| What you see | On my card |
|---|---|
| `nvidia-smi` reports a big power draw **at idle** (0 % usage) | ~390-400 W at idle, ~420 W under load |
| Under load the clock stays at the **minimum** (210 MHz) | 210 MHz, 3.4 TFLOPS versus ~25 for my healthy twin card |
| `nvidia-smi -q -d PERFORMANCE`: **SW Power Cap: Active** (`clocks_event_reasons.active` = `0x4`) | yes, permanently under load |
| Fan fixed at **50 %**, even at 25 °C | yes |
| No thermal or power-supply cause | 23-26 °C at idle, 1600 W PSU |
| Same behaviour with other drivers / another slot | 3 driver versions, OCuLink dock then motherboard slot |
| The BIOS is the original one | full flash dump byte-identical to the published reference for this model |

### The check

```bash
./scripts/diagnostic.sh        # read-only; run it at idle, then during a load (tools/gpuload 60)
```

It prints one line per card and a verdict (“SUSPICIOUS: reads 395 W while the GPU is idle”, …). It prints no serial number or UUID, so you can paste the output into an issue.

### The decisive test: a wall power meter

`nvidia-smi` can be wrong, **a wall meter cannot**. Compare:

- the power `nvidia-smi` credits to the card at idle;
- the power of **the whole PC** (monitor included) measured at the wall, at idle.

If `nvidia-smi` says 395 W for *one card* while the wall shows 272 W for the *whole PC*, the reading is bogus (that was my case). If the wall confirms the consumption, **do not apply this fix**: you would be hiding a real problem (short circuit, overheating…).

## 2. The fix, step by step (Linux)

**Requirements**: Linux, a recent NVIDIA driver with GSP firmware (tested: 615.71.09, **open** kernel modules), a Volta-or-newer card, root, ideally a wall power meter.

**1. Find your card's PCI address** (here `0000:09:00.0`):

```bash
lspci -D -nn | grep -E "VGA|3D" | grep -i nvidia
# or: ./scripts/apply-fix.sh --list
```

**2. Write the configuration** (replace the address!):

```bash
sudo tee /etc/modprobe.d/nvidia-bogus-power-fix.conf <<'EOF'
options nvidia NVreg_RegistryDwordsPerDevice="pci=0000:09:00.0;RmPmgrPmuOverride=1;"
EOF
```

The quotes, the `pci=` prefix and the `;` (including the last one) matter. Thanks to `pci=`, **only that card** is affected: your healthy card, if any, is untouched.

**3. Rebuild the initramfs** (on many distributions the `nvidia` module is loaded from the initramfs, before the root disk is mounted: without this step the option is not seen at boot):

```bash
sudo update-initramfs -u -k all     # Debian / Ubuntu
sudo dracut -f --regenerate-all     # Fedora / RHEL / openSUSE
sudo mkinitcpio -P                  # Arch
```

**4. Reboot.**

**5. Check**:

```bash
grep RegistryDwordsPerDevice /proc/driver/nvidia/params   # must show your address and RmPmgrPmuOverride=1
./scripts/verify.sh --bus 0000:09:00.0                    # short load + verdict
```

**Shortcut**: `sudo ./scripts/apply-fix.sh --bus 0000:09:00.0` does steps 2 and 3 with safeguards (checks the address, asks for confirmation, checks that `modprobe` sees the option). Add `--dry-run` to see what it would do without changing anything.

**Undo**: `sudo ./scripts/remove-fix.sh`, then reboot.

## 3. Results on my card

| | Before | After |
|---|---|---|
| Displayed GPU clock under load | 210 MHz | **1995 MHz** (1965 MHz at 44 °C) |
| Memory clock under load | 9251 MHz | 9251 MHz |
| Compute throughput (FP32 FMA, `tools/gpuload`) | 3.4 TFLOPS | **19.4 TFLOPS** |
| Clock event reason | SW Power Cap | “Reliability” and “Board Limit” (benign) |
| Power read by `nvidia-smi` | ~395 W (bogus) | `N/A` |
| Temperature (120 s at full load) | – | 31 → 44 °C, flattening curve |
| Wall (whole PC + monitor) | – | 329 W idle → 515 W with the card at full load (**+186 W**) |

The +186 W at the wall, with a power-supply efficiency of about 90 %, gives **~150-170 W** for the card: half of its 320 W rating.

My healthy twin card (Palit RTX 3080) gives 25 TFLOPS at 319 W. The fixed card gives 77 % of that for about half the power. The reason is in [Open questions](#7-open-questions): **its real clock is only ~1335 MHz**, not 1995.

Raw measurements are in [`data/`](data/), the details of the research in [`docs/how-it-works.md`](docs/how-it-works.md).

## 4. What it costs (read before applying)

The `RmPmgrPmuOverride=1` key switches off, **for that card**, the power management done by the card's PMU. Observed consequences:

1. **No more power reading** on that card (`power.draw` = `N/A`) **and no more power limit**: nothing throttles it if it starts drawing too much. On my card it stays around ~160 W, but watching it (wall meter) is up to you.
2. **The fan reading** (`fan.speed`) returns “Unknown Error”. My fans spin (I can hear them) and the temperature is normal, but I can no longer read or set their speed with `nvidia-smi`.
3. **Hardware protections** (slowdown at 95 °C, shutdown at 98 °C) remain in place; still, watch the temperatures the first times.
4. **Do not apply** this fix if the displayed consumption is real (see the wall meter test), or if you suspect a real electrical fault.
5. To **bound** the consumption one can presumably lock the clocks (`nvidia-smi -lgc`): I have **not tested** that in this state yet.
6. The setting is tied to the **PCI address**: if you move the card to another slot, redo it (`apply-fix.sh`).
7. A **driver update** may change the meaning of the key: re-check with `verify.sh`.
8. If the card is still **under warranty**, an exchange or a repair is better. I did not open mine: a hardware cause is likely but not proven.

## 5. If it does not work

- **`verify.sh` says “NO: no option for that address”**: the option did not reach the module. Check that `modprobe -c | grep RegistryDwordsPerDevice` prints your line, that the address is right (`lspci -D`), that the initramfs was rebuilt and that you rebooted.
- **The option is received but the card stays at 210 MHz**: your card probably has another cause. Open an issue with the output of `diagnostic.sh`.
- **Do not use `RmPerfLimitsOverride=2`** (nor `170`): it makes “SW Power Cap” disappear and looks like a win, but the card stays frozen in performance state P8 (420 MHz, memory at 405 MHz): 6.9 TFLOPS and an idle memory. It is a trap (details in [`docs/how-it-works.md`](docs/how-it-works.md)).
- **No display / `nvidia-smi` errors** after rebooting: open a text console (Ctrl+Alt+F3) or boot in recovery mode and delete `/etc/modprobe.d/nvidia-bogus-power-fix.conf`, then rebuild the initramfs.

## 6. How I found it

1. **Ruled out**: heat, power supply, RAM, drivers (three versions), slot (OCuLink dock then motherboard) and BIOS: a full flash dump is **byte-identical** to the published reference for this model (TechPowerUp's BIOS database), so the seller had not left a mining BIOS.
2. **The culprit**: the clock event reason “SW Power Cap”, triggered by a power reading of ~395 W, **constant** at idle while my wall meter shows 272 W for the whole PC.
3. **Hypothesis (unproven)**: one of the card's current-sense channels is stuck at full scale. A measurement chain with a 5 mΩ shunt, a 163.84 mV full scale and a 12 V rail saturates at exactly 163.84 mV ÷ 5 mΩ × 12 V ≈ **393 W**, the constant value observed at idle; the other, normal channels add ~+29 W under load. A BIOS with a higher power limit would therefore not have helped.
4. **The software lead**: the `nvidia` module accepts per-card “registry keys” (`NVreg_RegistryDwordsPerDevice`) passed to the card's GSP firmware. I built a test bench that, for each setting, unloads then reloads the driver and measures the card (first with one reboot per trial, ~2 min, then by reloading the driver, ~45 s): [`research/`](research/).
5. **The result**: `RmPerfLimitsOverride=2` removes the cap but freezes the card in P8; `RmPmgrPmuOverride=1` gives a card whose clocks go up and down normally, without a power cap. It was the first setting tested in the fast series.

The full story, the table of all trials and what is (and is not) known about the mechanism: [`docs/how-it-works.md`](docs/how-it-works.md).

## 7. Open questions

- **Real clock ~1335 MHz for 1995 displayed.** Measured with `tools/sondeclk` (the SMs' cycle counter divided by the global timer): my healthy card delivers 1917-1938 MHz for 1905-1920 displayed, the fixed card only ~1335 MHz for 1995 displayed. Yet the computation results are **bit-identical** on both cards. Hypothesis: without the power management, the card's voltage is no longer driven properly and the adaptive clock limits itself to what the voltage allows. A sweep of `nvidia-smi -lgc` with `sondeclk` would tell whether it is a voltage/frequency limit or a divider.
- **Other cards?** Ex-mining RTX 3060 Ti / 3070 / 3080 / 3090, other families? Only my card is tested.
- **Other systems?** Proprietary (non-open) kernel modules, other driver versions, other distributions: not tested. On Windows I know of no equivalent.
- **Which channel is at fault?** Inspecting the card (solder joints and traces around the sense shunts, signs of a “shunt mod” by the previous owner) would locate the defect. I did not do it.

## 8. Contributing

If you try it, **tell me in an issue** (“Compatibility report” template in [`.github/ISSUE_TEMPLATE/`](.github/ISSUE_TEMPLATE/)) with the output of `scripts/diagnostic.sh` before and after. Negative reports are as useful as positive ones: they are what will tell on which cards it works.

## 9. Disclaimer, license, credits

- **At your own risk.** No warranty. This repository explains how to disable a protection feature of a graphics card: only touch it if you have checked that the power reading is bogus and you watch your machine.
- **Nothing from NVIDIA is included**: no firmware, no BIOS, no driver code. The measurement tools only use the driver's public API. NVIDIA, GeForce and RTX are trademarks of NVIDIA Corporation; this project is neither affiliated with nor endorsed by NVIDIA.
- **License**: [MIT](LICENSE).
- **Credits**: the hardware, the measurements, the tests and the decisions are Zblank31's; the diagnosis, the scripts and the measurement tools were written with the assistant [Claude Code](https://claude.com/claude-code) (Anthropic).
