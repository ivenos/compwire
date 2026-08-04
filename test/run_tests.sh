#!/bin/sh
# Tests run without Docker or a WireGuard kernel module.
# All wg / wg-quick calls are mocked; only config generation is verified.
set -eu

PASS=0
FAIL=0
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/entrypoint.sh"

# validate_wg_key enforces 44-char base64 keys - pad distinctive prefixes to that shape.
fake_key() { _fk="$1"; while [ "${#_fk}" -lt 43 ]; do _fk="${_fk}A"; done; printf '%s=' "$_fk"; }
K_PRIV="$(fake_key FAKEPRIV123)"
K_PRIV2="$(fake_key FAKEPRIVUNIQUE)"
K_PRIVFILE="$(fake_key PRIVFF)"
K_SRVPUB="$(fake_key SRVPUB)"
K_BERLIN="$(fake_key BERLINP)"
K_NUM="$(fake_key NUMERICP)"
K_STATIC="$(fake_key STATICP)"
K_ROAM="$(fake_key ROAMP)"
K_PSK="$(fake_key FAKEPSK1)"
K_PSKFILE="$(fake_key FAKEPSKFF)"
K_CLPSK="$(fake_key CLPSK)"
K_CLPSKFILE="$(fake_key CLPSKFF)"

ok()   { echo "  [PASS] $*"; PASS=$(( PASS + 1 )); }
fail() { echo "  [FAIL] $*"; FAIL=$(( FAIL + 1 )); }

assert_contains() {
  label="$1"; pattern="$2"; file="$3"
  if [ ! -f "$file" ]; then
    fail "$label -- $file was not created"
    return 0
  fi
  if grep -qF "$pattern" "$file"; then
    ok "$label"
  else
    fail "$label -- '$pattern' not found in $file"
    echo "--- Contents of $file ---"; cat "$file" || true; echo "-------------------------"
  fi
}

assert_not_contains() {
  label="$1"; pattern="$2"; file="$3"
  # Without this the missing file makes grep fail and the assertion reports PASS.
  if [ ! -f "$file" ]; then
    fail "$label -- $file was not created"
    return 0
  fi
  if ! grep -qF "$pattern" "$file"; then
    ok "$label"
  else
    fail "$label -- '$pattern' should NOT be in $file"
  fi
}

assert_stdout_contains() {
  label="$1"; pattern="$2"
  if grep -qF "$pattern" "$TMPDIR_TEST/stdout.txt"; then
    ok "$label"
  else
    fail "$label -- '$pattern' not in output"
    echo "--- Output ---"; cat "$TMPDIR_TEST/stdout.txt" || true; echo "--------------"
  fi
}

setup_mock_env() {
  TMPDIR_TEST="$(mktemp -d)"
  MOCK_BIN="$TMPDIR_TEST/bin"
  mkdir -p "$MOCK_BIN"

  cat > "$MOCK_BIN/wg" <<'EOF'
#!/bin/sh
case "${1:-}" in
  genkey)
    echo "FAKEPRIV1234567890123456789012345678901234="
    ;;
  pubkey)
    input="$(cat)"
    printf 'FAKEPUB_%s\n' "$(printf '%s' "$input" | head -c 8 | od -A n -t x1 | tr -d ' \n')"
    ;;
  show)
    shift
    shift 2>/dev/null || true
    case "${1:-}" in
      latest-handshakes) printf 'FAKEPUB_abc123 %s\n' "$(date +%s)" ;;
      listen-port)       echo "51820" ;;
      public-key)        printf '%s\n' "${MOCK_IFACE_PUBKEY:-}" ;;
      *)                 exit 0 ;;
    esac
    ;;
  genpsk)
    echo "FAKEPSKGENERATED567890123456789012345678901="
    ;;
esac
EOF
  chmod +x "$MOCK_BIN/wg"

  printf '#!/bin/sh\ncat >/dev/null\necho MOCK_QR_OUTPUT\n' > "$MOCK_BIN/qrencode"
  chmod +x "$MOCK_BIN/qrencode"

  for cmd in wg-quick sysctl iptables ip6tables resolvconf; do
    printf '#!/bin/sh\nexit 0\n' > "$MOCK_BIN/$cmd"
    chmod +x "$MOCK_BIN/$cmd"
  done

  # `ip link show dev` must report "no such interface", or the entrypoint takes
  # its stale-interface path. MOCK_IFACE_EXISTS=1 flips that for the tests that
  # exercise it.
  cat > "$MOCK_BIN/ip" <<'EOF'
#!/bin/sh
case "$*" in
  "link show dev "*) [ "${MOCK_IFACE_EXISTS:-0}" = "1" ] && exit 0; exit 1 ;;
  "link del "*)      echo "MOCK ip $*" ;;
esac
exit 0
EOF
  chmod +x "$MOCK_BIN/ip"

  # sleep exits immediately so the sleep infinity & wait loop terminates
  printf '#!/bin/sh\nexit 0\n' > "$MOCK_BIN/sleep"
  chmod +x "$MOCK_BIN/sleep"

  ORIG_PATH="$PATH"
  export PATH="$MOCK_BIN:$PATH"
  export WG_CONFIG_DIR="$TMPDIR_TEST/etc/wireguard"
  mkdir -p "$WG_CONFIG_DIR"
}

cleanup_mock_env() {
  rm -rf "$TMPDIR_TEST"
  # Without this PATH accumulates a dead mock dir per test.
  PATH="$ORIG_PATH"; export PATH
}

# Patch config path, replace sleep-infinity with exit 0, then run.
# Takes KEY=VALUE pairs as separate arguments, so values may contain spaces.
run_entrypoint() {
  _iface=wg0
  for _kv in "$@"; do
    case "$_kv" in WG_IFACE=*) _iface="${_kv#WG_IFACE=}" ;; esac
  done
  CONFIG_FILE="$WG_CONFIG_DIR/${_iface}.conf"
  PATCHED="$TMPDIR_TEST/entrypoint_patched.sh"
  sed "s|/etc/wireguard|$WG_CONFIG_DIR|g; s|/etc/resolv.conf|$TMPDIR_TEST/resolv.conf|g" "$SCRIPT" > "$PATCHED"
  sed -i '/sleep infinity/,/wait/c\exit 0' "$PATCHED"
  chmod +x "$PATCHED"
  env -i PATH="$PATH" "MOCK_IFACE_EXISTS=${MOCK_IFACE_EXISTS:-0}" "$@" \
    sh "$PATCHED" > "$TMPDIR_TEST/stdout.txt" 2>&1
}

# Same, but invokes the script with a subcommand argument.
run_subcommand() {
  _arg="$1"; shift
  CONFIG_FILE="$WG_CONFIG_DIR/wg0.conf"
  PATCHED="$TMPDIR_TEST/entrypoint_patched.sh"
  sed "s|/etc/wireguard|$WG_CONFIG_DIR|g; s|/etc/resolv.conf|$TMPDIR_TEST/resolv.conf|g" "$SCRIPT" > "$PATCHED"
  sed -i '/sleep infinity/,/wait/c\exit 0' "$PATCHED"
  env -i PATH="$PATH" "MOCK_IFACE_EXISTS=${MOCK_IFACE_EXISTS:-0}" "$@" \
    sh "$PATCHED" "$_arg" > "$TMPDIR_TEST/stdout.txt" 2>&1
}

echo ""
echo "=== Test 1: Server - no peers (warning, interface block written) ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" || true
assert_contains     "Interface Address default"  "Address    = 10.77.0.1/24"  "$CONFIG_FILE"
assert_contains     "Interface ListenPort"        "ListenPort = 51820"          "$CONFIG_FILE"
assert_contains     "PrivateKey written"          "PrivateKey = $K_PRIV"    "$CONFIG_FILE"
if grep -q "WARNING" "$TMPDIR_TEST/stdout.txt" 2>/dev/null; then
  ok "No-peers warning produced"
else
  fail "Should warn when no peers are configured"
fi
cleanup_mock_env

echo ""
echo "=== Test 2: Server - single named peer ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_PEER_BERLIN_PUBKEY=$K_BERLIN" WG_PEER_BERLIN_ALLOWED_IPS=10.77.0.2/32 || true
assert_contains "Peer block present"   "[Peer]"                              "$CONFIG_FILE"
assert_contains "Peer PublicKey"       "PublicKey           = $K_BERLIN"     "$CONFIG_FILE"
assert_contains "Peer AllowedIPs"      "AllowedIPs          = 10.77.0.2/32"  "$CONFIG_FILE"
assert_not_contains "No PresharedKey without PSK" "PresharedKey" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 3: Server - multiple peers (named + numbered) ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_PEER_BERLIN_PUBKEY=$K_BERLIN" WG_PEER_BERLIN_ALLOWED_IPS=10.77.0.2/32,192.168.10.0/24 "WG_PEER_0_PUBKEY=$K_NUM" WG_PEER_0_ALLOWED_IPS=10.77.0.3/32 || true
assert_contains "Berlin peer present"   "PublicKey           = $K_BERLIN"              "$CONFIG_FILE"
assert_contains "Berlin AllowedIPs"     "AllowedIPs          = 10.77.0.2/32,192.168.10.0/24" "$CONFIG_FILE"
assert_contains "Numbered peer present" "PublicKey           = $K_NUM"             "$CONFIG_FILE"
assert_contains "Numbered AllowedIPs"   "AllowedIPs          = 10.77.0.3/32"           "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 4: Server - peer with inline PSK ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_PEER_BERLIN_PUBKEY=$K_BERLIN" WG_PEER_BERLIN_ALLOWED_IPS=10.77.0.2/32 "WG_PEER_BERLIN_PSK=$K_PSK" || true
assert_contains "PSK in peer block"    "PresharedKey        = $K_PSK"  "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 5: Server - peer PSK from file ==="
setup_mock_env
echo "$K_PSKFILE" > "$TMPDIR_TEST/peer_psk.txt"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_PEER_BERLIN_PUBKEY=$K_BERLIN" WG_PEER_BERLIN_ALLOWED_IPS=10.77.0.2/32 "WG_PEER_BERLIN_PSK_FILE=$TMPDIR_TEST/peer_psk.txt" || true
assert_contains "PSK from file in config" "PresharedKey        = $K_PSKFILE" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 6: Server - missing ALLOWED_IPS for peer -> error ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_PEER_BERLIN_PUBKEY=$K_BERLIN"; then
  fail "Missing ALLOWED_IPS should fail"
else
  ok "Missing ALLOWED_IPS fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 7: Client - minimal config ==="
setup_mock_env
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" WG_SERVER_ENDPOINT=1.2.3.4:51820 || true
assert_contains "Interface Address default"     "Address    = 10.77.0.2/24"           "$CONFIG_FILE"
assert_contains "Server PublicKey"              "PublicKey           = $K_SRVPUB"      "$CONFIG_FILE"
assert_contains "Endpoint set"                  "Endpoint            = 1.2.3.4:51820"  "$CONFIG_FILE"
assert_contains "PersistentKeepalive default"   "PersistentKeepalive = 25"             "$CONFIG_FILE"
assert_contains "AllowedIPs default"            "AllowedIPs          = 10.77.0.1/32"  "$CONFIG_FILE"
assert_not_contains "No PresharedKey by default" "PresharedKey"                        "$CONFIG_FILE"
assert_not_contains "No ListenPort without WG_PORT (client)" "ListenPort"             "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 8: Client - custom AllowedIPs and port ==="
setup_mock_env
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" WG_SERVER_ENDPOINT=1.2.3.4:51820 WG_ALLOWED_IPS=0.0.0.0/0 WG_PORT=12345 || true
assert_contains "Custom AllowedIPs"   "AllowedIPs          = 0.0.0.0/0"  "$CONFIG_FILE"
assert_contains "Custom port"         "ListenPort = 12345"                "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 9: Client - with inline PSK ==="
setup_mock_env
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" WG_SERVER_ENDPOINT=1.2.3.4:51820 "WG_PSK=$K_CLPSK" || true
assert_contains "Client PSK present"  "PresharedKey        = $K_CLPSK"  "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 10: Client - PSK from file ==="
setup_mock_env
echo "$K_CLPSKFILE" > "$TMPDIR_TEST/client_psk.txt"
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" WG_SERVER_ENDPOINT=1.2.3.4:51820 "WG_PSK_FILE=$TMPDIR_TEST/client_psk.txt" || true
assert_contains "Client PSK from file" "PresharedKey        = $K_CLPSKFILE" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 11: WG_PRIVATE_KEY_FILE ==="
setup_mock_env
echo "$K_PRIVFILE" > "$TMPDIR_TEST/privkey.txt"
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY_FILE=$TMPDIR_TEST/privkey.txt" "WG_SERVER_PUBKEY=$K_SRVPUB" WG_SERVER_ENDPOINT=1.2.3.4:51820 || true
assert_contains "PrivateKey loaded from file" "PrivateKey = $K_PRIVFILE" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 12: genkey subcommand ==="
setup_mock_env
OUTPUT="$(sh "$SCRIPT" genkey 2>&1)"
if printf '%s' "$OUTPUT" | grep -q "^PRIVATE_KEY="; then
  ok "genkey outputs PRIVATE_KEY"
else
  fail "genkey should output PRIVATE_KEY"
fi
if printf '%s' "$OUTPUT" | grep -q "^PUBLIC_KEY="; then
  ok "genkey outputs PUBLIC_KEY"
else
  fail "genkey should output PUBLIC_KEY"
fi
cleanup_mock_env

echo ""
echo "=== Test 13: Missing required variables -> exit != 0 ==="
setup_mock_env
if run_entrypoint "WG_PRIVATE_KEY=$K_PRIV"; then
  fail "Missing WG_ROLE should fail"
else
  ok "Missing WG_ROLE fails correctly"
fi
if run_entrypoint WG_ROLE=server; then
  fail "Missing WG_PRIVATE_KEY should fail"
else
  ok "Missing WG_PRIVATE_KEY fails correctly"
fi
if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" WG_SERVER_ENDPOINT=1.2.3.4:51820; then
  fail "Missing WG_SERVER_PUBKEY should fail"
else
  ok "Missing WG_SERVER_PUBKEY fails correctly"
fi
if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB"; then
  fail "Missing WG_SERVER_ENDPOINT should fail"
else
  ok "Missing WG_SERVER_ENDPOINT fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 14: Invalid WG_PORT -> exit != 0 ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_PORT=abc; then
  fail "Non-numeric WG_PORT should fail"
else
  ok "Non-numeric WG_PORT fails correctly"
fi
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_PORT=99999; then
  fail "WG_PORT out of range should fail"
else
  ok "WG_PORT out of range fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 15: Invalid WG_ADDRESS (IPv4) -> exit != 0 ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=notanip/24; then
  fail "Non-numeric IP should fail"
else
  ok "Non-numeric IP in WG_ADDRESS fails correctly"
fi
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=10.0.0.1/99; then
  fail "Prefix > 32 should fail"
else
  ok "Prefix > 32 in WG_ADDRESS fails correctly"
fi
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=10.0.0.1; then
  fail "WG_ADDRESS without prefix should fail"
else
  ok "WG_ADDRESS without CIDR prefix fails correctly"
fi
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=256.0.0.1/24; then
  fail "Octet > 255 should fail"
else
  ok "Octet > 255 in WG_ADDRESS fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 16: Invalid WG_SERVER_ENDPOINT format -> exit != 0 ==="
setup_mock_env
if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" WG_SERVER_ENDPOINT=example.com; then
  fail "Endpoint without port should fail"
else
  ok "Endpoint without port fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 17: Config file permissions = 600 ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" || true
PERMS="$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || stat -f '%Lp' "$CONFIG_FILE" 2>/dev/null)"
if [ "$PERMS" = "600" ]; then
  ok "Config file has permissions 600"
else
  fail "Config file permissions are $PERMS, expected 600"
fi
cleanup_mock_env

echo ""
echo "=== Test 18: PrivateKey is written to config ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV2" || true
assert_contains "PrivateKey in config" "PrivateKey = $K_PRIV2" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 19: Client - custom WG_KEEPALIVE ==="
setup_mock_env
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" WG_SERVER_ENDPOINT=1.2.3.4:51820 WG_KEEPALIVE=60 || true
assert_contains "Custom keepalive" "PersistentKeepalive = 60" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 20: Invalid WG_IFACE -> exit != 0 ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_IFACE=wg0/bad; then
  fail "Invalid WG_IFACE should fail"
else
  ok "Invalid WG_IFACE fails correctly"
fi
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_IFACE=wg0;evil"; then
  fail "WG_IFACE with semicolon should fail"
else
  ok "WG_IFACE with semicolon fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 21: Server - empty peer pubkey -> error ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_PEER_BERLIN_PUBKEY= WG_PEER_BERLIN_ALLOWED_IPS=10.77.0.2/32; then
  fail "Empty peer PUBKEY should fail"
else
  ok "Empty peer PUBKEY fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 22: DNS written to [Interface] ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_DNS=1.1.1.1,8.8.8.8 || true
assert_contains "DNS line present"  "DNS        = 1.1.1.1,8.8.8.8"  "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 23: MTU written to [Interface] ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_MTU=1420 || true
assert_contains "MTU line present"  "MTU        = 1420"  "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 24: Table written to [Interface] ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_TABLE=off || true
assert_contains "Table=off present"   "Table      = off"  "$CONFIG_FILE"
cleanup_mock_env
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_TABLE=auto || true
assert_contains "Table=auto present"  "Table      = auto" "$CONFIG_FILE"
cleanup_mock_env
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_TABLE=200 || true
assert_contains "Table=200 present"   "Table      = 200"  "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 25: Hooks written to [Interface] ==="
setup_mock_env
# Hook values must be single words: run_entrypoint passes $1 unquoted.
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_PRE_UP=do-preup WG_POST_UP=do-postup WG_PRE_DOWN=do-predown WG_POST_DOWN=do-postdown || true
assert_contains "PreUp present"    "PreUp      = do-preup"    "$CONFIG_FILE"
assert_contains "PostUp present"   "PostUp     = do-postup"   "$CONFIG_FILE"
assert_contains "PreDown present"  "PreDown    = do-predown"  "$CONFIG_FILE"
assert_contains "PostDown present" "PostDown   = do-postdown" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 26: Hooks absent when not set ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" || true
assert_not_contains "No PreUp"    "PreUp"    "$CONFIG_FILE"
assert_not_contains "No PostUp"   "PostUp"   "$CONFIG_FILE"
assert_not_contains "No PreDown"  "PreDown"  "$CONFIG_FILE"
assert_not_contains "No PostDown" "PostDown" "$CONFIG_FILE"
assert_not_contains "No DNS"      "DNS"      "$CONFIG_FILE"
assert_not_contains "No MTU"      "MTU"      "$CONFIG_FILE"
assert_not_contains "No Table"    "Table"    "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 27: IPv6 WG_ADDRESS accepted ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=fd00::1/64 || true
assert_contains "IPv6 address in config" "Address    = fd00::1/64" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 28: Dual-stack WG_ADDRESS (IPv4 + IPv6) ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=10.77.0.1/24,fd00::1/64 || true
assert_contains "Dual-stack address in config" "Address    = 10.77.0.1/24,fd00::1/64" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 29: Invalid IPv6 WG_ADDRESS -> exit != 0 ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=gggg::1/64; then
  fail "Invalid IPv6 hex chars should fail"
else
  ok "Invalid IPv6 characters in WG_ADDRESS fails correctly"
fi
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=fd00::1/129; then
  fail "IPv6 prefix > 128 should fail"
else
  ok "IPv6 prefix > 128 fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 30: Server peer - Endpoint ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_PEER_STATIC_PUBKEY=$K_STATIC" WG_PEER_STATIC_ALLOWED_IPS=10.77.0.5/32 WG_PEER_STATIC_ENDPOINT=203.0.113.5:51820 || true
assert_contains "Peer Endpoint present" "Endpoint            = 203.0.113.5:51820" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 31: Server peer - Endpoint without port -> error ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_PEER_STATIC_PUBKEY=$K_STATIC" WG_PEER_STATIC_ALLOWED_IPS=10.77.0.5/32 WG_PEER_STATIC_ENDPOINT=203.0.113.5; then
  fail "Peer Endpoint without port should fail"
else
  ok "Peer Endpoint without port fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 32: Server peer - PersistentKeepalive ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_PEER_ROAM_PUBKEY=$K_ROAM" WG_PEER_ROAM_ALLOWED_IPS=10.77.0.6/32 WG_PEER_ROAM_KEEPALIVE=30 || true
assert_contains "Peer Keepalive present" "PersistentKeepalive = 30" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 33: Invalid WG_MTU -> exit != 0 ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_MTU=abc; then
  fail "Non-numeric MTU should fail"
else
  ok "Non-numeric MTU fails correctly"
fi
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_MTU=100; then
  fail "MTU < 1280 should fail"
else
  ok "MTU below minimum fails correctly"
fi
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_MTU=9001; then
  fail "MTU > 9000 should fail"
else
  ok "MTU above maximum fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 34: Invalid WG_TABLE -> exit != 0 ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_TABLE=invalid; then
  fail "Non-keyword, non-numeric Table should fail"
else
  ok "Invalid WG_TABLE fails correctly"
fi
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_TABLE=0; then
  fail "Table=0 should fail (must be >= 1)"
else
  ok "WG_TABLE=0 fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 35: Invalid WG_KEEPALIVE -> exit != 0 ==="
setup_mock_env
if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" WG_SERVER_ENDPOINT=1.2.3.4:51820 WG_KEEPALIVE=abc; then
  fail "Non-numeric keepalive should fail"
else
  ok "Non-numeric WG_KEEPALIVE fails correctly"
fi
if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" WG_SERVER_ENDPOINT=1.2.3.4:51820 WG_KEEPALIVE=0; then
  fail "Keepalive=0 should fail"
else
  ok "WG_KEEPALIVE=0 fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 36: Invalid WG_DNS -> exit != 0 ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_DNS=\$bad"; then
  fail "DNS with shell metachar should fail"
else
  ok "WG_DNS with invalid characters fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 37: Client - invalid WG_ALLOWED_IPS -> exit != 0 ==="
setup_mock_env
if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" WG_SERVER_ENDPOINT=1.2.3.4:51820 WG_ALLOWED_IPS=notanip/24; then
  fail "Invalid WG_ALLOWED_IPS should fail"
else
  ok "Invalid WG_ALLOWED_IPS fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 38: Server peer - invalid ALLOWED_IPS -> exit != 0 ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_PEER_BERLIN_PUBKEY=$K_BERLIN" WG_PEER_BERLIN_ALLOWED_IPS=notanip; then
  fail "Invalid peer ALLOWED_IPS should fail"
else
  ok "Invalid peer ALLOWED_IPS fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 39: Endpoint with non-numeric port -> exit != 0 ==="
setup_mock_env
if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" WG_SERVER_ENDPOINT=1.2.3.4:notaport; then
  fail "Non-numeric endpoint port should fail"
else
  ok "Non-numeric endpoint port fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 40: Bare IPv6 endpoint without brackets -> exit != 0 ==="
setup_mock_env
if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" WG_SERVER_ENDPOINT=::1; then
  fail "Bare IPv6 endpoint should fail"
else
  ok "Bare IPv6 endpoint without brackets fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 41: IPv6 bracket endpoint accepted ==="
setup_mock_env
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" "WG_SERVER_ENDPOINT=[::1]:51820" || true
assert_contains "IPv6 bracket endpoint in config" "Endpoint            = [::1]:51820" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 42: WG_IFACE longer than 15 chars -> exit != 0 ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_IFACE=wireguard0toolong; then
  fail "WG_IFACE > 15 chars should fail"
else
  ok "WG_IFACE too long fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 43: Empty hostname in endpoint (:51820) -> exit != 0 ==="
setup_mock_env
if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" WG_SERVER_ENDPOINT=:51820; then
  fail "Endpoint with empty hostname should fail"
else
  ok "Endpoint with empty hostname fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 44: Empty bracketed hostname ([]:51820) -> exit != 0 ==="
setup_mock_env
if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" WG_SERVER_ENDPOINT=[]:51820; then
  fail "Endpoint with empty bracketed hostname should fail"
else
  ok "Endpoint with empty bracketed hostname fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 45: Multiple '::' in IPv6 address -> exit != 0 ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=fd00::1::2/64; then
  fail "IPv6 with multiple '::' should fail"
else
  ok "IPv6 with multiple '::' fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 46: Too many colons in IPv6 address -> exit != 0 ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=1:2:3:4:5:6:7:8:9/64; then
  fail "IPv6 with 8+ colons should fail"
else
  ok "IPv6 with too many colons fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 47: Empty IPv4 octet -> exit != 0 ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=10..0.1/24; then
  fail "Empty middle octet should fail"
else
  ok "Empty middle octet fails correctly"
fi
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=.1.2.3/24; then
  fail "Empty leading octet should fail"
else
  ok "Empty leading octet fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 48: Malformed IPv6 addresses -> exit != 0 ==="
setup_mock_env
for addr in fd00:::1/64 fd00:/64 :fd00::1/64 12345::1/64 1:2:3/64; do
  if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_ADDRESS=$addr"; then
    fail "Malformed IPv6 '$addr' should fail"
  else
    ok "Malformed IPv6 '$addr' fails correctly"
  fi
done
cleanup_mock_env

echo ""
echo "=== Test 49: Valid IPv6 edge forms accepted ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=fd00::/64 || true
assert_contains "Trailing '::' accepted" "Address    = fd00::/64" "$CONFIG_FILE"
cleanup_mock_env
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=1:2:3:4:5:6:7:8/64 || true
assert_contains "Full 8-group address accepted" "Address    = 1:2:3:4:5:6:7:8/64" "$CONFIG_FILE"
cleanup_mock_env
setup_mock_env
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" WG_SERVER_ENDPOINT=1.2.3.4:51820 WG_ALLOWED_IPS=0.0.0.0/0,::/0 || true
assert_contains "Full-tunnel '::/0' accepted" "AllowedIPs          = 0.0.0.0/0,::/0" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 50: Invalid peer ID (lowercase/underscore) -> exit != 0 ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_PEER_laptop_PUBKEY=$K_BERLIN" WG_PEER_laptop_ALLOWED_IPS=10.77.0.2/32; then
  fail "Lowercase peer ID should fail"
else
  ok "Lowercase peer ID fails correctly"
fi
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_PEER_NODE_A_PUBKEY=$K_BERLIN" WG_PEER_NODE_A_ALLOWED_IPS=10.77.0.2/32; then
  fail "Peer ID with underscore should fail"
else
  ok "Peer ID with underscore fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 51: Key with wrong length -> exit != 0 ==="
setup_mock_env
if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" WG_SERVER_PUBKEY=TOOSHORT WG_SERVER_ENDPOINT=1.2.3.4:51820; then
  fail "Short WG_SERVER_PUBKEY should fail"
else
  ok "Short WG_SERVER_PUBKEY fails correctly"
fi
if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" WG_SERVER_ENDPOINT=1.2.3.4:51820 WG_PSK=SHORTPSK; then
  fail "Short WG_PSK should fail"
else
  ok "Short WG_PSK fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 52: Integers beyond 64 bits are rejected, not passed through ==="
setup_mock_env
for pair in "WG_PORT=99999999999999999999" "WG_MTU=99999999999999999999" "WG_TABLE=99999999999999999999"; do
  if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "$pair"; then
    fail "Out-of-range $pair should fail"
  else
    ok "Out-of-range $pair fails correctly"
  fi
done
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=10.0.0.1/99999999999999999999; then
  fail "Out-of-range CIDR prefix should fail"
else
  ok "Out-of-range CIDR prefix fails correctly"
fi
if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
   WG_SERVER_ENDPOINT=1.2.3.4:99999999999999999999; then
  fail "Out-of-range endpoint port should fail"
else
  ok "Out-of-range endpoint port fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 53: Empty secret files are rejected, never silently dropped ==="
setup_mock_env
: > "$TMPDIR_TEST/empty"
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY_FILE=$TMPDIR_TEST/empty"; then
  fail "Empty WG_PRIVATE_KEY_FILE should fail"
else
  ok "Empty WG_PRIVATE_KEY_FILE fails correctly"
fi
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_PEER_BERLIN_PUBKEY=$K_BERLIN" \
   WG_PEER_BERLIN_ALLOWED_IPS=10.77.0.2/32 "WG_PEER_BERLIN_PSK_FILE=$TMPDIR_TEST/empty"; then
  fail "Empty peer PSK file should fail (peer would silently lose its PSK)"
else
  ok "Empty peer PSK file fails correctly"
fi
if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
   WG_SERVER_ENDPOINT=1.2.3.4:51820 "WG_PSK_FILE=$TMPDIR_TEST/empty"; then
  fail "Empty client PSK file should fail"
else
  ok "Empty client PSK file fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 54: Missing secret files are rejected ==="
setup_mock_env
if run_entrypoint WG_ROLE=server WG_PRIVATE_KEY_FILE=/nonexistent/key; then
  fail "Missing WG_PRIVATE_KEY_FILE should fail"
else
  ok "Missing WG_PRIVATE_KEY_FILE fails correctly"
fi
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_PEER_BERLIN_PUBKEY=$K_BERLIN" \
   WG_PEER_BERLIN_ALLOWED_IPS=10.77.0.2/32 WG_PEER_BERLIN_PSK_FILE=/nonexistent/psk; then
  fail "Missing peer PSK file should fail"
else
  ok "Missing peer PSK file fails correctly"
fi
if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
   WG_SERVER_ENDPOINT=1.2.3.4:51820 WG_PSK_FILE=/nonexistent/psk; then
  fail "Missing client PSK file should fail"
else
  ok "Missing client PSK file fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 55: Misspelled or incomplete peer variables are rejected ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_PEER_GOOD_PUBKEY=$K_BERLIN" \
   WG_PEER_GOOD_ALLOWED_IPS=10.77.0.2/32 "WG_PEER_TYPO_PUBKEYS=$K_NUM"; then
  fail "Misspelled peer variable should fail, not be silently dropped"
else
  ok "Misspelled peer variable fails correctly"
fi
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_PEER_ORPHAN_ALLOWED_IPS=10.77.0.9/32; then
  fail "Peer without PUBKEY should fail"
else
  ok "Peer without PUBKEY fails correctly"
fi
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_PEER_BERLIN_ENDPOINTT=1.2.3.4:51820" \
   "WG_PEER_BERLIN_PUBKEY=$K_BERLIN" WG_PEER_BERLIN_ALLOWED_IPS=10.77.0.2/32; then
  fail "Unknown peer attribute should fail"
else
  ok "Unknown peer attribute fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 56: Address list edge cases ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=/24; then
  fail "Empty address in CIDR should fail"
else
  ok "Empty address in CIDR fails correctly"
fi
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_ADDRESS=10.0.0.1/24,,10.0.0.2/24"; then
  fail "Empty list entry should fail"
else
  ok "Empty list entry fails correctly"
fi
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_ADDRESS=10.0.0.1/24,  10.0.0.2/24" || true
assert_contains "Padded list entries are accepted" "Address    = 10.0.0.1/24,  10.0.0.2/24" "$CONFIG_FILE"
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_ADDRESS=10.0.0.1
10.0.0.2/24"; then
  fail "Newline in WG_ADDRESS should fail (injects a raw config line)"
else
  ok "Newline in WG_ADDRESS fails correctly"
fi
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_ADDRESS=*"; then
  fail "Glob in WG_ADDRESS should fail"
else
  ok "Glob in WG_ADDRESS fails correctly"
fi
assert_stdout_contains "Glob is reported verbatim, not as a filename" "got: '*'"
cleanup_mock_env

echo ""
echo "=== Test 57: Base64 shape of keys ==="
setup_mock_env
K_MISPAD="$(printf 'A%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21)=$(printf 'A%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21)="
if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_MISPAD" \
   WG_SERVER_ENDPOINT=1.2.3.4:51820; then
  fail "Key with interior '=' should fail"
else
  ok "Key with interior '=' fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 58: Invalid WG_ROLE value -> exit != 0 ==="
setup_mock_env
if run_entrypoint WG_ROLE=peer "WG_PRIVATE_KEY=$K_PRIV"; then
  fail "Unknown WG_ROLE should fail"
else
  ok "Unknown WG_ROLE fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 59: Hooks with spaces and newlines ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_POST_UP=iptables -A FORWARD -i %i -j ACCEPT" || true
assert_contains "Multi-word hook written verbatim" \
  "PostUp     = iptables -A FORWARD -i %i -j ACCEPT" "$CONFIG_FILE"
cleanup_mock_env
setup_mock_env
for hook in WG_PRE_UP WG_POST_UP WG_PRE_DOWN WG_POST_DOWN; do
  if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "$hook=echo hi
PostUp = touch /tmp/injected"; then
    fail "Newline in $hook should fail"
  else
    ok "Newline in $hook fails correctly"
  fi
done
cleanup_mock_env

echo ""
echo "=== Test 60: Stale interface handling ==="
setup_mock_env
EXPECT_PUB="$(printf '%s' "$K_PRIV" | "$MOCK_BIN/wg" pubkey)"
MOCK_IFACE_EXISTS=1
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "MOCK_IFACE_PUBKEY=$EXPECT_PUB" || true
assert_stdout_contains "Own leftover interface is reclaimed" "leftover from an earlier run"
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" MOCK_IFACE_PUBKEY=SOMEONEELSE; then
  fail "Foreign interface should abort the start"
else
  ok "Foreign interface aborts the start"
fi
assert_stdout_contains "Foreign interface is not torn down" "belongs to something else"
if grep -q "MOCK ip link del" "$TMPDIR_TEST/stdout.txt"; then
  fail "Foreign interface must not be deleted"
else
  ok "Foreign interface is left alone"
fi
MOCK_IFACE_EXISTS=0
cleanup_mock_env

echo ""
echo "=== Test 61: Subcommands ==="
setup_mock_env
run_subcommand genpsk || true
assert_stdout_contains "genpsk emits a key" "FAKEPSKGENERATED"
if run_subcommand bogus; then
  fail "Unknown argument should fail"
else
  ok "Unknown argument fails correctly"
fi
assert_stdout_contains "Unknown argument is named" "Unknown argument: 'bogus'"
if run_subcommand showqr WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV"; then
  fail "showqr for a server should fail"
else
  ok "showqr for a server fails correctly"
fi
if [ -f "$CONFIG_FILE" ]; then
  fail "showqr must not leave a config with the private key behind"
else
  ok "showqr for a server writes no config"
fi
run_subcommand showqr WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  WG_SERVER_ENDPOINT=1.2.3.4:51820 || true
assert_stdout_contains "showqr renders a QR code" "MOCK_QR_OUTPUT"
cleanup_mock_env

echo ""
echo "=== Test 62: Config file mode is 600 even if one already exists ==="
setup_mock_env
mkdir -p "$WG_CONFIG_DIR"
touch "$WG_CONFIG_DIR/wg0.conf"
chmod 644 "$WG_CONFIG_DIR/wg0.conf"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" || true
PERMS="$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || stat -f '%Lp' "$CONFIG_FILE" 2>/dev/null)"
if [ "$PERMS" = "600" ]; then
  ok "Pre-existing config is chmodded before the key is written"
else
  fail "Pre-existing config kept mode $PERMS"
fi
cleanup_mock_env

echo ""
echo "=== Test 63: WG_PSK on a server warns instead of being ignored ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_PSK=$K_PSK" || true
assert_stdout_contains "Server-side WG_PSK is called out" "ignored for WG_ROLE=server"
cleanup_mock_env

echo ""
echo "=== Test 64: A successful run exits 0 ==="
# Every other positive test ignores the exit code, so nothing after the config
# write is covered without this.
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_PEER_BERLIN_PUBKEY=$K_BERLIN" WG_PEER_BERLIN_ALLOWED_IPS=10.77.0.2/32; then
  ok "Server startup path exits 0"
else
  fail "Server startup path exited non-zero"
  cat "$TMPDIR_TEST/stdout.txt" || true
fi
cleanup_mock_env
setup_mock_env
if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  WG_SERVER_ENDPOINT=1.2.3.4:51820; then
  ok "Client startup path exits 0"
else
  fail "Client startup path exited non-zero"
  cat "$TMPDIR_TEST/stdout.txt" || true
fi
assert_stdout_contains "Client reports the handshake" "tunnel is live"
cleanup_mock_env

echo ""
echo "=== Test 65: Trailing comma in a CIDR list -> error ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_ADDRESS=10.77.0.1/24,"; then
  fail "Trailing comma should fail"
else
  ok "Trailing comma fails correctly"
fi
assert_stdout_contains "Trailing comma is named" "must not start or end with a comma"
cleanup_mock_env

echo ""
echo "=== Test 66: Two peers sharing a key or a prefix -> error ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_PEER_ALPHA_PUBKEY=$K_BERLIN" WG_PEER_ALPHA_ALLOWED_IPS=10.77.0.2/32 \
  "WG_PEER_BRAVO_PUBKEY=$K_BERLIN" WG_PEER_BRAVO_ALLOWED_IPS=10.77.0.3/32; then
  fail "Duplicate peer pubkey should fail"
else
  ok "Duplicate peer pubkey fails correctly"
fi
cleanup_mock_env
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_PEER_ALPHA_PUBKEY=$K_BERLIN" WG_PEER_ALPHA_ALLOWED_IPS=10.77.0.2/32 \
  "WG_PEER_BRAVO_PUBKEY=$K_NUM" "WG_PEER_BRAVO_ALLOWED_IPS=10.77.0.3/32, 10.77.0.2/32"; then
  fail "Duplicate AllowedIPs entry should fail"
else
  ok "Duplicate AllowedIPs entry fails correctly"
fi
assert_stdout_contains "Duplicate prefix is named" "already assigned to another peer"
cleanup_mock_env
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_PEER_ALPHA_PUBKEY=$K_BERLIN" WG_PEER_ALPHA_ALLOWED_IPS=10.77.0.2/32 \
  "WG_PEER_BRAVO_PUBKEY=$K_NUM" WG_PEER_BRAVO_ALLOWED_IPS=10.77.0.3/32 || true
assert_contains "Distinct peers are still accepted" "AllowedIPs          = 10.77.0.3/32" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 67: WG_IFACE picks the config file name ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_IFACE=wg1 || true
assert_contains "Config written for wg1" "PrivateKey = $K_PRIV" "$CONFIG_FILE"
if [ -f "$WG_CONFIG_DIR/wg0.conf" ]; then
  fail "wg0.conf must not be written when WG_IFACE=wg1"
else
  ok "No wg0.conf when WG_IFACE=wg1"
fi
cleanup_mock_env

echo ""
echo "=== Test 68: Malformed keys and peer values -> error ==="
setup_mock_env
if run_entrypoint WG_ROLE=server WG_PRIVATE_KEY=not-a-key; then
  fail "Malformed WG_PRIVATE_KEY should fail"
else
  ok "Malformed WG_PRIVATE_KEY fails correctly"
fi
cleanup_mock_env
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  WG_PEER_BERLIN_PUBKEY=AAAA WG_PEER_BERLIN_ALLOWED_IPS=10.77.0.2/32; then
  fail "Malformed peer PUBKEY should fail"
else
  ok "Malformed peer PUBKEY fails correctly"
fi
cleanup_mock_env
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_PEER_BERLIN_PUBKEY=$K_BERLIN" WG_PEER_BERLIN_ALLOWED_IPS=10.77.0.2/32 \
  WG_PEER_BERLIN_PSK=short; then
  fail "Malformed peer PSK should fail"
else
  ok "Malformed peer PSK fails correctly"
fi
cleanup_mock_env
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_PEER_BERLIN_PUBKEY=$K_BERLIN" WG_PEER_BERLIN_ALLOWED_IPS=10.77.0.2/32 \
  WG_PEER_BERLIN_KEEPALIVE=0; then
  fail "Peer KEEPALIVE=0 should fail"
else
  ok "Peer KEEPALIVE=0 fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 69: Endpoint host is validated ==="
setup_mock_env
if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  'WG_SERVER_ENDPOINT=vpn;touch /tmp/x:51820'; then
  fail "Endpoint host with shell characters should fail"
else
  ok "Endpoint host with shell characters fails correctly"
fi
cleanup_mock_env
setup_mock_env
if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  'WG_SERVER_ENDPOINT=[fd00::1]:51820:99'; then
  fail "Bracket endpoint with a trailing port should fail"
else
  ok "Bracket endpoint with a trailing port fails correctly"
fi
cleanup_mock_env
setup_mock_env
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  'WG_SERVER_ENDPOINT=[fd00::1]:51820' || true
assert_contains "Bracketed IPv6 endpoint accepted" "Endpoint            = [fd00::1]:51820" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 70: WG_PEER_* without an ID is reported as unknown ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_PEER_PSK=$K_PSK"; then
  fail "WG_PEER_PSK should fail"
else
  ok "WG_PEER_PSK fails correctly"
fi
assert_stdout_contains "WG_PEER_PSK is named as unknown" "Unknown peer variable 'WG_PEER_PSK'"
cleanup_mock_env

echo ""
echo "=== Test 71: Validation messages name the variable once ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_ADDRESS=10.0.0.1/24,10.0.0.2/999" || true
assert_stdout_contains "Prefix error is not doubled" "WG_ADDRESS prefix must be 0-32"
cleanup_mock_env

echo ""
echo "=== Test 72: A key and its _FILE together warn ==="
setup_mock_env
printf '%s\n' "$K_PRIVFILE" > "$TMPDIR_TEST/priv.key"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_PRIVATE_KEY_FILE=$TMPDIR_TEST/priv.key" || true
assert_stdout_contains "Ignored key file is called out" "WG_PRIVATE_KEY_FILE is ignored"
assert_contains "Environment key wins" "PrivateKey = $K_PRIV" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 73: WG_DNS prepares resolv.conf for openresolv ==="
setup_mock_env
printf '# Generated by Docker Engine.\nnameserver 127.0.0.11\n' > "$TMPDIR_TEST/resolv.conf"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_DNS=1.1.1.1 || true
assert_contains "resolvconf marker written" "# Generated by resolvconf" "$TMPDIR_TEST/resolv.conf"
assert_contains "Existing nameserver kept"  "nameserver 127.0.0.11"     "$TMPDIR_TEST/resolv.conf"
cleanup_mock_env
setup_mock_env
printf '# Generated by Docker Engine.\n' > "$TMPDIR_TEST/resolv.conf"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" || true
assert_not_contains "Untouched without WG_DNS" "# Generated by resolvconf" "$TMPDIR_TEST/resolv.conf"
cleanup_mock_env

echo ""
echo "=================================="
printf   "  Result: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "=================================="
[ "$FAIL" -eq 0 ]
