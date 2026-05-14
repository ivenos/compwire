#!/bin/sh
# Real WireGuard integration tests — three scenarios mirroring examples/*.yaml.
#
# Scenarios and their corresponding examples:
#   basic        → examples/basic.yaml        (server + 1 IPv4 client)
#   multi-client → examples/multi-client.yaml (server + 2 clients, PSK, cross-routing)
#   ipv6-endpoint→ examples/ipv6-endpoint.yaml(client via IPv6 endpoint [::1]:51820)
#
# Note: examples/*.yaml use network_mode:host for real deployments on separate
# machines. These tests use a Docker bridge network so all containers run on one
# host without routing-table conflicts between WireGuard interfaces.
#
# Requires: Docker with NET_ADMIN support, Linux kernel >= 5.6 (WireGuard built-in).
# Usage: sh test/integration_test.sh [IMAGE]
set -eu

IMAGE="${1:-compwire:integration-test}"
PASS=0
FAIL=0

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
ok()   { printf '  [PASS] %s\n' "$*"; PASS=$(( PASS + 1 )); }
fail() { printf '  [FAIL] %s\n' "$*"; FAIL=$(( FAIL + 1 )); }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
parse_key() { grep "^${1}=" | cut -d= -f2-; }

genkeys() {
  _out=$(docker run --rm "$IMAGE" genkey)
  _priv=$(printf '%s' "$_out" | parse_key PRIVATE_KEY)
  _pub=$(printf '%s'  "$_out" | parse_key PUBLIC_KEY)
  printf '%s %s' "$_priv" "$_pub"
}

ping_test() {
  _from="$1" _dst="$2" _label="$3"
  if docker exec "$_from" ping -c 3 -W 3 "$_dst" >/dev/null 2>&1; then
    ok "$_label"
  else
    fail "$_label"
  fi
}

# Run a scenario: bring up containers, run the check function, tear down.
# Usage: run_scenario <net> <check_fn> <container...>
_NET=""
_CONTAINERS=""
scenario_cleanup() {
  [ -z "$_CONTAINERS" ] && [ -z "$_NET" ] && return
  log "Tearing down..."
  # shellcheck disable=SC2086
  docker rm -f $_CONTAINERS 2>/dev/null || true
  if [ -n "$_NET" ]; then docker network rm "$_NET" 2>/dev/null || true; fi
  _CONTAINERS=""
  _NET=""
}

scenario_start() {
  _NET="$1"
  _CONTAINERS=""
  docker network create "$_NET" >/dev/null
}

scenario_add() {
  _CONTAINERS="${_CONTAINERS:+$_CONTAINERS }$1"
}

# ---------------------------------------------------------------------------
# Build image if missing
# ---------------------------------------------------------------------------
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  log "Image '$IMAGE' not found — building..."
  docker build -t "$IMAGE" "$ROOT"
fi

# ===========================================================================
# Test: genkey subcommand  (examples: all scenarios)
# ===========================================================================
echo ""
echo "################################################################"
echo "# genkey subcommand"
echo "################################################################"
_keys=$(docker run --rm "$IMAGE" genkey)
if printf '%s' "$_keys" | grep -q "^PRIVATE_KEY="; then
  ok "genkey outputs PRIVATE_KEY"
else
  fail "genkey: PRIVATE_KEY missing"
fi
if printf '%s' "$_keys" | grep -q "^PUBLIC_KEY="; then
  ok "genkey outputs PUBLIC_KEY"
else
  fail "genkey: PUBLIC_KEY missing"
fi
if printf '%s' "$_keys" | grep -qE "^PRIVATE_KEY=[A-Za-z0-9+/]{43}=$"; then
  ok "genkey PRIVATE_KEY is valid base64 (44 chars)"
else
  fail "genkey: PRIVATE_KEY format unexpected"
fi

# ===========================================================================
# Scenario: basic  (mirrors examples/basic.yaml)
# Server + 1 IPv4 client, default settings.
# ===========================================================================
echo ""
echo "################################################################"
echo "# Scenario: basic  (examples/basic.yaml)"
echo "################################################################"

RUN="$$b"
SRV="wg-basic-srv-$RUN"; CL="wg-basic-cl-$RUN"
scenario_start "wg-basic-$RUN"

_s=$(genkeys); SRV_PRIV="${_s% *}"; SRV_PUB="${_s#* }"
_c=$(genkeys); CL_PRIV="${_c% *}";  CL_PUB="${_c#* }"

docker run -d --name "$SRV" \
  --network "wg-basic-$RUN" \
  --cap-add NET_ADMIN \
  -e WG_ROLE=server \
  -e "WG_PRIVATE_KEY=$SRV_PRIV" \
  -e "WG_PEER_CLIENT_PUBKEY=$CL_PUB" \
  -e WG_PEER_CLIENT_ALLOWED_IPS=10.77.0.2/32 \
  "$IMAGE" >/dev/null
scenario_add "$SRV"

SRV_IP=$(docker inspect "$SRV" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
log "basic/server started — Docker IP: $SRV_IP"
sleep 3

docker run -d --name "$CL" \
  --network "wg-basic-$RUN" \
  --cap-add NET_ADMIN \
  -e WG_ROLE=client \
  -e "WG_PRIVATE_KEY=$CL_PRIV" \
  -e "WG_SERVER_PUBKEY=$SRV_PUB" \
  -e "WG_SERVER_ENDPOINT=${SRV_IP}:51820" \
  "$IMAGE" >/dev/null
scenario_add "$CL"
log "basic/client started"

log "Waiting 15s for handshake..."
sleep 15

ping_test "$CL" 10.77.0.1 "basic: client → server (10.77.0.1)"

# Server sees 1 active peer
NOW=$(date +%s)
HS=$(docker exec "$SRV" wg show wg0 latest-handshakes 2>/dev/null || true)
ACTIVE=$(printf '%s' "$HS" | awk -v now="$NOW" '
  NF >= 2 && $2 != "0" && (now - $2) <= 120 { c++ }
  END { print c + 0 }
')
if [ "$ACTIVE" -ge 1 ]; then
  ok "basic: server sees $ACTIVE active peer(s)"
else
  fail "basic: server sees no active peers"
fi

for _c in "$SRV" "$CL"; do
  if docker exec "$_c" wg show wg0 >/dev/null 2>&1; then
    ok "basic: $_c wg0 interface is up"
  else
    fail "basic: $_c wg0 interface is not up"
  fi
done

# Health check (mirrors Dockerfile HEALTHCHECK logic)
for _c in "$SRV" "$CL"; do
  # shellcheck disable=SC2016
  if docker exec "$_c" sh -c '
    iface="${WG_IFACE:-wg0}"
    wg show "$iface" >/dev/null 2>&1 || exit 1
    [ "$WG_ROLE" != "client" ] && exit 0
    hs=$(wg show "$iface" latest-handshakes 2>/dev/null | awk "NR==1{print \$2}")
    [ -n "$hs" ] && [ "$hs" != "0" ] && [ "$(( $(date +%s) - hs ))" -le 185 ]
  ' >/dev/null 2>&1; then
    ok "basic: $_c HEALTHCHECK passes"
  else
    fail "basic: $_c HEALTHCHECK failed"
  fi
done

scenario_cleanup

# ===========================================================================
# Scenario: multi-client  (mirrors examples/multi-client.yaml)
# Server + 2 clients, client2 uses PSK, client-to-client routing via server.
# ===========================================================================
echo ""
echo "################################################################"
echo "# Scenario: multi-client  (examples/multi-client.yaml)"
echo "################################################################"

RUN="$$m"
SRV="wg-mc-srv-$RUN"; CL1="wg-mc-cl1-$RUN"; CL2="wg-mc-cl2-$RUN"
scenario_start "wg-mc-$RUN"

_s=$(genkeys); SRV_PRIV="${_s% *}"; SRV_PUB="${_s#* }"
_1=$(genkeys); CL1_PRIV="${_1% *}"; CL1_PUB="${_1#* }"
_2=$(genkeys); CL2_PRIV="${_2% *}"; CL2_PUB="${_2#* }"
PSK=$(openssl rand -base64 32 | tr -d '\n')

POST_UP='iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT'

docker run -d --name "$SRV" \
  --network "wg-mc-$RUN" \
  --cap-add NET_ADMIN \
  --sysctl net.ipv4.ip_forward=1 \
  -e WG_ROLE=server \
  -e "WG_PRIVATE_KEY=$SRV_PRIV" \
  -e WG_ADDRESS=10.77.0.1/24 \
  -e WG_MTU=1420 \
  -e "WG_PEER_CLIENT1_PUBKEY=$CL1_PUB" \
  -e WG_PEER_CLIENT1_ALLOWED_IPS=10.77.0.2/32 \
  -e "WG_PEER_CLIENT2_PUBKEY=$CL2_PUB" \
  -e WG_PEER_CLIENT2_ALLOWED_IPS=10.77.0.3/32 \
  -e "WG_PEER_CLIENT2_PSK=$PSK" \
  -e "WG_POST_UP=$POST_UP" \
  "$IMAGE" >/dev/null
scenario_add "$SRV"

SRV_IP=$(docker inspect "$SRV" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
log "multi-client/server started — Docker IP: $SRV_IP"
sleep 3

docker run -d --name "$CL1" \
  --network "wg-mc-$RUN" \
  --cap-add NET_ADMIN \
  -e WG_ROLE=client \
  -e "WG_PRIVATE_KEY=$CL1_PRIV" \
  -e WG_ADDRESS=10.77.0.2/32 \
  -e "WG_SERVER_PUBKEY=$SRV_PUB" \
  -e "WG_SERVER_ENDPOINT=${SRV_IP}:51820" \
  -e WG_ALLOWED_IPS=10.77.0.0/24 \
  -e WG_KEEPALIVE=10 \
  "$IMAGE" >/dev/null
scenario_add "$CL1"

docker run -d --name "$CL2" \
  --network "wg-mc-$RUN" \
  --cap-add NET_ADMIN \
  -e WG_ROLE=client \
  -e "WG_PRIVATE_KEY=$CL2_PRIV" \
  -e WG_ADDRESS=10.77.0.3/32 \
  -e "WG_SERVER_PUBKEY=$SRV_PUB" \
  -e "WG_SERVER_ENDPOINT=${SRV_IP}:51820" \
  -e WG_ALLOWED_IPS=10.77.0.0/24 \
  -e "WG_PSK=$PSK" \
  -e WG_KEEPALIVE=10 \
  "$IMAGE" >/dev/null
scenario_add "$CL2"
log "multi-client/client1 and client2 started"

log "Waiting 15s for handshakes..."
sleep 15

# Connectivity
ping_test "$CL1" 10.77.0.1 "multi-client: client1 → server  (10.77.0.1)"
ping_test "$CL2" 10.77.0.1 "multi-client: client2 → server  (10.77.0.1)"
ping_test "$CL1" 10.77.0.3 "multi-client: client1 → client2 (10.77.0.3, routed via server)"
ping_test "$CL2" 10.77.0.2 "multi-client: client2 → client1 (10.77.0.2, routed via server)"

# Server sees 2 active peers
NOW=$(date +%s)
HS=$(docker exec "$SRV" wg show wg0 latest-handshakes 2>/dev/null || true)
ACTIVE=$(printf '%s' "$HS" | awk -v now="$NOW" '
  NF >= 2 && $2 != "0" && (now - $2) <= 120 { c++ }
  END { print c + 0 }
')
if [ "$ACTIVE" -ge 2 ]; then
  ok "multi-client: server sees $ACTIVE active peer(s)"
else
  fail "multi-client: server sees only $ACTIVE active peer(s), expected >= 2"
fi

# PSK on server for client2
if docker exec "$SRV" wg show wg0 preshared-keys 2>/dev/null | grep -qv "(none)"; then
  ok "multi-client: PSK configured for client2 on server"
else
  fail "multi-client: PSK not found in server preshared-keys"
fi

# MTU
SRV_MTU=$(docker exec "$SRV" ip link show wg0 2>/dev/null \
  | grep -oE 'mtu [0-9]+' | awk '{print $2}') || SRV_MTU=""
if [ "$SRV_MTU" = "1420" ]; then
  ok "multi-client: WG_MTU=1420 applied on server wg0"
else
  fail "multi-client: server MTU expected 1420, got '${SRV_MTU:-<empty>}'"
fi

for _c in "$SRV" "$CL1" "$CL2"; do
  if docker exec "$_c" wg show wg0 >/dev/null 2>&1; then
    ok "multi-client: $_c wg0 interface is up"
  else
    fail "multi-client: $_c wg0 interface is not up"
  fi
done

for _c in "$SRV" "$CL1" "$CL2"; do
  # shellcheck disable=SC2016
  if docker exec "$_c" sh -c '
    iface="${WG_IFACE:-wg0}"
    wg show "$iface" >/dev/null 2>&1 || exit 1
    [ "$WG_ROLE" != "client" ] && exit 0
    hs=$(wg show "$iface" latest-handshakes 2>/dev/null | awk "NR==1{print \$2}")
    [ -n "$hs" ] && [ "$hs" != "0" ] && [ "$(( $(date +%s) - hs ))" -le 185 ]
  ' >/dev/null 2>&1; then
    ok "multi-client: $_c HEALTHCHECK passes"
  else
    fail "multi-client: $_c HEALTHCHECK failed"
  fi
done

scenario_cleanup

# ===========================================================================
# Scenario: ipv6-endpoint  (mirrors examples/ipv6-endpoint.yaml)
# Client connects to server via IPv6 endpoint [::1]:51820.
# ===========================================================================
echo ""
echo "################################################################"
echo "# Scenario: ipv6-endpoint  (examples/ipv6-endpoint.yaml)"
echo "################################################################"

RUN="$$6"
SRV="wg-v6-srv-$RUN"; CL="wg-v6-cl-$RUN"
scenario_start "wg-v6-$RUN"

_s=$(genkeys); SRV_PRIV="${_s% *}"; SRV_PUB="${_s#* }"
_c=$(genkeys); CL_PRIV="${_c% *}";  CL_PUB="${_c#* }"

docker run -d --name "$SRV" \
  --network "wg-v6-$RUN" \
  --cap-add NET_ADMIN \
  -e WG_ROLE=server \
  -e "WG_PRIVATE_KEY=$SRV_PRIV" \
  -e "WG_PEER_CLIENT_PUBKEY=$CL_PUB" \
  -e WG_PEER_CLIENT_ALLOWED_IPS=10.77.0.2/32 \
  "$IMAGE" >/dev/null
scenario_add "$SRV"

# Resolve server IPv6 address on the Docker bridge
_raw_ipv6=$(docker inspect "$SRV" \
  --format '{{range .NetworkSettings.Networks}}{{.GlobalIPv6Address}}{{end}}')
# Accept only values that look like IPv6 (contain ':'); Docker returns
# "invalid IP" or empty string when the network has no IPv6 support.
case "$_raw_ipv6" in
  *:*) SRV_IPV6="$_raw_ipv6" ;;
  *)   SRV_IPV6="" ;;
esac
log "ipv6-endpoint/server started — IPv6: ${SRV_IPV6:-<none>}"
sleep 3

if [ -z "$SRV_IPV6" ]; then
  # Docker bridge doesn't have IPv6 enabled — skip connectivity, validate config
  log "Docker bridge has no IPv6; testing config generation only."

  docker run -d --name "$CL" \
    --network "wg-v6-$RUN" \
    --cap-add NET_ADMIN \
    -e WG_ROLE=client \
    -e "WG_PRIVATE_KEY=$CL_PRIV" \
    -e "WG_SERVER_PUBKEY=$SRV_PUB" \
    -e "WG_SERVER_ENDPOINT=[::1]:51820" \
    "$IMAGE" >/dev/null || true
  scenario_add "$CL"
  sleep 5

  CFG=$(docker exec "$CL" cat /etc/wireguard/wg0.conf 2>/dev/null || true)
  if printf '%s' "$CFG" | grep -q "Endpoint.*\[.*\]:51820"; then
    ok "ipv6-endpoint: [::1]:51820 written to client config"
  else
    fail "ipv6-endpoint: IPv6 endpoint not found in client config"
  fi
  if printf '%s' "$CFG" | grep -q "PublicKey.*=.*$SRV_PUB"; then
    ok "ipv6-endpoint: server PublicKey written to client config"
  else
    fail "ipv6-endpoint: server PublicKey not found in client config"
  fi
else
  docker run -d --name "$CL" \
    --network "wg-v6-$RUN" \
    --cap-add NET_ADMIN \
    -e WG_ROLE=client \
    -e "WG_PRIVATE_KEY=$CL_PRIV" \
    -e "WG_SERVER_PUBKEY=$SRV_PUB" \
    -e "WG_SERVER_ENDPOINT=[${SRV_IPV6}]:51820" \
    "$IMAGE" >/dev/null
  scenario_add "$CL"
  log "ipv6-endpoint/client started — endpoint [${SRV_IPV6}]:51820"

  log "Waiting 15s for handshake..."
  sleep 15

  ping_test "$CL" 10.77.0.1 "ipv6-endpoint: client → server via IPv6 transport"

  NOW=$(date +%s)
  HS=$(docker exec "$SRV" wg show wg0 latest-handshakes 2>/dev/null || true)
  ACTIVE=$(printf '%s' "$HS" | awk -v now="$NOW" '
    NF >= 2 && $2 != "0" && (now - $2) <= 120 { c++ }
    END { print c + 0 }
  ')
  if [ "$ACTIVE" -ge 1 ]; then
    ok "ipv6-endpoint: server sees $ACTIVE active peer(s) via IPv6"
  else
    fail "ipv6-endpoint: server sees no active peers"
  fi
fi

scenario_cleanup

# ===========================================================================
echo ""
echo "=================================================================="
printf   "  Result: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "=================================================================="
[ "$FAIL" -eq 0 ]
