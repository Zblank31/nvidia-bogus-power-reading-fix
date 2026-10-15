#!/bin/bash
# reload-trials.sh — try NVIDIA registry options on ONE GPU, one after the other, WITHOUT rebooting (reload the driver between trials).
# Essaie des options de registre NVIDIA sur UNE carte, l'une après l'autre, SANS redémarrer (le pilote est rechargé entre deux essais).
#
# !!! WARNING / ATTENTION !!!  This script STOPS YOUR DESKTOP (display manager) and every program using the GPUs, unloads the NVIDIA kernel
# modules, reloads them, and brings the desktop back at the end (you log in again). Save your work. Run it from a text console or detached
# (systemd-run), never from inside the desktop session. If a card does not come back after a reload (it happened once in testing after a
# firmware flash, never during these trials), you must reboot. Nothing is flashed, nothing permanent is written (see the end of the script).
# Logs are in French. It is the tool that found the fix of this repository: see ../docs/how-it-works.md.
#
# Principle: for each plan line, unload the driver, write /etc/modprobe.d/zz-gpu-trials.conf, `modprobe nvidia` (modprobe re-reads
# /etc/modprobe.d: no initramfs rebuild, no reboot), check the driver received the option, measure idle + load (+ real clock with
# tools/sondeclk) and go on. ~45 s per trial. Stops at the first SUCCESS (real clock >= 1000 MHz), which stays active until the next boot.
#
# Prerequisites: `make -C ../tools` (gpuload, sondeclk), root, a plan file (see plan.example.txt).
# Run (detached, as root; the guard variable is deliberate):
#   sudo systemd-run --setenv=I_UNDERSTAND_THIS_STOPS_MY_DESKTOP=yes --setenv=TARGET_ID=10de:2216 --unit=gpu-trials --collect \
#        /bin/bash $PWD/reload-trials.sh $PWD/plan.example.txt
# Follow: tail -f /var/lib/gpu-trials/last/journal.log      Stop cleanly: sudo touch /var/lib/gpu-trials/STOP
# Plan line:  name|registry setting|optional command(s)     (e.g.  7_lgc|RmPerfLimitsOverride=2|lgc=1000,1000 lmc=9251,9501 ; "idle" = idle-only probe)
# Consecutive lines with the SAME setting do not reload the driver (sub-measurements).
set -u
SIM=${RAPIDE_SIM:-0}                 # 1 = test avec de fausses commandes (aucun effet sur la machine)
ETAT=${ETAT:-/var/lib/gpu-trials}
CONF=${CONF:-/etc/modprobe.d/zz-gpu-trials.conf}
PARAMS=${PARAMS:-/proc/driver/nvidia/params}
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLAN=${1:-$DIR/plan.example.txt}
GPULOAD=${GPULOAD:-$DIR/../tools/gpuload}
SONDECLK=${SONDECLK:-$DIR/../tools/sondeclk}
TARGET_ID=${TARGET_ID:-10de:2216}   # vendor:device of the card under test (lspci -nn -d 10de:)
COPIE=${COPIE:-$DIR/runs}            # copy of the results next to the script (readable without sudo)
DUREE_CHARGE=${DUREE_CHARGE:-12}
UTIL=${UTIL:-$(stat -c %U "$DIR")}   # user who owns this directory: gets the copy of the results and the desktop notice
export LC_ALL=C CUDA_DEVICE_ORDER=PCI_BUS_ID

[ "${I_UNDERSTAND_THIS_STOPS_MY_DESKTOP:-no}" = yes ] || { echo "Ce script ferme le bureau et décharge le pilote NVIDIA : lis l'en-tête, puis relance avec I_UNDERSTAND_THIS_STOPS_MY_DESKTOP=yes."; echo "This script stops your desktop and unloads the NVIDIA driver: read the header, then rerun with I_UNDERSTAND_THIS_STOPS_MY_DESKTOP=yes."; exit 1; }
[ "$SIM" = 1 ] || [ "$(id -u)" -eq 0 ] || { echo "Lance-moi avec sudo (voir l'en-tête du script)."; exit 1; }
mkdir -p "$ETAT"; chmod 755 "$ETAT" 2>/dev/null
exec 9>"$ETAT/.lock"
flock -n 9 || { echo "Une série rapide est déjà en cours."; exit 1; }
rm -f "$ETAT/STOP"
RUN=$ETAT/run_$(date +%Y%m%d_%H%M%S)
mkdir -p "$RUN" || exit 1
ln -sfn "$RUN" "$ETAT/last"
RES=$RUN/resultats.tsv; LOG=$RUN/journal.log
exec 3>&1
exec >>"$LOG" 2>&1
log() { printf '%s %s\n' "$(date +%T)" "$*"; }
avorte() { log "$1 : abandon, rien n'a été touché"; echo "$1 : abandon, rien n'a été touché (journal : $LOG)" >&3; exit 1; }
log "=== série rapide démarrée (sim=$SIM) ; plan : $PLAN"

# ---------- vérifications avant de toucher à quoi que ce soit ----------
BUS=$(lspci -D -d "$TARGET_ID" | head -1 | cut -d' ' -f1); COURT=${BUS#*:}
compter_cartes() { timeout 40 nvidia-smi -L 2>/dev/null | grep -c '^GPU '; }
[ -n "$BUS" ] || avorte "carte $TARGET_ID introuvable sur le bus PCI"
[ "$(compter_cartes)" -ge 2 ] || avorte "les deux cartes ne sont pas vues par le pilote"
[ -x "$GPULOAD" ] || avorte "$GPULOAD introuvable"
[ -s "$PLAN" ] || avorte "plan $PLAN vide ou absent"
mapfile -t LIGNES < <(grep -vE '^[[:space:]]*(#|$)' "$PLAN")
total=${#LIGNES[@]}
DM=""; DM_ACTIF=""
for d in gdm3 gdm sddm lightdm; do   # first display manager that is running
  if [ "$(systemctl is-active "$d.service" 2>/dev/null)" = active ]; then DM=$d; DM_ACTIF=active; break; fi
done
log "carte testée = $BUS ; $total essais ; gestionnaire de session : $DM ($DM_ACTIF)"

# ---------- outils ----------
pids_detenteurs() { fuser /dev/nvidia* /dev/dri/* 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | grep -vx "$$" | sort -un; }
liberer_cartes() { # attend que plus rien ne tienne les cartes ; après 20 s : arrêt poli, puis forcé des retardataires
  local i p
  for i in $(seq 1 20); do [ -z "$(pids_detenteurs)" ] && return 0; sleep 1; done
  log "   encore utilisées par : $(for p in $(pids_detenteurs); do printf '%s(%s) ' "$p" "$(cat /proc/$p/comm 2>/dev/null)"; done)"
  for p in $(pids_detenteurs); do kill -TERM "$p" 2>/dev/null; done; sleep 5
  for p in $(pids_detenteurs); do kill -KILL "$p" 2>/dev/null; done; sleep 2
  [ -z "$(pids_detenteurs)" ]
}
console_fb() { # $1 = 0 (détacher) ou 1 (rattacher) la console texte du framebuffer : elle empêche parfois de décharger nvidia_drm
  local v; [ "$SIM" = 1 ] && return 0
  for v in /sys/class/vtconsole/vtcon*; do
    [ -e "$v/name" ] && grep -q 'frame buffer' "$v/name" && echo "$1" > "$v/bind" 2>/dev/null
  done; return 0
}
decharger() {
  local i m
  console_fb 0
  for i in $(seq 1 15); do
    for m in nvidia_drm nvidia_uvm nvidia_modeset nvidia_peermem nvidia; do
      lsmod | grep -q "^$m " && { timeout 90 rmmod "$m" 2>&1 | sed "s/^/   rmmod $m : /"; }
    done
    lsmod | grep -q '^nvidia ' || { log "   pilote déchargé"; return 0; }
    sleep 2
  done
  log "!! le pilote ne se décharge pas : $(lsmod | grep -E '^nvidia' | tr '\n' ' ')"; return 1
}
ecrire_conf() { # $1 = réglage ('' = aucun)
  if [ -z "$1" ]; then rm -f "$CONF"
  else printf 'options nvidia NVreg_RegistryDwordsPerDevice="pci=%s;%s;"\n' "$BUS" "$1" > "$CONF"; fi
}
charger() { # $1 = étiquette ; vrai si les deux cartes sont revenues
  local n0 i; n0=$(dmesg | wc -l)
  timeout 180 modprobe nvidia 2>&1 | sed 's/^/   modprobe nvidia : /'
  timeout 60 modprobe nvidia_uvm 2>&1 | sed 's/^/   modprobe nvidia_uvm : /'
  nvidia-modprobe -u -c=0 2>&1 | sed 's/^/   nvidia-modprobe : /'
  timeout 120 systemctl start nvidia-persistenced.service 2>&1 | sed 's/^/   persistenced : /'
  for i in $(seq 1 30); do [ "$(compter_cartes)" -ge 2 ] && break; sleep 2; done
  dmesg | tail -n +$((n0 + 1)) | grep -iE 'nvrm|nvidia|gsp|aer|pcieport' > "$RUN/noyau_$1.txt"
  [ "$(compter_cartes)" -ge 2 ]
}
trouver_idx() { # numéro de la carte testée pour nvidia-smi
  idx=$(timeout 30 nvidia-smi --query-gpu=index,pci.bus_id --format=csv,noheader 2>/dev/null | awk -F', ' -v b="$COURT" 'index($2,b){print $1}' | head -1)
  [ -n "$idx" ]
}
verifier_recu() { # $1 = réglage ; remplit pok : le réglage est-il VRAIMENT arrivé dans le module ?
  local cle=${1%%=*}
  if [ -z "$1" ]; then pok="-"
  elif grep -F "RegistryDwordsPerDevice" "$PARAMS" | grep -qF "$COURT" && grep -F "RegistryDwordsPerDevice" "$PARAMS" | grep -qF "$cle"; then pok=oui
  else pok=NON; fi
}
recuperer() { # la carte testée ne revient pas : reset PCI, puis retrait + nouvelle détection ; vrai si elle est revenue
  log "   récupération : arrêt, remise à zéro PCI de la carte testée, rechargement sans réglage"
  systemctl stop nvidia-persistenced.service 2>&1; liberer_cartes; decharger || return 1
  ecrire_conf ""
  if [ "$SIM" != 1 ] && [ -e "/sys/bus/pci/devices/$BUS/reset" ]; then
    echo 1 > "/sys/bus/pci/devices/$BUS/reset" 2>&1 && log "   reset PCI : fait" || log "   reset PCI : refusé"; sleep 3; fi
  charger "r$k" && return 0
  log "   toujours absente : retrait puis nouvelle détection du périphérique PCI"
  systemctl stop nvidia-persistenced.service 2>&1; liberer_cartes; decharger || return 1
  if [ "$SIM" != 1 ]; then echo 1 > "/sys/bus/pci/devices/$BUS/remove" 2>&1; sleep 2; echo 1 > /sys/bus/pci/rescan; sleep 4; fi
  charger "rr$k"
}
ligne_tsv() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$RES"; }
ligne_echec() { ligne_tsv "$1" "$2" "$3" "" "" "" "" "" "" "" "" "" "" "" "" "" "$4"; } # essai nom réglage statut

mesurer_repos() { # remplit idleW idleF idleC + instantané détaillé
  sleep 3
  : > "$RUN/idle.tmp"
  for i in 1 2 3 4 5 6; do
    timeout 20 nvidia-smi -i "$idx" --query-gpu=power.draw,fan.speed,clocks.sm,temperature.gpu,pstate,clocks_event_reasons.active --format=csv,noheader,nounits >> "$RUN/idle.tmp"; sleep 1
  done
  timeout 30 nvidia-smi -i "$idx" -q -d PERFORMANCE,CLOCK,POWER > "$RUN/essai_${k}_perf_repos.txt" 2>&1
  idleW=$(awk -F', ' '{s+=$1;n++} END{if(n)printf "%.0f",s/n}' "$RUN/idle.tmp")
  idleF=$(tail -1 "$RUN/idle.tmp" | awk -F', ' '{print $2}'); idleC=$(tail -1 "$RUN/idle.tmp" | awk -F', ' '{print $3}')
}
mesurer_charge() { # $1 = commande(s) facultative(s) ; remplit loadW clkM clkX capP tmax pst rais memM tfl
  local a L S n tt
  for a in $1; do case "$a" in
    lgc=*) log "   verrouillage de l'horloge GPU : ${a#lgc=}"; timeout 30 nvidia-smi -i "$idx" -lgc "${a#lgc=}" 2>&1 | sed 's/^/   | /';;
    lmc=*) log "   verrouillage de l'horloge mémoire : ${a#lmc=}"; timeout 30 nvidia-smi -i "$idx" -lmc "${a#lmc=}" 2>&1 | sed 's/^/   | /';;
    *) log "   commande inconnue ignorée : $a";;
  esac; done
  nvidia-smi -i "$idx" --query-gpu=utilization.gpu,power.draw,clocks.sm,temperature.gpu,clocks_event_reasons.sw_power_cap,pstate,clocks_event_reasons.active,clocks.mem --format=csv,noheader,nounits -l 1 > "$RUN/charge.tmp" & S=$!
  sleep 2
  CUDA_VISIBLE_DEVICES=$idx timeout -k 3 $((DUREE_CHARGE + 40)) "$GPULOAD" "$DUREE_CHARGE" > "$RUN/gpuload.tmp" 2>&1 & L=$!
  n=0
  while kill -0 $L 2>/dev/null; do
    sleep 1; n=$((n + 1))
    [ "$n" = 8 ] && timeout 30 nvidia-smi -i "$idx" -q -d PERFORMANCE,CLOCK,POWER > "$RUN/essai_${k}_perf_charge.txt" 2>&1
    tt=$(timeout 10 nvidia-smi -i "$idx" --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null)
    if [[ $tt =~ ^[0-9]+$ ]] && [ "$tt" -ge 80 ]; then log "!! ARRET DE LA CHARGE : $tt °C"; kill $L 2>/dev/null; fi
  done
  wait $L 2>/dev/null; sleep 1; kill $S 2>/dev/null; wait $S 2>/dev/null
  cp "$RUN/charge.tmp" "$RUN/essai_${k}_charge.csv"
  realM=""   # REAL SM clock (what the SMs deliver), measured while any clock lock is still applied
  if [ -x "$SONDECLK" ]; then
    realM=$(CUDA_VISIBLE_DEVICES=$idx timeout 60 "$SONDECLK" 3 2000000 2>/dev/null | grep -E 'launch 3|lancement 3' | sed -E 's/.*(mean|moyenne) ([0-9]+) MHz.*/\2/')
  fi
  for a in $1; do case "$a" in lgc=*) timeout 30 nvidia-smi -i "$idx" -rgc >/dev/null 2>&1;; lmc=*) timeout 30 nvidia-smi -i "$idx" -rmc >/dev/null 2>&1;; esac; done
  read -r loadW clkM clkX capP tmax pst rais memM < <(awk -F', ' '$1+0>=90 {n++; w+=$2; c+=$3; if($3+0>mx)mx=$3+0; if($5 ~ /^Active/)a++; if($4+0>tm)tm=$4+0; p=$6; r=$7; m+=$8} END{ if(n) printf "%.0f %.0f %.0f %.0f %.0f %s %s %.0f", w/n, c/n, mx, 100*a/n, tm, p, r, m/n; else print "0 0 0 0 0 - - 0"}' "$RUN/charge.tmp")
  tfl=$(grep -o '[0-9.]* TFLOPS' "$RUN/gpuload.tmp" | head -1 | cut -d' ' -f1)
  rm -f "$RUN"/*.tmp
}

# ---------- remise en ordre (toujours exécutée à la sortie) ----------
TOUCHE=0; RESTAURE=0; SUCCES=0; SUCCES_REGL=""; SUCCES_NOM=""; SUCCES_CMD=""
restaurer() {
  [ "$RESTAURE" = 1 ] && return 0; RESTAURE=1; trap - EXIT INT TERM HUP
  if [ "$TOUCHE" = 1 ]; then
    log "=== remise en ordre : rechargement propre du pilote, retour de nvidia-persistenced et du bureau"
    [ -n "$(jobs -p)" ] && kill $(jobs -p) 2>/dev/null
    systemctl stop nvidia-persistenced.service 2>&1; liberer_cartes
    decharger || log "!! pilote non déchargé : on tente quand même de relancer le bureau"
    ecrire_conf "$SUCCES_REGL"
    timeout 180 modprobe nvidia 2>&1 | sed 's/^/   modprobe nvidia : /'
    # le gagnant reste actif jusqu'au prochain démarrage, mais on le met à l'abri d'un update-initramfs involontaire (qui lit les *.conf)
    [ "$SUCCES" = 1 ] && [ -e "$CONF" ] && mv -f "$CONF" "$CONF.gagnant"
    timeout 60 modprobe nvidia_modeset 2>&1 | sed 's/^/   modprobe nvidia_modeset : /'
    timeout 60 modprobe nvidia_uvm 2>&1 | sed 's/^/   modprobe nvidia_uvm : /'
    timeout 60 modprobe nvidia_drm 2>&1 | sed 's/^/   modprobe nvidia_drm : /'
    nvidia-modprobe -u -c=0 2>&1 | sed 's/^/   nvidia-modprobe : /'
    timeout 120 systemctl start nvidia-persistenced.service 2>&1 | sed 's/^/   persistenced : /'
    udevadm settle --timeout=10 2>&1
    console_fb 1
    log "   cartes vues par le pilote : $(compter_cartes) (attendu : 2)"
    [ "$DM_ACTIF" = active ] && { timeout 120 systemctl start "$DM.service" 2>&1; log "   bureau ($DM) relancé"; }
  fi
  log "=== bilan"
  [ -s "$RES" ] && column -t -s$'\t' "$RES"
  [ "$SUCCES" = 1 ] && log "SUCCES avec « $SUCCES_NOM » : $SUCCES_REGL ${SUCCES_CMD:+(+ $SUCCES_CMD pendant la charge)} -> actif maintenant (jusqu'au prochain démarrage), copie dans $CONF.gagnant (pas dans l'initramfs)"
  [ -n "${ABANDON:-}" ] && log "SÉRIE ARRÊTÉE : $ABANDON"
  echo "${ABANDON:-fini} ($(date '+%F %T'))" > "$ETAT/finished"; chmod 644 "$ETAT/finished"
  if [ "$SIM" != 1 ]; then
    mkdir -p "$COPIE/$(basename "$RUN")" && cp -a "$RUN/." "$COPIE/$(basename "$RUN")/" && chown -R "$UTIL:$UTIL" "$COPIE" 2>/dev/null
  fi
  log "=== terminé"
}
trap restaurer EXIT
trap 'log "signal reçu"; exit 143' INT TERM HUP

ligne_tsv essai nom reglage recu repos_W ventilo_pct horloge_repos charge_W horloge_charge_moy horloge_charge_max memoire_charge_moy horloge_reelle_MHz TFLOPS cap_actif_pct etat_charge raisons_hex statut

# ---------- 1) fermeture du bureau (après 20 s de préavis : on a le temps d'enregistrer ce qui est ouvert, ou d'annuler) ----------
if [ "$SIM" != 1 ]; then
  wall "Essais carte graphique 1 : le bureau se ferme dans 20 secondes (~$((total * 45 / 60)) minutes, écrans noirs). Pour annuler : sudo touch $ETAT/STOP" 2>/dev/null
  runuser -u "$UTIL" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$UTIL")/bus" \
    notify-send -u critical -t 20000 "Essais carte graphique 1" "Le bureau se ferme dans 20 secondes (~$((total * 45 / 60)) minutes, écrans noirs). Enregistre ce qui est ouvert." 2>/dev/null
  log "préavis de 20 s donné"; sleep 20
fi
[ -e "$ETAT/STOP" ] && { ABANDON="annulé pendant le préavis"; exit 0; }
TOUCHE=1
log "arrêt du bureau (${DM:-aucun gestionnaire de session actif}) et de nvidia-persistenced : les écrans vont s'éteindre"
[ -n "$DM" ] && timeout 120 systemctl stop "$DM.service" 2>&1
systemctl stop nvidia-persistenced.service 2>&1
liberer_cartes || { ABANDON="des processus tiennent encore les cartes"; exit 1; }

# ---------- 2) les essais ----------
charge_regl="@@"; ABANDON=""
for ((k = 0; k < total; k++)); do
  [ -e "$ETAT/STOP" ] && { ABANDON="arrêt demandé (fichier STOP)"; break; }
  ligne=${LIGNES[$k]}; nom=${ligne%%|*}; reste=${ligne#*|}; regl=${reste%%|*}; cmd=""; case "$reste" in *\|*) cmd=${reste#*|};; esac
  affiche="${regl:-(aucun)}${cmd:+ + $cmd}"
  log ">> essai $k/$total : $nom [$affiche]"
  if [ "$regl" != "$charge_regl" ]; then
    charge_regl="@@"
    systemctl stop nvidia-persistenced.service 2>&1
    liberer_cartes && decharger || { ABANDON="impossible de décharger le pilote (essai $k)"; ligne_echec "$k" "$nom" "$affiche" "ECHEC : pilote non déchargeable"; break; }
    ecrire_conf "$regl"
    if ! charger "$k"; then
      log "!! carte absente ou en erreur après chargement avec [${regl:-aucun réglage}] : voir $RUN/noyau_$k.txt"
      ligne_echec "$k" "$nom" "$affiche" "ECHEC : une carte n'est pas revenue"
      if recuperer; then log "   carte testée récupérée, on continue"; charge_regl=""; continue; fi
      ABANDON="la carte testée ne revient pas (essai $k) : un redémarrage du PC sera nécessaire"; break
    fi
    charge_regl=$regl
    trouver_idx || { ABANDON="carte testée introuvable par nvidia-smi (essai $k)"; ligne_echec "$k" "$nom" "$affiche" "ECHEC : carte testée absente"; break; }
    verifier_recu "$regl"
    log "   carte testée = index $idx ; réglage reçu par le pilote : $pok"
    if [ "$pok" = NON ]; then
      ABANDON="réglage non reçu par le pilote (essai $k) : la série ne prouverait rien"
      ligne_tsv "$k" "$nom" "$affiche" NON "" "" "" "" "" "" "" "" "" "" "" "" "INVALIDE : réglage non reçu par le pilote"; break
    fi
    mesurer_repos
  fi
  case " $cmd " in *" idle "*) # sonde : on ne regarde que la lecture de puissance au repos (pas de charge)
    ligne_tsv "$k" "$nom" "$affiche" "$pok" "$idleW" "$idleF" "$idleC" "" "" "" "" "" "" "" "" "" "sonde au repos seulement"
    log "   sonde : repos ${idleW} W | ventilateur ${idleF} % | horloge ${idleC} MHz"; continue;;
  esac
  mesurer_charge "$cmd"
  eff=${realM:-$clkM}   # judge on the REAL clock when the probe is available (the displayed clock can be misleading)
  statut="sans effet"
  [ "${capP:-100}" -le 20 ] && statut="EFFET : limitation de puissance levee"
  [ "${eff:-0}" -ge 1000 ] && statut="SUCCES : horloge ${realM:+réelle }>= 1000 MHz"
  ligne_tsv "$k" "$nom" "$affiche" "$pok" "$idleW" "$idleF" "$idleC" "$loadW" "$clkM" "$clkX" "$memM" "${realM:-?}" "${tfl:-?}" "$capP" "$pst" "$rais" "$statut"
  log "   résultat : repos ${idleW} W | charge ${loadW} W | horloge affichée moy ${clkM} MHz (max ${clkX}), réelle ${realM:-?} MHz, mémoire ${memM} MHz | tmax ${tmax} °C | ${tfl:-?} TFLOPS | cap ${capP} % | état ${pst} raisons ${rais} | $statut"
  if [ "${eff:-0}" -ge 1000 ]; then
    SUCCES=1; SUCCES_REGL=$regl; SUCCES_NOM=$nom; SUCCES_CMD=$cmd
    echo "$nom : $regl ${cmd:+(+ $cmd)}" > "$ETAT/SUCCES"; chmod 644 "$ETAT/SUCCES"
    break
  fi
done
[ -z "$ABANDON" ] && [ "$SUCCES" = 0 ] && log "tous les essais sont faits"
exit 0
