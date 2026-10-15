# research/ : the bench that found the fix / le banc d'essai qui a trouvé le correctif

**EN.** `reload-trials.sh` tries NVIDIA registry options on one card, one after the other, **without rebooting**. For each line of a plan it unloads the NVIDIA kernel modules, writes the option to `/etc/modprobe.d`, loads the driver again, checks that the driver really received the option, then measures idle and load: displayed clock, real clock (`../tools/sondeclk`), TFLOPS (`../tools/gpuload`), temperature (the load is cut at 80 °C). About 45 s per trial. It stops at the first trial whose real SM clock reaches 1000 MHz and leaves that option active until the next boot; nothing permanent is written.

**FR.** `reload-trials.sh` essaie des options de registre NVIDIA sur une carte, l'une après l'autre, **sans redémarrer**. Pour chaque ligne d'un plan il décharge les modules noyau NVIDIA, écrit l'option dans `/etc/modprobe.d`, recharge le pilote, vérifie que le pilote l'a bien reçue, puis mesure le repos et la charge : horloge affichée, horloge réelle (`../tools/sondeclk`), TFLOPS (`../tools/gpuload`), température (la charge est coupée à 80 °C). Environ 45 s par essai. Il s'arrête au premier essai dont l'horloge réelle des SM atteint 1000 MHz et laisse cette option active jusqu'au prochain démarrage ; rien de permanent n'est écrit.

## Warning / Attention

**It stops your desktop** (display manager) and every program using the GPUs, unloads the driver, and starts the desktop again at the end: you will have to log in again. Save your work first. Run it detached as root, never from inside the desktop session. If a card does not come back after a reload you have to reboot (it never happened during the trials that found the fix). It was written on Ubuntu with GNOME/GDM and `nvidia-persistenced`; read the script before running it on anything else. It needs at least one display that does not depend on the card under test.

**Il ferme ton bureau** et tous les programmes qui utilisent les cartes, décharge le pilote, puis relance le bureau à la fin : il faudra te reconnecter. Enregistre ton travail avant. Lance-le détaché, en root, jamais depuis la session graphique. Si une carte ne revient pas après un rechargement, il faut redémarrer (ça n'est pas arrivé pendant les essais qui ont trouvé le correctif). Il a été écrit sur Ubuntu avec GNOME/GDM et `nvidia-persistenced` : lis le script avant de le lancer ailleurs. Il faut un affichage qui ne dépend pas de la carte testée.

## Usage

```bash
make -C ../tools                       # builds gpuload and sondeclk
sudo systemd-run --setenv=I_UNDERSTAND_THIS_STOPS_MY_DESKTOP=yes --setenv=TARGET_ID=10de:2216 \
     --unit=gpu-trials --collect /bin/bash "$PWD/reload-trials.sh" "$PWD/plan.example.txt"
tail -f /var/lib/gpu-trials/last/journal.log      # progress (the desktop is gone: use a console or another machine)
sudo touch /var/lib/gpu-trials/STOP               # stop cleanly after the current trial
```

`TARGET_ID` is the `vendor:device` of the card under test (`lspci -nn -d 10de:`). The journal is in English.

Results are in `/var/lib/gpu-trials/last/` (and copied to `runs/` next to the script at the end, readable without sudo):

| File | Content |
|---|---|
| `results.tsv` | one row per trial, same columns as [`../data/`](../data/) plus the real clock |
| `journal.log` | what the script did, with timings |
| `kernel_N.txt` | kernel messages produced by the load of trial N (look here when a card does not come back) |
| `trial_N_perf_idle.txt`, `trial_N_perf_load.txt` | `nvidia-smi -q -d PERFORMANCE,CLOCK,POWER` at idle and under load |
| `trial_N_load.csv` | the one-second samples taken during the load |

## The plan file / le fichier de plan

One line per trial: `name|registry setting|optional commands`. See [`plan.example.txt`](plan.example.txt), the plan that was run on the card this repository is about (the series stopped at trial 1, the fix). Commands: `lgc=min,max` and `lmc=min,max` lock the GPU / memory clock during the load, `idle` only reads the idle power. Consecutive lines with the same setting reuse the loaded driver.

## What it leaves behind / ce qu'il laisse

It flashes nothing and writes no BIOS. The option is written to `/etc/modprobe.d/zz-gpu-trials.conf` and removed at the end, except the winning one, which is renamed `zz-gpu-trials.conf.winner` right after the driver has loaded it: it stays active until the next boot, and a later `update-initramfs` cannot bake it in by accident. To make a fix permanent, use [`../scripts/apply-fix.sh`](../scripts/apply-fix.sh).

## Tests

`tests/run-sim.sh` runs the script against fake `systemctl`, `modprobe`, `rmmod`, `nvidia-smi`, `gpuload`... in a temporary directory: nothing touches the real driver, the desktop or `/etc`. It covers the normal case, the P8 trap, a sub-measurement with a clock lock, a card that comes back after the recovery, a card that never comes back, an option the driver ignores, the idle probe and the guards. Run it (or `make check` at the top of the repository) after changing the script.
