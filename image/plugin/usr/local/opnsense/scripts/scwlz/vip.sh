#!/bin/sh
# Data VIP failover for the OPNsense HA pair.
#   vip.sh <vhid>@<interface> MASTER|BACKUP|INIT   rc.syshook carp (90-scwlz-vip)
#   vip.sh reconcile                               cron, every minute
#
# The data VIPs (hub next hop, egress SNAT source) are IPAM reservations
# attached to the real NIC MAC of the CARP master: Scaleway hypervisors drop
# frames to a CARP virtual MAC. When this node is MASTER it moves them to its
# own MACs (IPAM "move" API). The VPC router resolves the hub VIP from IPAM,
# but the Public Gateways resolve the egress VIP by ARP: the master also holds
# it as an IP alias (adding it sends a gratuitous ARP), the backup must not.
# The cron run covers a missed transition, an API failure or a node installed
# while already MASTER.
#
# /usr/local/etc/scwlz.conf (from the metadata, see sync.sh) sets CARP_VHID,
# CARP_IF, EGRESS_IF, NODE, REGION, MOVES ("<ipam ip id>=<own NIC MAC> ..."),
# ALIASES ("<interface>=<VIP> ..."), SYNC_IP (own sync address), PEER_SYNC_IP,
# PEER_MACS (hub and egress MACs of the peer), PEER_NODE and PEER_MOVES (MOVES
# of the peer). /conf/scwlz/secrets.env holds SCW_SECRET_KEY. Without them
# (fresh image) the script does nothing.

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH

# Split brain guard. CARP runs on the hub leg only: when it is cut (one node's
# hub leg down, or a partition), both nodes are MASTER and their cron runs
# would steal the VIPs from each other every minute. A cron run therefore
# leaves a VIP alone while the peer holds it AND still answers on the sync
# leg (a separate network): a peer that is gone for real does not answer, and
# the VIP is taken as before. The MASTER event is never held back: a planned
# handover (peer in CARP maintenance mode, still alive) must move the VIPs,
# and the single move at a real partition is the right one (the node that
# still hears nobody on the hub leg has lost it).
# $1 holder MAC; uses $mode (cron|event), PEER_MACS, SYNC_IP, PEER_SYNC_IP.
peer_holds() {
  [ "$mode" = cron ] || return 1
  case " $PEER_MACS " in *" $1 "*) ;; *) return 1 ;; esac
  ping -c 2 -t 2 -S "$SYNC_IP" "$PEER_SYNC_IP" >/dev/null 2>&1
}

# $1 IP id; at most once a minute per VIP (a cron run tries several times).
split_brain_log() {
  stamp=${SCWLZ_STATE_DIR:-/var/run}/scwlz-split-brain-$1
  now=$(date +%s)
  [ $((now - $(cat "$stamp" 2>/dev/null || echo 0))) -ge 55 ] || return 0
  echo "$now" > "$stamp"
  logger -p daemon.err -t scwlz-vip "split brain: peer alive and holding $1, not moving it"
}

# Hand back. Once a split brain heals, the node that took the VIPs during it
# turns BACKUP and keeps them, while the MASTER's guard (peer_holds) never takes
# them from a living peer. So a BACKUP's cron run gives a VIP it still holds to its peer,
# only while the peer answers on the sync leg (never to a dead one).
# $1 IP id, $2 own MAC for it, $3 peer MAC for it.
release() {
  [ -n "$2" ] && [ -n "$3" ] && [ "$(holder "$1")" = "$2" ] || return 0
  ping -c 2 -t 2 -S "$SYNC_IP" "$PEER_SYNC_IP" >/dev/null 2>&1 || return 0
  code=$(api -o /dev/null -w '%{http_code}' -X POST "$ips/$1/move" \
    -d "{\"from_resource\":{\"mac_address\":\"$2\"},\"to_resource\":{\"mac_address\":\"$3\",\"name\":\"$PEER_NODE\"}}")
  if [ "$code" = 200 ]; then
    logger -p daemon.notice -t scwlz-vip "$1 handed back to $PEER_NODE ($3): this node is BACKUP"
  else
    logger -p daemon.err -t scwlz-vip "$1 hand back to $PEER_NODE failed: HTTP $code"
  fi
}

# Own MAC for an IP id, from MOVES.
own_mac() {
  for m in $MOVES; do [ "${m%=*}" = "$1" ] && echo "${m#*=}"; done
}

# Tests (image/tests/test-vip.sh) source the functions above only.
[ -n "$SCWLZ_VIP_TEST" ] && return 0

[ -r /usr/local/etc/scwlz.conf ] && [ -r /conf/scwlz/secrets.env ] || exit 0
. /usr/local/etc/scwlz.conf
SCW_SECRET_KEY=$(sed -n "s/^SCW_SECRET_KEY='\(.*\)'$/\1/p" /conf/scwlz/secrets.env)
[ -n "$SCW_SECRET_KEY" ] || exit 0

if [ "$1" = reconcile ]; then
  mode=cron
  state=reconcile
else
  mode=event
  [ "${1%@*}" = "$CARP_VHID" ] || exit 0
  state=$2
fi
ips="https://api.scaleway.com/ipam/v1/regions/$REGION/ips"

is_master() {
  ifconfig "$CARP_IF" | grep -q "carp: MASTER vhid $CARP_VHID "
}

api() {
  curl -s -m 8 -H "X-Auth-Token: $SCW_SECRET_KEY" -H 'Content-Type: application/json' "$@"
}

holder() { # $1 IP id -> MAC currently holding it, lower case (empty on API error)
  api "$ips/$1" | tr -d ' \n' | sed -n 's/.*"mac_address":"\([0-9A-Fa-f:]*\)".*/\1/p' | tr 'A-F' 'a-f'
}

claim() { # $1 IP id, $2 MAC, $3 max tries; retries while this node stays MASTER
  try=0
  code=000
  while [ "$try" -lt "$3" ] && is_master; do
    try=$((try + 1))
    cur=$(holder "$1")
    [ "$cur" = "$2" ] && return 0
    if [ -n "$cur" ] && peer_holds "$cur"; then
      split_brain_log "$1"
      return 0
    fi
    # The API refuses a move that does not name the current holder (412).
    [ -n "$cur" ] && code=$(api -o /dev/null -w '%{http_code}' -X POST "$ips/$1/move" \
      -d "{\"from_resource\":{\"mac_address\":\"$cur\"},\"to_resource\":{\"mac_address\":\"$2\",\"name\":\"$NODE\"}}")
    if [ "$code" = "200" ]; then
      logger -p daemon.notice -t scwlz-vip "$1 -> $NODE ($2) after $try tries"
      return 0
    fi
    sleep 2
  done
  is_master && logger -p daemon.err -t scwlz-vip "$1 -> $NODE failed: HTTP $code after $try tries"
}

# $1 add|remove; idempotent, so the cron keeps the aliases in line with CARP
# (OPNsense drops unknown aliases when it reconfigures an interface).
aliases() {
  for a in $ALIASES; do
    held=$(ifconfig "${a%=*}" | grep -c "inet ${a#*=} ")
    if [ "$1" = add ] && [ "$held" = 0 ]; then
      ifconfig "${a%=*}" alias "${a#*=}/32" && logger -p daemon.notice -t scwlz-vip "alias ${a#*=} added on ${a%=*}"
      # The PGW may keep the old master's MAC for the VIP in its ARP cache
      # despite the gratuitous ARP; traffic from the VIP to it makes it switch at once.
      gw=$(route -n get default 2>/dev/null | sed -n 's/.*gateway: //p')
      [ -n "$gw" ] && ping -c 2 -t 3 -S "${a#*=}" "$gw" >/dev/null 2>&1 &
    elif [ "$1" = remove ] && [ "$held" != 0 ]; then
      ifconfig "${a%=*}" -alias "${a#*=}" && logger -p daemon.notice -t scwlz-vip "alias ${a#*=} removed from ${a%=*}"
    fi
  done
}

# OPNsense picks the default route at boot, before dpinger has judged the
# PGWs, and may leave it on the hub router: no Internet, no API.
# Re-evaluate routing whenever the default route is not on the egress leg.
if ! route -n get default 2>/dev/null | grep -q "interface: $EGRESS_IF"; then
  configctl -d interface routes configure >/dev/null
  logger -p daemon.notice -t scwlz-vip "default route off $EGRESS_IF: routing re-evaluated"
fi

# pfsync demotes CARP (+240) until its bulk state transfer completes. When both
# nodes reload their configuration at once (first boot), the request can be
# lost and the demotion stays forever: the node then loses every
# election. Re-arm pfsync when it is still not in sync on two cron runs.
if [ "$1" = reconcile ]; then
  stuck=/var/run/scwlz-pfsync-stuck
  if ifconfig pfsync0 2>/dev/null | grep -q 'syncok: 0'; then
    if [ -f "$stuck" ]; then
      dev=$(ifconfig pfsync0 | sed -n 's/.*syncdev: \([^ ]*\).*/\1/p')
      peer=$(ifconfig pfsync0 | sed -n 's/.*syncpeer: \([^ ]*\).*/\1/p')
      ifconfig pfsync0 -syncdev && ifconfig pfsync0 syncdev "$dev" syncpeer "$peer" &&
        logger -p daemon.notice -t scwlz-vip "pfsync bulk transfer stuck: re-armed"
      rm -f "$stuck"
    else
      touch "$stuck"
    fi
  else
    rm -f "$stuck"
  fi
fi

# The MASTER event retries for minutes; each cron run only tries briefly, as
# the next one comes a minute later.
tries=30
[ "$state" = reconcile ] && { tries=3; is_master && state=MASTER || state=BACKUP; }

case "$state" in
BACKUP | INIT)
  aliases remove
  if [ "$mode" = cron ] && [ "$state" = BACKUP ]; then
    for m in $PEER_MOVES; do
      release "${m%=*}" "$(own_mac "${m%=*}")" "${m#*=}" </dev/null >/dev/null 2>&1 &
    done
  fi
  ;;
MASTER)
  # A booting node can be MASTER for about a second before it hears its peer,
  # and taking the VIPs then would cause an outage. Act only on a mastership
  # that holds.
  [ "$tries" = 30 ] && { sleep 3; is_master || exit 0; }
  aliases add
  # Detached and parallel: devd must not wait, one VIP must not wait for the
  # other (a lost zone can keep the API unreachable until dpinger moves the
  # default route to the surviving PGW).
  for m in $MOVES; do
    claim "${m%=*}" "${m#*=}" "$tries" </dev/null >/dev/null 2>&1 &
  done
  ;;
esac
