#!/bin/sh
# Offline test of the split brain guard and the hand back of vip.sh (no
# network, no OPNsense).
#   sh image/tests/test-vip.sh
# Kept outside plugin/: bake.sh packages that tree and the test must not ship.

here=$(cd "$(dirname "$0")" && pwd)
SCWLZ_STATE_DIR=$(mktemp -d)
export SCWLZ_STATE_DIR
trap 'rm -rf "$SCWLZ_STATE_DIR"' EXIT

SCWLZ_VIP_TEST=1
. "$here/../plugin/usr/local/opnsense/scripts/scwlz/vip.sh"

# Stubs: the peer answers on the sync leg when PING_RC=0; logs are captured.
PING_RC=0
ping() { return "$PING_RC"; }
logger() { echo "$*" >> "$SCWLZ_STATE_DIR/log"; }

PEER_MACS='02:00:00:aa:00:01 02:00:00:aa:00:02'
SYNC_IP=10.255.0.11
PEER_SYNC_IP=10.255.0.12
fail=0

check() { # name expected-rc command...
  name=$1 want=$2
  shift 2
  "$@"
  got=$?
  [ "$got" = "$want" ] || { echo "FAIL: $name (rc $got, want $want)"; fail=1; }
}

mode=cron PING_RC=0 check "peer holds and answers: hold" 0 peer_holds 02:00:00:aa:00:01
mode=cron PING_RC=1 check "peer holds but silent: take" 1 peer_holds 02:00:00:aa:00:01
mode=cron PING_RC=0 check "held by a third party: take" 1 peer_holds 02:00:00:bb:00:01
mode=cron PING_RC=0 check "no current holder: take" 1 peer_holds ""
mode=event PING_RC=0 check "MASTER event never held back" 1 peer_holds 02:00:00:aa:00:01
mode=cron PEER_MACS='' PING_RC=0 check "no peer settings: take" 1 peer_holds 02:00:00:aa:00:01

# Log: once per minute and per VIP.
split_brain_log ip1
split_brain_log ip1
split_brain_log ip2
n=$(grep -c 'split brain: peer alive and holding ip1, not moving it' "$SCWLZ_STATE_DIR/log")
[ "$n" = 1 ] || { echo "FAIL: ip1 logged $n times, want 1"; fail=1; }
grep -q 'holding ip2' "$SCWLZ_STATE_DIR/log" || { echo "FAIL: ip2 not logged"; fail=1; }
echo 1 > "$SCWLZ_STATE_DIR/scwlz-split-brain-ip1"
split_brain_log ip1
n=$(grep -c 'holding ip1' "$SCWLZ_STATE_DIR/log")
[ "$n" = 2 ] || { echo "FAIL: ip1 not logged again after a minute ($n)"; fail=1; }

# Hand back (release): a BACKUP gives a VIP it still holds to a living peer.
HOLDER=''
holder() { echo "$HOLDER"; }
api() { echo "MOVE $*" >> "$SCWLZ_STATE_DIR/api"; echo 200; }
ips=https://api.test/ips
PEER_NODE=peer
moves() { grep -c MOVE "$SCWLZ_STATE_DIR/api" 2>/dev/null || echo 0; }
HOLDER=02:00:00:cc:00:01 PING_RC=0 release ip1 02:00:00:cc:00:01 02:00:00:aa:00:01
[ "$(moves)" = 1 ] || { echo "FAIL: own VIP, living peer: not handed back"; fail=1; }
grep -q '"from_resource":{"mac_address":"02:00:00:cc:00:01"},"to_resource":{"mac_address":"02:00:00:aa:00:01","name":"peer"}' "$SCWLZ_STATE_DIR/api" ||
  { echo "FAIL: hand back body"; fail=1; }
HOLDER=02:00:00:cc:00:01 PING_RC=1 release ip1 02:00:00:cc:00:01 02:00:00:aa:00:01
[ "$(moves)" = 1 ] || { echo "FAIL: handed back to a dead peer"; fail=1; }
HOLDER=02:00:00:aa:00:01 PING_RC=0 release ip1 02:00:00:cc:00:01 02:00:00:aa:00:01
[ "$(moves)" = 1 ] || { echo "FAIL: moved a VIP this node does not hold"; fail=1; }
HOLDER=02:00:00:cc:00:01 PING_RC=0 release ip1 "" 02:00:00:aa:00:01
[ "$(moves)" = 1 ] || { echo "FAIL: moved without own MAC"; fail=1; }

# own_mac reads MOVES.
MOVES='ip1=02:00:00:cc:00:01 ip2=02:00:00:cc:00:02'
[ "$(own_mac ip2)" = 02:00:00:cc:00:02 ] || { echo "FAIL: own_mac"; fail=1; }
[ -z "$(own_mac ip9)" ] || { echo "FAIL: own_mac of an unknown id"; fail=1; }

[ "$fail" = 0 ] && echo "test-vip: ok"
exit "$fail"
