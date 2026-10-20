#!/usr/bin/env bash
# Build the golden OPNsense image and publish it as one block snapshot per zone
# (plus a qcow2 in Object Storage, for distribution).
#
# Runs on the operator's machine or a CI runner with the scw CLI (credentials
# from the environment or the scw profile) and SSH access to a build host: any
# OPNsense instance of the same version, e.g. a firewall of a test landing zone.
#
# Required:
#   BUILD_SERVER  <zone>/<uuid> of the build host
#   BUILD_SSH     ssh destination of the build host, e.g. root@10.0.4.12
# Optional:
#   BUILD_SSH_OPTS    extra ssh options, e.g. "-J bastion@203.0.113.1:61000"
#   OPNSENSE_VERSION  default 26.1
#   NANO_SHA256       default: read from the official checksums file
#   PLUGIN_VERSION    default 1.0.0
#   IMAGE_NAME        default opnsense-<version>-scwlz-<plugin version>
#   ZONES             zones to publish to, default: the build host's zone
#   BUCKET            Object Storage bucket (same region) for the qcow2 export;
#                     required when ZONES spans more than the build host's zone
#   PROJECT_ID        project of the snapshots, default: the scw default
#   DISK_GB           golden volume size, default 25 (OPNsense grows its file
#                     system to the firewall volume size at first boot)

set -euo pipefail
: "${BUILD_SERVER:?<zone>/<uuid> of the build host}" "${BUILD_SSH:?ssh destination of the build host}"
version=${OPNSENSE_VERSION:-26.1}
plugin_version=${PLUGIN_VERSION:-1.0.0}
name=${IMAGE_NAME:-opnsense-$version-scwlz-$plugin_version}
build_zone=${BUILD_SERVER%%/*}
server=${BUILD_SERVER#*/}
zones=${ZONES:-$build_zone}
region=${build_zone%-*}
project=(${PROJECT_ID:+project-id=$PROJECT_ID})
here=$(cd "$(dirname "$0")" && pwd)
ssh_b() { ssh ${BUILD_SSH_OPTS:-} "$BUILD_SSH" "$@"; }
log() { echo "build: $*" >&2; }

if [ -z "${NANO_SHA256:-}" ]; then
  NANO_SHA256=$(curl -fsS "https://pkg.opnsense.org/releases/$version/OPNsense-$version-checksums-amd64.sha256" |
    sed -n "s/^SHA256 (OPNsense-$version-nano-amd64.img.bz2) = //p")
fi
[ -n "$NANO_SHA256" ] || { log "no sha256 for OPNsense $version nano"; exit 1; }
for z in $zones; do
  [ "$z" = "$build_zone" ] || [ -n "${BUCKET:-}" ] || { log "BUCKET is required to publish to $z"; exit 1; }
done

log "creating the golden volume in $build_zone"
vol=$(scw block volume create zone="$build_zone" name="$name" from-empty.size="${DISK_GB:-25}GB" perf-iops=5000 \
  "${project[@]}" -w -o template='{{ .ID }}')
cleanup() {
  scw instance server detach-volume server-id="$server" volume-id="$vol" zone="$build_zone" >/dev/null 2>&1 || true
  scw block volume wait "$vol" zone="$build_zone" terminal-status=available >/dev/null 2>&1 || true
  scw block volume delete "$vol" zone="$build_zone" >/dev/null 2>&1 || true
}
trap cleanup EXIT

before=$(ssh_b sysctl -n kern.disks)
scw instance server attach-volume server-id="$server" volume-id="$vol" volume-type=sbs_volume zone="$build_zone" >/dev/null
disk=
for _ in $(seq 1 30); do
  disk=$(comm -13 <(tr ' ' '\n' <<<"$before" | sort) <(ssh_b sysctl -n kern.disks | tr ' ' '\n' | sort) | head -1)
  [ -n "$disk" ] && break
  sleep 5
done
[ -n "$disk" ] || { log "the volume never showed up on the build host"; exit 1; }
log "volume attached as $disk"

# No macOS extended attributes in the archive: the build host is FreeBSD.
COPYFILE_DISABLE=1 tar --no-xattrs -C "$here" -cf - bake.sh bootstrap-config.xml plugin |
  ssh_b 'rm -rf /var/tmp/scwlz-src && mkdir -p /var/tmp/scwlz-src && tar -xf - -C /var/tmp/scwlz-src'
ssh_b sh /var/tmp/scwlz-src/bake.sh "$disk" "$version" "$NANO_SHA256" "$plugin_version"

scw instance server detach-volume server-id="$server" volume-id="$vol" zone="$build_zone" >/dev/null
scw block volume wait "$vol" zone="$build_zone" terminal-status=available timeout=30m >/dev/null
snap=$(scw block snapshot create volume-id="$vol" name="$name" zone="$build_zone" "${project[@]}" -w -o template='{{ .ID }}')
log "snapshot $build_zone/$snap"
echo "$build_zone/$snap"

if [ -n "${BUCKET:-}" ]; then
  key="releases/$name.qcow2"
  scw block snapshot export-to-object-storage snapshot-id="$snap" bucket="$BUCKET" key="$key" zone="$build_zone" >/dev/null
  scw block snapshot wait "$snap" zone="$build_zone" terminal-status=available timeout=30m >/dev/null
  log "exported s3://$BUCKET/$key"
  for z in $zones; do
    [ "$z" = "$build_zone" ] && continue
    s=$(scw block snapshot import-from-object-storage bucket="$BUCKET" key="$key" name="$name" zone="$z" "${project[@]}" \
      -o template='{{ .ID }}')
    scw block snapshot wait "$s" zone="$z" terminal-status=available timeout=30m >/dev/null
    log "snapshot $z/$s"
    echo "$z/$s"
  done
fi
