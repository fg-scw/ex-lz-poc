#!/bin/sh
# Pull this node's configuration from the Scaleway instance metadata.
#   sync.sh boot   rc.syshook start (every boot)
#   sync.sh cron   every minute (/usr/local/etc/cron.d/scwlz)
#
# user_data keys, written by Terraform (modules/hub):
#   opnsense_secrets   KEY='value' lines. Stored in /conf/scwlz/secrets.env
#                      (root only), then deleted from the metadata.
#   opnsense_config    base64 config.xml; secrets appear as @@KEY@@ tokens.
#   opnsense_platform  hash of the platform part (interfaces, CARP, HA,
#                      gateways). A node that already has a configuration
#                      (cron or reboot alike) only applies policy changes
#                      (rules, NAT, aliases, routes); a platform change means
#                      rebuilding the node. Only a new node applies one.
#   scwlz              VIP failover settings (vip.sh), no secret.
#
# The metadata answers only on the VPC router (169.254.169.254, any Private
# Network leg) and only to a privileged source port (< 1024).

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH

mode=${1:-cron}
[ -n "$SCWLZ_LOCKED" ] || exec env SCWLZ_LOCKED=1 lockf -t 0 /var/run/scwlz-sync.lock "$0" "$@"

META_IP=169.254.42.42
VPC_ROUTER=169.254.169.254
META="http://$META_IP/user_data"
D=/conf/scwlz
CONF=/usr/local/etc/scwlz.conf

log() { logger -p daemon.notice -t scwlz "$*"; }
# A random privileged source port per request: with a fixed range curl always
# binds the same first free port, and a request within the TIME_WAIT of the
# previous one (60 s) then fails at once (seen live: the cron never got its
# configuration).
md() { curl -s -m 8 --local-port "$(jot -r 1 600 1000)-1023" "$@"; }

T=$(mktemp -d /tmp/scwlz.XXXXXX) || exit 1
trap 'rm -rf "$T"' EXIT
umask 077
mkdir -p "$D"

# $1 key -> $T/$1; fails when the key is absent or the metadata unreachable.
get() { [ "$(md -o "$T/$1" -w '%{http_code}' "$META/$1")" = 200 ]; }

# Fresh image (no Private Network leg configured yet): lease an address on
# vtnet1, the first Private NIC, and reach the VPC router through it, never
# through vtnet0 (public NIC, which a default route may point to).
j=0
while [ $j -lt 6 ] && ! ifconfig vtnet1 2>/dev/null | grep -q 'inet '; do
  dhclient vtnet1 >/dev/null 2>&1
  j=$((j + 1))
  sleep 2
done
route -n get "$VPC_ROUTER" 2>/dev/null | grep -q 'interface: vtnet[1-9]' || {
  route -n delete -host "$VPC_ROUTER" >/dev/null 2>&1
  route -n add -host "$VPC_ROUTER" -iface vtnet1 >/dev/null 2>&1
}
route -n get "$META_IP" 2>/dev/null | grep -q "gateway: $VPC_ROUTER" || {
  route -n delete -host "$META_IP" >/dev/null 2>&1
  route -n add -host "$META_IP" "$VPC_ROUTER" >/dev/null 2>&1
}

tries=1
[ "$mode" = boot ] && tries=12
i=0
until md -o /dev/null "$META?format=json"; do
  i=$((i + 1))
  [ $i -ge $tries ] && { [ "$mode" = boot ] && log "metadata unreachable"; exit 0; }
  sleep 5
done

if get opnsense_secrets; then
  cat "$T/opnsense_secrets" > "$D/secrets.env"
  [ "$(md -o /dev/null -w '%{http_code}' -X DELETE "$META/opnsense_secrets")" = 204 ] &&
    log "secrets stored, removed from the metadata"
fi

if get scwlz && ! cmp -s "$T/scwlz" "$CONF"; then
  install -m 0644 "$T/scwlz" "$CONF" && log "failover settings updated"
fi

get opnsense_config || exit 0
new=$(sha256 -q "$T/opnsense_config")
[ "$new" = "$(cat "$D/config.hash" 2>/dev/null)" ] && exit 0
[ -s "$D/secrets.env" ] || { log "configuration waits for its secrets"; exit 0; }

get opnsense_platform || : > "$T/opnsense_platform"
platform=$(cat "$T/opnsense_platform")
first=
[ -f "$D/config.hash" ] || first=1
# Only a new node (no config.hash yet: first boot, rebuild) takes a different
# platform. Whatever the mode: a plain reboot of a node in service must not
# apply a pending platform change at a time nobody chose.
if [ -z "$first" ] && [ "$platform" != "$(cat "$D/platform.hash" 2>/dev/null)" ]; then
  [ "$new" = "$(cat "$D/pending.hash" 2>/dev/null)" ] ||
    log "platform change (interfaces, CARP, HA or gateways): rebuild this node to apply it"
  echo "$new" > "$D/pending.hash"
  exit 0
fi

# Secrets replace their @@KEY@@ tokens; values are taken literally.
openssl base64 -d -A -in "$T/opnsense_config" > "$T/config.tpl" || exit 0
(
  set -a
  . "$D/secrets.env"
  set +a
  awk '{
    while (match($0, /@@[A-Z0-9_]+@@/)) {
      k = substr($0, RSTART + 2, RLENGTH - 4)
      printf "%s%s", substr($0, 1, RSTART - 1), ENVIRON[k]
      $0 = substr($0, RSTART + RLENGTH)
    }
    print
  }' "$T/config.tpl"
) > "$T/config.xml"
if ! grep -q '</opnsense>' "$T/config.xml"; then
  log "rejected configuration $new: not an OPNsense config"
  exit 0
fi

cp -p /conf/config.xml /conf/config.xml.scwlz-prev 2>/dev/null
cat "$T/config.xml" > /conf/config.xml
echo "$new" > "$D/config.hash"
echo "$platform" > "$D/platform.hash"
rm -f "$D/pending.hash"

if [ -n "$first" ] || [ "$mode" = boot ]; then
  # A full configuration is applied by a reboot, not rc.reload_all: a live
  # reload left a node without DNS and with a partial ruleset (seen live),
  # while a boot applies everything, and pfsync's boot-time demotion keeps a
  # returning node BACKUP.
  log "configuration $new stored, rebooting to apply it"
  ( sleep 10; shutdown -r now ) </dev/null >/dev/null 2>&1 &
else
  # Model migrations, as the boot runs them (convert_config): they fill the
  # settings the template leaves out. Without them a live apply differed from
  # the boot, e.g. IPv6 allowed instead of blocked (seen live).
  pluginctl -m >/dev/null
  configctl filter reload >/dev/null
  configctl interface routes configure >/dev/null
  log "policy $new applied (filter and routes reloaded)"
fi
