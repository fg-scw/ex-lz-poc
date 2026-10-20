#!/bin/sh
# Bake the golden image onto an empty disk. Runs as root on the build host,
# an OPNsense (FreeBSD) instance with the target SBS volume attached.
#   bake.sh <disk> <opnsense version> <nano image sha256> <plugin version>
# Expects bootstrap-config.xml and plugin/ next to it (build.sh copies them).
#
# The image is never booted here: nothing to clean afterwards. The gate at the
# end refuses an image holding a key, a password hash or host-specific state.
# Needs about 4 GB free in /var/tmp (compressed and raw nano image).

set -eu
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin

disk=$1 version=$2 sha=$3 plugin_version=$4
src=$(cd "$(dirname "$0")" && pwd)
work=/var/tmp/scwlz-build
mnt=/mnt/scwlz-image
nano=OPNsense-$version-nano-amd64.img.bz2

fail() { echo "bake: $*" >&2; exit 1; }

# The target must be a whole, unused disk, never the build host's own.
[ -c "/dev/$disk" ] || fail "/dev/$disk not found"
mount | grep -q "^/dev/$disk" && fail "/dev/$disk is mounted"
swapctl -l | grep -q "/dev/$disk" && fail "/dev/$disk is used as swap"

mkdir -p "$work" "$mnt"
cd "$work"
[ -f "$nano" ] || fetch -q -o "$nano" "https://pkg.opnsense.org/releases/$version/$nano"
[ "$(sha256 -q "$nano")" = "$sha" ] || fail "$nano does not match sha256 $sha"

# os-scw-lz package: the plugin tree as is, version from the build.
rm -rf stage && mkdir stage
(cd "$src/plugin" && tar -cf - --exclude +MANIFEST .) | (cd stage && tar -xf -)
sed "s/%%VERSION%%/$plugin_version/" "$src/plugin/+MANIFEST" > manifest
(cd stage && find . -type f | sed 's|^\.||') > plist
rm -f os-scw-lz-*.pkg
pkg create -M manifest -p plist -r stage -o .
pkgfile=$(ls os-scw-lz-*.pkg)

# The nano image is a bare BSD-labelled disk that only boots in BIOS mode;
# Scaleway instances boot UEFI. Lay out the target like the OPNsense
# installer does (GPT: EFI system partition, BIOS boot, UFS root) and copy
# the nano file system into the root partition as is: its UFS label stays,
# so its fstab (/dev/ufs/OPNsense_Nano) still matches.
[ -f nano.img ] || bunzip2 -k -c "$nano" > nano.img
md=$(mdconfig -a -t vnode -o readonly -f nano.img)
trap 'umount "$mnt" 2>/dev/null; umount "$mnt/esp" 2>/dev/null; mdconfig -d -u "${md#md}" 2>/dev/null || true' EXIT
echo "bake: laying out /dev/$disk (GPT, UEFI and BIOS boot)"
gpart destroy -F "$disk" >/dev/null 2>&1 || true
gpart create -s gpt "$disk" >/dev/null
gpart add -t efi -s 260m "$disk" >/dev/null
gpart add -t freebsd-boot -s 512k "$disk" >/dev/null
gpart add -t freebsd-ufs "$disk" >/dev/null
dd if="/dev/${md}a" of="/dev/${disk}p3" bs=1m 2>/dev/null
growfs -y "/dev/${disk}p3" >/dev/null
mount "/dev/${disk}p3" "$mnt"
gpart bootcode -b "$mnt/boot/pmbr" -p "$mnt/boot/gptboot" -i 2 "$disk" >/dev/null
newfs_msdos -F 32 -c 1 -L EFISYS "/dev/${disk}p1" >/dev/null
mkdir -p "$mnt/esp"
mount -t msdosfs "/dev/${disk}p1" "$mnt/esp"
mkdir -p "$mnt/esp/EFI/BOOT"
cp "$mnt/boot/loader.efi" "$mnt/esp/EFI/BOOT/BOOTX64.EFI"
umount "$mnt/esp"
rmdir "$mnt/esp"
# Already grown to the volume size; a larger firewall volume is grown at
# first boot by FreeBSD's growfs (this probe file).

install -m 0644 "$src/bootstrap-config.xml" "$mnt/conf/config.xml"
pkg -r "$mnt" add -q "$work/$pkgfile"
# Host-specific state: every instance must generate its own.
rm -f "$mnt/entropy" "$mnt"/var/db/entropy/* "$mnt"/etc/ssh/ssh_host_* "$mnt"/conf/sshd/*

# Gate. usr/local/etc/config.xml(.sample) are OPNsense's factory defaults
# (public default password), used only by a console factory reset, and the
# console is locked: not a secret.
bad=0
for f in etc/ssh/ssh_host_* conf/sshd/* root/.ssh/* conf/backup/* conf/scwlz/* usr/local/etc/scwlz.conf entropy; do
  for p in "$mnt"/$f; do [ -e "$p" ] && { echo "gate: unexpected $p" >&2; bad=1; }; done
done
grep -q '<password>\*</password>' "$mnt/conf/config.xml" || { echo "gate: root is not locked" >&2; bad=1; }
hits=$(grep -rIlE 'PRIVATE KEY|ssh-(ed25519|rsa) AAAA|\$2[aby]\$|\$6\$|SCW_SECRET_KEY=' \
  "$mnt/conf" "$mnt/root" "$mnt/etc/ssh" "$mnt/usr/local/etc" 2>/dev/null |
  grep -vE "^$mnt/usr/local/etc/config\.xml(\.sample)?$" || true)
[ -z "$hits" ] || { echo "gate: secret-like content in: $hits" >&2; bad=1; }
[ "$bad" = 0 ] || fail "image refused by the gate"

pkg -r "$mnt" query '%n %v' os-scw-lz
gpart show "$disk"
umount "$mnt"
mdconfig -d -u "${md#md}"
trap - EXIT
echo "bake: done, /dev/$disk holds OPNsense $version nano + os-scw-lz $plugin_version"
