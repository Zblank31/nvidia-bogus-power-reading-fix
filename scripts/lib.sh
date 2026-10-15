# Helpers shared by the scripts in this directory. Source it, don't run it.
# shellcheck shell=bash

# User-facing messages are bilingual: French if the locale starts with "fr", English otherwise.
#   say "texte en francais" "english text"
case "${LC_ALL:-${LANG:-}}" in fr*) FR=1 ;; *) FR=0 ;; esac
say() { if [ "$FR" = 1 ]; then printf '%s\n' "$1"; else printf '%s\n' "$2"; fi; }
die() { say "$1" "$2" >&2; exit 1; }

need_root() {
  [ "$(id -u)" -eq 0 ] || die "Lance-moi avec sudo (ou ajoute --dry-run pour voir sans rien modifier)." \
                              "Run me with sudo (or add --dry-run to see what would happen without changing anything)."
}

DEFAULT_CONF=/etc/modprobe.d/nvidia-bogus-power-fix.conf
DEFAULT_KEY="RmPmgrPmuOverride=1"

# One line per NVIDIA display/3D controller: "<pci address> <vendor:device> <name>".
# The address keeps the PCI domain (0000:09:00.0) because that is the form the driver option wants.
list_gpus() {
  lspci -D -nn -d 10de: 2>/dev/null | awk '
    # class 0300 = VGA controller, 0302 = 3D controller; this skips the HDMI audio function of the same card
    /\[0300\]|\[0302\]/ {
      addr = $1
      id = ""
      if (match($0, /\[10de:[0-9a-f]{4}\]/)) id = substr($0, RSTART + 1, RLENGTH - 2)
      name = $0
      sub(/^[^ ]+ [^:]+: /, "", name)              # drop "0000:09:00.0 VGA compatible controller [0300]: "
      sub(/ \[10de:[0-9a-f]{4}\].*$/, "", name)    # drop the trailing "[10de:2216] (rev a1)"
      print addr, id, name
    }'
}

# "09:00.0" -> "0000:09:00.0", lower-cased. Fails if the result is not a PCI address.
normalize_bus() {
  local b="${1,,}"
  [[ $b =~ ^[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] && b="0000:$b"
  [[ $b =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] || return 1
  printf '%s' "$b"
}

# nvidia-smi index of the GPU at a PCI address. Careful: nvidia-smi prints 8-digit domains
# (00000000:09:00.0) while lspci prints 4-digit ones, so only the bus:dev.fn part is compared.
gpu_index_for_bus() {
  local short="${1#*:}"
  nvidia-smi --query-gpu=index,pci.bus_id --format=csv,noheader 2>/dev/null |
    awk -F', ' -v b="$short" 'index($2, b) { print $1; exit }'
}

# On many distributions the nvidia module is loaded from the initramfs, before the root
# filesystem is mounted, so a new modprobe option is only seen at boot once it has been copied there.
# Rebuilding is harmless on distributions that load nvidia later.
rebuild_initramfs() {
  if command -v update-initramfs >/dev/null 2>&1; then
    say "-> update-initramfs -u -k all (Debian/Ubuntu), ça peut durer une minute..." \
        "-> update-initramfs -u -k all (Debian/Ubuntu), this can take a minute..."
    update-initramfs -u -k all
  elif command -v dracut >/dev/null 2>&1; then
    say "-> dracut -f --regenerate-all (Fedora/RHEL/openSUSE)..." "-> dracut -f --regenerate-all (Fedora/RHEL/openSUSE)..."
    dracut -f --regenerate-all
  elif command -v mkinitcpio >/dev/null 2>&1; then
    say "-> mkinitcpio -P (Arch)..." "-> mkinitcpio -P (Arch)..."
    mkinitcpio -P
  else
    say "!! Je ne sais pas reconstruire l'initramfs de ta distribution : fais-le à la main (le fichier de configuration est déjà en place)." \
        "!! I don't know how to rebuild the initramfs on your distribution: do it by hand (the configuration file is already in place)."
    return 2
  fi
}
