#!/bin/sh
# Integration tests mirroring examples/*.yaml (basic, multi-client, ipv6-endpoint).
# Uses a Docker bridge network instead of host networking to run on one machine.
# Requires Docker with NET_ADMIN and kernel >= 5.6.
# Usage: sh test/integration_test.sh [IMAGE]
set -eu

IMAGE="${1:-compwire:integration-test}"
PASS=0
FAIL=0
SKIP=0

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
ok()   { printf '  [PASS] %s\n' "$*"; PASS=$(( PASS + 1 )); }
fail() { printf '  [FAIL] %s\n' "$*"; FAIL=$(( FAIL + 1 )); }
skip() { printf '  [SKIP] %s\n' "$*"; SKIP=$(( SKIP + 1 )); }

# --- Helpers ---
parse_key() { grep "^${1}=" | cut -d= -f2-; }

genkeys() {
  _out=$(docker run --rm "$IMAGE" genkey)
  _priv=$(printf '%s' "$_out" | parse_key PRIVATE_KEY)
  _pub=$(printf '%s'  "$_out" | parse_key PUBLIC_KEY)
  # A pipeline hides grep's status, so an empty key would travel into the
  # scenario and fail several steps later under an unrelated symptom.
  if [ -z "$_priv" ] || [ -z "$_pub" ]; then
    printf 'genkey produced no usable key pair:\n%s\n' "$_out" >&2
    exit 1
  fi
  printf '%s %s' "$_priv" "$_pub"
}

ping_test() {
  _from="$1" _dst="$2" _label="$3" _tries=0
  while [ "$_tries" -lt 10 ]; do
    if docker exec "$_from" ping -c 1 -W 2 "$_dst" >/dev/null 2>&1; then
      ok "$_label"
      return 0
    fi
    _tries=$(( _tries + 1 ))
    sleep 2
  done
  fail "$_label"
  docker logs "$_from" 2>&1 | tail -10 || true
}

_NET=""
_CONTAINERS=""
# Teardown asks Docker what carries the label instead of trusting a hand-kept list.
RUN_LABEL="compwire-test-run=$$"
scenario_cleanup() {
  _leftover="$(docker ps -aq --filter "label=$RUN_LABEL" 2>/dev/null || true)"
  [ -z "$_leftover" ] && [ -z "$_NET" ] && return
  log "Tearing down..."
  # Not an AND-list: as the function's last command a failing docker rm would end
  # the run under set -e, before the network is removed.
  if [ -n "$_leftover" ]; then
    # shellcheck disable=SC2086
    docker rm -f $_leftover >/dev/null 2>&1 || true
  fi
  if [ -n "$_NET" ]; then docker network rm "$_NET" >/dev/null 2>&1 || true; fi
  _CONTAINERS=""
  _NET=""
}

scenario_start() {
  _net_name="$1"; shift
  _CONTAINERS=""
  # Claimed only once it exists, or a failed create lets the EXIT trap delete
  # somebody else's network.
  docker network create "$@" "$_net_name" >/dev/null
  _NET="$_net_name"
}

# Labeled rather than listed: `docker run -d` can exit non-zero with the container
# already created, and a name recorded only on success leaves that one behind.
scenario_run() {
  _name="$1"; shift
  docker run -d --label "$RUN_LABEL" --name "$_name" "$@"
  _CONTAINERS="${_CONTAINERS:+$_CONTAINERS }$_name"
}

# Under set -e any failing docker command aborts mid-scenario, and a returning
# signal handler would resume against containers it just deleted.
final_cleanup() {
  scenario_cleanup
  # Only the image this run created, never one the caller passed in.
  [ -n "${BUILT_IMAGE:-}" ] && docker rmi "$BUILT_IMAGE" >/dev/null 2>&1
  return 0
}
trap final_cleanup EXIT
trap 'final_cleanup; exit 130' INT
trap 'final_cleanup; exit 143' TERM

# Poll the container's own HEALTHCHECK rather than re-implementing it here.
assert_healthy() {
  _c="$1" _label="$2" _waited=0
  while [ "$_waited" -lt 90 ]; do
    _state="$(docker inspect -f '{{.State.Status}}' "$_c" 2>/dev/null)" || _state=missing
    if [ "$_state" != "running" ]; then
      fail "$_label -- container is '$_state'"
      docker logs "$_c" 2>&1 | tail -15 || true
      return 0
    fi
    # docker inspect prints an empty line and fails for a container that is gone,
    # so the fallback has to replace the output rather than append to it.
    _status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$_c" 2>/dev/null)" || _status=missing
    [ -n "$_status" ] || _status=missing
    case "$_status" in
      healthy)          ok "$_label (docker health: healthy)"; return 0 ;;
      none|missing)     fail "$_label -- no healthcheck reported by docker"; return 0 ;;
    esac
    sleep 3
    _waited=$(( _waited + 3 ))
  done
  fail "$_label -- still '$_status' after ${_waited}s"
}

assert_running() {
  _c="$1" _label="$2"
  _state="$(docker inspect -f '{{.State.Status}}' "$_c" 2>/dev/null)" || _state=missing
  if [ "$_state" = "running" ]; then
    ok "$_label"
    return 0
  fi
  fail "$_label -- container is '$_state'"
  docker logs "$_c" 2>&1 | tail -15 || true
  return 1
}

# --- Build image if missing ---
BUILT_IMAGE=""
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  log "Image '$IMAGE' not found - building..."
  docker build -t "$IMAGE" "$ROOT"
  BUILT_IMAGE="$IMAGE"
fi

# --- Test: genkey subcommand ---
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

# --- Scenario: basic - server + 1 IPv4 client (examples/basic.yaml) ---
echo ""
echo "################################################################"
echo "# Scenario: basic  (examples/basic.yaml)"
echo "################################################################"

RUN="$$b"
SRV="wg-basic-srv-$RUN"; CL="wg-basic-cl-$RUN"
scenario_start "wg-basic-$RUN"

_s=$(genkeys); SRV_PRIV="${_s% *}"; SRV_PUB="${_s#* }"
_c=$(genkeys); CL_PRIV="${_c% *}";  CL_PUB="${_c#* }"

scenario_run "$SRV" \
  --network "wg-basic-$RUN" \
  --cap-add NET_ADMIN \
  -e WG_ROLE=server \
  -e "WG_PRIVATE_KEY=$SRV_PRIV" \
  -e "WG_PEER_CLIENT_PUBKEY=$CL_PUB" \
  -e WG_PEER_CLIENT_ALLOWED_IPS=10.77.0.2/32 \
  "$IMAGE" >/dev/null

SRV_IP=$(docker inspect "$SRV" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
log "basic/server started - Docker IP: $SRV_IP"
sleep 3

scenario_run "$CL" \
  --network "wg-basic-$RUN" \
  --cap-add NET_ADMIN \
  -e WG_ROLE=client \
  -e "WG_PRIVATE_KEY=$CL_PRIV" \
  -e "WG_SERVER_PUBKEY=$SRV_PUB" \
  -e "WG_SERVER_ENDPOINT=${SRV_IP}:51820" \
  "$IMAGE" >/dev/null
log "basic/client started"

log "Waiting 15s for handshake..."
sleep 15

assert_running "$SRV" "basic: server is running" || true
assert_running "$CL"  "basic: client is running" || true

ping_test "$CL" 10.77.0.1 "basic: client -> server (10.77.0.1)"

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

for _c in "$SRV" "$CL"; do
  assert_healthy "$_c" "basic: $_c HEALTHCHECK passes"
done

scenario_cleanup

# --- Scenario: multi-client - 2 clients, PSK, cross-routing (examples/multi-client.yaml) ---
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
PSK=$(docker run --rm "$IMAGE" genpsk | tr -d '\n')

POST_UP='iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT'

scenario_run "$SRV" \
  --network "wg-mc-$RUN" \
  --cap-drop ALL --cap-add NET_ADMIN \
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

SRV_IP=$(docker inspect "$SRV" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
log "multi-client/server started - Docker IP: $SRV_IP"
sleep 3

scenario_run "$CL1" \
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

scenario_run "$CL2" \
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
log "multi-client/client1 and client2 started"

log "Waiting 15s for handshakes..."
sleep 15

for _c in "$SRV" "$CL1" "$CL2"; do
  assert_running "$_c" "multi-client: $_c is running" || true
done

# Connectivity
ping_test "$CL1" 10.77.0.1 "multi-client: client1 -> server  (10.77.0.1)"
ping_test "$CL2" 10.77.0.1 "multi-client: client2 -> server  (10.77.0.1)"
ping_test "$CL1" 10.77.0.3 "multi-client: client1 -> client2 (10.77.0.3, routed via server)"
ping_test "$CL2" 10.77.0.2 "multi-client: client2 -> client1 (10.77.0.2, routed via server)"

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
if docker exec "$SRV" wg show wg0 preshared-keys 2>/dev/null \
   | grep -F "$CL2_PUB" | grep -qv "(none)"; then
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
  assert_healthy "$_c" "multi-client: $_c HEALTHCHECK passes"
done

scenario_cleanup

# --- Scenario: ipv6-endpoint - client via [::1]:51820 (examples/ipv6-endpoint.yaml) ---
echo ""
echo "################################################################"
echo "# Scenario: ipv6-endpoint  (examples/ipv6-endpoint.yaml)"
echo "################################################################"

RUN="$$6"
SRV="wg-v6-srv-$RUN"; CL="wg-v6-cl-$RUN"
# A plain bridge has no IPv6 address at all, which drops this scenario into the
# config-only branch below - the one thing the unit tests already cover.
if ! scenario_start "wg-v6-$RUN" --ipv6 --subnet fd00:c0de:1::/64; then
  log "Daemon rejected an IPv6 network; falling back to IPv4-only."
  scenario_start "wg-v6-$RUN"
fi

_s=$(genkeys); SRV_PRIV="${_s% *}"; SRV_PUB="${_s#* }"
_c=$(genkeys); CL_PRIV="${_c% *}";  CL_PUB="${_c#* }"

scenario_run "$SRV" \
  --network "wg-v6-$RUN" \
  --cap-add NET_ADMIN \
  -e WG_ROLE=server \
  -e "WG_PRIVATE_KEY=$SRV_PRIV" \
  -e "WG_PEER_CLIENT_PUBKEY=$CL_PUB" \
  -e WG_PEER_CLIENT_ALLOWED_IPS=10.77.0.2/32 \
  "$IMAGE" >/dev/null

# Resolve server IPv6 address on the Docker bridge
_raw_ipv6=$(docker inspect "$SRV" \
  --format '{{range .NetworkSettings.Networks}}{{.GlobalIPv6Address}}{{end}}')
# Accept only values that look like IPv6 (contain ':'); Docker returns
# "invalid IP" or empty string when the network has no IPv6 support.
case "$_raw_ipv6" in
  *:*) SRV_IPV6="$_raw_ipv6" ;;
  *)   SRV_IPV6="" ;;
esac
log "ipv6-endpoint/server started - IPv6: ${SRV_IPV6:-<none>}"
sleep 3

if [ -z "$SRV_IPV6" ]; then
  # Docker bridge doesn't have IPv6 enabled - skip connectivity, validate config
  log "Docker bridge has no IPv6; testing config generation only."

  scenario_run "$CL" \
    --network "wg-v6-$RUN" \
    --cap-add NET_ADMIN \
    -e WG_ROLE=client \
    -e "WG_PRIVATE_KEY=$CL_PRIV" \
    -e "WG_SERVER_PUBKEY=$SRV_PUB" \
    -e "WG_SERVER_ENDPOINT=[::1]:51820" \
    "$IMAGE" >/dev/null || true
  sleep 5

  CFG=$(docker exec "$CL" cat /etc/wireguard/wg0.conf 2>/dev/null || true)
  if printf '%s' "$CFG" | grep -q "Endpoint.*\[.*\]:51820"; then
    ok "ipv6-endpoint: [::1]:51820 written to client config"
  else
    fail "ipv6-endpoint: IPv6 endpoint not found in client config"
  fi
  # The transport itself stays untested here, and a PASS would claim otherwise.
  skip "ipv6-endpoint: IPv6 transport (this host's Docker bridge has no IPv6)"
else
  scenario_run "$CL" \
    --network "wg-v6-$RUN" \
    --cap-add NET_ADMIN \
    -e WG_ROLE=client \
    -e "WG_PRIVATE_KEY=$CL_PRIV" \
    -e "WG_SERVER_PUBKEY=$SRV_PUB" \
    -e "WG_SERVER_ENDPOINT=[${SRV_IPV6}]:51820" \
    "$IMAGE" >/dev/null
  log "ipv6-endpoint/client started - endpoint [${SRV_IPV6}]:51820"

  log "Waiting 15s for handshake..."
  sleep 15

  assert_running "$SRV" "ipv6-endpoint: server is running" || true
  assert_running "$CL"  "ipv6-endpoint: client is running" || true

  ping_test "$CL" 10.77.0.1 "ipv6-endpoint: client -> server via IPv6 transport"

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

# --- Test: genpsk subcommand ---
echo ""
echo "################################################################"
echo "# genpsk subcommand"
echo "################################################################"
_psk=$(docker run --rm "$IMAGE" genpsk)
if printf '%s' "$_psk" | grep -qE "^[A-Za-z0-9+/]{43}=$"; then
  ok "genpsk outputs a 44-character base64 key"
else
  fail "genpsk: unexpected output '$_psk'"
fi

_qk=$(genkeys); _qpriv="${_qk% *}"
_srv=$(genkeys); _srvpub="${_srv#* }"

# Exit code alone would also pass against an image that fails for any reason at
# all, and this ran green on a host where every tunnel scenario failed.
_bogus=$(docker run --rm "$IMAGE" bogus-subcommand 2>&1) && _bogus_rc=0 || _bogus_rc=$?
if [ "$_bogus_rc" -ne 0 ] && printf '%s' "$_bogus" | grep -q "Unknown argument: 'bogus-subcommand'"; then
  ok "unknown subcommand fails"
else
  fail "unknown subcommand should fail and name the argument (exit $_bogus_rc)"
fi

# --- Test: graceful shutdown ---
# A client sits in the handshake wait loop for 15s after start.
echo ""
echo "################################################################"
echo "# Graceful shutdown during the client handshake window"
echo "################################################################"
RUN="$$s"
scenario_start "wg-stop-$RUN"
STOPC="wg-stop-client-$RUN"
scenario_run "$STOPC" \
  --network "wg-stop-$RUN" \
  --cap-add NET_ADMIN \
  -e WG_ROLE=client \
  -e "WG_PRIVATE_KEY=$_qpriv" \
  -e "WG_SERVER_PUBKEY=$_srvpub" \
  -e WG_SERVER_ENDPOINT=192.0.2.1:51820 \
  "$IMAGE" >/dev/null
sleep 2
# A container that died on its own would pass the timing and exit-code checks
# below without ever exercising the signal path.
if ! assert_running "$STOPC" "shutdown: client is up before the signal"; then
  skip "shutdown: timing, exit code and cleanup count (nothing was signaled)"
else
_t0=$(date +%s)
docker stop -t 10 "$STOPC" >/dev/null 2>&1 || true
_elapsed=$(( $(date +%s) - _t0 ))
_code=$(docker inspect -f '{{.State.ExitCode}}' "$STOPC" 2>/dev/null || echo "?")
if [ "$_elapsed" -lt 8 ]; then
  ok "shutdown: container exits promptly (${_elapsed}s)"
else
  fail "shutdown: container needed ${_elapsed}s, i.e. it was SIGKILLed"
fi
# 143 exactly: a crash during the stop window also produces "not 137".
if [ "$_code" = "143" ]; then
  ok "shutdown: exit code 143 (clean SIGTERM path)"
else
  fail "shutdown: exit code $_code, expected 143"
fi
_shutdowns=$(docker logs "$STOPC" 2>&1 | grep -c "Shutting down" || true)
if [ "$_shutdowns" = "1" ]; then
  ok "shutdown: cleanup runs exactly once"
else
  fail "shutdown: cleanup ran $_shutdowns times"
fi
fi
scenario_cleanup

# --- Test: SIGTERM while the entrypoint is still validating ---
# As PID 1 the shell discards every signal it has no trap for. Only reachable at
# PID 1, which is why no unit test can cover it.
echo ""
echo "################################################################"
echo "# SIGTERM during validation"
echo "################################################################"
RUN="$$v"
scenario_start "wg-val-$RUN"
VALC="wg-val-server-$RUN"
# WG_ADDRESS and not a peer's AllowedIPs: peers are validated past the second pair
# of traps. The dedup check is quadratic, so a few thousand entries park the script
# in the early window for a few seconds.
_many=$(awk 'BEGIN { for (i = 0; i < 3000; i++) printf "%s10.%d.%d.0/24", (i ? "," : ""), int(i / 256), i % 256 }')
scenario_run "$VALC" \
  --network "wg-val-$RUN" \
  --cap-add NET_ADMIN \
  -e WG_ROLE=server \
  -e "WG_PRIVATE_KEY=$_qpriv" \
  -e "WG_ADDRESS=$_many" \
  "$IMAGE" >/dev/null
# The log, not a fixed sleep: "running" is also true once wg-quick holds the
# interface, where a signal is deferred by design.
_w=0
while [ "$_w" -lt 50 ]; do
  [ "$(docker inspect -f '{{.State.Running}}' "$VALC" 2>/dev/null)" = "true" ] && break
  sleep 0.1; _w=$(( _w + 1 ))
done
if docker logs "$VALC" 2>&1 | grep -q "Starting WireGuard"; then
  fail "validation signal: validation was already over before anything was signaled"
  skip "validation signal: timing and exit code (nothing was signaled)"
elif ! assert_running "$VALC" "validation signal: container is still validating"; then
  skip "validation signal: timing and exit code (nothing was signaled)"
else
  _t0=$(date +%s)
  docker stop -t 10 "$VALC" >/dev/null 2>&1 || true
  _elapsed=$(( $(date +%s) - _t0 ))
  _code=$(docker inspect -f '{{.State.ExitCode}}' "$VALC" 2>/dev/null || echo "?")
  # Without the trap this is 10s and 137, because the signal never arrives.
  if [ "$_elapsed" -lt 8 ]; then
    ok "validation signal: container exits promptly (${_elapsed}s)"
  else
    fail "validation signal: container needed ${_elapsed}s, i.e. it was SIGKILLed"
  fi
  if [ "$_code" = "143" ]; then
    ok "validation signal: exit code 143"
  else
    fail "validation signal: exit code $_code, expected 143"
  fi
  # Nothing was built yet, so nothing may be announced as torn down.
  if docker logs "$VALC" 2>&1 | grep -q "Shutting down"; then
    fail "validation signal: a teardown was announced for a tunnel that never existed"
  else
    ok "validation signal: no teardown is announced"
  fi
fi
scenario_cleanup

# --- Scenario: WG_DNS ---
# resolvconf refuses to touch the resolv.conf Docker mounts without the marker.
echo ""
echo "################################################################"
echo "# Scenario: WG_DNS  (no example sets it)"
echo "################################################################"

RUN="$$d"
SRV="wg-dns-srv-$RUN"
scenario_start "wg-dns-$RUN"

_s=$(genkeys); SRV_PRIV="${_s% *}"
_c=$(genkeys); CL_PUB="${_c#* }"

scenario_run "$SRV" \
  --network "wg-dns-$RUN" \
  --cap-add NET_ADMIN \
  -e WG_ROLE=server \
  -e "WG_PRIVATE_KEY=$SRV_PRIV" \
  -e WG_DNS=1.1.1.1 \
  -e "WG_PEER_CLIENT_PUBKEY=$CL_PUB" \
  -e WG_PEER_CLIENT_ALLOWED_IPS=10.77.0.2/32 \
  "$IMAGE" >/dev/null
sleep 5

if assert_running "$SRV" "WG_DNS: server stays up"; then
  assert_healthy "$SRV" "WG_DNS: server HEALTHCHECK passes"
  if docker exec "$SRV" grep -q "nameserver 1.1.1.1" /etc/resolv.conf 2>/dev/null; then
    ok "WG_DNS: resolvconf applied the tunnel nameserver"
  else
    fail "WG_DNS: 1.1.1.1 missing from /etc/resolv.conf"
    docker exec "$SRV" cat /etc/resolv.conf 2>&1 | head -5 || true
  fi
  # openresolv keeps its subscriber list in /run, which a SIGKILL leaves behind
  # while Docker restores its own resolv.conf.
  docker kill -s KILL "$SRV" >/dev/null 2>&1 || true
  docker start "$SRV" >/dev/null 2>&1 || true
  sleep 5
  if docker exec "$SRV" grep -q "nameserver 1.1.1.1" /etc/resolv.conf 2>/dev/null; then
    ok "WG_DNS: it is applied again after a hard kill and restart"
  else
    fail "WG_DNS: 1.1.1.1 missing from /etc/resolv.conf after a restart"
    docker exec "$SRV" cat /etc/resolv.conf 2>&1 | head -5 || true
  fi
else
  skip "WG_DNS: healthcheck and resolv.conf (server is not running)"
fi

scenario_cleanup

# --- Scenario: hardened - the capability set every example ships ---
echo ""
echo "################################################################"
echo "# Scenario: hardened  (cap_drop ALL)"
echo "################################################################"

# Every compose file runs the image this way; above only the multi-client server does.
RUN="$$h"
SRV="wg-hard-srv-$RUN"; CL="wg-hard-cl-$RUN"
scenario_start "wg-hard-$RUN"

_s=$(genkeys); SRV_PRIV="${_s% *}"; SRV_PUB="${_s#* }"
_c=$(genkeys); CL_PRIV="${_c% *}";  CL_PUB="${_c#* }"
PSK=$(docker run --rm "$IMAGE" genpsk)

HARDENED="--cap-drop ALL --cap-add NET_ADMIN"

# shellcheck disable=SC2086
scenario_run "$SRV" \
  --network "wg-hard-$RUN" \
  $HARDENED \
  -e WG_ROLE=server \
  -e "WG_PRIVATE_KEY=$SRV_PRIV" \
  -e "WG_PEER_CLIENT_PUBKEY=$CL_PUB" \
  -e WG_PEER_CLIENT_ALLOWED_IPS=10.77.0.2/32 \
  -e "WG_PEER_CLIENT_PSK=$PSK" \
  "$IMAGE" >/dev/null

SRV_IP=$(docker inspect "$SRV" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
log "hardened/server started - Docker IP: $SRV_IP"
sleep 3

# shellcheck disable=SC2086
scenario_run "$CL" \
  --network "wg-hard-$RUN" \
  $HARDENED \
  -e WG_ROLE=client \
  -e "WG_PRIVATE_KEY=$CL_PRIV" \
  -e "WG_SERVER_PUBKEY=$SRV_PUB" \
  -e "WG_SERVER_ENDPOINT=${SRV_IP}:51820" \
  -e "WG_PSK=$PSK" \
  "$IMAGE" >/dev/null
log "hardened/client started"

log "Waiting 15s for handshake..."
sleep 15

assert_running "$SRV" "hardened: server is running" || true
if assert_running "$CL" "hardened: client is running"; then
  assert_healthy "$CL" "hardened: client HEALTHCHECK passes"
  NOW=$(date +%s)
  HS=$(docker exec "$CL" wg show wg0 latest-handshakes 2>/dev/null || true)
  ACTIVE=$(printf '%s' "$HS" | awk -v now="$NOW" '
    NF >= 2 && $2 != "0" && (now - $2) <= 120 { c++ }
    END { print c+0 }')
  if [ "$ACTIVE" -ge 1 ]; then
    ok "hardened: tunnel comes up under cap_drop ALL"
  else
    fail "hardened: no handshake under the documented capability set"
    docker logs "$CL" 2>&1 | tail -10 || true
  fi
  # The shutdown path touches /run and /etc/wireguard, which is where a missing
  # capability would surface late rather than at start.
  docker stop "$CL" >/dev/null 2>&1 || true
  if [ "$(docker inspect "$CL" --format '{{.State.ExitCode}}' 2>/dev/null)" = "143" ]; then
    ok "hardened: the client shuts down cleanly on SIGTERM"
  else
    fail "hardened: SIGTERM did not reach a clean shutdown"
    docker logs "$CL" 2>&1 | tail -10 || true
  fi
else
  skip "hardened: handshake and shutdown (client is not running)"
fi

scenario_cleanup

echo ""
echo "=================================================================="
printf   "  Result: %d passed, %d failed, %d skipped\n" "$PASS" "$FAIL" "$SKIP"
echo "=================================================================="
[ "$FAIL" -eq 0 ]
