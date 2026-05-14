#!/bin/sh
# Tests run without Docker or a WireGuard kernel module.
# All wg / wg-quick calls are mocked; only config generation is verified.
set -eu

PASS=0
FAIL=0
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/entrypoint.sh"

ok()   { echo "  [PASS] $*"; PASS=$(( PASS + 1 )); }
fail() { echo "  [FAIL] $*"; FAIL=$(( FAIL + 1 )); }

assert_contains() {
  label="$1"; pattern="$2"; file="$3"
  if grep -qF "$pattern" "$file" 2>/dev/null; then
    ok "$label"
  else
    fail "$label -- '$pattern' not found in $file"
    echo "--- Contents of $file ---"; cat "$file"; echo "-------------------------"
  fi
}

assert_not_contains() {
  label="$1"; pattern="$2"; file="$3"
  if ! grep -qF "$pattern" "$file" 2>/dev/null; then
    ok "$label"
  else
    fail "$label -- '$pattern' should NOT be in $file"
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
      *)                 exit 0 ;;
    esac
    ;;
esac
EOF
  chmod +x "$MOCK_BIN/wg"

  for cmd in wg-quick sysctl iptables ip6tables ip resolvconf; do
    printf '#!/bin/sh\nexit 0\n' > "$MOCK_BIN/$cmd"
    chmod +x "$MOCK_BIN/$cmd"
  done

  # sleep exits immediately so the sleep infinity & wait loop terminates
  printf '#!/bin/sh\nexit 0\n' > "$MOCK_BIN/sleep"
  chmod +x "$MOCK_BIN/sleep"

  export PATH="$MOCK_BIN:$PATH"
  export WG_CONFIG_DIR="$TMPDIR_TEST/etc/wireguard"
  mkdir -p "$WG_CONFIG_DIR"
}

cleanup_mock_env() {
  rm -rf "$TMPDIR_TEST"
}

# Patches the config path and replaces sleep infinity with exit 0, then runs.
# All output goes to stdout.txt; the exit code is preserved.
run_entrypoint() {
  _iface="$(printf '%s' "$1" | tr ' ' '\n' | grep '^WG_IFACE=' | cut -d= -f2)"
  CONFIG_FILE="$WG_CONFIG_DIR/${_iface:-wg0}.conf"
  PATCHED="$TMPDIR_TEST/entrypoint_patched.sh"
  sed "s|/etc/wireguard|$WG_CONFIG_DIR|g" "$SCRIPT" > "$PATCHED"
  sed -i '/sleep infinity/,/wait/c\exit 0' "$PATCHED"
  chmod +x "$PATCHED"
  # shellcheck disable=SC2086
  env -i PATH="$PATH" $1 sh "$PATCHED" > "$TMPDIR_TEST/stdout.txt" 2>&1
}

# ---------------------------------------------------------------------------

echo ""
echo "=== Test 1: Server - no peers (warning, interface block written) ==="
setup_mock_env
run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123" || true
assert_contains     "Interface Address default"  "Address    = 10.77.0.1/24"  "$CONFIG_FILE"
assert_contains     "Interface ListenPort"        "ListenPort = 51820"          "$CONFIG_FILE"
assert_contains     "PrivateKey written"          "PrivateKey = FAKEPRIV123"    "$CONFIG_FILE"
if grep -q "WARNING" "$TMPDIR_TEST/stdout.txt" 2>/dev/null; then
  ok "No-peers warning produced"
else
  fail "Should warn when no peers are configured"
fi
cleanup_mock_env

echo ""
echo "=== Test 2: Server - single named peer ==="
setup_mock_env
run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_PEER_BERLIN_PUBKEY=BERLINPUB WG_PEER_BERLIN_ALLOWED_IPS=10.77.0.2/32" || true
assert_contains "Peer block present"   "[Peer]"                              "$CONFIG_FILE"
assert_contains "Peer PublicKey"       "PublicKey           = BERLINPUB"     "$CONFIG_FILE"
assert_contains "Peer AllowedIPs"      "AllowedIPs          = 10.77.0.2/32"  "$CONFIG_FILE"
assert_not_contains "No PresharedKey without PSK" "PresharedKey" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 3: Server - multiple peers (named + numbered) ==="
setup_mock_env
run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_PEER_BERLIN_PUBKEY=BERLINPUB WG_PEER_BERLIN_ALLOWED_IPS=10.77.0.2/32,192.168.10.0/24 WG_PEER_0_PUBKEY=NUMERICPUB WG_PEER_0_ALLOWED_IPS=10.77.0.3/32" || true
assert_contains "Berlin peer present"   "PublicKey           = BERLINPUB"              "$CONFIG_FILE"
assert_contains "Berlin AllowedIPs"     "AllowedIPs          = 10.77.0.2/32,192.168.10.0/24" "$CONFIG_FILE"
assert_contains "Numbered peer present" "PublicKey           = NUMERICPUB"             "$CONFIG_FILE"
assert_contains "Numbered AllowedIPs"   "AllowedIPs          = 10.77.0.3/32"           "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 4: Server - peer with inline PSK ==="
setup_mock_env
run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_PEER_BERLIN_PUBKEY=BERLINPUB WG_PEER_BERLIN_ALLOWED_IPS=10.77.0.2/32 WG_PEER_BERLIN_PSK=FAKEPSK123" || true
assert_contains "PSK in peer block"    "PresharedKey        = FAKEPSK123"  "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 5: Server - peer PSK from file ==="
setup_mock_env
echo "FAKEPSKFROMFILE" > "$TMPDIR_TEST/peer_psk.txt"
run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_PEER_BERLIN_PUBKEY=BERLINPUB WG_PEER_BERLIN_ALLOWED_IPS=10.77.0.2/32 WG_PEER_BERLIN_PSK_FILE=$TMPDIR_TEST/peer_psk.txt" || true
assert_contains "PSK from file in config" "PresharedKey        = FAKEPSKFROMFILE" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 6: Server - missing ALLOWED_IPS for peer -> error ==="
setup_mock_env
if run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_PEER_BERLIN_PUBKEY=BERLINPUB"; then
  fail "Missing ALLOWED_IPS should fail"
else
  ok "Missing ALLOWED_IPS fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 7: Client - minimal config ==="
setup_mock_env
run_entrypoint "WG_ROLE=client WG_PRIVATE_KEY=FAKEPRIV123 WG_SERVER_PUBKEY=SERVERPUB WG_SERVER_ENDPOINT=1.2.3.4:51820" || true
assert_contains "Interface Address default"     "Address    = 10.77.0.2/24"           "$CONFIG_FILE"
assert_contains "Server PublicKey"              "PublicKey           = SERVERPUB"      "$CONFIG_FILE"
assert_contains "Endpoint set"                  "Endpoint            = 1.2.3.4:51820"  "$CONFIG_FILE"
assert_contains "PersistentKeepalive default"   "PersistentKeepalive = 25"             "$CONFIG_FILE"
assert_contains "AllowedIPs default"            "AllowedIPs          = 10.77.0.1/32"  "$CONFIG_FILE"
assert_not_contains "No PresharedKey by default" "PresharedKey"                        "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 8: Client - custom AllowedIPs and port ==="
setup_mock_env
run_entrypoint "WG_ROLE=client WG_PRIVATE_KEY=FAKEPRIV123 WG_SERVER_PUBKEY=SERVERPUB WG_SERVER_ENDPOINT=1.2.3.4:51820 WG_ALLOWED_IPS=0.0.0.0/0 WG_PORT=12345" || true
assert_contains "Custom AllowedIPs"   "AllowedIPs          = 0.0.0.0/0"  "$CONFIG_FILE"
assert_contains "Custom port"         "ListenPort = 12345"                "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 9: Client - with inline PSK ==="
setup_mock_env
run_entrypoint "WG_ROLE=client WG_PRIVATE_KEY=FAKEPRIV123 WG_SERVER_PUBKEY=SERVERPUB WG_SERVER_ENDPOINT=1.2.3.4:51820 WG_PSK=CLIENTPSK" || true
assert_contains "Client PSK present"  "PresharedKey        = CLIENTPSK"  "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 10: Client - PSK from file ==="
setup_mock_env
echo "CLIENTPSKFROMFILE" > "$TMPDIR_TEST/client_psk.txt"
run_entrypoint "WG_ROLE=client WG_PRIVATE_KEY=FAKEPRIV123 WG_SERVER_PUBKEY=SERVERPUB WG_SERVER_ENDPOINT=1.2.3.4:51820 WG_PSK_FILE=$TMPDIR_TEST/client_psk.txt" || true
assert_contains "Client PSK from file" "PresharedKey        = CLIENTPSKFROMFILE" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 11: WG_PRIVATE_KEY_FILE ==="
setup_mock_env
echo "PRIVFROMFILE" > "$TMPDIR_TEST/privkey.txt"
run_entrypoint "WG_ROLE=client WG_PRIVATE_KEY_FILE=$TMPDIR_TEST/privkey.txt WG_SERVER_PUBKEY=SERVERPUB WG_SERVER_ENDPOINT=1.2.3.4:51820" || true
assert_contains "PrivateKey loaded from file" "PrivateKey = PRIVFROMFILE" "$CONFIG_FILE"
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
if run_entrypoint "WG_PRIVATE_KEY=FAKEPRIV123"; then
  fail "Missing WG_ROLE should fail"
else
  ok "Missing WG_ROLE fails correctly"
fi
if run_entrypoint "WG_ROLE=server"; then
  fail "Missing WG_PRIVATE_KEY should fail"
else
  ok "Missing WG_PRIVATE_KEY fails correctly"
fi
if run_entrypoint "WG_ROLE=client WG_PRIVATE_KEY=FAKEPRIV123 WG_SERVER_ENDPOINT=1.2.3.4:51820"; then
  fail "Missing WG_SERVER_PUBKEY should fail"
else
  ok "Missing WG_SERVER_PUBKEY fails correctly"
fi
if run_entrypoint "WG_ROLE=client WG_PRIVATE_KEY=FAKEPRIV123 WG_SERVER_PUBKEY=SERVERPUB"; then
  fail "Missing WG_SERVER_ENDPOINT should fail"
else
  ok "Missing WG_SERVER_ENDPOINT fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 14: Invalid WG_PORT -> exit != 0 ==="
setup_mock_env
if run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_PORT=abc"; then
  fail "Non-numeric WG_PORT should fail"
else
  ok "Non-numeric WG_PORT fails correctly"
fi
if run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_PORT=99999"; then
  fail "WG_PORT out of range should fail"
else
  ok "WG_PORT out of range fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 15: Invalid WG_ADDRESS (IPv4) -> exit != 0 ==="
setup_mock_env
if run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_ADDRESS=notanip/24"; then
  fail "Non-numeric IP should fail"
else
  ok "Non-numeric IP in WG_ADDRESS fails correctly"
fi
if run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_ADDRESS=10.0.0.1/99"; then
  fail "Prefix > 32 should fail"
else
  ok "Prefix > 32 in WG_ADDRESS fails correctly"
fi
if run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_ADDRESS=10.0.0.1"; then
  fail "WG_ADDRESS without prefix should fail"
else
  ok "WG_ADDRESS without CIDR prefix fails correctly"
fi
if run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_ADDRESS=256.0.0.1/24"; then
  fail "Octet > 255 should fail"
else
  ok "Octet > 255 in WG_ADDRESS fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 16: Invalid WG_SERVER_ENDPOINT format -> exit != 0 ==="
setup_mock_env
if run_entrypoint "WG_ROLE=client WG_PRIVATE_KEY=FAKEPRIV123 WG_SERVER_PUBKEY=SERVERPUB WG_SERVER_ENDPOINT=example.com"; then
  fail "Endpoint without port should fail"
else
  ok "Endpoint without port fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 17: Config file permissions = 600 ==="
setup_mock_env
run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123" || true
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
run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIVUNIQUEXYZ" || true
assert_contains "PrivateKey in config" "PrivateKey = FAKEPRIVUNIQUEXYZ" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 19: Client - custom WG_KEEPALIVE ==="
setup_mock_env
run_entrypoint "WG_ROLE=client WG_PRIVATE_KEY=FAKEPRIV123 WG_SERVER_PUBKEY=SERVERPUB WG_SERVER_ENDPOINT=1.2.3.4:51820 WG_KEEPALIVE=60" || true
assert_contains "Custom keepalive" "PersistentKeepalive = 60" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 20: Invalid WG_IFACE -> exit != 0 ==="
setup_mock_env
if run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_IFACE=wg0/bad"; then
  fail "Invalid WG_IFACE should fail"
else
  ok "Invalid WG_IFACE fails correctly"
fi
if run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_IFACE=wg0;evil"; then
  fail "WG_IFACE with semicolon should fail"
else
  ok "WG_IFACE with semicolon fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 21: Server - empty peer pubkey -> error ==="
setup_mock_env
if run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_PEER_BERLIN_PUBKEY= WG_PEER_BERLIN_ALLOWED_IPS=10.77.0.2/32"; then
  fail "Empty peer PUBKEY should fail"
else
  ok "Empty peer PUBKEY fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 22: DNS written to [Interface] ==="
setup_mock_env
run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_DNS=1.1.1.1,8.8.8.8" || true
assert_contains "DNS line present"  "DNS        = 1.1.1.1,8.8.8.8"  "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 23: MTU written to [Interface] ==="
setup_mock_env
run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_MTU=1420" || true
assert_contains "MTU line present"  "MTU        = 1420"  "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 24: Table written to [Interface] ==="
setup_mock_env
run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_TABLE=off" || true
assert_contains "Table=off present"   "Table      = off"  "$CONFIG_FILE"
cleanup_mock_env
setup_mock_env
run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_TABLE=auto" || true
assert_contains "Table=auto present"  "Table      = auto" "$CONFIG_FILE"
cleanup_mock_env
setup_mock_env
run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_TABLE=200" || true
assert_contains "Table=200 present"   "Table      = 200"  "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 25: Hooks written to [Interface] ==="
setup_mock_env
# Hook values are single words here because run_entrypoint passes $1 unquoted.
# Real usage supports full commands (e.g. "iptables -A FORWARD -j ACCEPT").
run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_PRE_UP=do-preup WG_POST_UP=do-postup WG_PRE_DOWN=do-predown WG_POST_DOWN=do-postdown" || true
assert_contains "PreUp present"    "PreUp      = do-preup"    "$CONFIG_FILE"
assert_contains "PostUp present"   "PostUp     = do-postup"   "$CONFIG_FILE"
assert_contains "PreDown present"  "PreDown    = do-predown"  "$CONFIG_FILE"
assert_contains "PostDown present" "PostDown   = do-postdown" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 26: Hooks absent when not set ==="
setup_mock_env
run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123" || true
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
run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_ADDRESS=fd00::1/64" || true
assert_contains "IPv6 address in config" "Address    = fd00::1/64" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 28: Dual-stack WG_ADDRESS (IPv4 + IPv6) ==="
setup_mock_env
run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_ADDRESS=10.77.0.1/24,fd00::1/64" || true
assert_contains "Dual-stack address in config" "Address    = 10.77.0.1/24,fd00::1/64" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 29: Invalid IPv6 WG_ADDRESS -> exit != 0 ==="
setup_mock_env
if run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_ADDRESS=gggg::1/64"; then
  fail "Invalid IPv6 hex chars should fail"
else
  ok "Invalid IPv6 characters in WG_ADDRESS fails correctly"
fi
if run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_ADDRESS=fd00::1/129"; then
  fail "IPv6 prefix > 128 should fail"
else
  ok "IPv6 prefix > 128 fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 30: Server peer - Endpoint ==="
setup_mock_env
run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_PEER_STATIC_PUBKEY=STATICPUB WG_PEER_STATIC_ALLOWED_IPS=10.77.0.5/32 WG_PEER_STATIC_ENDPOINT=203.0.113.5:51820" || true
assert_contains "Peer Endpoint present" "Endpoint            = 203.0.113.5:51820" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 31: Server peer - Endpoint without port -> error ==="
setup_mock_env
if run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_PEER_STATIC_PUBKEY=STATICPUB WG_PEER_STATIC_ALLOWED_IPS=10.77.0.5/32 WG_PEER_STATIC_ENDPOINT=203.0.113.5"; then
  fail "Peer Endpoint without port should fail"
else
  ok "Peer Endpoint without port fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 32: Server peer - PersistentKeepalive ==="
setup_mock_env
run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_PEER_ROAM_PUBKEY=ROAMPUB WG_PEER_ROAM_ALLOWED_IPS=10.77.0.6/32 WG_PEER_ROAM_KEEPALIVE=30" || true
assert_contains "Peer Keepalive present" "PersistentKeepalive = 30" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 33: Invalid WG_MTU -> exit != 0 ==="
setup_mock_env
if run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_MTU=abc"; then
  fail "Non-numeric MTU should fail"
else
  ok "Non-numeric MTU fails correctly"
fi
if run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_MTU=100"; then
  fail "MTU < 1280 should fail"
else
  ok "MTU below minimum fails correctly"
fi
if run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_MTU=9001"; then
  fail "MTU > 9000 should fail"
else
  ok "MTU above maximum fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 34: Invalid WG_TABLE -> exit != 0 ==="
setup_mock_env
if run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_TABLE=invalid"; then
  fail "Non-keyword, non-numeric Table should fail"
else
  ok "Invalid WG_TABLE fails correctly"
fi
if run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_TABLE=0"; then
  fail "Table=0 should fail (must be >= 1)"
else
  ok "WG_TABLE=0 fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 35: Invalid WG_KEEPALIVE -> exit != 0 ==="
setup_mock_env
if run_entrypoint "WG_ROLE=client WG_PRIVATE_KEY=FAKEPRIV123 WG_SERVER_PUBKEY=SERVERPUB WG_SERVER_ENDPOINT=1.2.3.4:51820 WG_KEEPALIVE=abc"; then
  fail "Non-numeric keepalive should fail"
else
  ok "Non-numeric WG_KEEPALIVE fails correctly"
fi
if run_entrypoint "WG_ROLE=client WG_PRIVATE_KEY=FAKEPRIV123 WG_SERVER_PUBKEY=SERVERPUB WG_SERVER_ENDPOINT=1.2.3.4:51820 WG_KEEPALIVE=0"; then
  fail "Keepalive=0 should fail"
else
  ok "WG_KEEPALIVE=0 fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 36: Invalid WG_DNS -> exit != 0 ==="
setup_mock_env
if run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_DNS=\$bad"; then
  fail "DNS with shell metachar should fail"
else
  ok "WG_DNS with invalid characters fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 37: Client - invalid WG_ALLOWED_IPS -> exit != 0 ==="
setup_mock_env
if run_entrypoint "WG_ROLE=client WG_PRIVATE_KEY=FAKEPRIV123 WG_SERVER_PUBKEY=SERVERPUB WG_SERVER_ENDPOINT=1.2.3.4:51820 WG_ALLOWED_IPS=notanip/24"; then
  fail "Invalid WG_ALLOWED_IPS should fail"
else
  ok "Invalid WG_ALLOWED_IPS fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 38: Server peer - invalid ALLOWED_IPS -> exit != 0 ==="
setup_mock_env
if run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_PEER_BERLIN_PUBKEY=BERLINPUB WG_PEER_BERLIN_ALLOWED_IPS=notanip"; then
  fail "Invalid peer ALLOWED_IPS should fail"
else
  ok "Invalid peer ALLOWED_IPS fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 39: Endpoint with non-numeric port -> exit != 0 ==="
setup_mock_env
if run_entrypoint "WG_ROLE=client WG_PRIVATE_KEY=FAKEPRIV123 WG_SERVER_PUBKEY=SERVERPUB WG_SERVER_ENDPOINT=1.2.3.4:notaport"; then
  fail "Non-numeric endpoint port should fail"
else
  ok "Non-numeric endpoint port fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 40: Bare IPv6 endpoint without brackets -> exit != 0 ==="
setup_mock_env
if run_entrypoint "WG_ROLE=client WG_PRIVATE_KEY=FAKEPRIV123 WG_SERVER_PUBKEY=SERVERPUB WG_SERVER_ENDPOINT=::1"; then
  fail "Bare IPv6 endpoint should fail"
else
  ok "Bare IPv6 endpoint without brackets fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 41: IPv6 bracket endpoint accepted ==="
setup_mock_env
run_entrypoint "WG_ROLE=client WG_PRIVATE_KEY=FAKEPRIV123 WG_SERVER_PUBKEY=SERVERPUB WG_SERVER_ENDPOINT=[::1]:51820" || true
assert_contains "IPv6 bracket endpoint in config" "Endpoint            = [::1]:51820" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 42: WG_IFACE longer than 15 chars -> exit != 0 ==="
setup_mock_env
if run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_IFACE=wireguard0toolong"; then
  fail "WG_IFACE > 15 chars should fail"
else
  ok "WG_IFACE too long fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 43: Empty hostname in endpoint (:51820) -> exit != 0 ==="
setup_mock_env
if run_entrypoint "WG_ROLE=client WG_PRIVATE_KEY=FAKEPRIV123 WG_SERVER_PUBKEY=SERVERPUB WG_SERVER_ENDPOINT=:51820"; then
  fail "Endpoint with empty hostname should fail"
else
  ok "Endpoint with empty hostname fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 44: Empty bracketed hostname ([]:51820) -> exit != 0 ==="
setup_mock_env
if run_entrypoint "WG_ROLE=client WG_PRIVATE_KEY=FAKEPRIV123 WG_SERVER_PUBKEY=SERVERPUB WG_SERVER_ENDPOINT=[]:51820"; then
  fail "Endpoint with empty bracketed hostname should fail"
else
  ok "Endpoint with empty bracketed hostname fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 45: Multiple '::' in IPv6 address -> exit != 0 ==="
setup_mock_env
if run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_ADDRESS=fd00::1::2/64"; then
  fail "IPv6 with multiple '::' should fail"
else
  ok "IPv6 with multiple '::' fails correctly"
fi
cleanup_mock_env

echo ""
echo "=== Test 46: Too many colons in IPv6 address -> exit != 0 ==="
setup_mock_env
if run_entrypoint "WG_ROLE=server WG_PRIVATE_KEY=FAKEPRIV123 WG_ADDRESS=1:2:3:4:5:6:7:8:9/64"; then
  fail "IPv6 with 8+ colons should fail"
else
  ok "IPv6 with too many colons fails correctly"
fi
cleanup_mock_env

echo ""
echo "=================================="
printf   "  Result: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "=================================="
[ "$FAIL" -eq 0 ]
