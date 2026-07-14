#!/bin/sh
set -eu

log()  { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
warn() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] WARNING: $*" >&2; }
die()  { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: $*" >&2; exit 1; }

# --- Subcommand: genkey ---
if [ "${1:-}" = "genkey" ]; then
  priv=$(wg genkey)
  pub=$(printf '%s' "$priv" | wg pubkey)
  printf 'PRIVATE_KEY=%s\nPUBLIC_KEY=%s\n' "$priv" "$pub"
  exit 0
fi

# --- Subcommand: showqr ---
_showqr=0
[ "${1:-}" = "showqr" ] && _showqr=1

# Validate a single IPv4 or IPv6 CIDR.
validate_cidr() {
  _label="$1" _cidr="$2"
  _ip="${_cidr%/*}" _prefix="${_cidr#*/}"
  [ "$_ip" = "$_cidr" ] && \
    die "$_label must be in CIDR notation (e.g. 10.0.0.1/24 or fd00::1/64), got: '$_cidr'."
  case "$_prefix" in
    ''|*[!0-9]*) die "$_label prefix must be a number, got: '$_cidr'." ;;
  esac
  case "$_ip" in
    *:*)
      [ "$_prefix" -gt 128 ] && die "$_label IPv6 prefix must be 0-128, got: '$_cidr'."
      case "$_ip" in
        *[!0-9a-fA-F:]*) die "$_label is not a valid IPv6 address in '$_cidr'." ;;
      esac
      case "$_ip" in
        *:::*) die "$_label is not a valid IPv6 address in '$_cidr' (':::')." ;;
      esac
      case "$_ip" in
        *::*::*) die "$_label is not a valid IPv6 address in '$_cidr' (multiple '::')." ;;
      esac
      case "$_ip" in
        ::*) ;;
        :*) die "$_label is not a valid IPv6 address in '$_cidr' (leading single ':')." ;;
      esac
      case "$_ip" in
        *::) ;;
        *:) die "$_label is not a valid IPv6 address in '$_cidr' (trailing single ':')." ;;
      esac
      _colon_count=$(printf '%s' "$_ip" | tr -cd ':' | wc -c | tr -d ' ')
      if [ "$_colon_count" -gt 7 ]; then
        die "$_label is not a valid IPv6 address in '$_cidr' (too many colons)."
      fi
      case "$_ip" in
        *::*) ;;
        *)
          if [ "$_colon_count" -ne 7 ]; then
            die "$_label is not a valid IPv6 address in '$_cidr' (fewer than 8 groups without '::')."
          fi
          ;;
      esac
      _gIFS="$IFS"; IFS=':'
      for _group in $_ip; do
        case "$_group" in
          ?????*) die "$_label is not a valid IPv6 address in '$_cidr' (group '$_group' too long)." ;;
        esac
      done
      IFS="$_gIFS"
      ;;
    *)
      [ "$_prefix" -gt 32 ] && die "$_label prefix must be 0-32, got: '$_cidr'."
      printf '%s' "$_ip" | awk -F. '
        NF!=4 { exit 1 }
        $1=="" || $2=="" || $3=="" || $4=="" { exit 1 }
        $1~/[^0-9]/ || $2~/[^0-9]/ || $3~/[^0-9]/ || $4~/[^0-9]/ { exit 1 }
        $1>255 || $2>255 || $3>255 || $4>255 { exit 1 }
      ' || die "$_label must be a valid IPv4 CIDR (e.g. 10.0.0.1/24), got: '$_cidr'."
      ;;
  esac
}

# Validate a comma-separated list of IPv4 or IPv6 CIDRs (e.g. WG_ADDRESS).
validate_cidr_list() {
  _label="$1" _list="$2"
  _oIFS="$IFS"; IFS=','
  # shellcheck disable=SC2086
  for _entry in $_list; do
    _entry="${_entry# }"; _entry="${_entry% }"
    [ -z "$_entry" ] && die "$_label contains an empty entry in '$_list'."
    validate_cidr "$_label" "$_entry"
  done
  IFS="$_oIFS"
}

# Validate MTU: integer 1280-9000.
validate_mtu() {
  case "$1" in
    ''|*[!0-9]*) die "WG_MTU must be a number (got: '$1')." ;;
  esac
  if [ "$1" -lt 1280 ] || [ "$1" -gt 9000 ]; then
    die "WG_MTU must be 1280-9000 (got: $1)."
  fi
}

# Validate Table: 'auto', 'off', or a positive routing table ID.
validate_table() {
  case "$1" in
    auto|off) return 0 ;;
    ''|*[!0-9]*) die "WG_TABLE must be 'auto', 'off', or a positive integer (got: '$1')." ;;
  esac
  if [ "$1" -lt 1 ]; then
    die "WG_TABLE as integer must be >= 1 (got: '$1')."
  fi
}

# Reject newlines - would inject extra wg-quick config keys.
validate_no_newline() {
  case "$2" in
    *'
'*) die "$1 must not contain newline characters." ;;
  esac
}

# Validate DNS: allowlist for IPs, hostnames, comma/space separators.
validate_dns() {
  [ -z "$1" ] && die "WG_DNS is set but empty."
  case "$1" in
    *[!A-Za-z0-9.:,\ -]*) die "WG_DNS contains invalid characters: '$1'." ;;
  esac
}

# Validate a WireGuard key or PSK: 44 base64 chars (32 bytes).
validate_wg_key() {
  _label="$1" _key="$2"
  [ -z "$_key" ] && die "$_label is empty."
  case "$_key" in
    *[!A-Za-z0-9+/=]*) die "$_label contains invalid characters (must be base64)." ;;
  esac
  if [ "${#_key}" -ne 44 ]; then
    die "$_label must be a 44-character base64 WireGuard key (got ${#_key} characters)."
  fi
}

# Validate keepalive: integer 1-65535.
validate_keepalive() {
  _label="$1" _val="$2"
  case "$_val" in
    ''|*[!0-9]*) die "$_label must be a number (got: '$_val')." ;;
  esac
  if [ "$_val" -lt 1 ] || [ "$_val" -gt 65535 ]; then
    die "$_label must be 1-65535 (got: '$_val')."
  fi
}

# Validate endpoint: host:port or [ipv6]:port.
validate_endpoint() {
  _label="$1" _ep="$2"
  validate_no_newline "$_label" "$_ep"
  case "$_ep" in
    \[*\]:*)
      _host="${_ep#[}"; _host="${_host%%]:*}"
      _port="${_ep##*:}"
      [ -z "$_host" ] && die "$_label has empty host (got: '$_ep')."
      ;;
    *:*)
      _rest="${_ep#*:}"
      case "$_rest" in
        *:*) die "$_label has multiple colons without brackets; use [address]:port for IPv6 (got: '$_ep')." ;;
      esac
      _host="${_ep%%:*}"
      _port="${_ep##*:}"
      [ -z "$_host" ] && die "$_label has empty host (got: '$_ep')."
      ;;
    *)
      die "$_label must be in host:port format (got: '$_ep')."
      ;;
  esac
  case "$_port" in
    ''|*[!0-9]*) die "$_label port must be a number (got: '$_ep')." ;;
  esac
  if [ "$_port" -lt 1 ] || [ "$_port" -gt 65535 ]; then
    die "$_label port must be 1-65535 (got: '$_ep')."
  fi
}

# --- Required variables ---
WG_ROLE="${WG_ROLE:-}"
[ -z "$WG_ROLE" ] && die "WG_ROLE must be 'server' or 'client'."
case "$WG_ROLE" in
  server|client) ;;
  *) die "WG_ROLE must be 'server' or 'client' (got: '$WG_ROLE')." ;;
esac

# Resolve WG_PRIVATE_KEY from file if needed
if [ -z "${WG_PRIVATE_KEY:-}" ] && [ -n "${WG_PRIVATE_KEY_FILE:-}" ]; then
  [ -f "$WG_PRIVATE_KEY_FILE" ] || die "WG_PRIVATE_KEY_FILE points to non-existent file: '$WG_PRIVATE_KEY_FILE'."
  WG_PRIVATE_KEY="$(tr -d '[:space:]' < "$WG_PRIVATE_KEY_FILE")"
fi
[ -z "${WG_PRIVATE_KEY:-}" ] && die "WG_PRIVATE_KEY (or WG_PRIVATE_KEY_FILE) is not set."
validate_wg_key "WG_PRIVATE_KEY" "$WG_PRIVATE_KEY"

# --- Optional [Interface] variables ---
# Clients get no ListenPort unless WG_PORT is set - avoids port clashes on a shared network stack.
if [ "$WG_ROLE" = "server" ]; then
  WG_PORT="${WG_PORT:-51820}"
else
  WG_PORT="${WG_PORT:-}"
fi
WG_IFACE="${WG_IFACE:-wg0}"
WG_MTU="${WG_MTU:-}"
WG_TABLE="${WG_TABLE:-}"
WG_DNS="${WG_DNS:-}"
WG_PRE_UP="${WG_PRE_UP:-}"
WG_POST_UP="${WG_POST_UP:-}"
WG_PRE_DOWN="${WG_PRE_DOWN:-}"
WG_POST_DOWN="${WG_POST_DOWN:-}"

if [ -n "$WG_PORT" ]; then
  case "$WG_PORT" in
    *[!0-9]*) die "WG_PORT must be a number (got: '$WG_PORT')." ;;
  esac
  if [ "$WG_PORT" -lt 1 ] || [ "$WG_PORT" -gt 65535 ]; then
    die "WG_PORT must be 1-65535 (got: $WG_PORT)."
  fi
fi

case "$WG_IFACE" in
  *[!a-zA-Z0-9_-]*) die "WG_IFACE contains invalid characters: '$WG_IFACE'." ;;
esac
if [ "${#WG_IFACE}" -gt 15 ]; then
  die "WG_IFACE must be at most 15 characters (got: '$WG_IFACE')."
fi

[ -n "$WG_MTU"   ] && validate_mtu   "$WG_MTU"
[ -n "$WG_TABLE" ] && validate_table "$WG_TABLE"
[ -n "$WG_DNS"   ] && validate_dns   "$WG_DNS"

# Hooks are arbitrary shell commands by design - only block config-line injection.
validate_no_newline "WG_PRE_UP"    "$WG_PRE_UP"
validate_no_newline "WG_POST_UP"   "$WG_POST_UP"
validate_no_newline "WG_PRE_DOWN"  "$WG_PRE_DOWN"
validate_no_newline "WG_POST_DOWN" "$WG_POST_DOWN"

# --- Role-specific variables ---
if [ "$WG_ROLE" = "server" ]; then
  WG_ADDRESS="${WG_ADDRESS:-10.77.0.1/24}"
else
  WG_ADDRESS="${WG_ADDRESS:-10.77.0.2/24}"
  WG_SERVER_PUBKEY="${WG_SERVER_PUBKEY:-}"
  WG_SERVER_ENDPOINT="${WG_SERVER_ENDPOINT:-}"
  WG_ALLOWED_IPS="${WG_ALLOWED_IPS:-10.77.0.1/32}"
  WG_KEEPALIVE="${WG_KEEPALIVE:-25}"

  [ -z "$WG_SERVER_PUBKEY" ]   && die "WG_SERVER_PUBKEY is not set."
  validate_wg_key "WG_SERVER_PUBKEY" "$WG_SERVER_PUBKEY"
  [ -z "$WG_SERVER_ENDPOINT" ] && die "WG_SERVER_ENDPOINT is not set (e.g. vpn.example.com:51820)."
  validate_endpoint "WG_SERVER_ENDPOINT" "$WG_SERVER_ENDPOINT"

  validate_keepalive "WG_KEEPALIVE" "$WG_KEEPALIVE"
  validate_cidr_list "WG_ALLOWED_IPS" "$WG_ALLOWED_IPS"

  if [ -z "${WG_PSK:-}" ] && [ -n "${WG_PSK_FILE:-}" ]; then
    [ -f "$WG_PSK_FILE" ] || die "WG_PSK_FILE points to non-existent file: '$WG_PSK_FILE'."
    WG_PSK="$(tr -d '[:space:]' < "$WG_PSK_FILE")"
  fi
  [ -n "${WG_PSK:-}" ] && validate_wg_key "WG_PSK" "$WG_PSK"
fi

validate_cidr_list "WG_ADDRESS" "$WG_ADDRESS"

WG_PUBLIC_KEY="$(printf '%s' "$WG_PRIVATE_KEY" | wg pubkey)"
log "Role: $WG_ROLE | Address: $WG_ADDRESS | Public key: $WG_PUBLIC_KEY"

# --- Write WireGuard config ---
# umask 077: file never world-readable, even before the explicit chmod 600 below.
umask 077
mkdir -p /etc/wireguard
CFG="/etc/wireguard/${WG_IFACE}.conf"

{
  printf '[Interface]\n'
  printf '%-11s= %s\n' "Address"    "$WG_ADDRESS"
  [ -n "$WG_PORT" ] && printf '%-11s= %s\n' "ListenPort" "$WG_PORT"
  printf '%-11s= %s\n' "PrivateKey" "$WG_PRIVATE_KEY"
  [ -n "$WG_DNS"       ] && printf '%-11s= %s\n' "DNS"      "$WG_DNS"
  [ -n "$WG_MTU"       ] && printf '%-11s= %s\n' "MTU"      "$WG_MTU"
  [ -n "$WG_TABLE"     ] && printf '%-11s= %s\n' "Table"    "$WG_TABLE"
  [ -n "$WG_PRE_UP"    ] && printf '%-11s= %s\n' "PreUp"    "$WG_PRE_UP"
  [ -n "$WG_POST_UP"   ] && printf '%-11s= %s\n' "PostUp"   "$WG_POST_UP"
  [ -n "$WG_PRE_DOWN"  ] && printf '%-11s= %s\n' "PreDown"  "$WG_PRE_DOWN"
  [ -n "$WG_POST_DOWN" ] && printf '%-11s= %s\n' "PostDown" "$WG_POST_DOWN"
} > "$CFG"

chmod 600 "$CFG"
unset WG_PRIVATE_KEY

if [ "$WG_ROLE" = "server" ]; then
  # Discover peers from WG_PEER_<ID>_PUBKEY env vars; ID = [A-Z0-9]+, no underscores.
  peer_ids="$(env | grep -E '^WG_PEER_[A-Z0-9]+_PUBKEY=' | sed 's/^WG_PEER_//;s/_PUBKEY=.*//' | sort -V)"

  # Reject peer vars whose ID would otherwise be silently ignored.
  bad_peer_vars="$(env | grep -E '^WG_PEER_.*_PUBKEY=' | grep -Ev '^WG_PEER_[A-Z0-9]+_PUBKEY=' | sed 's/=.*//' | sort)"
  if [ -n "$bad_peer_vars" ]; then
    die "Invalid peer ID in: $(printf '%s' "$bad_peer_vars" | tr '\n' ' ')- peer IDs must be uppercase alphanumeric (e.g. WG_PEER_NODE1_PUBKEY)."
  fi

  [ -z "$peer_ids" ] && warn "No peers configured (no WG_PEER_<ID>_PUBKEY vars found). Server will accept no connections."

  peer_count=0
  for id in $peer_ids; do
    peer_pubkey="$(printenv "WG_PEER_${id}_PUBKEY" || true)"
    peer_allowed="$(printenv "WG_PEER_${id}_ALLOWED_IPS" || true)"
    peer_psk="$(printenv "WG_PEER_${id}_PSK" || true)"
    peer_psk_file="$(printenv "WG_PEER_${id}_PSK_FILE" || true)"
    peer_endpoint="$(printenv "WG_PEER_${id}_ENDPOINT" || true)"
    peer_keepalive="$(printenv "WG_PEER_${id}_KEEPALIVE" || true)"

    [ -z "$peer_pubkey" ] && die "WG_PEER_${id}_PUBKEY is empty."
    validate_wg_key "WG_PEER_${id}_PUBKEY" "$peer_pubkey"
    [ -z "$peer_allowed" ] && die "WG_PEER_${id}_ALLOWED_IPS is not set."
    validate_cidr_list "WG_PEER_${id}_ALLOWED_IPS" "$peer_allowed"

    if [ -z "$peer_psk" ] && [ -n "$peer_psk_file" ]; then
      [ -f "$peer_psk_file" ] || die "WG_PEER_${id}_PSK_FILE points to non-existent file: '$peer_psk_file'."
      peer_psk="$(tr -d '[:space:]' < "$peer_psk_file")"
    fi
    [ -n "$peer_psk" ] && validate_wg_key "WG_PEER_${id}_PSK" "$peer_psk"

    [ -n "$peer_endpoint" ] && validate_endpoint "WG_PEER_${id}_ENDPOINT" "$peer_endpoint"

    [ -n "$peer_keepalive" ] && validate_keepalive "WG_PEER_${id}_KEEPALIVE" "$peer_keepalive"

    log "Adding peer: ${id} | AllowedIPs: ${peer_allowed}${peer_endpoint:+ | Endpoint: $peer_endpoint}"

    {
      printf '\n[Peer]\n'
      printf '%-20s= %s\n' "PublicKey"           "$peer_pubkey"
      printf '%-20s= %s\n' "AllowedIPs"          "$peer_allowed"
      [ -n "$peer_psk"       ] && printf '%-20s= %s\n' "PresharedKey"        "$peer_psk"
      [ -n "$peer_endpoint"  ] && printf '%-20s= %s\n' "Endpoint"            "$peer_endpoint"
      [ -n "$peer_keepalive" ] && printf '%-20s= %s\n' "PersistentKeepalive" "$peer_keepalive"
    } >> "$CFG"
    unset peer_psk peer_psk_file

    peer_count=$(( peer_count + 1 ))
  done

  log "Configured ${peer_count} peer(s)."

else
  # Client: single server peer
  {
    printf '\n[Peer]\n'
    printf '%-20s= %s\n' "PublicKey"           "$WG_SERVER_PUBKEY"
    printf '%-20s= %s\n' "AllowedIPs"          "$WG_ALLOWED_IPS"
    printf '%-20s= %s\n' "Endpoint"            "$WG_SERVER_ENDPOINT"
    printf '%-20s= %s\n' "PersistentKeepalive" "$WG_KEEPALIVE"
    [ -n "${WG_PSK:-}" ] && printf '%-20s= %s\n' "PresharedKey" "$WG_PSK"
  } >> "$CFG"
  unset WG_PSK
fi

# --- Subcommand: showqr (exit before starting WireGuard) ---
if [ "$_showqr" = "1" ]; then
  [ "$WG_ROLE" != "client" ] && die "showqr is only supported for WG_ROLE=client."
  warn "The QR code encodes the private key - treat it as a secret."
  log "Scan with the WireGuard app:"
  qrencode -t ansiutf8 < "$CFG"
  exit 0
fi

# --- Start WireGuard ---
log "Starting WireGuard (${WG_ROLE}) on ${WG_ADDRESS}..."
wg-quick up "$WG_IFACE"

cleanup() {
  log "Shutting down ${WG_IFACE}..."
  if [ -n "${MONITOR_PID:-}" ]; then
    kill "${MONITOR_PID}" 2>/dev/null || true
    wait "${MONITOR_PID}" 2>/dev/null || true
  fi
  wg-quick down "$WG_IFACE" 2>/dev/null || true
}
trap cleanup INT TERM EXIT

wg show "$WG_IFACE" >/dev/null 2>&1 || die "WireGuard interface ${WG_IFACE} failed to start."
log "Interface ${WG_IFACE} is up (port $(wg show "$WG_IFACE" listen-port))."

# Client: wait for initial handshake
if [ "$WG_ROLE" = "client" ]; then
  log "Waiting for peer handshake..."
  _attempts=0
  while [ $_attempts -lt 15 ]; do
    _hs="$(wg show "$WG_IFACE" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')"
    if [ -n "$_hs" ] && [ "$_hs" != "0" ]; then
      log "Peer handshake established - tunnel is live."
      break
    fi
    _attempts=$(( _attempts + 1 ))
    sleep 1
  done
  [ $_attempts -eq 15 ] && warn "No peer handshake after 15s. Tunnel may not be fully connected yet."
fi

# Background monitor: logs peer connection changes every 30s
monitor_connection() {
  _state="unknown"
  while sleep 30; do
    _now="$(date +%s)"
    _hs_data="$(wg show "$WG_IFACE" latest-handshakes 2>/dev/null || true)"
    [ -z "$_hs_data" ] && continue
    _counts="$(printf '%s\n' "$_hs_data" | awk -v now="$_now" '
      NF>=2 { total++; if ($2!="0" && (now-$2)<=185) connected++ }
      END   { print connected+0, total+0 }
    ')"
    _connected="${_counts%% *}"
    _total="${_counts##* }"
    [ "$_total" -eq 0 ] && continue
    if [ "$_connected" -eq 0 ]; then
      _cur="disconnected"
    elif [ "$_connected" -lt "$_total" ]; then
      _cur="partial"
    else
      _cur="connected"
    fi
    if [ "$_state" = "unknown" ]; then
      log "Peer status: ${_connected}/${_total} peer(s) with recent handshake."
    elif [ "$_cur" != "$_state" ]; then
      case "$_cur" in
        connected)    log  "All peers connected (${_connected}/${_total})." ;;
        partial)      warn "Partial connectivity (${_connected}/${_total} peers with recent handshake)." ;;
        disconnected) warn "All peers disconnected (no handshake within 185s)." ;;
      esac
    fi
    _state="$_cur"
  done
}

monitor_connection &
MONITOR_PID=$!

sleep infinity &
wait $!
