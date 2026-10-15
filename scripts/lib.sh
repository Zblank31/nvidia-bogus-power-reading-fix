# shellcheck shell=bash
# Shared helpers for the scripts in this directory (sourced, not run).
# Fonctions communes aux scripts de ce dossier (à "sourcer", pas à lancer).

# Language: French if the locale starts with "fr", English otherwise.
case "${LC_ALL:-${LANG:-}}" in fr*) FR=1;; *) FR=0;; esac
t()   { if [ "$FR" = 1 ]; then printf '%s\n' "$1"; else printf '%s\n' "$2"; fi; }   # t "texte français" "english text"
die() { t "$1" "$2" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "Lance-moi avec sudo (ou ajoute --dry-run pour voir sans rien modifier)." "Run me with sudo (or add --dry-run to see what would happen without changing anything)."; }

DEFAULT_CONF=/etc/modprobe.d/nvidia-bogus-power-fix.conf
DEFAULT_KEY="RmPmgrPmuOverride=1"

# list_gpus: one line per NVIDIA display/3D controller: "<domain:bus:dev.fn> <vendor:device> <name>"
list_gpus() {
  lspci -D -nn -d 10de: 2>/dev/null | awk '/\[0300\]|\[0302\]/ {
    bus=$1; id=""; if (match($0, /\[10de:[0-9a-f]{4}\]/)) id=substr($0, RSTART+1, RLENGTH-2);
    name=$0; sub(/^[^ ]+ [^:]+: /, "", name); sub(/ \[10de:[0-9a-f]{4}\].*$/, "", name); print bus, id, name }'
}

# normalize_bus: "09:00.0" -> "0000:09:00.0" ; lower-case ; returns 1 if the format is wrong
normalize_bus() {
  local b="${1,,}"
  [[ $b =~ ^[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] && b="0000:$b"
  [[ $b =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] || return 1
  printf '%s' "$b"
}

# gpu_index_for_bus: nvidia-smi index of the GPU at the given PCI address (nvidia-smi prints 8-digit domains: 00000000:09:00.0)
gpu_index_for_bus() {
  local short="${1#*:}"   # 0000:09:00.0 -> 09:00.0
  nvidia-smi --query-gpu=index,pci.bus_id --format=csv,noheader 2>/dev/null | awk -F', ' -v b="$short" 'index($2, b) {print $1; exit}'
}

# rebuild_initramfs: the nvidia module is loaded from the initramfs on many distros, so the new option must be copied into it.
rebuild_initramfs() {
  if   command -v update-initramfs >/dev/null 2>&1; then t "-> update-initramfs -u -k all (Debian/Ubuntu), ça peut durer une minute..." "-> update-initramfs -u -k all (Debian/Ubuntu), this can take a minute..."; update-initramfs -u -k all
  elif command -v dracut           >/dev/null 2>&1; then t "-> dracut -f --regenerate-all (Fedora/RHEL/openSUSE)..." "-> dracut -f --regenerate-all (Fedora/RHEL/openSUSE)..."; dracut -f --regenerate-all
  elif command -v mkinitcpio       >/dev/null 2>&1; then t "-> mkinitcpio -P (Arch)..." "-> mkinitcpio -P (Arch)..."; mkinitcpio -P
  else
    t "!! Je ne sais pas reconstruire l'initramfs de ta distribution : fais-le à la main (le fichier de configuration est déjà en place)." \
      "!! I don't know how to rebuild the initramfs on your distribution: do it by hand (the configuration file is already in place)."
    return 2
  fi
}
