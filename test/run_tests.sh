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
# Right length, wrong alphabet - the only way to reach the charset message.
K_BADCHAR="$(fake_key 'BAD!KEY')"

ok()   { echo "  [PASS] $*"; PASS=$(( PASS + 1 )); }
fail() { echo "  [FAIL] $*"; FAIL=$(( FAIL + 1 )); }

# -e and -- on every grep below, or a pattern like "-d wg0" is read as an option.
assert_contains() {
  label="$1"; pattern="$2"; file="$3"
  if [ ! -f "$file" ]; then
    fail "$label -- $file was not created"
    return 0
  fi
  if grep -qFe "$pattern" -- "$file"; then
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
  if ! grep -qFe "$pattern" -- "$file"; then
    ok "$label"
  else
    fail "$label -- '$pattern' should NOT be in $file"
  fi
}

assert_stdout_contains() {
  label="$1"; pattern="$2"
  if grep -qFe "$pattern" -- "$TMPDIR_TEST/stdout.txt"; then
    ok "$label"
  else
    fail "$label -- '$pattern' not in output"
    echo "--- Output ---"; cat "$TMPDIR_TEST/stdout.txt" || true; echo "--------------"
  fi
}

# A message can name the right variable and still give the wrong cause.
assert_stdout_not_contains() {
  label="$1"; pattern="$2"
  if grep -qFe "$pattern" -- "$TMPDIR_TEST/stdout.txt"; then
    fail "$label -- '$pattern' should not be in output"
    echo "--- Output ---"; cat "$TMPDIR_TEST/stdout.txt" || true; echo "--------------"
  else
    ok "$label"
  fi
}

setup_mock_env() {
  TMPDIR_TEST="$(mktemp -d)"
  MOCK_BIN="$TMPDIR_TEST/bin"
  mkdir -p "$MOCK_BIN"

  cat > "$MOCK_BIN/wg" <<'EOF'
#!/bin/sh
# MOCK_WG_LOG is the only way to see a monitor still polling after the teardown.
[ -n "${MOCK_WG_LOG:-}" ] && printf '%s\n' "$*" >> "$MOCK_WG_LOG"
case "${1:-}" in
  genkey)
    # Ends on a character that can carry the two spare bits, like the real one.
    echo "FAKEPRIV12345678901234567890123456789012340="
    ;;
  pubkey)
    input="$(cat)"
    # Or the entrypoint's "not a valid WireGuard key" branch is unreachable.
    [ "${MOCK_PUBKEY_FAIL:-0}" = "1" ] && { echo "invalid key" >&2; exit 1; }
    case "$input" in
      *[!A-Za-z0-9+/=]*) echo "invalid base64" >&2; exit 1 ;;
    esac
    [ "${#input}" -eq 44 ] || { echo "invalid key length" >&2; exit 1; }
    # Over the whole key: the fixtures share their first bytes.
    out="FAKEPUB$(printf '%s' "$input" | cksum | tr -cd '0-9')"
    while [ "${#out}" -lt 43 ]; do out="${out}A"; done
    printf '%s=\n' "$out"
    ;;
  show)
    shift
    # Without the knob the entrypoint's "failed to start" check can never fire.
    [ "${MOCK_WGSHOW_FAIL:-0}" = "1" ] && exit 1
    _if="${1:-wg0}"
    shift 2>/dev/null || true
    case "${1:-}" in
      latest-handshakes)
        # Real wg prints nothing and exits 0 for a peerless interface.
        [ "${MOCK_NO_PEERS:-0}" = "1" ] && exit 0
        hs1="${MOCK_HANDSHAKE:-$(date +%s)}"
        hs2="${MOCK_HANDSHAKE2:-}"
        # One word per call, the last repeating; 'gone' fails like a removed one.
        if [ -n "${MOCK_HS_SEQ:-}" ]; then
          seq_n=0
          [ -f "${MOCK_HS_SEQ_STATE:-/nonexistent}" ] && seq_n="$(cat "$MOCK_HS_SEQ_STATE")"
          seq_i=0
          for seq_t in $MOCK_HS_SEQ; do
            seq_tok="$seq_t"
            [ "$seq_i" -eq "$seq_n" ] && break
            seq_i=$(( seq_i + 1 ))
          done
          printf '%s\n' "$(( seq_n + 1 ))" > "$MOCK_HS_SEQ_STATE"
          [ "$seq_tok" = "gone" ] && exit 1
        fi
        # The monitor only logs on a state change.
        if [ -n "${MOCK_FLAG:-}" ]; then
          if [ -f "$MOCK_FLAG" ]; then
            [ "${MOCK_HS_GONE_AFTER:-0}" = "1" ] && exit 1
            [ -n "${MOCK_HANDSHAKE_AFTER:-}" ] && hs1="$MOCK_HANDSHAKE_AFTER"
          else
            : > "$MOCK_FLAG"
          fi
        fi
        printf 'FAKEPUBabc123 %s\n' "$hs1"
        # A second peer, so the monitor's partial-connectivity branch is reachable.
        [ -n "$hs2" ] && printf 'FAKEPUBdef456 %s\n' "$hs2"
        ;;
      # Out of the config, the way the kernel would have it.
      listen-port)
        _lp=""
        [ -n "${MOCK_CONFDIR:-}" ] && _lp="$(sed -n 's/^ListenPort *= *//p' "$MOCK_CONFDIR/${_if}.conf" 2>/dev/null)"
        echo "${_lp:-51820}"
        ;;
      public-key)        printf '%s\n' "${MOCK_IFACE_PUBKEY:-}" ;;
      *)                 exit 0 ;;
    esac
    ;;
  genpsk)
    echo "FAKEPSKGENERATED5678901234567890123456789A0="
    ;;
  # Real wg has no other subcommands; a silent success here would hide a typo.
  *) exit 1 ;;
esac
# Explicit: the entrypoint reads a non-zero wg as "the interface is gone".
exit 0
EOF
  chmod +x "$MOCK_BIN/wg"

  # Only present in the image, so an unmocked call is invisible here.
  cat > "$MOCK_BIN/resolvconf" <<'EOF'
#!/bin/sh
[ -n "${MOCK_RESOLVCONF_LOG:-}" ] && printf '%s\n' "$*" >> "$MOCK_RESOLVCONF_LOG"
exit 0
EOF
  chmod +x "$MOCK_BIN/resolvconf"

  for cmd in sysctl iptables ip6tables; do
    printf '#!/bin/sh\nexit 0\n' > "$MOCK_BIN/$cmd"
    chmod +x "$MOCK_BIN/$cmd"
  done

  # ENVDUMP records what wg-quick and the hooks inherit, LOG every call.
  cat > "$MOCK_BIN/wg-quick" <<'EOF'
#!/bin/sh
[ -n "${MOCK_WGQUICK_LOG:-}" ] && printf '%s\n' "$*" >> "$MOCK_WGQUICK_LOG"
[ -n "${MOCK_WGQUICK_ENVDUMP:-}" ] && env > "$MOCK_WGQUICK_ENVDUMP"
# MOCK_IFACE_FLAG makes the device follow wg-quick instead of a fixed answer.
if [ -n "${MOCK_IFACE_FLAG:-}" ]; then
  [ "${1:-}" = "up" ] && : > "$MOCK_IFACE_FLAG"
  [ "${1:-}" = "down" ] && [ "${MOCK_WGQUICK_DOWNFAIL:-0}" != "1" ] && rm -f "$MOCK_IFACE_FLAG"
fi
# Whether the claim is still held while the interface is being taken down.
if [ -n "${MOCK_CLAIM_PROBE:-}" ] && [ "${1:-}" = "down" ]; then
  if [ -f "$MOCK_CLAIM_PROBE" ]; then echo "claim-held-during-down"; else echo "claim-gone-during-down"; fi \
    > "$MOCK_CLAIM_PROBE.seen"
fi
if [ "${MOCK_WGQUICK_FAIL:-0}" = "1" ] && [ "${1:-}" = "up" ]; then
  echo "MOCK wg-quick: bring-up refused"
  exit 1
fi
if [ "${MOCK_WGQUICK_DOWNFAIL:-0}" = "1" ] && [ "${1:-}" = "down" ]; then
  # On stderr like the real thing; the replay is the point of capturing it.
  echo "MOCK wg-quick: PostDown hook failed" >&2
  exit 1
fi
exit 0
EOF
  chmod +x "$MOCK_BIN/wg-quick"

  # Must report "no such interface" by default; MOCK_IFACE_EXISTS=1 flips it.
  cat > "$MOCK_BIN/ip" <<'EOF'
#!/bin/sh
case "$*" in
  "link show dev "*) [ "${MOCK_IFACE_EXISTS:-0}" = "1" ] && exit 0
                     [ -n "${MOCK_IFACE_FLAG:-}" ] && [ -f "$MOCK_IFACE_FLAG" ] && exit 0
                     exit 1 ;;
  "link del "*)      [ "${MOCK_IPDEL_FAIL:-0}" = "1" ] && {
                       echo "RTNETLINK answers: Operation not permitted" >&2; exit 2; }
                     echo "MOCK ip $*" ;;
esac
exit 0
EOF
  chmod +x "$MOCK_BIN/ip"

  # Exits at once so the wait loop terminates; MOCK_SLEEP_REAL pauses instead.
  # MOCK_SLEEP_LOG keeps the monitor's own interval observable.
  cat > "$MOCK_BIN/sleep" <<'EOF'
#!/bin/sh
[ -n "${MOCK_SLEEP_LOG:-}" ] && printf '%s\n' "$1" >> "$MOCK_SLEEP_LOG"
[ "${MOCK_SLEEP_REAL:-0}" = "1" ] && exec /bin/sleep 0.01
exit 0
EOF
  chmod +x "$MOCK_BIN/sleep"

  # Parks the script between the config write and the traps. Only on `sort -V`:
  # the entrypoint's first sort is the blank sweep, long before the config.
  _real_sort="$(command -v sort)"
  cat > "$MOCK_BIN/sort" <<EOF
#!/bin/sh
case " \$* " in *" -V "*) [ -n "\${MOCK_SORT_DELAY:-}" ] && /bin/sleep "\$MOCK_SORT_DELAY" ;; esac
exec "$_real_sort" "\$@"
EOF
  chmod +x "$MOCK_BIN/sort"

  ORIG_PATH="$PATH"
  export PATH="$MOCK_BIN:$PATH"
  export WG_CONFIG_DIR="$TMPDIR_TEST/etc/wireguard"
  mkdir -p "$WG_CONFIG_DIR"
}

cleanup_mock_env() {
  rm -rf "$TMPDIR_TEST"
  # Without this PATH accumulates a dead mock dir per test.
  PATH="$ORIG_PATH"; export PATH
  # Left set, the next test silently runs against an interface that is not there.
  unset MOCK_IFACE_EXISTS MOCK_IFACE_PUBKEY MOCK_WGQUICK_FAIL MOCK_WGQUICK_DOWNFAIL \
        MOCK_WGQUICK_LOG MOCK_WGQUICK_ENVDUMP MOCK_WGSHOW_FAIL MOCK_PUBKEY_FAIL \
        MOCK_HANDSHAKE MOCK_HANDSHAKE2 MOCK_HANDSHAKE_AFTER MOCK_HS_GONE_AFTER MOCK_NO_PEERS MOCK_WG_LOG \
        MOCK_FLAG MOCK_SLEEP_REAL MOCK_SLEEP_LOG MOCK_SORT_DELAY MOCK_HS_SEQ MOCK_HS_SEQ_STATE \
        MOCK_IFACE_FLAG MOCK_CLAIM_PROBE MOCK_IPDEL_FAIL MOCK_RESOLVCONF_LOG 2>/dev/null || true
}

# Every absolute path the entrypoint writes to has to land inside TMPDIR_TEST.
# Keep in step with entrypoint.sh. The argument replaces the sleep-infinity wait.
patch_entrypoint() {
  PATCHED="$TMPDIR_TEST/entrypoint_patched.sh"
  sed "s|/etc/wireguard|$WG_CONFIG_DIR|g; s|/etc/resolv.conf|$TMPDIR_TEST/resolv.conf|g; s|/run/compwire|$TMPDIR_TEST/run/compwire|g; s|mkdir -p /run |mkdir -p $TMPDIR_TEST/run |g" "$SCRIPT" > "$PATCHED"
  # Taken where the script would sleep, so assertions can read what it wrote.
  sed -i "/sleep infinity/,/wait/c\\cp -p \"\$CFG\" \"\$CFG.written\" 2>/dev/null || true; ${1:-exit 0}" "$PATCHED"
  chmod +x "$PATCHED"
}

# Content in CONFIG_FILE, what survived the teardown in CONFIG_LIVE.
set_config_paths() {
  CONFIG_LIVE="$WG_CONFIG_DIR/${1}.conf"
  CONFIG_FILE="$CONFIG_LIVE.written"
}

# Long enough for the monitor to log, without cutting the traps. Its sleep is
# mocked to 0.01s, so this is around a hundred polls where two to four are needed.
run_entrypoint_lingering() {
  set_config_paths wg0
  patch_entrypoint '/bin/sleep 1'
  run_patched env -i PATH="$PATH" "MOCK_IFACE_EXISTS=${MOCK_IFACE_EXISTS:-0}" MOCK_SLEEP_REAL=1 "MOCK_CONFDIR=$WG_CONFIG_DIR" "$@" \
    sh "$PATCHED" > "$TMPDIR_TEST/stdout.txt" 2>&1
}

# A hang is a failure, not a 10-minute CI timeout with no output.
run_patched() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 30 "$@"
  else
    "$@"
  fi
}

# Takes KEY=VALUE pairs as separate arguments, so values may contain spaces.
run_entrypoint() {
  _iface=wg0
  for _kv in "$@"; do
    case "$_kv" in WG_IFACE=*) _iface="${_kv#WG_IFACE=}" ;; esac
  done
  set_config_paths "$_iface"
  patch_entrypoint
  run_patched env -i PATH="$PATH" "MOCK_IFACE_EXISTS=${MOCK_IFACE_EXISTS:-0}" "MOCK_CONFDIR=$WG_CONFIG_DIR" "$@" \
    sh "$PATCHED" > "$TMPDIR_TEST/stdout.txt" 2>&1
}

# Same, but invokes the script with a subcommand argument.
run_subcommand() {
  _arg="$1"; shift
  set_config_paths wg0
  patch_entrypoint
  run_patched env -i PATH="$PATH" "MOCK_IFACE_EXISTS=${MOCK_IFACE_EXISTS:-0}" "MOCK_CONFDIR=$WG_CONFIG_DIR" "$@" \
    sh "$PATCHED" "$_arg" > "$TMPDIR_TEST/stdout.txt" 2>&1
}

echo ""
echo "=== Test 1: Server - no peers (warning, interface block written) ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" || true
assert_contains     "Interface Address default"  "Address    = 10.77.0.1/24"  "$CONFIG_FILE"
assert_contains     "Interface ListenPort"        "ListenPort = 51820"          "$CONFIG_FILE"
assert_contains     "PrivateKey written"          "PrivateKey = $K_PRIV"    "$CONFIG_FILE"
if grep -qF "No peers configured" "$TMPDIR_TEST/stdout.txt" 2>/dev/null; then
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
assert_contains "Interface Address default"     "Address    = 10.77.0.2/32"           "$CONFIG_FILE"
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
PERMS="$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || stat -f '%Lp' "$CONFIG_FILE" 2>/dev/null || true)"
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
assert_stdout_contains "Invalid WG_IFACE is named as such" "WG_IFACE contains invalid characters"
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
assert_stdout_contains "The blank sweep is what catches it" "Set but empty: WG_PEER_BERLIN_PUBKEY"
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
assert_stdout_contains "The empty host is named as such" "has empty host"
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
assert_stdout_contains "Too many colons is the reason given" "(too many colons)"
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
assert_stdout_contains "Empty key file is named as empty" "WG_PRIVATE_KEY_FILE is empty"
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
assert_stdout_contains "Missing key file is named" "WG_PRIVATE_KEY_FILE does not point to an existing file"
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_PEER_BERLIN_PUBKEY=$K_BERLIN" \
   WG_PEER_BERLIN_ALLOWED_IPS=10.77.0.2/32 WG_PEER_BERLIN_PSK_FILE=/nonexistent/psk; then
  fail "Missing peer PSK file should fail"
else
  ok "Missing peer PSK file fails correctly"
fi
assert_stdout_contains "Missing peer PSK file is named" "WG_PEER_BERLIN_PSK_FILE does not point to an existing file"
if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
   WG_SERVER_ENDPOINT=1.2.3.4:51820 WG_PSK_FILE=/nonexistent/psk; then
  fail "Missing client PSK file should fail"
else
  ok "Missing client PSK file fails correctly"
fi
assert_stdout_contains "Missing client PSK file is named" "WG_PSK_FILE does not point to an existing file"
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
assert_stdout_contains "The orphan peer names its own PUBKEY" "but other WG_PEER_ORPHAN_* variables are present"
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
assert_stdout_contains "The empty address is named" "has an empty address"
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_ADDRESS=10.0.0.1/24,,10.0.0.2/24"; then
  fail "Empty list entry should fail"
else
  ok "Empty list entry fails correctly"
fi
assert_stdout_contains "The empty entry is named" "contains an empty entry"
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
assert_stdout_contains "Unknown role is named" "WG_ROLE must be 'server' or 'client'"
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
cleanup_mock_env

echo ""
echo "=== Test 62: An existing config does not carry its mode over ==="
setup_mock_env
mkdir -p "$WG_CONFIG_DIR"
touch "$WG_CONFIG_DIR/wg0.conf"
chmod 644 "$WG_CONFIG_DIR/wg0.conf"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" || true
PERMS="$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || stat -f '%Lp' "$CONFIG_FILE" 2>/dev/null || true)"
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
assert_stdout_contains "Duplicate prefix names the peer that holds it" "already assigned to peer ALPHA"
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
assert_stdout_contains "Prefix error is not doubled" "ERROR: WG_ADDRESS prefix must be 0-32 (got:"
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
echo "=== Test 74: Numbers with a leading zero are rejected ==="
setup_mock_env
for bad in WG_PORT=051820 WG_MTU=01500 WG_KEEPALIVE=025; do
  if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
     WG_SERVER_ENDPOINT=1.2.3.4:51820 "$bad"; then
    fail "$bad should fail"
  else
    ok "$bad fails correctly"
  fi
done
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  WG_SERVER_ENDPOINT=1.2.3.4:51820 WG_KEEPALIVE=099 || true
assert_stdout_contains "Leading zero is named as the reason" "must not have a leading zero"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=10.0.0.1/0 || true
assert_contains "Prefix 0 still accepted" "Address    = 10.0.0.1/0" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 75: Malformed IPv4 is rejected ==="
setup_mock_env
for bad in 10.0.0.02/32 010.0.0.1/24 10.0.0/24 1.2.3.4.5/24; do
  if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_ADDRESS=$bad"; then
    fail "WG_ADDRESS=$bad should fail"
  else
    ok "WG_ADDRESS=$bad fails correctly"
  fi
done
cleanup_mock_env

echo ""
echo "=== Test 76: Bracketed IPv6 endpoints are validated, not just charset-checked ==="
setup_mock_env
for bad in '[::::]:51820' '[gggg::1]:51820' '[1:2:3:4:5:6:7:8:9::]:51820' '[fd00::1::2]:51820'; do
  if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
     "WG_SERVER_ENDPOINT=$bad"; then
    fail "Endpoint $bad should fail"
  else
    ok "Endpoint $bad fails correctly"
  fi
done
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  "WG_SERVER_ENDPOINT=[fd00::1]:51820" || true
assert_contains "Valid bracket endpoint accepted" "Endpoint            = [fd00::1]:51820" "$CONFIG_FILE"
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  WG_SERVER_ENDPOINT=2001:db8::1:51820 || true
assert_stdout_contains "Bare IPv6 endpoint names brackets" "use [address]:port for IPv6"
cleanup_mock_env

echo ""
echo "=== Test 77: Valid IPv6 spellings are accepted ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=1:2:3:4:5:6:7::/64 || true
assert_contains "Eight colons with a trailing :: accepted" "Address    = 1:2:3:4:5:6:7::/64" "$CONFIG_FILE"
cleanup_mock_env
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=::ffff:1.2.3.4/96 || true
assert_contains "IPv4-mapped IPv6 accepted" "Address    = ::ffff:1.2.3.4/96" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 78: A newline in an unrelated variable invents no peer ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_PEER_BERLIN_PUBKEY=$K_BERLIN" \
  WG_PEER_BERLIN_ALLOWED_IPS=10.77.0.2/32 \
  "APP_BANNER=harmless
WG_PEER_GHOST_PUBKEY=x" || true
assert_stdout_contains "Real peer still configured" "Configured 1 peer(s)."
if grep -q "GHOST" "$TMPDIR_TEST/stdout.txt"; then
  fail "A newline in a foreign variable must not create a peer"
else
  ok "No ghost peer from a multi-line variable"
fi
cleanup_mock_env

echo ""
echo "=== Test 79: Duplicate AllowedIPs are caught across spellings ==="
setup_mock_env
for dup in 'FD00::1/128' 'fd00:0:0:0:0:0:0:1/128'; do
  if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
     "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=fd00::1/128 \
     "WG_PEER_B_PUBKEY=$K_NUM" "WG_PEER_B_ALLOWED_IPS=$dup"; then
    fail "$dup should collide with fd00::1/128"
  else
    ok "$dup collides with fd00::1/128"
  fi
done
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=fd00::1/128 \
  "WG_PEER_B_PUBKEY=$K_NUM" WG_PEER_B_ALLOWED_IPS=fd00::2/128 || true
assert_stdout_contains "Distinct IPv6 peers accepted" "Configured 2 peer(s)."
cleanup_mock_env

echo ""
echo "=== Test 80: A peer may not claim the interface's own key or address ==="
setup_mock_env
OWN_PUB="$(printf '%s' "$K_PRIV" | "$MOCK_BIN/wg" pubkey)"
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=10.77.0.1/24 \
   "WG_PEER_A_PUBKEY=$OWN_PUB" WG_PEER_A_ALLOWED_IPS=10.77.0.2/32; then
  fail "A peer using the server's own key should fail"
else
  ok "Peer with the server's own key fails correctly"
fi
assert_stdout_contains "Own key collision is named" "own public key, not a peer's"
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=10.77.0.1/24 \
   "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=10.77.0.1/32; then
  fail "A peer claiming the server's own address should fail"
else
  ok "Peer claiming the server address fails correctly"
fi
assert_stdout_contains "Own address collision is named" "own address from WG_ADDRESS"
cleanup_mock_env

echo ""
echo "=== Test 81: Key shapes wg itself would reject ==="
setup_mock_env
K_NOPAD="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
K_SHORTPAD="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
K_BADTAIL="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB="
for bad in "$K_NOPAD" "$K_SHORTPAD" "$K_BADTAIL"; do
  if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$bad"; then
    fail "Key '$bad' should fail"
  else
    ok "Key ending '$(printf '%s' "$bad" | tail -c 4)' fails correctly"
  fi
done
assert_stdout_contains "Bad final character is named" "bad final character"
cleanup_mock_env

echo ""
echo "=== Test 82: WG_IFACE may not start with a dash ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_IFACE=-r; then
  fail "WG_IFACE=-r should fail"
else
  ok "WG_IFACE=-r fails correctly"
fi
assert_stdout_contains "Leading dash is named" "must start with a letter or a digit"
cleanup_mock_env

echo ""
echo "=== Test 83: WG_DNS list shape is validated ==="
setup_mock_env
for bad in '1.1.1.1,' ',1.1.1.1' '1.1.1.1,,8.8.8.8'; do
  if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_DNS=$bad"; then
    fail "WG_DNS=$bad should fail"
  else
    ok "WG_DNS=$bad fails correctly"
  fi
done
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_DNS=1.1.1.1,8.8.8.8 || true
assert_contains "Valid WG_DNS list accepted" "DNS        = 1.1.1.1,8.8.8.8" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 84: An aborted start leaves no config holding the key ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=10.77.0.2/32 \
  "WG_PEER_B_PUBKEY=$K_BERLIN" WG_PEER_B_ALLOWED_IPS=10.77.0.3/32 || true
if [ -f "$CONFIG_LIVE" ]; then
  fail "Config with the private key survived a failed start"
else
  ok "Config removed after a failed start"
fi
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" || true
assert_contains "Config written on success" "PrivateKey = $K_PRIV" "$CONFIG_FILE"
if [ -f "$CONFIG_LIVE" ]; then
  fail "Config with the private key survived a clean shutdown"
else
  ok "Config removed once the teardown took the interface down"
fi
cleanup_mock_env

echo ""
echo "=== Test 85: A PSK read from a file is reported under the _FILE name ==="
setup_mock_env
printf '%s\n' "$K_BADCHAR" > "$TMPDIR_TEST/badpsk"
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  WG_SERVER_ENDPOINT=1.2.3.4:51820 "WG_PSK_FILE=$TMPDIR_TEST/badpsk" || true
assert_stdout_contains "Client PSK file named in the error" "WG_PSK_FILE contains invalid characters"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_PEER_A_PUBKEY=$K_BERLIN" \
  WG_PEER_A_ALLOWED_IPS=10.77.0.2/32 "WG_PEER_A_PSK_FILE=$TMPDIR_TEST/badpsk" || true
assert_stdout_contains "Peer PSK file named in the error" "WG_PEER_A_PSK_FILE contains invalid characters"
cleanup_mock_env

echo ""
echo "=== Test 86: A peer PSK and its _FILE together warn ==="
setup_mock_env
printf '%s\n' "$K_PSKFILE" > "$TMPDIR_TEST/psk"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_PEER_A_PUBKEY=$K_BERLIN" \
  WG_PEER_A_ALLOWED_IPS=10.77.0.2/32 "WG_PEER_A_PSK=$K_PSK" "WG_PEER_A_PSK_FILE=$TMPDIR_TEST/psk" || true
assert_stdout_contains "Ignored peer PSK file is called out" "WG_PEER_A_PSK_FILE is ignored"
assert_contains "Inline peer PSK wins" "PresharedKey        = $K_PSK" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 87: A failed bring-up reports the cause and no shutdown ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" MOCK_WGQUICK_FAIL=1; then
  fail "A failing wg-quick should fail the start"
else
  ok "Failing wg-quick fails the start"
fi
assert_stdout_contains "wg-quick failure names the usual causes" "modprobe wireguard"
assert_stdout_contains "wg-quick failure names an unresolvable endpoint" "Endpoint hostname that does not resolve"
assert_stdout_contains "Shutdown is not announced for an interface that never came up" "ERROR: wg-quick could not bring up"
if grep -qF "Shutting down" "$TMPDIR_TEST/stdout.txt"; then
  fail "A failed start must not log a shutdown"
else
  ok "No shutdown line after a failed start"
fi
cleanup_mock_env

echo ""
echo "=== Test 88: A client without a handshake warns ==="
setup_mock_env
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  WG_SERVER_ENDPOINT=1.2.3.4:51820 MOCK_HANDSHAKE=0 || true
assert_stdout_contains "Missing handshake is reported" "No peer handshake after 15s"
cleanup_mock_env

echo ""
echo "=== Test 90: A second entrypoint leaves a live tunnel's config alone ==="
setup_mock_env
mkdir -p "$WG_CONFIG_DIR" "$TMPDIR_TEST/run"
printf '[Interface]\nPrivateKey = RUNNING-TUNNEL-KEY\n' > "$WG_CONFIG_DIR/wg0.conf"
#  Stands in for the container's PID 1: alive, cmdline names the script.
printf '#!/bin/sh\n/bin/sleep 30\n' > "$TMPDIR_TEST/entrypoint.sh"
chmod +x "$TMPDIR_TEST/entrypoint.sh"
"$TMPDIR_TEST/entrypoint.sh" &
OWNER_PID=$!
printf '%s\n' "$OWNER_PID" > "$TMPDIR_TEST/run/compwire-wg0.pid"
MOCK_IFACE_EXISTS=1
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV"; then
  fail "A second entrypoint against a live tunnel should fail"
else
  ok "A second entrypoint against a live tunnel fails"
fi
assert_stdout_contains "The live owner is named" "already owned by process $OWNER_PID"
assert_contains "The running tunnel's config survives" "PrivateKey = RUNNING-TUNNEL-KEY" "$WG_CONFIG_DIR/wg0.conf"
MOCK_IFACE_EXISTS=0
kill "$OWNER_PID" 2>/dev/null || true
cleanup_mock_env

echo ""
echo "=== Test 91: Interface names reserved by wg and the kernel are rejected ==="
setup_mock_env
for _name in all interfaces default; do
  if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_IFACE=$_name"; then
    fail "WG_IFACE=$_name should be rejected"
  else
    ok "WG_IFACE=$_name is rejected"
  fi
done
assert_stdout_contains "The reserved name is quoted back" "WG_IFACE must not be 'default'"
cleanup_mock_env

echo ""
echo "=== Test 92: A repeated entry in a CIDR list is rejected ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=10.0.0.1/24,10.0.0.1/24; then
  fail "A repeated address should be rejected"
else
  ok "A repeated address is rejected"
fi
assert_stdout_contains "The repeated entry is named" "WG_ADDRESS lists '10.0.0.1/24' twice"
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_ADDRESS=fd00::1/64,FD00:0:0:0:0:0:0:1/64"; then
  fail "The same IPv6 address spelled twice should be rejected"
else
  ok "The same IPv6 address spelled two ways is rejected"
fi
cleanup_mock_env

echo ""
echo "=== Test 93: An endpoint host of digits and dots is read as an address ==="
setup_mock_env
if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
   WG_SERVER_ENDPOINT=10.0.0.256:51820; then
  fail "A malformed endpoint address should be rejected"
else
  ok "A malformed endpoint address is rejected"
fi
assert_stdout_contains "The endpoint address is named" "not a valid IPv4 address in '10.0.0.256:51820'"
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  WG_SERVER_ENDPOINT=vpn.example.com:51820 || true
assert_contains "A hostname endpoint still passes" "Endpoint            = vpn.example.com:51820" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 94: A failed bring-up leaves no config holding the key ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" MOCK_WGQUICK_FAIL=1 || true
if [ -f "$CONFIG_LIVE" ]; then
  fail "A failed bring-up left the key on disk"
else
  ok "A failed bring-up removes the config"
fi
cleanup_mock_env

echo ""
echo "=== Test 95: A key read from a file is reported under the _FILE name ==="
setup_mock_env
printf '%s\n' "$K_BADCHAR" > "$TMPDIR_TEST/key"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY_FILE=$TMPDIR_TEST/key" || true
assert_stdout_contains "A bad key from a file names the _FILE variable" "WG_PRIVATE_KEY_FILE contains invalid characters"
cleanup_mock_env

echo ""
echo "=== Test 96: A secret passed where a path belongs stays out of the log ==="
setup_mock_env
if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY_FILE=$K_PRIV"; then
  fail "A key in WG_PRIVATE_KEY_FILE should fail"
else
  ok "A key in WG_PRIVATE_KEY_FILE fails"
fi
if grep -qF "$K_PRIV" "$TMPDIR_TEST/stdout.txt"; then
  fail "The key was echoed back into the log"
else
  ok "The key is not echoed back"
fi
assert_stdout_contains "The message points at the right variable" "To pass the key itself use WG_PRIVATE_KEY."
cleanup_mock_env

echo ""
echo "=== Test 97: WG_DNS accepts a search domain and rejects a blank list ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_DNS=   "; then
  fail "A blank WG_DNS should be rejected"
else
  ok "A blank WG_DNS is rejected"
fi
assert_stdout_contains "The blank list is named" "WG_DNS is set but lists no entry"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_DNS=10.0.0.1,corp_ad.local || true
assert_contains "An underscore in a search domain passes" "DNS        = 10.0.0.1,corp_ad.local" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 98: The monitor counts only handshakes inside its window ==="
setup_mock_env
NOW="$(date +%s)"
run_entrypoint_lingering WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  WG_SERVER_ENDPOINT=1.2.3.4:51820 "MOCK_HANDSHAKE=$(( NOW - 100 ))" || true
assert_stdout_contains "A handshake inside the window counts as connected" "Peer status: 1/1"
run_entrypoint_lingering WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  WG_SERVER_ENDPOINT=1.2.3.4:51820 "MOCK_HANDSHAKE=$(( NOW - 400 ))" || true
assert_stdout_contains "A stale handshake counts as disconnected" "Peer status: 0/1"
run_entrypoint_lingering WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  WG_SERVER_ENDPOINT=1.2.3.4:51820 WG_KEEPALIVE=300 "MOCK_HANDSHAKE=$(( NOW - 400 ))" || true
assert_stdout_contains "A long keepalive stretches the window" "Peer status: 1/1"
cleanup_mock_env

echo ""
echo "=== Test 99: The monitor logs the state it moves into ==="
setup_mock_env
NOW="$(date +%s)"
run_entrypoint_lingering WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=10.77.0.2/32 \
  "MOCK_HANDSHAKE=$NOW" \
  "MOCK_HANDSHAKE_AFTER=$(( NOW - 400 ))" "MOCK_FLAG=$TMPDIR_TEST/flag1" || true
assert_stdout_contains "Losing the last handshake is reported" "All peers disconnected"
run_entrypoint_lingering WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=10.77.0.2/32 \
  "MOCK_HANDSHAKE=$(( NOW - 400 ))" \
  "MOCK_HANDSHAKE_AFTER=$NOW" "MOCK_FLAG=$TMPDIR_TEST/flag2" || true
assert_stdout_contains "Regaining a handshake is reported" "All peers connected (1/1)"
run_entrypoint_lingering WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=10.77.0.2/32 \
  "WG_PEER_B_PUBKEY=$K_NUM" WG_PEER_B_ALLOWED_IPS=10.77.0.3/32 \
  "MOCK_HANDSHAKE=$NOW" "MOCK_HANDSHAKE2=$NOW" \
  "MOCK_HANDSHAKE_AFTER=$(( NOW - 400 ))" "MOCK_FLAG=$TMPDIR_TEST/flag3" || true
assert_stdout_contains "One peer of two dropping out is reported" "Partial connectivity (1/2"
run_entrypoint_lingering WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  WG_SERVER_ENDPOINT=1.2.3.4:51820 "MOCK_HANDSHAKE=$NOW" \
  MOCK_HS_GONE_AFTER=1 "MOCK_FLAG=$TMPDIR_TEST/flag4" || true
assert_stdout_contains "A vanished interface is reported" "Interface wg0 is gone"
_gone_lines="$(grep -c "is gone" "$TMPDIR_TEST/stdout.txt" || true)"
if [ "$_gone_lines" = "1" ]; then
  ok "The vanished interface is reported once, not repeatedly"
else
  fail "The vanished interface was reported $_gone_lines times"
fi
cleanup_mock_env

echo ""
echo "=== Test 100: SIGTERM tears down once, exits 143 and clears the runfile ==="
setup_mock_env
patch_entrypoint '/bin/sleep 5'
RUNFILE_TEST="$TMPDIR_TEST/run/compwire-wg0.pid"
env -i PATH="$PATH" MOCK_IFACE_EXISTS=0 MOCK_SLEEP_REAL=1 \
  WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" sh "$PATCHED" > "$TMPDIR_TEST/stdout.txt" 2>&1 &
SIG_PID=$!
_wait=0
while [ "$_wait" -lt 100 ] && ! grep -q "is up (port" "$TMPDIR_TEST/stdout.txt" 2>/dev/null; do
  /bin/sleep 0.05; _wait=$(( _wait + 1 ))
done
if [ -f "$RUNFILE_TEST" ] && [ "$(cat "$RUNFILE_TEST")" = "$SIG_PID" ]; then
  ok "A running tunnel leaves a runfile naming its own process"
else
  fail "The runfile is missing or names the wrong process"
fi
kill -TERM "$SIG_PID" 2>/dev/null || true
SIG_RC=0; wait "$SIG_PID" || SIG_RC=$?
if [ "$SIG_RC" -eq 143 ]; then
  ok "SIGTERM exits 143"
else
  fail "SIGTERM exited $SIG_RC, expected 143"
fi
_shut="$(grep -c "Shutting down" "$TMPDIR_TEST/stdout.txt" || true)"
if [ "$_shut" = "1" ]; then
  ok "The shutdown is logged exactly once"
else
  fail "The shutdown was logged $_shut times"
fi
if [ -f "$RUNFILE_TEST" ]; then
  fail "The runfile outlived the process"
else
  ok "The runfile is removed on the way out"
fi
cleanup_mock_env

echo ""
echo "=== Test 101: A runfile that names no live entrypoint does not block ==="
setup_mock_env
mkdir -p "$TMPDIR_TEST/run"
EXPECT_PUB="$(printf '%s' "$K_PRIV" | "$MOCK_BIN/wg" pubkey)"
MOCK_IFACE_EXISTS=1
printf 'notapid\n' > "$TMPDIR_TEST/run/compwire-wg0.pid"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "MOCK_IFACE_PUBKEY=$EXPECT_PUB" || true
assert_stdout_contains "A garbage runfile is ignored" "leftover from an earlier run"
/bin/sleep 30 &
FOREIGN_PID=$!
printf '%s\n' "$FOREIGN_PID" > "$TMPDIR_TEST/run/compwire-wg0.pid"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "MOCK_IFACE_PUBKEY=$EXPECT_PUB" || true
assert_stdout_contains "A reused PID is ignored" "leftover from an earlier run"
kill "$FOREIGN_PID" 2>/dev/null || true
MOCK_IFACE_EXISTS=0
cleanup_mock_env

echo ""
echo "=== Test 102: An interface wg cannot read fails the start ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" MOCK_WGSHOW_FAIL=1; then
  fail "An unreadable interface should fail the start"
else
  ok "An unreadable interface fails the start"
fi
assert_stdout_contains "The unreadable interface is named" "WireGuard interface wg0 failed to start"
assert_stdout_contains "The teardown of a half-started tunnel is announced" "Shutting down wg0"
cleanup_mock_env

echo ""
echo "=== Test 103: A failed teardown is not swallowed ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" MOCK_WGQUICK_DOWNFAIL=1 || true
assert_stdout_contains "A failed wg-quick down warns" "wg-quick down wg0 failed"
cleanup_mock_env

echo ""
echo "=== Test 104: wg-quick and the hooks inherit no secrets ==="
setup_mock_env
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  WG_SERVER_ENDPOINT=1.2.3.4:51820 "WG_PSK=$K_PSK" \
  "MOCK_WGQUICK_ENVDUMP=$TMPDIR_TEST/wgq.env" || true
assert_not_contains "The private key is out of wg-quick's environment" "$K_PRIV" "$TMPDIR_TEST/wgq.env"
assert_not_contains "The PSK is out of wg-quick's environment" "$K_PSK" "$TMPDIR_TEST/wgq.env"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_PEER_A_PUBKEY=$K_BERLIN" \
  WG_PEER_A_ALLOWED_IPS=10.77.0.2/32 "WG_PEER_A_PSK=$K_PSK" \
  "MOCK_WGQUICK_ENVDUMP=$TMPDIR_TEST/wgq2.env" || true
assert_not_contains "The peer PSK is out of wg-quick's environment" "$K_PSK" "$TMPDIR_TEST/wgq2.env"
cleanup_mock_env

echo ""
echo "=== Test 105: Range checks reject the first value past the limit ==="
setup_mock_env
for _bad in WG_MTU=1279 WG_MTU=9001 WG_IFACE=abcdefghijklmnop WG_ADDRESS=10.0.0./24 \
            WG_ADDRESS=::1:2:3:4:5:6:7:8/64 WG_TABLE=4294967296; do
  if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "$_bad"; then
    fail "$_bad should be rejected"
  else
    ok "$_bad is rejected"
  fi
done
for _bad in WG_KEEPALIVE=65536 WG_SERVER_ENDPOINT=1.2.3.4:65536; do
  if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
     WG_SERVER_ENDPOINT=1.2.3.4:51820 "$_bad"; then
    fail "$_bad should be rejected"
  else
    ok "$_bad is rejected"
  fi
done
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_MTU=1280 WG_IFACE=abcdefghijklmno || true
assert_contains "The lowest valid MTU is accepted" "MTU        = 1280" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 106: genkey derives the public key it prints ==="
setup_mock_env
run_subcommand genkey || true
GK_PRIV="$(sed -n 's/^PRIVATE_KEY=//p' "$TMPDIR_TEST/stdout.txt")"
GK_PUB="$(sed -n 's/^PUBLIC_KEY=//p' "$TMPDIR_TEST/stdout.txt")"
GK_EXPECT="$(printf '%s' "$GK_PRIV" | "$MOCK_BIN/wg" pubkey)"
if [ -n "$GK_PUB" ] && [ "$GK_PUB" = "$GK_EXPECT" ]; then
  ok "The printed public key belongs to the printed private key"
else
  fail "genkey printed a public key that is not derived from its private key"
fi
if [ "${#GK_PUB}" = "44" ] && [ "${#GK_PRIV}" = "44" ]; then
  ok "Both keys have the WireGuard key shape"
else
  fail "genkey printed keys of ${#GK_PRIV} and ${#GK_PUB} characters"
fi
if run_subcommand bogus WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV"; then
  fail "An unknown argument should fail even with a valid environment"
else
  ok "An unknown argument fails even with a valid environment"
fi
cleanup_mock_env

echo ""
echo "=== Test 109: The reclaim uses wg-quick before it resorts to ip link del ==="
setup_mock_env
EXPECT_PUB="$(printf '%s' "$K_PRIV" | "$MOCK_BIN/wg" pubkey)"
WGQ_LOG="$TMPDIR_TEST/wgquick.log"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" MOCK_IFACE_EXISTS=1 \
  "MOCK_IFACE_PUBKEY=$EXPECT_PUB" "MOCK_WGQUICK_LOG=$WGQ_LOG" || true
assert_stdout_contains "The leftover is announced" "leftover from an earlier run"
if [ "$(head -n 1 "$WGQ_LOG" 2>/dev/null)" = "down wg0" ]; then
  ok "wg-quick down runs before anything else"
else
  fail "The reclaim did not start with wg-quick down (log: $(tr '\n' '/' < "$WGQ_LOG" 2>/dev/null))"
fi
assert_stdout_contains "The device itself is removed too" "MOCK ip link del wg0"
cleanup_mock_env

echo ""
echo "=== Test 110: A leftover is removed even when wg-quick down fails ==="
setup_mock_env
EXPECT_PUB="$(printf '%s' "$K_PRIV" | "$MOCK_BIN/wg" pubkey)"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" MOCK_IFACE_EXISTS=1 \
  "MOCK_IFACE_PUBKEY=$EXPECT_PUB" MOCK_WGQUICK_DOWNFAIL=1 || true
assert_stdout_contains "The fallback deletes the device" "MOCK ip link del wg0"
cleanup_mock_env

echo ""
echo "=== Test 111: The monitor window matches the healthcheck, at the boundary ==="
setup_mock_env
DOCKERFILE="$(cd "$(dirname "$0")/.." && pwd)/Dockerfile"
if [ ! -f "$DOCKERFILE" ]; then
  fail "The Dockerfile is not next to the suite, so the healthcheck cannot be checked against it"
else
  #  The same arithmetic lives in the Dockerfile; nothing else notices a drift.
  # shellcheck disable=SC2016
  for _const in 'max=185' 'ka + 125' '"$ka" -gt 60'; do
    if grep -qF "$_const" "$DOCKERFILE"; then
      ok "The healthcheck still carries $_const"
    else
      fail "The healthcheck no longer carries $_const"
    fi
  done
fi
#  The clock is pinned: the 184s case has one second of slack against the real one.
PIN_NOW="$(date +%s)"
cat > "$MOCK_BIN/date" <<EOF
#!/bin/sh
[ "\$1" = "+%s" ] && { echo "$PIN_NOW"; exit 0; }
exec /bin/date "\$@"
EOF
chmod +x "$MOCK_BIN/date"
run_entrypoint_lingering WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=10.77.0.2/32 \
  "MOCK_HANDSHAKE=$(( PIN_NOW - 184 ))" || true
assert_stdout_contains "A handshake just inside the window counts" "Peer status: 1/1"
run_entrypoint_lingering WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=10.77.0.2/32 \
  "MOCK_HANDSHAKE=$(( PIN_NOW - 186 ))" || true
assert_stdout_contains "A handshake just outside it does not" "Peer status: 0/1"
cleanup_mock_env

echo ""
echo "=== Test 112: A keepalive over 60s widens the window, 60 itself does not ==="
setup_mock_env
#  At ka=61 the boundary is one second wide, too narrow for the real clock.
FIXED_NOW="$(date +%s)"
cat > "$MOCK_BIN/date" <<EOF
#!/bin/sh
[ "\$1" = "+%s" ] && { echo "$FIXED_NOW"; exit 0; }
exec /bin/date "\$@"
EOF
chmod +x "$MOCK_BIN/date"
run_entrypoint_lingering WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_SERVER_PUBKEY=$K_SRVPUB" WG_SERVER_ENDPOINT=1.2.3.4:51820 WG_KEEPALIVE=60 \
  "MOCK_HANDSHAKE=$(( FIXED_NOW - 186 ))" || true
assert_stdout_contains "60 keeps the 185s window" "Peer status: 0/1"
run_entrypoint_lingering WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_SERVER_PUBKEY=$K_SRVPUB" WG_SERVER_ENDPOINT=1.2.3.4:51820 WG_KEEPALIVE=61 \
  "MOCK_HANDSHAKE=$(( FIXED_NOW - 186 ))" || true
assert_stdout_contains "61 widens it to ka + 125" "Peer status: 1/1"
run_entrypoint_lingering WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_SERVER_PUBKEY=$K_SRVPUB" WG_SERVER_ENDPOINT=1.2.3.4:51820 \
  "MOCK_HANDSHAKE=$(( FIXED_NOW - 185 ))" || true
assert_stdout_contains "185s is still connected" "Peer status: 1/1"
run_entrypoint_lingering WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_SERVER_PUBKEY=$K_SRVPUB" WG_SERVER_ENDPOINT=1.2.3.4:51820 \
  "MOCK_HANDSHAKE=$(( FIXED_NOW - 186 ))" || true
assert_stdout_contains "186s is not" "Peer status: 0/1"
rm -f "$MOCK_BIN/date"
cleanup_mock_env

echo ""
echo "=== Test 113: A peer keepalive widens the server's window too ==="
setup_mock_env
run_entrypoint_lingering WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=10.77.0.2/32 \
  "MOCK_HANDSHAKE=$(( $(date +%s) - 300 ))" || true
assert_stdout_contains "Without one, 300s is stale" "Peer status: 0/1"
run_entrypoint_lingering WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=10.77.0.2/32 WG_PEER_A_KEEPALIVE=300 \
  "MOCK_HANDSHAKE=$(( $(date +%s) - 300 ))" || true
assert_stdout_contains "With WG_PEER_A_KEEPALIVE=300 it is current" "Peer status: 1/1"
cleanup_mock_env

echo ""
echo "=== Test 114: A PSK ignored on a server does not reach wg-quick ==="
setup_mock_env
ENVDUMP="$TMPDIR_TEST/envdump.txt"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_PSK=$K_PSK" \
  "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=10.77.0.2/32 \
  "MOCK_WGQUICK_ENVDUMP=$ENVDUMP" || true
assert_stdout_contains "The ignored PSK is called out" "WG_PSK/WG_PSK_FILE is ignored"
assert_not_contains "The ignored PSK is unset, not just unused" "$K_PSK" "$ENVDUMP"
cleanup_mock_env

echo ""
echo "=== Test 115: A private key wg itself refuses fails the start ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" MOCK_PUBKEY_FAIL=1; then
  fail "A key wg cannot read should fail the start"
else
  ok "A key wg cannot read fails the start"
fi
assert_stdout_contains "The rejected key is named" "WG_PRIVATE_KEY is not a valid WireGuard key"
cleanup_mock_env

echo ""
echo "=== Test 116: A key longer than 44 characters is rejected, by length ==="
setup_mock_env
K_LONG="${K_PRIV}AAAA"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_LONG" || true
assert_stdout_contains "48 characters is not a key" "got 48 characters"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=${K_PRIV} " || true
assert_stdout_contains "A trailing space is reported as a length" "got 45 characters"
cleanup_mock_env

echo ""
echo "=== Test 117: WG_PORT is pinned at both ends, and the log reports it ==="
setup_mock_env
for _p in 0 65536; do
  if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_PORT=$_p"; then
    fail "WG_PORT=$_p should be rejected"
  else
    ok "WG_PORT=$_p is rejected"
  fi
done
for _p in 1 65535; do
  if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_PORT=$_p"; then
    ok "WG_PORT=$_p is accepted"
  else
    fail "WG_PORT=$_p should be accepted"
  fi
done
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_PORT=51821 || true
assert_contains        "The port reaches the config" "ListenPort = 51821" "$CONFIG_FILE"
assert_stdout_contains "The port reaches the log"    "is up (port 51821)"
cleanup_mock_env

echo ""
echo "=== Test 118: An endpoint port of 0 is rejected ==="
setup_mock_env
if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_SERVER_PUBKEY=$K_SRVPUB" WG_SERVER_ENDPOINT=1.2.3.4:0; then
  fail "An endpoint port of 0 should be rejected"
else
  ok "An endpoint port of 0 is rejected"
fi
assert_stdout_contains "The endpoint port is named" "WG_SERVER_ENDPOINT port"
cleanup_mock_env

echo ""
echo "=== Test 119: A client PSK and its _FILE together warn, and the inline one wins ==="
setup_mock_env
printf '%s\n' "$K_CLPSKFILE" > "$TMPDIR_TEST/clpsk"
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  WG_SERVER_ENDPOINT=1.2.3.4:51820 "WG_PSK=$K_CLPSK" "WG_PSK_FILE=$TMPDIR_TEST/clpsk" || true
assert_stdout_contains "The ignored client PSK file is called out" "WG_PSK_FILE is ignored"
assert_contains     "The inline client PSK wins" "PresharedKey        = $K_CLPSK" "$CONFIG_FILE"
assert_not_contains "The file PSK is not used"   "$K_CLPSKFILE" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 120: A resolv.conf that cannot take the marker fails the start ==="
setup_mock_env
patch_entrypoint
: > "$TMPDIR_TEST/resolv.conf"
if [ "$(id -u)" = "0" ]; then
  echo "  [SKIP] running as root, the mode bits do not apply"
else
  chmod 444 "$TMPDIR_TEST/resolv.conf"
  if run_patched env -i PATH="$PATH" MOCK_IFACE_EXISTS=0 \
    WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_DNS=1.1.1.1 \
    sh "$PATCHED" > "$TMPDIR_TEST/stdout.txt" 2>&1; then
    fail "An unwritable resolv.conf should fail the start"
  else
    ok "An unwritable resolv.conf fails the start"
  fi
  assert_stdout_contains "The cause names WG_DNS" "WG_DNS is set, but"
  assert_stdout_contains "The cause names the consequence" "is not writable, so wg-quick cannot apply it"
  chmod 644 "$TMPDIR_TEST/resolv.conf"
fi
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_DNS=1.1.1.1 || true
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_DNS=1.1.1.1 || true
_markers="$(grep -c '^# Generated by resolvconf$' "$TMPDIR_TEST/resolv.conf" || true)"
if [ "$_markers" = "1" ]; then
  ok "The resolvconf marker is written once"
else
  fail "The resolvconf marker appears $_markers times"
fi
cleanup_mock_env

echo ""
echo "=== Test 121: Padding around a list entry is stripped on both sides ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_ADDRESS=10.0.0.1/24 , 10.0.0.2/24" || true
assert_contains "A trailing space before the comma is trimmed" "Address    = 10.0.0.1/24 , 10.0.0.2/24" "$CONFIG_FILE"
if grep -q "ERROR" "$TMPDIR_TEST/stdout.txt"; then
  fail "Padding on either side of a comma should be accepted"
else
  ok "Padding on either side of a comma is accepted"
fi
cleanup_mock_env

echo ""
echo "=== Test 122: An address without a prefix says so ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=10.0.0.1 || true
assert_stdout_contains "The missing prefix is named" "must be in CIDR notation"
cleanup_mock_env

echo ""
echo "=== Test 123: An IPv6 address ending in a single colon is rejected ==="
setup_mock_env
for _a in '1:2:3:4:5:6:7:/64' 'fd00:1:2:3:4:5:6:/64'; do
  if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_ADDRESS=$_a"; then
    fail "WG_ADDRESS=$_a should be rejected"
  else
    ok "WG_ADDRESS=$_a is rejected"
  fi
done
cleanup_mock_env

echo ""
echo "=== Test 124: The monitor reports a tunnel that comes back, and goes again ==="
setup_mock_env
run_entrypoint_lingering WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=10.77.0.2/32 \
  "MOCK_HS_SEQ=ok gone ok gone" "MOCK_HS_SEQ_STATE=$TMPDIR_TEST/seq" || true
assert_stdout_contains "A vanished interface is reported" "Interface wg0 is gone"
_gone_count="$(grep -c "is gone; no peer status" "$TMPDIR_TEST/stdout.txt" || true)"
_stat_count="$(grep -c "Peer status:" "$TMPDIR_TEST/stdout.txt" || true)"
if [ "$_gone_count" = "2" ]; then
  ok "Each outage is reported exactly once"
else
  fail "The gone warning was logged $_gone_count times, expected 2"
fi
if [ "$_stat_count" = "2" ]; then
  ok "The recovery is reported too"
else
  fail "Peer status was logged $_stat_count times, expected 2"
fi
cleanup_mock_env

echo ""
echo "=== Test 125: Warnings are logged as warnings ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" || true
assert_stdout_contains "The no-peers notice carries WARNING" "WARNING: No peers configured"
cleanup_mock_env

echo ""
echo "=== Test 126: Two peers cannot claim one network, however it is spelled ==="
setup_mock_env
for _pair in '192.168.5.1/24 192.168.5.2/24' 'fd00::1/64 fd00::2/64' '10.0.0.0/24 10.0.0.0/24' \
             '172.16.5.130/25 172.16.5.129/25' '2001:db8:abcd:12::1/60 2001:db8:abcd:1f::9/60'; do
  _a="${_pair% *}"; _b="${_pair#* }"
  if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
    "WG_PEER_A_PUBKEY=$K_BERLIN" "WG_PEER_A_ALLOWED_IPS=$_a" \
    "WG_PEER_B_PUBKEY=$K_NUM" "WG_PEER_B_ALLOWED_IPS=$_b"; then
    fail "$_a and $_b are the same route and should collide"
  else
    ok "$_a collides with $_b"
  fi
done
assert_stdout_contains "The collision names the other peer, the entry and the network" "is already assigned to peer A (both cover"
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=10.9.0.0/16 \
  "WG_PEER_B_PUBKEY=$K_NUM" WG_PEER_B_ALLOWED_IPS=10.9.1.0/24; then
  ok "Different prefix lengths stay distinct"
else
  fail "10.9.0.0/16 beside 10.9.1.0/24 should be accepted"
fi
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=172.16.5.127/25 \
  "WG_PEER_B_PUBKEY=$K_NUM" WG_PEER_B_ALLOWED_IPS=172.16.5.130/25; then
  ok "The two halves of a /24 stay distinct"
else
  fail "172.16.5.127/25 beside 172.16.5.130/25 should be accepted"
fi
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=10.0.0.1/24,10.0.0.2/24; then
  ok "WG_ADDRESS still allows two addresses in one subnet"
else
  fail "WG_ADDRESS=10.0.0.1/24,10.0.0.2/24 should be accepted"
fi
cleanup_mock_env

echo ""
echo "=== Test 127: A peer range that swallows the server's own address warns ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=10.77.0.1/24 \
  "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=10.77.0.0/24 || true
assert_stdout_contains "The overlap is named" "covers this interface's own address 10.77.0.1"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=10.77.0.1/24 \
  "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=0.0.0.0/0 || true
if grep -q "covers this interface's own address" "$TMPDIR_TEST/stdout.txt"; then
  fail "A default route on a peer should not be warned about"
else
  ok "A default route on a peer is left alone"
fi
cleanup_mock_env

echo ""
echo "=== Test 128: A client refuses its own public key as the server's ==="
setup_mock_env
OWN_PUB="$(printf '%s' "$K_PRIV" | "$MOCK_BIN/wg" pubkey)"
if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$OWN_PUB" \
  WG_SERVER_ENDPOINT=1.2.3.4:51820; then
  fail "A client should refuse its own public key as the server's"
else
  ok "A client refuses its own public key as the server's"
fi
assert_stdout_contains "The mistake is named" "is this client's own public key"
cleanup_mock_env

echo ""
echo "=== Test 129: Variables belonging to the other role are called out ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ALLOWED_IPS=0.0.0.0/0 \
  "WG_SERVER_PUBKEY=$K_SRVPUB" WG_KEEPALIVE=25 \
  "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=10.77.0.2/32 || true
assert_stdout_contains "Client variables on a server are listed" "Ignored for WG_ROLE=server: WG_SERVER_PUBKEY WG_ALLOWED_IPS WG_KEEPALIVE"
assert_not_contains "A full tunnel is not silently dropped" "AllowedIPs          = 0.0.0.0/0" "$CONFIG_FILE"
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  WG_SERVER_ENDPOINT=1.2.3.4:51820 \
  "WG_PEER_SERVER_PUBKEY=$K_BERLIN" WG_PEER_SERVER_ALLOWED_IPS=10.77.0.0/24 || true
assert_stdout_contains "Peer variables on a client are listed" "Ignored for WG_ROLE=client: WG_PEER_SERVER_ALLOWED_IPS WG_PEER_SERVER_PUBKEY"
cleanup_mock_env

echo ""
echo "=== Test 130: WG_DNS entries are checked one by one ==="
setup_mock_env
for _d in '999.999.999.999' '8.8.8.8.8' '1.1.1.1:53' ' ,1.1.1.1' '-bad.example'; do
  if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_DNS=$_d"; then
    fail "WG_DNS='$_d' should be rejected"
  else
    ok "WG_DNS='$_d' is rejected"
  fi
done
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_DNS=corp.local; then
  fail "A search-domain-only WG_DNS should be rejected"
else
  ok "A search-domain-only WG_DNS is rejected"
fi
assert_stdout_contains "A search-domain-only list says why" "lists only search domains"
for _d in '1.1.1.1' '1.1.1.1,corp.local' '1.1.1.1 8.8.8.8' 'fd00::1' '1.1.1.1, corp_ad.local'; do
  if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_DNS=$_d"; then
    ok "WG_DNS='$_d' is accepted"
  else
    fail "WG_DNS='$_d' should be accepted"
  fi
done
cleanup_mock_env

echo ""
echo "=== Test 131: A secret file that exists but cannot be read is named ==="
setup_mock_env
if [ "$(id -u)" = "0" ]; then
  echo "  [SKIP] running as root, the mode bits do not apply"
else
  printf '%s\n' "$K_PRIVFILE" > "$TMPDIR_TEST/noread"
  chmod 000 "$TMPDIR_TEST/noread"
  if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY_FILE=$TMPDIR_TEST/noread"; then
    fail "An unreadable key file should fail the start"
  else
    ok "An unreadable key file fails the start"
  fi
  assert_stdout_contains "The variable is named, not just the errno" "WG_PRIVATE_KEY_FILE exists but is not readable"
  chmod 644 "$TMPDIR_TEST/noread"
fi
cleanup_mock_env

echo ""
echo "=== Test 132: A signal before bring-up still clears the key from disk ==="
setup_mock_env
patch_entrypoint
#  The staged path: the config is only renamed in once every check has passed.
CFG_EARLY="$WG_CONFIG_DIR/wg0.conf.new"
#  Parked between the config write and the teardown traps.
env -i PATH="$PATH" MOCK_IFACE_EXISTS=0 MOCK_SORT_DELAY=3 \
  WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=10.77.0.2/32 \
  sh "$PATCHED" > "$TMPDIR_TEST/stdout.txt" 2>&1 &
EARLY_PID=$!
_wait=0
while [ "$_wait" -lt 100 ] && [ ! -s "$CFG_EARLY" ]; do /bin/sleep 0.05; _wait=$(( _wait + 1 )); done
if grep -qF "PrivateKey = $K_PRIV" "$CFG_EARLY" 2>/dev/null; then
  ok "The key is on disk while validation is still running"
else
  fail "The config was not written before peer validation"
fi
kill -TERM "$EARLY_PID" 2>/dev/null || true
EARLY_RC=0; wait "$EARLY_PID" || EARLY_RC=$?
if [ "$EARLY_RC" -eq 143 ]; then
  ok "The signal is handled rather than defaulted"
else
  fail "A signal before bring-up exited $EARLY_RC, expected 143"
fi
#  Only bites under busybox ash: bash catches SIGTERM by itself to reach EXIT.
if [ -f "$CFG_EARLY" ]; then
  fail "The config holding the private key outlived the signal"
else
  ok "The config holding the private key is removed"
fi
cleanup_mock_env

echo ""
echo "=== Test 133: A subcommand takes no further arguments ==="
setup_mock_env
for _args in 'genkey extra' 'genpsk extra'; do
  patch_entrypoint
  # shellcheck disable=SC2086
  if run_patched env -i PATH="$PATH" WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" \
    "WG_SERVER_PUBKEY=$K_SRVPUB" WG_SERVER_ENDPOINT=1.2.3.4:51820 \
    sh "$PATCHED" $_args > "$TMPDIR_TEST/stdout.txt" 2>&1; then
    fail "'$_args' should be rejected"
  else
    ok "'$_args' is rejected"
  fi
  assert_stdout_contains "The rejected arguments are quoted back" "Too many arguments: '$_args'"
done
cleanup_mock_env

echo ""
echo "=== Test 134: The Dockerfile healthcheck, run rather than read ==="
setup_mock_env
DOCKERFILE="$(cd "$(dirname "$0")/.." && pwd)/Dockerfile"
#  Lifted out of the Dockerfile and run against the same mocks.
# shellcheck disable=SC1003  # tr's own escape for a backslash, not the shell's
HC="$(awk '/^HEALTHCHECK/,/[^\\]$/' "$DOCKERFILE" | tr -d '\\' | tr '\n' ' ' | sed 's/^.*[[:space:]]CMD //')"
hc_says() {  # hc_says <expected: healthy|unhealthy> <label> <env...>
  _want="$1"; _lbl="$2"; shift 2
  #  Ahead of "$@": env takes the last assignment, so a case can override it.
  if env -i PATH="$PATH" WG_IFACE=wg0 "MOCK_IFACE_PUBKEY=$K_SRVPUB" "$@" sh -c "$HC" >/dev/null 2>&1; then
    _got=healthy
  else
    _got=unhealthy
  fi
  if [ "$_got" = "$_want" ]; then ok "$_lbl"; else fail "$_lbl -- reported $_got"; fi
}
if [ -z "$HC" ]; then
  fail "The HEALTHCHECK could not be read out of the Dockerfile"
else
  #  The assertions sit on the exact second the window ends.
  NOW=1767225600
  cat > "$MOCK_BIN/date" <<EOF
#!/bin/sh
[ "\$1" = "+%s" ] && { echo $NOW; exit 0; }
exec /bin/date "\$@"
EOF
  chmod +x "$MOCK_BIN/date"
  hc_says healthy   "A server is healthy while the interface is there" WG_ROLE=server
  hc_says unhealthy "A server without an interface is unhealthy"       WG_ROLE=server MOCK_WGSHOW_FAIL=1
  hc_says unhealthy "A server whose interface carries no key is unhealthy" WG_ROLE=server "MOCK_IFACE_PUBKEY=(none)"
  hc_says unhealthy "A client whose interface carries no key is unhealthy" WG_ROLE=client "MOCK_IFACE_PUBKEY=(none)" "MOCK_HANDSHAKE=$NOW"
  hc_says healthy   "A fresh handshake is healthy"        WG_ROLE=client "MOCK_HANDSHAKE=$NOW"
  hc_says healthy   "184s is inside the default window"   WG_ROLE=client "MOCK_HANDSHAKE=$(( NOW - 184 ))"
  hc_says healthy   "185s is the last second inside it"   WG_ROLE=client "MOCK_HANDSHAKE=$(( NOW - 185 ))"
  hc_says unhealthy "186s is outside it"                  WG_ROLE=client "MOCK_HANDSHAKE=$(( NOW - 186 ))"
  hc_says unhealthy "A peer that never handshook is unhealthy" WG_ROLE=client MOCK_HANDSHAKE=0
  hc_says healthy   "A long keepalive widens the window"  WG_ROLE=client WG_KEEPALIVE=300 "MOCK_HANDSHAKE=$(( NOW - 400 ))"
  hc_says unhealthy "It widens it by exactly ka + 125"    WG_ROLE=client WG_KEEPALIVE=300 "MOCK_HANDSHAKE=$(( NOW - 426 ))"
  hc_says unhealthy "A leading-zero keepalive falls back to 185s" WG_ROLE=client WG_KEEPALIVE=0300 "MOCK_HANDSHAKE=$(( NOW - 300 ))"
  printf '#!/bin/sh\nexit 1\n' > "$MOCK_BIN/date"
  chmod +x "$MOCK_BIN/date"
  hc_says unhealthy "A clock that fails does not report healthy" WG_ROLE=client "MOCK_HANDSHAKE=$NOW"
  rm -f "$MOCK_BIN/date"
fi
cleanup_mock_env

echo ""
echo "=== Test 135: A WG_ variable that is set but empty is refused by name ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=10.77.0.2/32 WG_PEER_A_PSK=; then
  fail "An empty WG_PEER_A_PSK should not be treated as unset"
else
  ok "An empty peer PSK is refused"
fi
assert_stdout_contains "The empty variable is named" "Set but empty: WG_PEER_A_PSK"
if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  WG_SERVER_ENDPOINT=1.2.3.4:51820 WG_ADDRESS=; then
  fail "An empty WG_ADDRESS should not fall back to the default"
else
  ok "An empty WG_ADDRESS is refused rather than defaulted"
fi
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_MTU= WG_DNS= || true
assert_stdout_contains "Every empty variable is listed" "Set but empty: WG_DNS WG_MTU"
cleanup_mock_env

echo ""
echo "=== Test 136: Two spellings of one v4-mapped IPv6 route collide ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=::ffff:1.2.3.4/128 \
  "WG_PEER_B_PUBKEY=$K_NUM" WG_PEER_B_ALLOWED_IPS=0:0:0:0:0:ffff:1.2.3.4/128; then
  fail "The same v4-mapped address in two spellings should collide"
else
  ok "v4-mapped spellings collide"
fi
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=::ffff:1.2.3.4/96 \
  "WG_PEER_B_PUBKEY=$K_NUM" WG_PEER_B_ALLOWED_IPS=::ffff:5.6.7.8/96; then
  fail "Two host addresses in one v4-mapped /96 should collide"
else
  ok "v4-mapped host bits are masked away"
fi
cleanup_mock_env

echo ""
echo "=== Test 137: An IPv6 peer range covering the server's own address warns ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=fd00::1/64 \
  "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=fd00::/64 || true
assert_stdout_contains "The IPv6 overlap is named" "covers this interface's own address fd00::1"
cleanup_mock_env

echo ""
echo "=== Test 138: One peer listing the same route twice is redundant, not a conflict ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=10.9.0.2/24,10.9.0.3/24; then
  ok "Two entries of one peer in the same network are accepted"
else
  fail "One peer's own overlapping entries should not be refused"
fi
assert_stdout_contains "The redundant entry is named without blaming another peer" \
  "is the route 10.9.0.0/24 an earlier entry in the same list already covers"
assert_stdout_not_contains "No absent peer is blamed" "assigned to peer"
cleanup_mock_env

echo ""
echo "=== Test 139: A peer's default route may name the server's own address ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=10.77.0.1/24 \
  "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=10.77.0.1/0; then
  ok "A /0 entry is a default route, not the own address"
else
  fail "10.77.0.1/0 is the default route and should be accepted"
fi
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=10.77.0.1/24 \
  "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=10.77.0.1/32; then
  fail "A /32 of the server's own address should be refused"
else
  ok "The own address at full prefix length is still refused"
fi
assert_stdout_contains "The own-address error is named" "is this interface's own address from WG_ADDRESS"
cleanup_mock_env

echo ""
echo "=== Test 140: One IPv6 address at two prefixes in WG_ADDRESS is refused ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=fd00::1/64,fd00::1/128; then
  fail "The same IPv6 address at two prefixes should be refused"
else
  ok "The same IPv6 address at two prefixes is refused"
fi
assert_stdout_contains "The reason names the kernel's rule" "compares IPv6 addresses without their prefix"
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=10.0.0.1/24,10.0.0.1/25; then
  ok "The IPv4 equivalent stays allowed"
else
  fail "10.0.0.1/24 next to 10.0.0.1/25 is legal for IPv4"
fi
cleanup_mock_env

echo ""
echo "=== Test 141: Brackets around a literal IPv4 address are accepted ==="
setup_mock_env
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  "WG_SERVER_ENDPOINT=[1.2.3.4]:51820" || true
assert_contains "The bracketed IPv4 endpoint reaches the config" "Endpoint            = [1.2.3.4]:51820" "$CONFIG_FILE"
if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  "WG_SERVER_ENDPOINT=[vpn.example.com]:51820"; then
  fail "Brackets around a hostname should be refused"
else
  ok "Brackets around a hostname are refused"
fi
assert_stdout_contains "The message names the real mistake" "puts brackets around a hostname"
assert_stdout_not_contains "It does not blame IPv6 parsing" "not a valid IPv6 address"
cleanup_mock_env

echo ""
echo "=== Test 142: An empty WG_DNS entry is named as one ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_DNS=1.1.1.1, ,8.8.8.8"; then
  fail "An empty WG_DNS entry should be refused"
else
  ok "An empty WG_DNS entry is refused"
fi
assert_stdout_contains "The empty entry is named as such" "WG_DNS contains an empty entry"
assert_stdout_not_contains "It is not reported as a bad address" "not a valid IPv4 address in ''"
cleanup_mock_env

echo ""
echo "=== Test 143: A key that came from a file is blamed on the file variable ==="
setup_mock_env
printf '%s\n' "$K_PRIVFILE" > "$TMPDIR_TEST/privkey.txt"
if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY_FILE=$TMPDIR_TEST/privkey.txt" \
  "WG_SERVER_PUBKEY=$K_SRVPUB" WG_SERVER_ENDPOINT=1.2.3.4:51820 MOCK_PUBKEY_FAIL=1; then
  fail "A key wg rejects should fail the start"
else
  ok "A key wg rejects fails the start"
fi
assert_stdout_contains "The file variable is named" "WG_PRIVATE_KEY_FILE is not a valid WireGuard key"
cleanup_mock_env

echo ""
echo "=== Test 144: A second entrypoint is refused before either has an interface ==="
setup_mock_env
mkdir -p "$TMPDIR_TEST/run"
printf '#!/bin/sh\n/bin/sleep 30\n' > "$TMPDIR_TEST/entrypoint.sh"
chmod +x "$TMPDIR_TEST/entrypoint.sh"
"$TMPDIR_TEST/entrypoint.sh" &
CLAIM_PID=$!
printf '%s\n' "$CLAIM_PID" > "$TMPDIR_TEST/run/compwire-wg0.pid"
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV"; then
  fail "A live claim should refuse the second entrypoint even with no interface up"
else
  ok "A live claim refuses the second entrypoint with no interface up"
fi
assert_stdout_contains "The owner is named" "already owned by process $CLAIM_PID"
if [ -s "$TMPDIR_TEST/run/compwire-wg0.pid" ]; then
  ok "The refused entrypoint leaves the owner's runfile alone"
else
  fail "The refused entrypoint deleted the owner's runfile"
fi
kill "$CLAIM_PID" 2>/dev/null || true
wait "$CLAIM_PID" 2>/dev/null || true
printf '%s\n' "$CLAIM_PID" > "$TMPDIR_TEST/run/compwire-wg0.pid"
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV"; then
  ok "A stale claim is taken over"
else
  fail "A claim naming a dead PID should be taken over"
fi
cleanup_mock_env

echo "=== Test 145: SIGINT tears down like SIGTERM ==="
setup_mock_env
#  Foreground: a non-interactive shell sets SIGINT to ignored in every '&' job,
#  and ignored on entry cannot be trapped.
patch_entrypoint '/bin/sleep 5'
RUNFILE_TEST="$TMPDIR_TEST/run/compwire-wg0.pid"
: > "$TMPDIR_TEST/stdout.txt"
(
  #  The bring-up line, not the runfile: the claim is taken in the prologue.
  _w=0
  while [ "$_w" -lt 600 ] && ! grep -q "is up (port" "$TMPDIR_TEST/stdout.txt" 2>/dev/null; do
    /bin/sleep 0.05; _w=$(( _w + 1 ))
  done
  [ -s "$RUNFILE_TEST" ] && kill -INT "$(cat "$RUNFILE_TEST")" 2>/dev/null
) &
INT_HELPER=$!
INT_RC=0
run_patched env -i PATH="$PATH" MOCK_IFACE_EXISTS=0 MOCK_SLEEP_REAL=1 \
  WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  sh "$PATCHED" > "$TMPDIR_TEST/stdout.txt" 2>&1 || INT_RC=$?
wait "$INT_HELPER" 2>/dev/null || true
if [ "$INT_RC" -eq 130 ]; then
  ok "SIGINT exits 130"
else
  fail "SIGINT should exit 130, got $INT_RC"
fi
if [ -f "$RUNFILE_TEST" ]; then
  fail "SIGINT left the runfile behind"
else
  ok "SIGINT removes the runfile"
fi
assert_stdout_contains "The teardown is announced" "Shutting down wg0"
cleanup_mock_env

echo "=== Test 146: Keys ending in other legal base64 characters are accepted ==="
setup_mock_env
for _tail in E I M Q U Y c g k o s w 0 4 8; do
  _k="$(fake_key "TAIL${_tail}")"
  _k="$(printf '%s' "$_k" | sed "s/.\{2\}\$/${_tail}=/")"
  if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$_k"; then
    ok "A key ending in ${_tail}= is accepted"
  else
    fail "A key ending in ${_tail}= should be accepted"
  fi
done
cleanup_mock_env

echo ""
echo "=== Test 147: Every IPv4 octet is validated, not just the first and last ==="
setup_mock_env
for _bad in 10.256.0.1 10.0.256.1 10.01.0.1 10.0.01.1; do
  if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_ADDRESS=${_bad}/24"; then
    fail "$_bad should be refused"
  else
    ok "$_bad is refused"
  fi
done
cleanup_mock_env

echo ""
echo "=== Test 148: Every search-domain shape is rejected ==="
setup_mock_env
for _bad in .corp.local corp..local corp- -corp . ..; do
  if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_DNS=1.1.1.1,${_bad}"; then
    fail "$_bad should be refused as a search domain"
  else
    ok "$_bad is refused as a search domain"
  fi
done
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_DNS=1.1.1.1,corp.local."; then
  ok "A fully qualified search domain is accepted"
else
  fail "corp.local. should be accepted as a search domain"
fi
assert_contains "The trailing dot survives into the config" "DNS        = 1.1.1.1,corp.local." "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 149: Every client-only variable is named on a server ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  WG_SERVER_ENDPOINT=1.2.3.4:51820 WG_ALLOWED_IPS=10.0.0.0/8 WG_KEEPALIVE=30 || true
assert_stdout_contains "The whole list is named" \
  "Ignored for WG_ROLE=server: WG_SERVER_PUBKEY WG_SERVER_ENDPOINT WG_ALLOWED_IPS WG_KEEPALIVE"
cleanup_mock_env

echo ""
echo "=== Test 150: The collision error carries the masked network ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=172.16.5.130/25 \
  "WG_PEER_B_PUBKEY=$K_NUM" WG_PEER_B_ALLOWED_IPS=172.16.5.200/25; then
  fail "Two addresses in one /25 should collide"
else
  ok "Two addresses in one /25 collide"
fi
assert_stdout_contains "The masked network is exact" "both cover 172.16.5.128/25"
cleanup_mock_env

echo ""
echo "=== Test 151: A server with no peers reports nothing ==="
setup_mock_env
run_entrypoint_lingering WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" MOCK_NO_PEERS=1 || true
assert_stdout_not_contains "No outage is reported" "All peers disconnected"
assert_stdout_not_contains "No peer status is reported" "Peer status:"
run_entrypoint_lingering WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=10.77.0.2/32 || true
assert_stdout_contains "A server with a peer does report" "Peer status:"
cleanup_mock_env

echo ""
echo "=== Test 152: A failing teardown says what wg-quick said ==="
setup_mock_env
CONFIG_FILE="$WG_CONFIG_DIR/wg0.conf"
patch_entrypoint '/bin/sleep 0.2'
run_patched env -i PATH="$PATH" MOCK_IFACE_EXISTS=0 MOCK_WGQUICK_DOWNFAIL=1 \
  WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" sh "$PATCHED" > "$TMPDIR_TEST/stdout.txt" 2>&1 || true
assert_stdout_contains "The failure is reported" "wg-quick down wg0 failed"
assert_stdout_contains "wg-quick's own reason is replayed" "MOCK wg-quick: PostDown hook failed"
cleanup_mock_env

echo ""
echo "=== Test 153: The teardown finishes and takes the monitor with it ==="
setup_mock_env
patch_entrypoint '/bin/sleep 5'
env -i PATH="$PATH" MOCK_IFACE_EXISTS=0 MOCK_SLEEP_REAL=1 "MOCK_WG_LOG=$TMPDIR_TEST/wg.log" \
  WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=10.77.0.2/32 \
  sh "$PATCHED" > "$TMPDIR_TEST/stdout.txt" 2>&1 &
MON_PID=$!
/bin/sleep 0.6
kill -TERM "$MON_PID" 2>/dev/null || true
_w=0
while [ "$_w" -lt 60 ] && kill -0 "$MON_PID" 2>/dev/null; do /bin/sleep 0.1; _w=$(( _w + 1 )); done
if kill -0 "$MON_PID" 2>/dev/null; then
  kill -9 "$MON_PID" 2>/dev/null || true
  fail "The teardown did not finish within 6s"
else
  ok "The teardown finishes"
fi
wait "$MON_PID" 2>/dev/null || true
_before="$(wc -l < "$TMPDIR_TEST/wg.log" 2>/dev/null || echo 0)"
/bin/sleep 0.5
_after="$(wc -l < "$TMPDIR_TEST/wg.log" 2>/dev/null || echo 0)"
if [ "$_before" = "$_after" ]; then
  ok "Nothing polls wg after the teardown"
else
  fail "Something was still polling wg after the teardown ($_before -> $_after)"
fi
cleanup_mock_env

echo "=== Test 154: A key file is read past the whitespace around it ==="
setup_mock_env
printf '%s\r\n' "$K_PRIVFILE" > "$TMPDIR_TEST/crlf.key"
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY_FILE=$TMPDIR_TEST/crlf.key" \
  "WG_SERVER_PUBKEY=$K_SRVPUB" WG_SERVER_ENDPOINT=1.2.3.4:51820 || true
assert_contains "A CRLF key file still yields the key" "PrivateKey = $K_PRIVFILE" "$CONFIG_FILE"
printf '  %s  \n' "$K_PRIVFILE" > "$TMPDIR_TEST/padded.key"
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY_FILE=$TMPDIR_TEST/padded.key" \
  "WG_SERVER_PUBKEY=$K_SRVPUB" WG_SERVER_ENDPOINT=1.2.3.4:51820 || true
assert_contains "A padded key file still yields the key" "PrivateKey = $K_PRIVFILE" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 155: Diagnostics go where a supervisor looks for them ==="
setup_mock_env
patch_entrypoint
run_patched env -i PATH="$PATH" MOCK_IFACE_EXISTS=0 WG_ROLE=server sh "$PATCHED" \
  > "$TMPDIR_TEST/out.txt" 2> "$TMPDIR_TEST/err.txt" || DIE_RC=$?
if [ "${DIE_RC:-0}" -eq 1 ]; then
  ok "A rejected configuration exits 1"
else
  fail "A rejected configuration should exit 1, got ${DIE_RC:-0}"
fi
if grep -q "ERROR:" "$TMPDIR_TEST/err.txt" && ! grep -q "ERROR:" "$TMPDIR_TEST/out.txt"; then
  ok "The error goes to stderr"
else
  fail "The error should be on stderr alone"
fi
unset DIE_RC
patch_entrypoint
env -i PATH="$PATH" MOCK_IFACE_EXISTS=0 WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" sh "$PATCHED" \
  > "$TMPDIR_TEST/out.txt" 2> "$TMPDIR_TEST/err.txt" || true
if grep -q "WARNING:" "$TMPDIR_TEST/err.txt" && ! grep -q "WARNING:" "$TMPDIR_TEST/out.txt"; then
  ok "The warning goes to stderr"
else
  fail "The warning should be on stderr alone"
fi
if grep -qE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\] Role: server' "$TMPDIR_TEST/out.txt"; then
  ok "Log lines are timestamped"
else
  fail "Log lines should start with a UTC timestamp"
fi
cleanup_mock_env

echo ""
echo "=== Test 156: A symlink in the config directory does not get the key ==="
setup_mock_env
mkdir -p "$WG_CONFIG_DIR"
printf 'not the config\n' > "$TMPDIR_TEST/bystander"
chmod 644 "$TMPDIR_TEST/bystander"
ln -s "$TMPDIR_TEST/bystander" "$WG_CONFIG_DIR/wg0.conf"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" || true
if grep -qF "$K_PRIV" "$TMPDIR_TEST/bystander"; then
  fail "The private key was written through a symlink"
else
  ok "The config write does not follow a symlink"
fi
assert_contains "The file behind the link is untouched" "not the config" "$TMPDIR_TEST/bystander"
cleanup_mock_env

echo ""
echo "=== Test 157: A teardown that leaves the device behind says so ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" MOCK_WGQUICK_FAIL=1 \
  MOCK_WGQUICK_DOWNFAIL=1 "MOCK_IFACE_FLAG=$TMPDIR_TEST/iface" || true
assert_stdout_contains "A half-built interface that survives the teardown is reported" \
  "wg-quick down wg0 failed"
assert_stdout_contains "wg-quick's reason comes with it" "MOCK wg-quick: PostDown hook failed"
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" MOCK_WGQUICK_FAIL=1 \
  MOCK_WGQUICK_DOWNFAIL=1 || true
assert_stdout_not_contains "A teardown with nothing left behind stays quiet" \
  "wg-quick down wg0 failed"
cleanup_mock_env

echo ""
echo "=== Test 158: The teardown leaves an interface that changed hands alone ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "MOCK_IFACE_PUBKEY=$K_SRVPUB" "MOCK_WGQUICK_LOG=$TMPDIR_TEST/wgq.log" || true
assert_stdout_contains "The takeover is reported" "carries another public key now"
if grep -q '^down wg0$' "$TMPDIR_TEST/wgq.log" 2>/dev/null; then
  fail "The teardown took down an interface belonging to somebody else"
else
  ok "The teardown does not take down a foreign interface"
fi
cleanup_mock_env

echo ""
echo "=== Test 159: The claim outlives the teardown it protects ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "MOCK_CLAIM_PROBE=$TMPDIR_TEST/run/compwire-wg0.pid" || true
assert_contains "The runfile is still held while wg-quick down runs" "claim-held-during-down" \
  "$TMPDIR_TEST/run/compwire-wg0.pid.seen"
if [ -f "$TMPDIR_TEST/run/compwire-wg0.pid" ]; then
  fail "The runfile outlived the teardown"
else
  ok "The runfile is gone once the teardown finished"
fi
cleanup_mock_env

echo ""
echo "=== Test 160: A value cannot forge a log line ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" 'WG_IFACE=wg0
[2026-01-01T00:00:00Z] Interface wg0 is up (port 51820).' || true
assert_stdout_contains "The rejection still names the variable" "WG_IFACE contains invalid characters"
if grep -qE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z\] Interface wg0 is up' "$TMPDIR_TEST/stdout.txt"; then
  fail "A value forged a log line of its own"
else
  ok "A newline in a value cannot start a log line"
fi
printf 'WG_IFACE=wg0\033[2K[2026-01-01T00:00:00Z] fake\n' > "$TMPDIR_TEST/esc.env"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "$(cat "$TMPDIR_TEST/esc.env")" || true
if grep -q "$(printf '\033')" "$TMPDIR_TEST/stdout.txt"; then
  fail "An escape sequence reached the log"
else
  ok "Escape sequences are stripped from the log"
fi
cleanup_mock_env

echo ""
echo "=== Test 161: A client that moved its address but not its routes is warned ==="
setup_mock_env
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  WG_SERVER_ENDPOINT=1.2.3.4:51820 WG_ADDRESS=10.8.0.2/32 || true
assert_stdout_contains "The stale default route is named" \
  "WG_ALLOWED_IPS is still the default 10.77.0.1/32"
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  WG_SERVER_ENDPOINT=1.2.3.4:51820 WG_ADDRESS=10.8.0.2/32 WG_ALLOWED_IPS=10.77.0.1/32 || true
assert_stdout_not_contains "An explicit WG_ALLOWED_IPS is left alone" \
  "WG_ALLOWED_IPS is still the default"
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  WG_SERVER_ENDPOINT=1.2.3.4:51820 || true
assert_stdout_not_contains "The untouched pair says nothing" "WG_ALLOWED_IPS is still the default"
cleanup_mock_env

echo ""
echo "=== Test 162: A /0 in WG_ADDRESS is called out ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=fd00::1/0 || true
assert_stdout_contains "The IPv6 default route is named" "turns it into a default route"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=10.77.0.1/24 || true
assert_stdout_not_contains "A normal prefix says nothing" "has prefix 0"
cleanup_mock_env

echo ""
echo "=== Test 163: An all-zero key is refused ==="
setup_mock_env
K_ZERO="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  WG_SERVER_ENDPOINT=1.2.3.4:51820 "WG_PSK=$K_ZERO"; then
  fail "An all-zero PSK should be refused"
else
  ok "An all-zero PSK is refused"
fi
assert_stdout_contains "The zero key is explained" "same as configuring no key at all"
assert_stdout_contains "The zero key is named by its variable" "WG_PSK is all zero bytes"
cleanup_mock_env

echo ""
echo "=== Test 164: A blank inside a list entry is named as one ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_PEER_A_PUBKEY=$K_BERLIN" "WG_PEER_A_ALLOWED_IPS=10.9.0.0/24 10.9.1.0/24"; then
  fail "A space-separated list should be refused"
else
  ok "A space-separated list is refused"
fi
assert_stdout_contains "The separator is named" "separates entries with a comma"
assert_stdout_not_contains "The prefix is not blamed" "prefix must be a number"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_ADDRESS=10.0.0.1/24,	fd00::1/64" || true
assert_contains "A tab after the comma is padding" "Address    = 10.0.0.1/24,	fd00::1/64" "$CONFIG_FILE"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_DNS=1.1.1.1,	8.8.8.8" || true
assert_contains "A tab in WG_DNS is padding too" "DNS        = 1.1.1.1,	8.8.8.8" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 165: An endpoint is read the way wg reads it ==="
setup_mock_env
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  "WG_SERVER_ENDPOINT= vpn.example.com:51820 " || true
assert_contains "A padded endpoint is accepted and trimmed" \
  "Endpoint            = vpn.example.com:51820" "$CONFIG_FILE"
if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  WG_SERVER_ENDPOINT=https://vpn.example.com:51820; then
  fail "A URL should be refused"
else
  ok "A URL is refused"
fi
assert_stdout_contains "A URL is named as a URL" "is a host and a port, not a URL"
assert_stdout_not_contains "A URL is not called an IPv6 problem" "use [address]:port for IPv6"
cleanup_mock_env

echo ""
echo "=== Test 166: A newline says where it came from ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" 'WG_POST_UP=iptables -A FORWARD -j ACCEPT
'; then
  fail "A trailing newline in a hook should be refused"
else
  ok "A trailing newline in a hook is refused"
fi
assert_stdout_contains "The YAML block scalar is named" "use '>-' or '|-'"
cleanup_mock_env

echo ""
echo "=== Test 167: A claim that cannot be taken is not silent ==="
setup_mock_env
patch_entrypoint
mkdir -p "$TMPDIR_TEST/run"
printf 'notapid\n' > "$TMPDIR_TEST/run/compwire-wg0.pid"
if [ "$(id -u)" = "0" ]; then
  echo "  [SKIP] running as root, the mode bits do not apply"
else
  chmod 500 "$TMPDIR_TEST/run"
  run_patched env -i PATH="$PATH" MOCK_IFACE_EXISTS=0 \
    WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
    sh "$PATCHED" > "$TMPDIR_TEST/stdout.txt" 2>&1 || true
  assert_stdout_contains "An unclaimable runfile is reported" "Could not claim"
  chmod 700 "$TMPDIR_TEST/run"
fi
cleanup_mock_env

echo ""
echo "=== Test 168: Keys carrying the rest of the base64 alphabet ==="
setup_mock_env
K_B64="ab+cd/efGHIJ+klm/nopQRST+uvw/xyz012345+/abQ="
if [ "${#K_B64}" -ne 44 ]; then
  fail "The alphabet fixture is not 44 characters"
else
  ok "The alphabet fixture is a 44-character key"
fi
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_B64" || true
assert_contains "A key with '+' and '/' is accepted" "PrivateKey = $K_B64" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 169: The key length and the padding are named ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; then
  fail "A 43-character key should be refused"
else
  ok "A 43-character key is refused"
fi
assert_stdout_contains "The length is named" "must be a 44-character base64 WireGuard key (got 43 characters)"
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"; then
  fail "A key without the '=' pad should be refused"
else
  ok "A key without the '=' pad is refused"
fi
assert_stdout_contains "The missing pad is named" "must be a base64 WireGuard key ending in '='"
cleanup_mock_env

echo ""
echo "=== Test 170: The characters names are actually made of ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_IFACE=wg_0-1 || true
assert_stdout_contains "An underscore and a hyphen are legal in WG_IFACE" "Interface wg_0-1 is up"
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_IFACE=wg.0; then
  fail "A dot in WG_IFACE should be refused"
else
  ok "A dot in WG_IFACE is refused"
fi
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  WG_SERVER_ENDPOINT=vpn-gw.example.com:51820 || true
assert_contains "A hyphen is legal in an endpoint host" \
  "Endpoint            = vpn-gw.example.com:51820" "$CONFIG_FILE"
if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  "WG_SERVER_ENDPOINT=vpn;evil:51820"; then
  fail "A semicolon in an endpoint host should be refused"
else
  ok "A semicolon in an endpoint host is refused"
fi
assert_stdout_contains "The host is named, not the port" "has an invalid host"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_DNS=1.1.1.1,my-corp.local || true
assert_contains "A hyphen is legal in a search domain" "DNS        = 1.1.1.1,my-corp.local" "$CONFIG_FILE"
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "WG_DNS=1.1.1.1,evil;domain"; then
  fail "A semicolon in WG_DNS should be refused"
else
  ok "A semicolon in WG_DNS is refused"
fi
assert_stdout_contains "The DNS charset is named" "WG_DNS contains invalid characters"
cleanup_mock_env

echo ""
echo "=== Test 171: A PSK file that cannot be read is named the same way ==="
setup_mock_env
if [ "$(id -u)" = "0" ]; then
  echo "  [SKIP] running as root, the mode bits do not apply"
else
  printf '%s\n' "$K_CLPSKFILE" > "$TMPDIR_TEST/psk_noread"
  chmod 000 "$TMPDIR_TEST/psk_noread"
  if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
    WG_SERVER_ENDPOINT=1.2.3.4:51820 "WG_PSK_FILE=$TMPDIR_TEST/psk_noread"; then
    fail "An unreadable WG_PSK_FILE should fail the start"
  else
    ok "An unreadable WG_PSK_FILE fails the start"
  fi
  assert_stdout_contains "WG_PSK_FILE is named" "WG_PSK_FILE exists but is not readable"
  assert_stdout_contains "The cap_drop cause is given" "world-readable"
  if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
    "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=10.77.0.2/32 \
    "WG_PEER_A_PSK_FILE=$TMPDIR_TEST/psk_noread"; then
    fail "An unreadable peer PSK file should fail the start"
  else
    ok "An unreadable peer PSK file fails the start"
  fi
  assert_stdout_contains "The peer PSK file is named" "WG_PEER_A_PSK_FILE exists but is not readable"
  chmod 600 "$TMPDIR_TEST/psk_noread"
fi
cleanup_mock_env

echo ""
echo "=== Test 172: A stale claim is taken over rather than worked around ==="
setup_mock_env
mkdir -p "$TMPDIR_TEST/run"
printf '999999\n' > "$TMPDIR_TEST/run/compwire-wg0.pid"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" || true
assert_stdout_contains "The tunnel comes up" "Interface wg0 is up"
assert_stdout_not_contains "The claim was taken, not skipped" "Could not claim"
cleanup_mock_env

echo ""
echo "=== Test 173: An IPv6 address of the interface's own is refused too ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=fd00::1/64 \
  "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=fd00::1/128; then
  fail "A peer claiming the server's own IPv6 address should be refused"
else
  ok "A peer claiming the server's own IPv6 address is refused"
fi
assert_stdout_contains "The own IPv6 address is named" "is this interface's own address from WG_ADDRESS"
cleanup_mock_env

echo ""
echo "=== Test 174: The v4-mapped tail is folded, not just compared to itself ==="
setup_mock_env
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=::ffff:1.2.3.4/128 \
  "WG_PEER_B_PUBKEY=$K_NUM" WG_PEER_B_ALLOWED_IPS=::ffff:102:304/128; then
  fail "The two spellings of one route should collide"
else
  ok "The two spellings of one route collide"
fi
assert_stdout_contains "The collision names the other peer" "already assigned to peer A"
cleanup_mock_env

echo ""
echo "=== Test 175: The numeric ranges at their edges ==="
setup_mock_env
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  WG_SERVER_ENDPOINT=1.2.3.4:51820 WG_KEEPALIVE=1 || true
assert_contains "Keepalive 1 is accepted" "PersistentKeepalive = 1" "$CONFIG_FILE"
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  WG_SERVER_ENDPOINT=1.2.3.4:51820 WG_KEEPALIVE=65535 || true
assert_contains "Keepalive 65535 is accepted" "PersistentKeepalive = 65535" "$CONFIG_FILE"
if run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  WG_SERVER_ENDPOINT=1.2.3.4:51820 WG_KEEPALIVE=65536; then
  fail "Keepalive 65536 should be refused"
else
  ok "Keepalive 65536 is refused"
fi
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_TABLE=4294967295 || true
assert_contains "The last routing table is accepted" "Table      = 4294967295" "$CONFIG_FILE"
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_TABLE=4294967296; then
  fail "A table beyond 32 bits should be refused"
else
  ok "A table beyond 32 bits is refused"
fi
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_TABLE=on; then
  fail "WG_TABLE=on should be refused"
else
  ok "WG_TABLE=on is refused"
fi
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_ADDRESS=255.255.255.254/24 || true
assert_contains "An octet of 255 is accepted" "Address    = 255.255.255.254/24" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 176: Peers are written in version order ==="
setup_mock_env
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_PEER_2_PUBKEY=$K_BERLIN" WG_PEER_2_ALLOWED_IPS=10.77.0.2/32 \
  "WG_PEER_10_PUBKEY=$K_NUM" WG_PEER_10_ALLOWED_IPS=10.77.0.10/32 || true
_l2="$(grep -n 'AllowedIPs          = 10.77.0.2/32' "$CONFIG_FILE" | cut -d: -f1)"
_l10="$(grep -n 'AllowedIPs          = 10.77.0.10/32' "$CONFIG_FILE" | cut -d: -f1)"
if [ -n "$_l2" ] && [ -n "$_l10" ] && [ "$_l2" -lt "$_l10" ]; then
  ok "Peer 2 is written before peer 10"
else
  fail "Peer order is $_l2 then $_l10, expected 2 before 10"
fi
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=10.77.0.2/32 WG_PEER_A_FOO=x; then
  fail "An unknown peer attribute should be refused"
else
  ok "An unknown peer attribute is refused"
fi
assert_stdout_contains "The unknown attribute is named" "Unknown peer variable 'WG_PEER_A_FOO'"
cleanup_mock_env

echo ""
echo "=== Test 177: A key file whose path contains a space ==="
setup_mock_env
mkdir -p "$TMPDIR_TEST/key dir"
printf '%s\n' "$K_PRIVFILE" > "$TMPDIR_TEST/key dir/priv.key"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY_FILE=$TMPDIR_TEST/key dir/priv.key" || true
assert_contains "A key file under a path with a space is read" \
  "PrivateKey = $K_PRIVFILE" "$CONFIG_FILE"
cleanup_mock_env

echo ""
echo "=== Test 178: The monitor polls on the interval it documents ==="
setup_mock_env
run_entrypoint_lingering WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=10.77.0.2/32 \
  "MOCK_SLEEP_LOG=$TMPDIR_TEST/sleeps.txt" || true
if grep -qx '30' "$TMPDIR_TEST/sleeps.txt" 2>/dev/null; then
  ok "The monitor asks for 30s between polls"
else
  fail "The monitor did not poll on 30s (asked for: $(tr '\n' ' ' < "$TMPDIR_TEST/sleeps.txt" 2>/dev/null))"
fi
cleanup_mock_env

echo ""
echo "=== Test 179: A numbered table swallows a full tunnel ==="
setup_mock_env
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  WG_SERVER_ENDPOINT=1.2.3.4:51820 WG_ALLOWED_IPS=0.0.0.0/0 WG_TABLE=100 || true
assert_stdout_contains "A numbered table with a default route is reported" "adds no ip rule pointing at it"
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  WG_SERVER_ENDPOINT=1.2.3.4:51820 WG_ALLOWED_IPS=::/0 WG_TABLE=100 || true
assert_stdout_contains "The IPv6 default route counts too" "adds no ip rule pointing at it"
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  WG_SERVER_ENDPOINT=1.2.3.4:51820 WG_ALLOWED_IPS=0.0.0.0/0 WG_TABLE=off || true
assert_stdout_not_contains "Table off is not warned about" "adds no ip rule pointing at it"
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  WG_SERVER_ENDPOINT=1.2.3.4:51820 WG_ALLOWED_IPS=0.0.0.0/0 WG_TABLE=auto || true
assert_stdout_not_contains "Table auto is not warned about" "adds no ip rule pointing at it"
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  WG_SERVER_ENDPOINT=1.2.3.4:51820 WG_ALLOWED_IPS=10.77.0.0/24 WG_TABLE=100 || true
assert_stdout_not_contains "A numbered table without a default route is fine" "adds no ip rule pointing at it"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  "WG_PEER_A_PUBKEY=$K_BERLIN" WG_PEER_A_ALLOWED_IPS=0.0.0.0/0 WG_TABLE=100 || true
assert_stdout_contains "A peer route of 0.0.0.0/0 counts as well" "adds no ip rule pointing at it"
cleanup_mock_env

echo ""
echo "=== Test 181: A device wg-quick created but never configured is ours ==="
setup_mock_env
MOCK_IFACE_EXISTS=1
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "MOCK_IFACE_PUBKEY=(none)" || true
assert_stdout_contains "A keyless leftover is reclaimed" "leftover from an earlier run"
assert_stdout_not_contains "A keyless leftover is not called a stranger's" "belongs to something else"
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" MOCK_IFACE_PUBKEY=; then
  fail "A device wg cannot read should abort the start"
else
  ok "A device wg cannot read aborts the start"
fi
assert_stdout_contains "A device wg cannot read is left alone" "belongs to something else"
MOCK_IFACE_EXISTS=0
cleanup_mock_env

echo ""
echo "=== Test 182: The teardown of a tunnel that really came up ==="
setup_mock_env
EXPECT_PUB="$(printf '%s' "$K_PRIV" | "$MOCK_BIN/wg" pubkey)"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "MOCK_IFACE_PUBKEY=$EXPECT_PUB" \
  "MOCK_WGQUICK_LOG=$TMPDIR_TEST/wgq.log" || true
assert_stdout_not_contains "Our own tunnel is not mistaken for a stranger's" "carries another public key"
if grep -q '^down wg0$' "$TMPDIR_TEST/wgq.log" 2>/dev/null; then
  ok "The teardown takes our own interface down"
else
  fail "The teardown left our own interface standing"
fi
cleanup_mock_env

echo ""
echo "=== Test 183: A failed teardown is worded by the device, not by a latch ==="
setup_mock_env
patch_entrypoint '/bin/sleep 0.2'
run_patched env -i PATH="$PATH" MOCK_IFACE_EXISTS=0 MOCK_WGQUICK_DOWNFAIL=1 \
  "MOCK_CONFDIR=$WG_CONFIG_DIR" WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  sh "$PATCHED" > "$TMPDIR_TEST/stdout.txt" 2>&1 || true
assert_stdout_contains "A gone interface is reported as gone" "is already gone"
assert_stdout_not_contains "A gone interface is not reported as standing" "still there"
run_patched env -i PATH="$PATH" MOCK_IFACE_EXISTS=1 MOCK_WGQUICK_DOWNFAIL=1 \
  "MOCK_IFACE_PUBKEY=$(printf '%s' "$K_PRIV" | "$MOCK_BIN/wg" pubkey)" \
  "MOCK_CONFDIR=$WG_CONFIG_DIR" WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  sh "$PATCHED" > "$TMPDIR_TEST/stdout.txt" 2>&1 || true
assert_stdout_contains "A surviving interface is reported as surviving" "still there"
cleanup_mock_env

echo ""
echo "=== Test 184: The base64 tail is refused on more than one example ==="
setup_mock_env
for _tail in B 9 z + /; do
  _k="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA${_tail}="
  if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$_k"; then
    fail "A key ending in '${_tail}=' should be refused"
  else
    ok "A key ending in '${_tail}=' is refused"
  fi
  assert_stdout_contains "The final character is named for '${_tail}='" "bad final character"
done
cleanup_mock_env

echo ""
echo "=== Test 185: A leftover that will not delete stops the start ==="
setup_mock_env
MOCK_IFACE_EXISTS=1
if run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
   "MOCK_IFACE_PUBKEY=$(printf '%s' "$K_PRIV" | "$MOCK_BIN/wg" pubkey)" \
   MOCK_WGQUICK_DOWNFAIL=1 MOCK_IPDEL_FAIL=1; then
  fail "A leftover that cannot be removed should fail the start"
else
  ok "A leftover that cannot be removed fails the start"
fi
assert_stdout_contains "The undeletable leftover is named" "could not be removed"
MOCK_IFACE_EXISTS=0
cleanup_mock_env

echo ""
echo "=== Test 186: A runfile this process did not create is left alone ==="
setup_mock_env
patch_entrypoint
mkdir -p "$TMPDIR_TEST/run"
#  A dangling symlink: set -C refuses to create through it and [ -f ] is false.
ln -s "$TMPDIR_TEST/run/nothing-here" "$TMPDIR_TEST/run/compwire-wg0.pid"
run_patched env -i PATH="$PATH" MOCK_IFACE_EXISTS=0 "MOCK_CONFDIR=$WG_CONFIG_DIR" \
  WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" sh "$PATCHED" > "$TMPDIR_TEST/stdout.txt" 2>&1 || true
assert_stdout_contains "An unclaimable runfile is reported" "Could not claim"
if [ -L "$TMPDIR_TEST/run/compwire-wg0.pid" ]; then
  ok "A claim that was never taken is not removed on the way out"
else
  fail "The teardown removed a runfile this process never owned"
fi
cleanup_mock_env

echo ""
echo "=== Test 187: A start that dies before the config exists drops its claim ==="
setup_mock_env
patch_entrypoint
mkdir -p "$WG_CONFIG_DIR/wg0.conf.new"
run_patched env -i PATH="$PATH" MOCK_IFACE_EXISTS=0 "MOCK_CONFDIR=$WG_CONFIG_DIR" \
  WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" sh "$PATCHED" > "$TMPDIR_TEST/stdout.txt" 2>&1 || true
if [ -e "$TMPDIR_TEST/run/compwire-wg0.pid" ]; then
  fail "A failed config write left the claim behind"
else
  ok "The claim is dropped when the config write fails"
fi
assert_stdout_contains "The failed config write says so in compwire's own words" "Could not replace"
cleanup_mock_env

echo ""
echo "=== Test 188: The directory holding the key is created 700 ==="
setup_mock_env
rm -rf "$WG_CONFIG_DIR"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" || true
DIRPERMS="$(stat -c '%a' "$WG_CONFIG_DIR" 2>/dev/null || stat -f '%Lp' "$WG_CONFIG_DIR" 2>/dev/null || true)"
if [ "$DIRPERMS" = "700" ]; then
  ok "The config directory is created 700"
else
  fail "The config directory is $DIRPERMS, not 700"
fi
cleanup_mock_env

echo ""
echo "=== Test 189: A start that fails leaves an existing config alone ==="
setup_mock_env
patch_entrypoint
printf '[Interface]\nPrivateKey = RUNNING-TUNNEL-KEY\n' > "$WG_CONFIG_DIR/wg0.conf"
run_patched env -i PATH="$PATH" MOCK_IFACE_EXISTS=0 "MOCK_CONFDIR=$WG_CONFIG_DIR" \
  WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_PEER_X_PUBKEY=not-a-key \
  sh "$PATCHED" > "$TMPDIR_TEST/stdout.txt" 2>&1 || true
assert_stdout_contains "The bad peer key is what stopped it" "WG_PEER_X_PUBKEY must be a 44-character"
assert_contains "The running tunnel's config survives a failed validation" "PrivateKey = RUNNING-TUNNEL-KEY" "$WG_CONFIG_DIR/wg0.conf"
if [ -e "$WG_CONFIG_DIR/wg0.conf.new" ]; then
  fail "The staged config was left behind"
else
  ok "The staged config is cleaned up"
fi
printf '[Interface]\nPrivateKey = RUNNING-TUNNEL-KEY\n' > "$WG_CONFIG_DIR/wg0.conf"
run_patched env -i PATH="$PATH" MOCK_IFACE_EXISTS=1 MOCK_IFACE_PUBKEY=FAKEPUBsomeoneelse \
  "MOCK_CONFDIR=$WG_CONFIG_DIR" WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" \
  sh "$PATCHED" > "$TMPDIR_TEST/stdout.txt" 2>&1 || true
assert_stdout_contains "The foreign interface is what stopped it" "belongs to something else"
assert_contains "The running tunnel's config survives a refused start" "PrivateKey = RUNNING-TUNNEL-KEY" "$WG_CONFIG_DIR/wg0.conf"
cleanup_mock_env

echo ""
echo "=== Test 190: A config that cannot be moved into place says so ==="
setup_mock_env
patch_entrypoint
mkdir -p "$WG_CONFIG_DIR/wg0.conf"
run_patched env -i PATH="$PATH" MOCK_IFACE_EXISTS=0 "MOCK_CONFDIR=$WG_CONFIG_DIR" \
  WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" sh "$PATCHED" > "$TMPDIR_TEST/stdout.txt" 2>&1 || true
assert_stdout_contains "The failed rename is named as such" "Could not move"
assert_stdout_not_contains "It is not reported as a failed create" "Could not create"
#  Every later test writes this path.
rm -rf "$WG_CONFIG_DIR/wg0.conf"
cleanup_mock_env

echo ""
echo "=== Test 191: The default-AllowedIPs warning knows the default range ==="
setup_mock_env
for _addr in 10.77.0.2/32 10.77.0.3/32 10.77.0.200/32 10.77.0.2/32,fd00::2/128; do
  run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
    WG_SERVER_ENDPOINT=vpn.example.com:51820 "WG_ADDRESS=$_addr" || true
  assert_stdout_not_contains "No AllowedIPs warning for $_addr" "WG_ALLOWED_IPS is still the default"
done
for _addr in 192.168.50.2/32 fd00::2/128; do
  run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
    WG_SERVER_ENDPOINT=vpn.example.com:51820 "WG_ADDRESS=$_addr" || true
  assert_stdout_contains "The stale default is named for $_addr" "WG_ALLOWED_IPS is still the default"
done
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  WG_SERVER_ENDPOINT=vpn.example.com:51820 WG_ADDRESS=192.168.50.2/32 WG_ALLOWED_IPS=10.77.0.1/32 || true
assert_stdout_not_contains "An explicit AllowedIPs is never second-guessed" "WG_ALLOWED_IPS is still the default"
run_entrypoint WG_ROLE=client "WG_PRIVATE_KEY=$K_PRIV" "WG_SERVER_PUBKEY=$K_SRVPUB" \
  WG_SERVER_ENDPOINT=vpn.example.com:51820 WG_ADDRESS=nonsense || true
assert_stdout_contains "The invalid address is what is reported" "must be in CIDR notation"
assert_stdout_not_contains "It does not first blame AllowedIPs" "WG_ALLOWED_IPS is still the default"
cleanup_mock_env

echo ""
echo "=== Test 192: A stale resolvconf subscriber is dropped before bring-up ==="
setup_mock_env
RCLOG="$TMPDIR_TEST/resolvconf.log"
: > "$RCLOG"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_DNS=1.1.1.1 "MOCK_RESOLVCONF_LOG=$RCLOG" || true
assert_contains "The subscriber for this interface is cleared" "-d wg0" "$RCLOG"
: > "$RCLOG"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" WG_IFACE=wg9 WG_DNS=1.1.1.1 "MOCK_RESOLVCONF_LOG=$RCLOG" || true
assert_contains "It follows WG_IFACE" "-d wg9" "$RCLOG"
: > "$RCLOG"
run_entrypoint WG_ROLE=server "WG_PRIVATE_KEY=$K_PRIV" "MOCK_RESOLVCONF_LOG=$RCLOG" || true
if [ -s "$RCLOG" ]; then
  fail "resolvconf was called without WG_DNS"
else
  ok "resolvconf is left alone without WG_DNS"
fi
cleanup_mock_env

echo ""
echo "=================================="
printf   "  Result: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "=================================="
[ "$FAIL" -eq 0 ]
