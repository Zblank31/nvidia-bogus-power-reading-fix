# tools/ — measurement tools / outils de mesure

No CUDA toolkit needed: `make` (a C compiler is enough). They load `libcuda` at run time and run a PTX kernel of fused multiply-adds, so they work on any Volta-or-newer NVIDIA GPU with the driver installed.

| Tool | What it does |
|---|---|
| `gpuload [seconds]` | Loads the GPU and prints the FP32 FMA throughput actually achieved (TFLOPS). Select the card with `CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES=<index>`. |
| `sondeclk [launches] [iterations]` | Measures the **real** SM clock (cycles ÷ global timer), prints the SM count and a checksum of the results (it must be identical on two cards of the same architecture). |
| `charge_longue.sh [gpu] [seconds] [cut-off °C]` | Sustained load with a temperature log every 3 s and an automatic cut-off. |

Output is in French if your locale starts with `fr`, English otherwise.
