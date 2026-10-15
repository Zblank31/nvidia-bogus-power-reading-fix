<!-- Video link: add it here (and in README.md) once it is online. -->
# NVIDIA card stuck at 210 MHz: a workaround

I bought a second-hand GALAX RTX 3080 LHR 10 GB that had been used for mining. It was unusable: `nvidia-smi` credited it with 400 W while it was doing nothing, and as soon as it got some work it stayed glued to 210 MHz. This repository tells what we found, how we got around it with a single line of configuration, and what that costs.

> One single card tested: Linux (Ubuntu 26.04), NVIDIA driver 615.71.09, open kernel modules.
> This is not a repair: the workaround switches off a protection. Read ["What it costs"](#4-what-it-costs) before applying it.
>
> Version française : [README.md](README.md)

> Important update: after a real reboot the real clock is ~1950 MHz (not 1335) and the card does ~28 TFLOPS. At that pace it heats up fast: 80 C after 90 s at full load, and still climbing, because without the power management the fan is no longer regulated. The 44 C figure below comes from an older test at 1335 MHz. Do not leave it at full load unattended or without a clock limit (being tested, see "What it costs").

## In short

If your card, often second-hand and ex-mining:

- reports an absurd power draw at idle, around 400 W;
- stays at 210 MHz under load, with the clock event reason "SW Power Cap" active;
- has its fan stuck at 50 % even at 25 °C;
- and behaves the same with another driver, another slot or the original BIOS,

then it believes it draws far more power than it does, and the firmware throttles it permanently. The following line, adapted with your card's PCI address, switches off the power management of that card, and only that card:

```
options nvidia NVreg_RegistryDwordsPerDevice="pci=0000:09:00.0;RmPmgrPmuOverride=1;"
```

On my card it goes from 210 to 1995 MHz displayed and from 3.4 to 19.4 TFLOPS (×5.7). It reaches 44 °C at most after two minutes at full load, and draws about 160 W according to the wall meter.

## 1. Is this your case?

This is what I saw. For this repository to help you, you should recognise the whole picture.

| What you observe | On my card |
|---|---|
| `nvidia-smi` reports a big power draw at idle (0 % usage) | ~390-400 W at idle, ~420 W under load |
| Under load the clock stays at the minimum (210 MHz) | 210 MHz, 3.4 TFLOPS versus ~25 for my healthy twin card |
| `nvidia-smi -q -d PERFORMANCE`: "SW Power Cap: Active" (`clocks_event_reasons.active` = `0x4`) | yes, permanently under load |
| Fan fixed at 50 %, even at 25 °C | yes |
| Neither heat nor the power supply is the cause | 23-26 °C at idle, 1600 W power supply |
| Same behaviour with other drivers or another slot | 3 driver versions, OCuLink dock then motherboard slot |
| Original BIOS | full flash dump byte-identical to the published reference for this model |

`./scripts/diagnostic.sh` goes through these points, read-only. Run it once at idle and once during a load (`tools/gpuload 60` in another terminal). It prints no serial number or UUID, so you can paste its output into an issue.

The test that settles it is a wall power meter. `nvidia-smi` can be wrong, the meter cannot. Compare what `nvidia-smi` credits to the card at idle with what the whole PC (monitor included) draws at the wall. On my machine, 395 W were reported for the card alone while the meter showed 272 W for the entire PC: the reading was bogus. If the meter confirms the consumption, do not apply this fix, you would be hiding a real problem (short circuit, overheating).

## 2. Applying the fix

You need Linux, a recent NVIDIA driver with GSP firmware (tested: 615.71.09, open kernel modules), a Volta-or-newer card, root, and ideally a wall power meter.

**1. Your card's PCI address** (here `0000:09:00.0`):

```bash
lspci -D -nn | grep -E "VGA|3D" | grep -i nvidia
# or: ./scripts/apply-fix.sh --list
```

**2. The configuration file** (replace the address):

```bash
sudo tee /etc/modprobe.d/nvidia-bogus-power-fix.conf <<'EOF'
options nvidia NVreg_RegistryDwordsPerDevice="pci=0000:09:00.0;RmPmgrPmuOverride=1;"
EOF
```

The quotes, the `pci=` prefix and the semicolons (the last one included) matter. Thanks to `pci=`, only that card is affected: a healthy card next to it is left alone.

**3. The initramfs.** On many distributions the `nvidia` module is loaded from the initramfs, before the root disk is mounted. Without this step the option is not seen at boot.

```bash
sudo update-initramfs -u -k all     # Debian / Ubuntu
sudo dracut -f --regenerate-all     # Fedora / RHEL / openSUSE
sudo mkinitcpio -P                  # Arch
```

**4. Reboot.**

**5. Check:**

```bash
grep RegistryDwordsPerDevice /proc/driver/nvidia/params   # must show your address and RmPmgrPmuOverride=1
./scripts/verify.sh --bus 0000:09:00.0                    # short load, then a verdict
```

To go faster, `sudo ./scripts/apply-fix.sh --bus 0000:09:00.0` does steps 2 and 3 with safeguards: it checks the address, asks for confirmation and checks that `modprobe` understands the line. With `--dry-run` it shows what it would do without changing anything.

To undo: `sudo ./scripts/remove-fix.sh`, then reboot.

## 3. What it gives on my card

| | Before | After |
|---|---|---|
| Displayed GPU clock under load | 210 MHz | 1995 MHz (1965 MHz at 44 °C) |
| Memory clock under load | 9251 MHz | 9251 MHz |
| Compute throughput (FP32 FMA, `tools/gpuload`) | 3.4 TFLOPS | 19.4 TFLOPS |
| Clock event reason | SW Power Cap | "Reliability" and "Board Limit" (benign) |
| Power read by `nvidia-smi` | ~395 W (bogus) | `N/A` |
| Temperature (120 s at full load) | | 31 → 44 °C, the curve flattens |
| Wall meter (whole PC + monitor) | | 329 W idle, 515 W with the card at full load (+186 W) |

With a power-supply efficiency of about 90 %, those extra 186 W at the wall mean 150 to 170 W for the card, half of its 320 W rating.

My healthy twin card (a Palit RTX 3080) does 25 TFLOPS at 319 W. The fixed card does 77 % of that for about half the power. The gap has a curious explanation, developed in [§7](#7-what-we-do-not-know): its real clock is only about 1335 MHz, not 1995.

Raw measurements are in [`data/`](data/) and the details of the research in [`docs/how-it-works.md`](docs/how-it-works.md).

## 4. What it costs

The `RmPmgrPmuOverride=1` key switches off, for that card, the power management done by its PMU. This is what I observed:

1. No more power reading (`power.draw` is `N/A`) and no more power limit: nothing throttles the card if it starts drawing too much. On my card it stays around 160 W, but watching it, with a wall meter, is up to you.
2. The fan reading (`fan.speed`) returns "Unknown Error". My fans spin (I can hear them) and the temperature is normal, but I can no longer read or set their speed with `nvidia-smi`.
3. The hardware protections (slowdown at 95 °C, shutdown at 98 °C) stay in place. Still, watch the temperatures the first times.
4. Do not apply this fix if the displayed consumption is real (see the wall meter test), or if you suspect a real electrical fault.
5. To bound the consumption you can probably lock the clocks with `nvidia-smi -lgc`. I have not tested that in this state yet.
6. The setting is tied to the PCI address. If you move the card to another slot, redo it with `apply-fix.sh`.
7. A driver update may change the meaning of the key. Run `verify.sh` again afterwards.
8. If the card is still under warranty, an exchange or a repair is better. I did not open mine: a hardware cause is likely, but not proven.

## 5. If it does not work

- `verify.sh` prints "NO: no option for that address". The option did not reach the module. Check that `modprobe -c | grep RegistryDwordsPerDevice` prints your line, that the address is right (`lspci -D`), that the initramfs was rebuilt and that you rebooted.
- The option is received but the card stays at 210 MHz. It probably has another cause. Open an issue with the output of `diagnostic.sh`.
- Do not use `RmPerfLimitsOverride=2` (nor `170`). "SW Power Cap" disappears and it looks like a win, but the card stays frozen in performance state P8 (420 MHz, memory at 405 MHz): 6.9 TFLOPS and a memory that does not wake up. It is a trap, detailed in [`docs/how-it-works.md`](docs/how-it-works.md).
- No display, or `nvidia-smi` errors after the reboot. Open a text console (Ctrl+Alt+F3) or boot in recovery mode, delete `/etc/modprobe.d/nvidia-bogus-power-fix.conf`, then rebuild the initramfs.

## 6. How we found it

First we ruled out the usual suspects: heat, power supply, RAM, drivers (three versions), slot (OCuLink dock then motherboard) and BIOS. A full dump of the flash is byte-identical to the published reference for this model (TechPowerUp's BIOS database), so the seller had not left a mining BIOS.

The culprit is the clock event reason "SW Power Cap", triggered by a power reading of about 395 W, constant even at idle, while the wall meter showed 272 W for the whole PC.

We think, without having proved it, that one current-sense channel is stuck at full scale. With a 5 mΩ shunt, a 163.84 mV full scale and a 12 V rail, a measurement chain saturates at exactly 163.84 mV ÷ 5 mΩ × 12 V, which is 393 W: the constant value read at idle. The other, normal channels add about 29 W under load. If so, a BIOS with a higher power limit would have been useless.

That left a software lead. The `nvidia` module accepts per-card "registry keys" (`NVreg_RegistryDwordsPerDevice`), passed on to the card's GSP firmware. We wrote a test bench that, for each setting, unloads then reloads the driver and measures the card: first with one reboot per trial (2 minutes each), then by reloading the driver (45 seconds). It is in [`research/`](research/).

`RmPerfLimitsOverride=2` removes the cap but freezes the card in P8. `RmPmgrPmuOverride=1` gives a card whose clocks go up and down normally, without a power cap: it was the first setting tried in the fast series.

The full story, the table of all trials and what is known about the mechanism: [`docs/how-it-works.md`](docs/how-it-works.md).

## 7. What we do not know

- The real clock. `tools/sondeclk` counts the SMs' cycles over an interval of the global timer. My healthy card delivers 1917-1938 MHz for 1905-1920 displayed, but the fixed card only about 1335 MHz for 1995 displayed. The computation results are nevertheless bit-identical on both cards. Our hypothesis: without the power management the voltage is no longer driven properly and the adaptive clock limits itself to what the voltage allows. A sweep of `nvidia-smi -lgc` with `sondeclk` would tell whether it is a voltage/frequency limit or a divider.
- Other cards. Ex-mining RTX 3060 Ti, 3070, 3080, 3090, other families: only my card is tested.
- Other systems. Proprietary kernel modules, other driver versions, other distributions: not tested. On Windows we know of no equivalent.
- The faulty channel. Inspecting the card (solder joints and traces around the sense shunts, signs of a "shunt mod" by the previous owner) would locate the defect. I did not do it.

## 8. Contributing

If you try it, say so in an issue ("Compatibility report" template in [`.github/ISSUE_TEMPLATE/`](.github/ISSUE_TEMPLATE/)), with the output of `scripts/diagnostic.sh` before and after. Failures are as useful as successes: that is how we will learn on which cards it works.

## 9. Disclaimer, license, credits

- At your own risk. No warranty. This repository explains how to disable a protection of a graphics card: only touch it if you have checked that the power reading is bogus, and keep an eye on your machine.
- Nothing from NVIDIA is included: no firmware, no BIOS, no driver code. The measurement tools only use the driver's public API. NVIDIA, GeForce and RTX are trademarks of NVIDIA Corporation, with which this project has no connection.
- License: [MIT](LICENSE).
- Credits: none of this could have been found without [Claude Code](https://claude.com/claude-code) and the power of the Claude Sonnet 5.5 model (Anthropic). The analysis, the scripts, the measurement tools and the documentation are its work; the card, the measurements on my machine and the decisions are mine.
