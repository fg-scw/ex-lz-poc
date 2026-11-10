#!/usr/bin/env bash
# Live check of the private load balancer.
# banner mode proves that `first` pins new sessions to node a, fails over to b,
# drops a held session, and fails back to a.
# wallix mode records which of 22/443/3389 the appliance actually accepts, then
# powers the nodes if at least one port is open on both.
set -euo pipefail

LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$LAB"

if [[ -z "${SCW_SECRET_KEY:-}" ]]; then
  echo "Le test live a besoin de SCW_SECRET_KEY (clé API du projet qui porte le lab)." >&2
  exit 2
fi

for bin in terraform jq python3 ssh curl; do
  command -v "$bin" >/dev/null || { echo "binaire manquant: $bin" >&2; exit 2; }
done

OUT="$(terraform output -json)"
ZONE="$(jq -r '.zone.value' <<<"$OUT")"
MODE="$(jq -r '.mode.value' <<<"$OUT")"
LB_IP="$(jq -r '.lb_private_ip.value' <<<"$OUT")"
IP_A="$(jq -r '.bastion_ips.value.a' <<<"$OUT")"
IP_B="$(jq -r '.bastion_ips.value.b' <<<"$OUT")"
PROBE="$(jq -r '.probe_public_ip.value' <<<"$OUT")"
ID_A="$(jq -r '.bastion_server_ids.value.a' <<<"$OUT")"
ID_B="$(jq -r '.bastion_server_ids.value.b' <<<"$OUT")"
ID_A="${ID_A##*/}"
ID_B="${ID_B##*/}"

KEY="$(mktemp)"
chmod 600 "$KEY"
terraform output -raw probe_private_key >"$KEY"

power() {
  local id="$1" action="$2"
  curl -fsS --max-time 60 -X POST \
    -H "X-Auth-Token: ${SCW_SECRET_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"action\":\"${action}\"}" \
    "https://api.scaleway.com/instance/v1/zones/${ZONE}/servers/${id}/action" \
    >/dev/null
}

server_state() {
  curl -fsS --max-time 30 -H "X-Auth-Token: ${SCW_SECRET_KEY}" \
    "https://api.scaleway.com/instance/v1/zones/${ZONE}/servers/${1}" \
    | jq -r '.server.state'
}

wait_state() {
  local id="$1" want="$2" timeout="${3:-180}" start now state
  start="$(date +%s)"
  while true; do
    state="$(server_state "$id")"
    if [[ "$state" == "$want" ]]; then
      return 0
    fi
    now="$(date +%s)"
    if ((now - start > timeout)); then
      echo "délai dépassé: serveur ${id} est ${state}, attendu ${want}" >&2
      return 1
    fi
    sleep 3
  done
}

restore() {
  power "$ID_A" poweron || true
  power "$ID_B" poweron || true
  rm -f "$KEY"
}
trap restore EXIT

SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 "root@${PROBE}")

echo "mode=${MODE} zone=${ZONE} lb=${LB_IP} a=${IP_A} b=${IP_B} probe=${PROBE}"

echo "attente SSH sur la sonde"
ready=0
for _ in $(seq 1 36); do
  if "${SSH[@]}" true; then
    ready=1
    break
  fi
  sleep 5
done
if ((ready == 0)); then
  echo "la sonde ne répond pas en SSH" >&2
  exit 1
fi

"${SSH[@]}" 'netplan apply || true; mkdir -p /tmp'
"${SSH[@]}" 'cat > /tmp/remote_check.py' <"${LAB}/scripts/remote_check.py"

remote() {
  "${SSH[@]}" python3 /tmp/remote_check.py "$@"
}

wait_banner() {
  local host="$1" port="$2" expect="$3" timeout="${4:-90}" start now line
  start="$(date +%s)"
  while true; do
    line="$(remote banner "$host" "$port" || true)"
    if [[ "$line" == "$expect"* ]]; then
      echo "$line"
      return 0
    fi
    now="$(date +%s)"
    if ((now - start > timeout)); then
      echo "délai dépassé: ${host}:${port} répond ${line:-rien}, attendu ${expect}" >&2
      return 1
    fi
    sleep 3
  done
}

reboot_bastions() {
  echo "redémarrage des deux bastions pour prendre l'adresse privée"
  power "$ID_A" reboot || true
  power "$ID_B" reboot || true
  wait_state "$ID_A" running 180
  wait_state "$ID_B" running 180
}

if [[ "$MODE" == "banner" ]]; then
  if ! wait_banner "$IP_A" 443 "a" 30 >/dev/null; then
    reboot_bastions
    wait_banner "$IP_A" 443 "a" 120 >/dev/null
    wait_banner "$IP_B" 443 "b" 120 >/dev/null
  fi

  for port in 22 443 3389; do
    direct_a="$(remote banner "$IP_A" "$port")"
    direct_b="$(remote banner "$IP_B" "$port")"
    echo "direct port=${port} a=${direct_a} b=${direct_b}"
    [[ "$direct_a" == a\ * && "$direct_b" == b\ * ]]
    remote many "$LB_IP" "$port" 20 "a "
    echo "pin port=${port} 20/20 vers a"
  done

  echo "extinction de b: le trafic reste sur a"
  power "$ID_B" poweroff
  wait_state "$ID_B" stopped 180
  remote many "$LB_IP" 3389 5 "a "
  power "$ID_B" poweron
  wait_state "$ID_B" running 180
  wait_banner "$IP_B" 3389 "b" 120 >/dev/null

  echo "extinction de a: les nouvelles sessions passent sur b"
  power "$ID_A" poweroff
  wait_state "$ID_A" stopped 180
  wait_banner "$LB_IP" 3389 "b" 90 >/dev/null

  echo "session tenue vers b, puis extinction de b"
  held="$(mktemp)"
  "${SSH[@]}" python3 -u /tmp/remote_check.py hold "$LB_IP" 3389 >"$held" &
  holder=$!
  for _ in $(seq 1 20); do
    if grep -q '^b ' "$held"; then
      break
    fi
    sleep 1
  done
  grep -q '^b ' "$held"
  power "$ID_B" poweroff
  wait "$holder" || true
  if grep -q 'AFTER TimeoutError' "$held" || ! grep -q '^AFTER ' "$held"; then
    echo "la session tenue n'a pas été coupée par l'extinction du nœud" >&2
    cat "$held" >&2
    exit 1
  fi
  echo "session coupée: $(grep '^AFTER ' "$held")"
  rm -f "$held"

  echo "rallumage: first revient sur a"
  power "$ID_A" poweron
  power "$ID_B" poweron
  wait_state "$ID_A" running 180
  wait_state "$ID_B" running 180
  wait_banner "$IP_A" 3389 "a" 120 >/dev/null
  wait_banner "$IP_B" 3389 "b" 120 >/dev/null
  wait_banner "$LB_IP" 3389 "a" 90 >/dev/null
  remote many "$LB_IP" 3389 10 "a "
  echo "failback: 10/10 vers a"
  echo "banner: bascule, coupure de session et retour sur a sont confirmés"
  exit 0
fi

echo "mode wallix: attente qu'un port privé réponde (180 s)"
opened=""
for _ in $(seq 1 36); do
  for port in 443 22 3389; do
    if [[ "$(remote open "$LB_IP" "$port" || true)" == "open" ]]; then
      opened="$port"
      break 2
    fi
  done
  sleep 5
done

if [[ -z "$opened" ]]; then
  reboot_bastions || true
  for _ in $(seq 1 36); do
    if [[ "$(remote open "$LB_IP" 443 || true)" == "open" || "$(remote open "$IP_A" 443 || true)" == "open" ]]; then
      break
    fi
    sleep 5
  done
fi

echo "table des ports"
any_both=""
any_lb=""
for port in 22 443 3389; do
  state_lb="$(remote open "$LB_IP" "$port" || true)"
  state_a="$(remote open "$IP_A" "$port" || true)"
  state_b="$(remote open "$IP_B" "$port" || true)"
  echo "port=${port} lb=${state_lb} a=${state_a} b=${state_b}"
  if [[ "$state_lb" == "open" ]]; then
    any_lb="$port"
  fi
  if [[ "$state_a" == "open" && "$state_b" == "open" && "$state_lb" == "open" ]]; then
    any_both="$port"
  fi
done

if [[ -z "$any_lb" ]]; then
  echo "finding: aucun de 22, 443, 3389 n'est ouvert sur l'IP du LB." >&2
  echo "finding: une image Wallix sans l'outil DHCP Scaleway (udev 72-scw-vpc-iface) ne configure pas la carte privée, qui est ajoutée après le premier boot." >&2
  echo "finding: relancer avec expose_bastion_admin = true pour ouvrir l'assistant sur 443/2242, puis configurer l'adresse privée dans System > Network." >&2
  exit 1
fi

if [[ -z "$any_both" ]]; then
  echo "finding: le LB répond, mais pas les deux nœuds sur le même port. Pas de bascule à mesurer." >&2
  echo "finding: 3389 et 22 restent fermés tant que le proxy Wallix n'est pas configuré (licence, chiffrement, cibles)." >&2
  exit 0
fi

echo "bascule sur le port ${any_both}"
power "$ID_A" poweroff
wait_state "$ID_A" stopped 180
start="$(date +%s)"
while true; do
  if [[ "$(remote open "$IP_A" "$any_both" || true)" == "closed" && "$(remote open "$LB_IP" "$any_both" || true)" == "open" ]]; then
    break
  fi
  now="$(date +%s)"
  if ((now - start > 90)); then
    echo "le LB n'a pas repris le port ${any_both} après l'extinction de a" >&2
    exit 1
  fi
  sleep 3
done
echo "a éteint, le LB répond encore sur ${any_both}"

power "$ID_A" poweron
wait_state "$ID_A" running 180
power "$ID_B" poweroff
wait_state "$ID_B" stopped 180
start="$(date +%s)"
while true; do
  if [[ "$(remote open "$LB_IP" "$any_both" || true)" == "open" ]]; then
    break
  fi
  now="$(date +%s)"
  if ((now - start > 90)); then
    echo "le LB ne répond plus sur ${any_both} avec b éteint" >&2
    exit 1
  fi
  sleep 3
done
echo "b éteint, le LB répond encore sur ${any_both}: le retour vers a fonctionne au niveau TCP"
power "$ID_B" poweron
wait_state "$ID_B" running 180
echo "wallix: le chemin TCP et la bascule d'alimentation sont confirmés sur le port ${any_both}"
echo "finding: ce test ne configure pas bastion-replication, le coffre, ni une session RDP multi-utilisateurs."
