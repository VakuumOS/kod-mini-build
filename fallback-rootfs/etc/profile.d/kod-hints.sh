# shellcheck shell=sh
# Vakuum OS Builder: short hints for the interactive console.
kod_help() {
    cat <<'HELP'
Vakuum OS Builder (kod-mini) — useful commands
  lsblk, fdisk -l          list disks and partitions
  sfdisk /dev/sdX          (scripted) partitioning, e.g. GPT + ESP + root
  wipefs -a /dev/sdX       remove old signatures
  mkfs.fat -F32 /dev/sdX1  EFI system partition
  mkfs.ext4 -L VAKUUM_ROOT /dev/sdX2
  vakuum-prep-swap /mnt    swap file on the mounted target (< 4 GiB RAM)
  vakuum-console ru|us     keyboard layout (Ctrl+Shift toggles EN/RU)
  wget https://...         download (BusyBox, built-in TLS)
  poweroff | reboot
HELP
}
