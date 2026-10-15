# research/ — the test bench that found the fix / le banc d'essai qui a trouvé le correctif

**EN** — `reload-trials.sh` tries NVIDIA registry options on one GPU, one after the other, **without rebooting**: for each line of a plan it unloads the NVIDIA kernel modules, writes the option to `/etc/modprobe.d`, reloads the driver, checks the driver received the option, measures idle and load (displayed clock, real clock with `../tools/sondeclk`, TFLOPS with `../tools/gpuload`, temperature with an 80 °C cut-off) and goes on. About 45 s per trial. It stops at the first success and leaves the winning option active until the next boot (nothing permanent is written).

**FR** — `reload-trials.sh` essaie des options de registre NVIDIA sur une carte, l'une après l'autre, **sans redémarrer** : pour chaque ligne d'un plan, il décharge les modules noyau NVIDIA, écrit l'option dans `/etc/modprobe.d`, recharge le pilote, vérifie que le pilote l'a reçue, mesure repos et charge (horloge affichée, horloge réelle avec `../tools/sondeclk`, TFLOPS avec `../tools/gpuload`, température avec une coupure à 80 °C) et passe au suivant. Environ 45 s par essai. Il s'arrête au premier succès et laisse l'option gagnante active jusqu'au prochain démarrage (rien de permanent n'est écrit).

## ⚠️ Warning / Attention

**It stops your desktop** (display manager) and every program using the GPUs, unloads the driver, and brings the desktop back at the end — you will have to log in again. Save your work first. Run it detached as root, never from inside the desktop session. If a card does not come back after a reload, you have to reboot (it never happened during these trials). It was written for one machine (Ubuntu + GNOME/GDM, `nvidia-persistenced`): read it before running it. Its logs are in French.

**Il ferme ton bureau** et tous les programmes qui utilisent les cartes, décharge le pilote, puis relance le bureau à la fin : il faudra te reconnecter. Enregistre ton travail avant. Lance-le détaché, en root, jamais depuis la session graphique. Si une carte ne revient pas après un rechargement, il faut redémarrer (ça n'est pas arrivé pendant ces essais). Il a été écrit pour une machine (Ubuntu + GNOME/GDM, `nvidia-persistenced`) : lis-le avant de le lancer. Ses journaux sont en français.

## Usage

```bash
make -C ../tools                       # gpuload and sondeclk
sudo systemd-run --setenv=I_UNDERSTAND_THIS_STOPS_MY_DESKTOP=yes --setenv=TARGET_ID=10de:2216 \
     --unit=gpu-trials --collect /bin/bash "$PWD/reload-trials.sh" "$PWD/plan.example.txt"
tail -f /var/lib/gpu-trials/last/journal.log      # progress (from another machine or a text console: the desktop is gone)
sudo touch /var/lib/gpu-trials/STOP               # clean stop
```

`TARGET_ID` is the `vendor:device` of the card under test (`lspci -nn -d 10de:`). Results: `/var/lib/gpu-trials/last/resultats.tsv` (a copy is made in `runs/` next to the script), with one `noyau_N.txt` (kernel messages) and `essai_N_perf_*.txt` (`nvidia-smi -q` snapshots) per trial.

## The plan file / le fichier de plan

One line per trial: `name|registry setting|optional command(s)`. See [`plan.example.txt`](plan.example.txt) — the plan that was run on the RTX 3080 LHR of this repository (the series stopped at trial 1). Commands: `lgc=min,max` / `lmc=min,max` lock the GPU / memory clock during the load; `idle` = idle-only probe. Consecutive lines with the same setting do not reload the driver.

## What it does not do / ce qu'il ne fait pas

It flashes nothing, writes no BIOS, and leaves no permanent configuration (the option is written to `/etc/modprobe.d/zz-gpu-trials.conf`, removed at the end — except the winning one, renamed `.gagnant` so that a later `update-initramfs` does not bake it in). To make a fix permanent, use `../scripts/apply-fix.sh`.
