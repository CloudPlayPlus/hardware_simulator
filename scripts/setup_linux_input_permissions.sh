#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This setup script is only needed on Linux."
  exit 0
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
plugin_root="$(cd -- "$script_dir/.." && pwd)"
rule_src="$plugin_root/linux/udev/rules.d/60-cloudplayplus-hardware-simulator.rules"
rule_dst="/etc/udev/rules.d/60-cloudplayplus-hardware-simulator.rules"

if [[ ! -f "$rule_src" ]]; then
  echo "Missing udev rule: $rule_src" >&2
  exit 1
fi

target_user="${SUDO_USER:-$USER}"
if [[ -z "$target_user" || "$target_user" == "root" ]]; then
  target_user="$(id -un)"
fi

echo "Installing CloudPlayPlus uinput udev rule..."
sudo install -m 0644 "$rule_src" "$rule_dst"

echo "Ensuring input group exists..."
sudo groupadd -f input

echo "Adding $target_user to input group..."
sudo usermod -aG input "$target_user"

echo "Loading uinput module..."
sudo modprobe uinput || true

echo "Reloading udev rules..."
sudo udevadm control --reload-rules
sudo udevadm trigger --property-match=DEVNAME=/dev/uinput || true

echo
echo "Current /dev/uinput state:"
ls -l /dev/uinput || true

echo
echo "Done. Log out and back in so the new input group membership applies."
echo "After logging back in, verify with:"
echo "  id"
echo "  ls -l /dev/uinput"
