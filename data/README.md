# data/ — raw measurements / mesures brutes

| File | What it is |
|---|---|
| `trials-series-2.tsv`, `trials-series-3.tsv` | The two valid series of trials, one reboot per setting. Columns: setting, whether the driver received it, idle power read, fan %, clocks, TFLOPS, `sw_power_cap_active_pct` (share of load samples with “SW Power Cap” active), P-state, clock event reasons, status. Series 1 (invalid: the initramfs was not rebuilt) is not included. |
| `trials-fast-series-1.tsv` | The fast series (driver reloaded between trials): reference, then `RmPmgrPmuOverride=1`. With the fix `idle_W_read`/`load_W_read` are 0 because `nvidia-smi` returns `N/A`. The “SUCCESS” label is by *displayed* clock; the real clock was ~1335 MHz. |
| `nvidia-smi-before-under-load.txt`, `nvidia-smi-after-under-load.txt` | `nvidia-smi -q -d PERFORMANCE,CLOCK,POWER` during the load, without and with the fix. Note “SW Power Cap: Active” before, “Board Limit / Reliability: Active” after, and the power readings (`~420 W` before, `N/A` after). |
| `sondeclk-both-gpus.txt` | Real SM clock (and results checksum) of the healthy card (GPU 0) and the fixed card (GPU 1). |

Setting names in the TSVs are the registry keys written after `pci=<address>;`. The status column of series 2 and 3 was recomputed from the numbers (the original label of the first runs was wrong for the `RmPerfLimitsOverride=170` row).
