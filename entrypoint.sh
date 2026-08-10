#!/bin/sh
set -eu
# No globbing: values are field-split in a few places and must not expand to filenames.
set -f

# As PID 1 the shell drops every signal it has no trap for. Nothing to clean up yet.
trap 'exit 130' INT
trap 'exit 143' TERM

# Out of the text, not the finished line: a newline in a value forges a log entry.
_say() {
  _say_msg="$(printf '%s' "$*" | tr -d '\000-\010\012-\037\177')"
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_say_msg"
}
log()  { _say "$*"; }
warn() { _say "WARNING: $*" >&2; }
die()  { _say "ERROR: $*" >&2; exit 1; }

# --- Subcommands ---
[ "$#" -le 1 ] || die "Too many arguments: '$*'. Supported: genkey, genpsk."
case "${1:-}" in
  genkey)
    priv=$(wg genkey)
    pub=$(printf '%s' "$priv" | wg pubkey)
    printf 'PRIVATE_KEY=%s\nPUBLIC_KEY=%s\n' "$priv" "$pub"
    exit 0
    ;;
  genpsk)
    wg genpsk
    exit 0
    ;;
  '') ;;
  *) die "Unknown argument: '$1'. Supported: genkey, genpsk." ;;
esac

# Length first: busybox test errors out beyond 64 bits instead of comparing.
validate_uint() {
  _ui_label="$1" _ui_val="$2" _ui_min="$3" _ui_max="$4" _ui_ctx="${5:-$2}"
  case "$_ui_val" in
    ''|*[!0-9]*) die "$_ui_label must be a number (got: '$_ui_ctx')." ;;
    # $(( )) reads a leading zero as octal, and the healthcheck does that on WG_KEEPALIVE.
    0?*) die "$_ui_label must not have a leading zero (got: '$_ui_ctx')." ;;
  esac
  if [ "${#_ui_val}" -gt "${#_ui_max}" ] || [ "$_ui_val" -lt "$_ui_min" ] || [ "$_ui_val" -gt "$_ui_max" ]; then
    die "$_ui_label must be ${_ui_min}-${_ui_max} (got: '$_ui_ctx')."
  fi
}

# Strip leading and trailing blanks, tabs included. The result lands in _trimmed.
trim_spaces() {
  _trimmed="$1"
  while :; do
    case "$_trimmed" in
      [[:blank:]]*) _trimmed="${_trimmed#?}" ;;
      *[[:blank:]]) _trimmed="${_trimmed%?}" ;;
      *)    break ;;
    esac
  done
}

# Validate a dotted-quad IPv4 address. Called from validate_ipv6 with its _v6_* live.
validate_ipv4() {
  _v4_label="$1" _v4_ip="$2" _v4_ctx="${3:-$2}"
  # awk gets no record from an empty string, skips every rule below and exits 0.
  [ -z "$_v4_ip" ] && die "$_v4_label is not a valid IPv4 address in '$_v4_ctx'."
  printf '%s' "$_v4_ip" | awk -F. '
    NF!=4 { exit 1 }
    $1=="" || $2=="" || $3=="" || $4=="" { exit 1 }
    $1~/[^0-9]/ || $2~/[^0-9]/ || $3~/[^0-9]/ || $4~/[^0-9]/ { exit 1 }
    # wg rejects 10.0.0.02 while ip addr reads it as decimal.
    $1~/^0./ || $2~/^0./ || $3~/^0./ || $4~/^0./ { exit 1 }
    $1>255 || $2>255 || $3>255 || $4>255 { exit 1 }
  ' || die "$_v4_label is not a valid IPv4 address in '$_v4_ctx'."
}

# Not a full parser: it rejects early what wg and iproute2 reject without a variable name.
validate_ipv6() {
  _v6_label="$1" _v6_ip="$2" _v6_ctx="${3:-$2}"
  # An embedded IPv4 tail stands for the last two groups.
  case "$_v6_ip" in
    *.*)
      validate_ipv4 "$_v6_label" "${_v6_ip##*:}" "$_v6_ctx"
      _v6_ip="${_v6_ip%:*}:0:0"
      ;;
  esac
  case "$_v6_ip" in
    *[!0-9a-fA-F:]*) die "$_v6_label is not a valid IPv6 address in '$_v6_ctx'." ;;
  esac
  case "$_v6_ip" in
    *:::*) die "$_v6_label is not a valid IPv6 address in '$_v6_ctx' (':::')." ;;
  esac
  case "$_v6_ip" in
    *::*::*) die "$_v6_label is not a valid IPv6 address in '$_v6_ctx' (multiple '::')." ;;
  esac
  case "$_v6_ip" in
    ::*) ;;
    :*) die "$_v6_label is not a valid IPv6 address in '$_v6_ctx' (leading single ':')." ;;
  esac
  case "$_v6_ip" in
    *::) ;;
    *:) die "$_v6_label is not a valid IPv6 address in '$_v6_ctx' (trailing single ':')." ;;
  esac
  _v6_colons=$(printf '%s' "$_v6_ip" | tr -cd ':' | wc -c | tr -d ' ')
  # 1:2:3:4:5:6:7:: is eight colons and correct; in the middle '::' never is.
  _v6_max=7
  case "$_v6_ip" in
    ::*|*::) _v6_max=8 ;;
  esac
  if [ "$_v6_colons" -gt "$_v6_max" ]; then
    die "$_v6_label is not a valid IPv6 address in '$_v6_ctx' (too many colons)."
  fi
  case "$_v6_ip" in
    *::*) ;;
    *)
      if [ "$_v6_colons" -ne 7 ]; then
        die "$_v6_label is not a valid IPv6 address in '$_v6_ctx' (fewer than 8 groups without '::')."
      fi
      ;;
  esac
  _v6IFS="$IFS"; IFS=':'
  for _v6_group in $_v6_ip; do
    case "$_v6_group" in
      ?????*) IFS="$_v6IFS"; die "$_v6_label is not a valid IPv6 address in '$_v6_ctx' (group '$_v6_group' too long)." ;;
    esac
  done
  IFS="$_v6IFS"
}

validate_cidr() {
  _label="$1" _cidr="$2"
  # Ahead of everything else: wg glues "10.0.0.1/24 10.0.0.2/24" into one address.
  case "$_cidr" in
    *[[:blank:]]*) die "$_label separates entries with a comma, and '$_cidr' has a blank inside one." ;;
  esac
  _ip="${_cidr%/*}" _prefix="${_cidr#*/}"
  [ "$_ip" = "$_cidr" ] && \
    die "$_label must be in CIDR notation (e.g. 10.0.0.1/24 or fd00::1/64), got: '$_cidr'."
  [ -z "$_ip" ] && die "$_label has an empty address in '$_cidr'."
  case "$_ip" in
    *:*)
      validate_uint "$_label IPv6 prefix" "$_prefix" 0 128 "$_cidr"
      validate_ipv6 "$_label" "$_ip" "$_cidr"
      ;;
    *)
      validate_uint "$_label prefix" "$_prefix" 0 32 "$_cidr"
      validate_ipv4 "$_label" "$_ip" "$_cidr"
      ;;
  esac
}

# Expand an IPv6 CIDR to eight four-digit groups: wg compares prefixes, not spellings.
normalize_cidr() {
  _norm="$1"
  case "$_norm" in
    *:*) ;;
    *) return 0 ;;
  esac
  _norm="$(printf '%s' "$_norm" | awk -F/ '{
    a = tolower($1)
    # wg stores an embedded IPv4 tail in hex, so fold it before comparing text.
    if (a ~ /\./) {
      i = length(a)
      while (i > 0 && substr(a, i, 1) != ":") i--
      if (split(substr(a, i + 1), q, ".") == 4)
        a = substr(a, 1, i) sprintf("%x:%x", q[1] * 256 + q[2], q[3] * 256 + q[4])
    }
    if (a ~ /::/) { sub(/::/, ":@:", a) }
    n = split(a, g, ":")
    cnt = 0
    for (i = 1; i <= n; i++) if (g[i] != "" && g[i] != "@") cnt++
    out = ""
    for (i = 1; i <= n; i++) {
      if (g[i] == "@") { for (j = cnt; j < 8; j++) out = out "0000:" }
      else if (g[i] != "") { p = g[i]; while (length(p) < 4) p = "0" p; out = out p ":" }
    }
    sub(/:$/, "", out)
    # Without this a bare address comes back as "addr/", whose prefix reads as 0.
    print out ($2 == "" ? "" : "/" $2)
  }')"
}

# wg masks AllowedIPs to the prefix, so 192.168.5.1/24 and .2/24 are one route.
mask_cidr() {
  _norm="$(printf '%s' "$1" | awk -F/ '
    function h2d(s,   i, n) {
      n = 0
      for (i = 1; i <= length(s); i++) n = n * 16 + index("0123456789abcdef", substr(s, i, 1)) - 1
      return n
    }
    # busybox awk has no dependable bitwise operators.
    function clear(v, k) { return int(v / 2 ^ k) * (2 ^ k) }
    {
      p = $2 + 0
      v6 = ($1 ~ /:/)
      if (v6) { n = split(tolower($1), g, ":"); w = 16; sep = ":"; fmt = "%04x" }
      else    { n = split($1, g, ".");          w = 8;  sep = "."; fmt = "%d"   }
      out = ""
      for (i = 1; i <= n; i++) {
        v = v6 ? h2d(g[i]) : g[i] + 0
        # Bits of this group the prefix covers, clamped either side of the boundary.
        bits = p - (i - 1) * w
        if (bits < 0) bits = 0
        if (bits > w) bits = w
        out = out (i > 1 ? sep : "") sprintf(fmt, clear(v, w - bits))
      }
      print out "/" p
    }
  ')"
}

network_key() {
  _nk="$1"
  case "$_nk" in
    */*) ;;
    *:*) _nk="${_nk}/128" ;;
    *)   _nk="${_nk}/32" ;;
  esac
  normalize_cidr "$_nk"
  mask_cidr "$_norm"
}

validate_cidr_list() {
  _label="$1" _list="$2"
  validate_no_newline "$_label" "$_list"
  # A trailing comma produces no empty field when the shell splits the list.
  case "$_list" in
    ,*|*,) die "$_label must not start or end with a comma (got: '$_list')." ;;
  esac
  _cl_seen="" _cl_seen6=""
  _oIFS="$IFS"; IFS=','
  # shellcheck disable=SC2086
  for _entry in $_list; do
    trim_spaces "$_entry"; _entry="$_trimmed"
    [ -z "$_entry" ] && die "$_label contains an empty entry in '$_list'."
    validate_cidr "$_label" "$_entry"
    # wg-quick's second `ip address add` fails, under a message about the kernel module.
    normalize_cidr "$_entry"
    case " $_cl_seen " in
      *" $_norm "*) IFS="$_oIFS"; die "$_label lists '$_entry' twice." ;;
    esac
    _cl_seen="${_cl_seen} ${_norm}"
    # ipv6_chk_same_addr ignores the prefix; the IPv4 path keys on both and takes them.
    case "$_entry" in
      *:*)
        _cl_addr="${_norm%%/*}"
        case " $_cl_seen6 " in
          *" $_cl_addr "*) IFS="$_oIFS"; die "$_label already lists the address in '$_entry' with a different prefix. The kernel compares IPv6 addresses without their prefix and refuses the second one." ;;
        esac
        _cl_seen6="${_cl_seen6} ${_cl_addr}"
        ;;
    esac
  done
  IFS="$_oIFS"
}

validate_mtu() {
  validate_uint "WG_MTU" "$1" 1280 9000
}

# Validate Table: 'auto', 'off', or a routing table ID (32-bit).
validate_table() {
  case "$1" in
    auto|off) return 0 ;;
    ''|*[!0-9]*) die "WG_TABLE must be 'auto', 'off', or a positive integer (got: '$1')." ;;
  esac
  validate_uint "WG_TABLE" "$1" 1 4294967295
}

# Reject newlines - would inject extra config keys. YAML's '>' and '|' append one.
validate_no_newline() {
  case "$2" in
    *'
'*) die "$1 must not contain newline characters. A YAML block scalar written with '>' or '|' appends one; use '>-' or '|-'." ;;
  esac
}

# wg-quick sorts entries itself: all digits and dots, or a colon, is a nameserver.
validate_dns() {
  # Underscore is not legal in a hostname but common in AD search domains.
  case "$1" in
    *[!A-Za-z0-9._:,[:blank:]-]*) die "WG_DNS contains invalid characters: '$1'." ;;
  esac
  trim_spaces "$1"; _dns_list="$_trimmed"
  [ -z "$_dns_list" ] && die "WG_DNS is set but lists no entry."
  # Against the trimmed value, or " ,1.1.1.1" walks straight past this.
  case "$_dns_list" in
    ,*|*,) die "WG_DNS must not start or end with a comma (got: '$1')." ;;
    *,,*) die "WG_DNS contains an empty entry (got: '$1')." ;;
  esac
  _dns_servers=0
  # wg-quick splits on the shell's IFS, which carries comma, space and tab.
  _dTAB="$(printf '\t')"
  _dIFS="$IFS"; IFS=", ${_dTAB}"
  # shellcheck disable=SC2086
  for _dns_entry in $_dns_list; do
    # IFS absorbs the space in ", ," and still yields an empty field.
    [ -z "$_dns_entry" ] && die "WG_DNS contains an empty entry (got: '$1')."
    case "$_dns_entry" in
      *:*)
        validate_ipv6 "WG_DNS" "$_dns_entry"
        _dns_servers=$(( _dns_servers + 1 ))
        ;;
      *[!0-9.]*)
        # A trailing dot is the fully qualified spelling; resolvconf keeps it.
        _dns_dom="${_dns_entry%.}"
        case "$_dns_dom" in
          ''|.*|*.|*..*|-*|*-) die "WG_DNS entry '$_dns_entry' is not a valid search domain." ;;
        esac
        ;;
      *)
        validate_ipv4 "WG_DNS" "$_dns_entry"
        _dns_servers=$(( _dns_servers + 1 ))
        ;;
    esac
  done
  IFS="$_dIFS"
  # wg-quick's set_dns writes nothing at all when the nameserver list is empty.
  if [ "$_dns_servers" -eq 0 ]; then
    die "WG_DNS lists only search domains (got: '$1'). wg-quick writes nothing without at least one nameserver."
  fi
}

# Validate a WireGuard key or PSK: 44 base64 chars (32 bytes).
validate_wg_key() {
  _label="$1" _key="$2"
  [ -z "$_key" ] && die "$_label is empty."
  # Length before charset: a trailing space is the common mistake.
  if [ "${#_key}" -ne 44 ]; then
    die "$_label must be a 44-character base64 WireGuard key (got ${#_key} characters)."
  fi
  case "$_key" in
    *[!A-Za-z0-9+/=]*) die "$_label contains invalid characters (must be base64)." ;;
  esac
  # 32 bytes encode to 43 base64 chars plus exactly one '=' pad at the end.
  case "$_key" in
    *=) ;;
    *) die "$_label must be a base64 WireGuard key ending in '='." ;;
  esac
  case "${_key%=}" in
    *[!A-Za-z0-9+/]*) die "$_label has misplaced '=' padding (must be base64)." ;;
  esac
  # 32 bytes leave the last character two unused bits, so only every fourth one fits.
  case "$_key" in
    *[AEIMQUYcgkosw048]=) ;;
    *) die "$_label is not a valid WireGuard key (bad final character)." ;;
  esac
  # 32 zero bytes is what the kernel mixes in with no pre-shared key at all.
  case "$_key" in
    AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=)
      die "$_label is all zero bytes, which is the same as configuring no key at all. Generate one with 'genpsk' (or 'genkey' for a private key)." ;;
  esac
}

validate_keepalive() {
  validate_uint "$1" "$2" 1 65535
}

# Validate endpoint: host:port or [ipv6]:port.
validate_endpoint() {
  _label="$1" _ep="$2"
  validate_no_newline "$_label" "$_ep"
  # wg strips the whitespace before parsing. The trimmed value lands in _endpoint.
  trim_spaces "$_ep"; _ep="$_trimmed"; _endpoint="$_ep"
  # Named first, or the second colon of "https://" reports itself as bracketless IPv6.
  case "$_ep" in
    *://*) die "$_label is a host and a port, not a URL (got: '$_ep')." ;;
  esac
  case "$_ep" in
    \[*\]:*)
      _host="${_ep#[}"; _host="${_host%%]:*}"
      # Not ##*: - that would take "[fd00::1]:51820:99" for port 99.
      _port="${_ep#*]:}"
      [ -z "$_host" ] && die "$_label has empty host (got: '$_ep')."
      # wg takes brackets around a literal IPv4 address too.
      case "$_host" in
        *:*) validate_ipv6 "$_label" "$_host" "$_ep" ;;
        *[!0-9.]*) die "$_label puts brackets around a hostname; they are for a literal IPv6 address (got: '$_ep')." ;;
        *) validate_ipv4 "$_label" "$_host" "$_ep" ;;
      esac
      ;;
    *:*)
      _rest="${_ep#*:}"
      case "$_rest" in
        *:*) die "$_label has multiple colons without brackets; use [address]:port for IPv6 (got: '$_ep')." ;;
      esac
      _host="${_ep%%:*}"
      _port="${_ep##*:}"
      [ -z "$_host" ] && die "$_label has empty host (got: '$_ep')."
      case "$_host" in
        *[!A-Za-z0-9._-]*) die "$_label has an invalid host (got: '$_ep')." ;;
        # Digits and dots alone is a typo'd address, not a name wg-quick can resolve.
        *[!0-9.]*) ;;
        *) validate_ipv4 "$_label" "$_host" "$_ep" ;;
      esac
      ;;
    *)
      die "$_label must be in host:port format (got: '$_ep')."
      ;;
  esac
  validate_uint "$_label port" "$_port" 1 65535 "$_ep"
}

# --- Required variables ---
# Compose renders a missing .env entry as an empty value, and no WG_* value is
# meaningfully empty.
_blank="$(awk 'BEGIN { for (k in ENVIRON) if (k ~ /^WG_/ && ENVIRON[k] == "") print k }' | sort | tr '\n' ' ')"
_blank="${_blank% }"
[ -n "$_blank" ] && die "Set but empty: ${_blank}. Compose substitutes a missing .env entry as an empty value; give the variable a value or leave it out entirely."

WG_ROLE="${WG_ROLE:-}"
[ -z "$WG_ROLE" ] && die "WG_ROLE must be 'server' or 'client'."
case "$WG_ROLE" in
  server|client) ;;
  *) die "WG_ROLE must be 'server' or 'client' (got: '$WG_ROLE')." ;;
esac

# Resolve WG_PRIVATE_KEY from file if needed
if [ -n "${WG_PRIVATE_KEY:-}" ] && [ -n "${WG_PRIVATE_KEY_FILE:-}" ]; then
  warn "WG_PRIVATE_KEY and WG_PRIVATE_KEY_FILE are both set; WG_PRIVATE_KEY_FILE is ignored."
fi
# The label follows the source, so a file-borne key is not blamed on WG_PRIVATE_KEY.
KEY_LABEL="WG_PRIVATE_KEY"
if [ -z "${WG_PRIVATE_KEY:-}" ] && [ -n "${WG_PRIVATE_KEY_FILE:-}" ]; then
  # No path in the message: the key itself is the likely value, and it would be logged.
  [ -f "$WG_PRIVATE_KEY_FILE" ] || die "WG_PRIVATE_KEY_FILE does not point to an existing file. To pass the key itself use WG_PRIVATE_KEY."
  # Opened rather than asked about: access(2) raises capabilities for uid 0, so
  # test -r says yes for a file cap_drop ALL then refuses to open.
  ( : < "$WG_PRIVATE_KEY_FILE" ) 2>/dev/null ||
    die "WG_PRIVATE_KEY_FILE exists but is not readable: '$WG_PRIVATE_KEY_FILE'. Under cap_drop ALL the container cannot read a file it does not own unless it is world-readable, and on an SELinux host it also needs a label the container may read (chcon -t container_file_t)."
  WG_PRIVATE_KEY="$(tr -d '[:space:]' < "$WG_PRIVATE_KEY_FILE")"
  [ -z "$WG_PRIVATE_KEY" ] && die "WG_PRIVATE_KEY_FILE is empty: '$WG_PRIVATE_KEY_FILE'."
  KEY_LABEL="WG_PRIVATE_KEY_FILE"
fi
[ -z "${WG_PRIVATE_KEY:-}" ] && die "WG_PRIVATE_KEY (or WG_PRIVATE_KEY_FILE) is not set."
validate_wg_key "$KEY_LABEL" "$WG_PRIVATE_KEY"

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

[ -n "$WG_PORT" ] && validate_uint "WG_PORT" "$WG_PORT" 1 65535

case "$WG_IFACE" in
  *[!a-zA-Z0-9_-]*) die "WG_IFACE contains invalid characters: '$WG_IFACE'." ;;
  # A leading dash turns the name into an option for ip, wg and wg-quick.
  [!a-zA-Z0-9]*) die "WG_IFACE must start with a letter or a digit (got: '$WG_IFACE')." ;;
  # `wg show interfaces` lists interfaces instead of reading one and exits 0 with none.
  all|interfaces|default) die "WG_IFACE must not be '$WG_IFACE' - the name is reserved by wg and the kernel." ;;
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
# Ahead of the role branch: both roles need it to spot the node's own key.
WG_PUBLIC_KEY="$(printf '%s' "$WG_PRIVATE_KEY" | wg pubkey)" ||
  die "${KEY_LABEL} is not a valid WireGuard key."

# Largest keepalive here; the monitor derives its handshake window from it.
MAX_KEEPALIVE=25
# Set by either role once an AllowedIPs entry covers the whole address space.
_default_route=0
if [ "$WG_ROLE" = "server" ]; then
  WG_ADDRESS="${WG_ADDRESS:-10.77.0.1/24}"
  if [ -n "${WG_PSK:-}${WG_PSK_FILE:-}" ]; then
    warn "WG_PSK/WG_PSK_FILE is ignored for WG_ROLE=server. Use WG_PEER_<ID>_PSK per peer."
    unset WG_PSK WG_PSK_FILE
  fi
  # WG_ALLOWED_IPS reads like a server setting and does nothing at all here.
  _stray=""
  for _sv in WG_SERVER_PUBKEY WG_SERVER_ENDPOINT WG_ALLOWED_IPS WG_KEEPALIVE; do
    [ -n "$(printenv "$_sv" || true)" ] && _stray="${_stray}${_stray:+ }${_sv}"
  done
  [ -n "$_stray" ] && warn "Ignored for WG_ROLE=server: ${_stray}. Those describe a client; a server names its peers with WG_PEER_<ID>_*."
else
  # /32: a wider prefix installs an on-link route for addresses the tunnel drops.
  WG_ADDRESS="${WG_ADDRESS:-10.77.0.2/32}"
  WG_SERVER_PUBKEY="${WG_SERVER_PUBKEY:-}"
  WG_SERVER_ENDPOINT="${WG_SERVER_ENDPOINT:-}"
  # Remembered before the default lands, so the check below can tell them apart.
  _allowed_set="${WG_ALLOWED_IPS:+1}"
  WG_ALLOWED_IPS="${WG_ALLOWED_IPS:-10.77.0.1/32}"
  WG_KEEPALIVE="${WG_KEEPALIVE:-25}"

  [ -z "$WG_SERVER_PUBKEY" ]   && die "WG_SERVER_PUBKEY is not set."
  validate_wg_key "WG_SERVER_PUBKEY" "$WG_SERVER_PUBKEY"
  # genkey prints both halves at once, and unchecked this looks like a dead server.
  [ "$WG_SERVER_PUBKEY" = "$WG_PUBLIC_KEY" ] && \
    die "WG_SERVER_PUBKEY is this client's own public key, not the server's."
  [ -z "$WG_SERVER_ENDPOINT" ] && die "WG_SERVER_ENDPOINT is not set (e.g. vpn.example.com:51820)."
  validate_endpoint "WG_SERVER_ENDPOINT" "$WG_SERVER_ENDPOINT"
  WG_SERVER_ENDPOINT="$_endpoint"

  validate_keepalive "WG_KEEPALIVE" "$WG_KEEPALIVE"
  MAX_KEEPALIVE="$WG_KEEPALIVE"
  validate_cidr_list "WG_ALLOWED_IPS" "$WG_ALLOWED_IPS"
  _rIFS="$IFS"; IFS=','
  # shellcheck disable=SC2086
  for _net in $WG_ALLOWED_IPS; do
    trim_spaces "$_net"
    case "${_trimmed#*/}" in 0) _default_route=1 ;; esac
  done
  IFS="$_rIFS"

  if [ -n "${WG_PSK:-}" ] && [ -n "${WG_PSK_FILE:-}" ]; then
    warn "WG_PSK and WG_PSK_FILE are both set; WG_PSK_FILE is ignored."
  fi
  PSK_LABEL="WG_PSK"
  if [ -z "${WG_PSK:-}" ] && [ -n "${WG_PSK_FILE:-}" ]; then
    [ -f "$WG_PSK_FILE" ] || die "WG_PSK_FILE does not point to an existing file. To pass the key itself use WG_PSK."
    ( : < "$WG_PSK_FILE" ) 2>/dev/null ||
      die "WG_PSK_FILE exists but is not readable: '$WG_PSK_FILE'. Under cap_drop ALL the container cannot read a file it does not own unless it is world-readable, and on an SELinux host it also needs a label the container may read (chcon -t container_file_t)."
    WG_PSK="$(tr -d '[:space:]' < "$WG_PSK_FILE")"
    [ -z "$WG_PSK" ] && die "WG_PSK_FILE is empty: '$WG_PSK_FILE'."
    PSK_LABEL="WG_PSK_FILE"
  fi
  [ -n "${WG_PSK:-}" ] && validate_wg_key "$PSK_LABEL" "$WG_PSK"

  # A server block copied into a client is how these appear.
  _stray="$(awk 'BEGIN { for (k in ENVIRON) if (k ~ /^WG_PEER_/) print k }' | sort | tr '\n' ' ')"
  trim_spaces "$_stray"
  [ -n "$_trimmed" ] && warn "Ignored for WG_ROLE=client: ${_trimmed}. A client describes one server, with WG_SERVER_PUBKEY and WG_SERVER_ENDPOINT."
fi

validate_cidr_list "WG_ADDRESS" "$WG_ADDRESS"

# The default is the server's address in 10.77.0.0/24, so a client on that range is fine.
if [ "$WG_ROLE" = "client" ] && [ -z "$_allowed_set" ]; then
  _reaches=0
  _dfIFS="$IFS"; IFS=','
  # shellcheck disable=SC2086
  for _net in $WG_ADDRESS; do
    trim_spaces "$_net"
    case "$_trimmed" in *:*) continue ;; esac
    network_key "${_trimmed%%/*}/24"
    [ "$_norm" = "10.77.0.0/24" ] && _reaches=1
  done
  IFS="$_dfIFS"
  if [ "$_reaches" = "0" ]; then
    warn "WG_ADDRESS is ${WG_ADDRESS} but WG_ALLOWED_IPS is still the default 10.77.0.1/32, the server's address in a range this client is not on. Only traffic to what WG_ALLOWED_IPS names goes through the tunnel; set it to the server's tunnel address or the networks behind it."
  fi
fi

# The kernel installs an IPv6 default route the moment a /0 address is added.
_aIFS="$IFS"; IFS=','
# shellcheck disable=SC2086
for _net in $WG_ADDRESS; do
  trim_spaces "$_net"
  case "${_trimmed#*/}" in
    0) IFS="$_aIFS"
       warn "WG_ADDRESS entry '${_trimmed}' has prefix 0. That is the whole address space, and for IPv6 the kernel turns it into a default route on ${WG_IFACE} as soon as the address is added. WG_ALLOWED_IPS is where a full tunnel is configured."
       IFS=',' ;;
  esac
done
IFS="$_aIFS"

log "Role: $WG_ROLE | Address: $WG_ADDRESS | Public key: $WG_PUBLIC_KEY"

# Claimed here and removed on the way out: it marks the tunnel as having an owner.
RUNFILE="/run/compwire-${WG_IFACE}.pid"
RUNFILE_OWNED=0
release_claim() {
  [ "$RUNFILE_OWNED" = "1" ] && rm -f "$RUNFILE"
  return 0
}

# Ahead of the config write and not keyed on the interface: a second `/entrypoint.sh`
# via docker exec would rewrite the live config. `set -C` so one of two racers wins.
mkdir -p /run 2>/dev/null || true
_tries=0
while [ "$_tries" -lt 3 ]; do
  _tries=$(( _tries + 1 ))
  if ( set -C; printf '%s\n' "$$" > "$RUNFILE" ) 2>/dev/null; then
    RUNFILE_OWNED=1
    break
  fi
  [ -f "$RUNFILE" ] || break
  _owner="$(cat "$RUNFILE" 2>/dev/null || true)"
  case "$_owner" in ''|*[!0-9]*) _owner="" ;; esac
  # A SIGKILLed container leaves a runfile naming a PID that is gone or reused.
  if [ -n "$_owner" ] && [ "$_owner" != "$$" ] && kill -0 "$_owner" 2>/dev/null &&
     tr '\0' ' ' < "/proc/${_owner}/cmdline" 2>/dev/null | grep -q 'entrypoint\.sh'; then
    die "Interface ${WG_IFACE} is already owned by process ${_owner} in this container."
  fi
  rm -f "$RUNFILE" 2>/dev/null || true
done
[ "$RUNFILE_OWNED" = "1" ] ||
  warn "Could not claim ${RUNFILE}; a second entrypoint in this container will not see that the tunnel has an owner."
trap release_claim EXIT

# --- Write WireGuard config ---
# The only thing that sets the config's mode; it is always freshly created below.
umask 077
mkdir -p /etc/wireguard
# Renamed in once every check has passed: on a shared /etc/wireguard a container
# that starts and fails used to truncate the live config.
CFG_FINAL="/etc/wireguard/${WG_IFACE}.conf"
CFG="${CFG_FINAL}.new"
# Unlinked first, then created with `set -C`: a plain truncate follows a symlink.
rm -f "$CFG" 2>/dev/null || die "Could not replace ${CFG}."
( set -C; : > "$CFG" ) 2>/dev/null ||
  die "Could not create ${CFG}. A bind-mounted /etc/wireguard has to be writable by the container, and on an SELinux host it also needs a label the container may write (add :z to the mount)."

# rename(2) replaces the destination path itself, so a symlink there is overwritten.
commit_config() {
  [ "$CFG" = "$CFG_FINAL" ] && return 0
  if [ -d "$CFG_FINAL" ] || ! mv -f "$CFG" "$CFG_FINAL" 2>/dev/null; then
    die "Could not move ${CFG} to ${CFG_FINAL}."
  fi
  CFG="$CFG_FINAL"
  return 0
}

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

# The file holds the private key while peer validation can still abort. INT and TERM
# too, because as PID 1 the shell drops an untrapped signal; cleared first, or EXIT
# removes a claim somebody else has taken meanwhile.
trap 'trap - INT TERM EXIT; release_claim; rm -f "$CFG"; exit 130' INT
trap 'trap - INT TERM EXIT; release_claim; rm -f "$CFG"; exit 143' TERM
trap 'release_claim; rm -f "$CFG"' EXIT

unset WG_PRIVATE_KEY

if [ "$WG_ROLE" = "server" ]; then
  # An unrecognised WG_PEER_* name is a typo, and silence would drop the peer.
  PEER_ATTRS="PUBKEY ALLOWED_IPS PSK PSK_FILE ENDPOINT KEEPALIVE"
  peer_ids=""
  # ENVIRON rather than parsing `env`: a newline in any value would invent a peer.
  _peer_vars="$(awk 'BEGIN { for (k in ENVIRON) if (k ~ /^WG_PEER_/) print k }' | sort)"
  # shellcheck disable=SC2086
  for _var in $_peer_vars; do
    _rest="${_var#WG_PEER_}"
    # Without a separator "${_rest#*_}" hands back the whole name.
    case "$_rest" in
      *_*) ;;
      *) die "Unknown peer variable '${_var}'. Expected WG_PEER_<ID>_<ATTR> with ATTR one of: ${PEER_ATTRS}." ;;
    esac
    _id="${_rest%%_*}"
    _attr="${_rest#*_}"
    case " $PEER_ATTRS " in
      *" $_attr "*) ;;
      *) die "Unknown peer variable '${_var}'. Expected WG_PEER_<ID>_<ATTR> with ATTR one of: ${PEER_ATTRS}." ;;
    esac
    case "$_id" in
      ''|*[!A-Z0-9]*) die "Invalid peer ID in '${_var}' - peer IDs must be uppercase alphanumeric (e.g. WG_PEER_NODE1_PUBKEY)." ;;
    esac
    case " $peer_ids " in
      *" $_id "*) ;;
      *) peer_ids="${peer_ids}${peer_ids:+ }${_id}" ;;
    esac
  done
  # shellcheck disable=SC2086
  peer_ids="$(printf '%s\n' $peer_ids | sort -V)"

  [ -z "$peer_ids" ] && warn "No peers configured (no WG_PEER_<ID>_PUBKEY vars found). Server will accept no connections."

  peer_count=0
  seen_pubkeys=""
  seen_networks=""
  # normalized|written pairs: the comparison needs one form, the message the other.
  own_addresses=""
  _aIFS="$IFS"; IFS=','
  # shellcheck disable=SC2086
  for _net in $WG_ADDRESS; do
    trim_spaces "$_net"; _net="${_trimmed%%/*}"
    normalize_cidr "$_net"
    own_addresses="${own_addresses} ${_norm}|${_net}"
  done
  IFS="$_aIFS"
  for id in $peer_ids; do
    peer_pubkey="$(printenv "WG_PEER_${id}_PUBKEY" || true)"
    peer_allowed="$(printenv "WG_PEER_${id}_ALLOWED_IPS" || true)"
    peer_psk="$(printenv "WG_PEER_${id}_PSK" || true)"
    peer_psk_file="$(printenv "WG_PEER_${id}_PSK_FILE" || true)"
    peer_endpoint="$(printenv "WG_PEER_${id}_ENDPOINT" || true)"
    peer_keepalive="$(printenv "WG_PEER_${id}_KEEPALIVE" || true)"

    [ -z "$peer_pubkey" ] && die "WG_PEER_${id}_PUBKEY is not set or empty, but other WG_PEER_${id}_* variables are present."
    validate_wg_key "WG_PEER_${id}_PUBKEY" "$peer_pubkey"
    [ -z "$peer_allowed" ] && die "WG_PEER_${id}_ALLOWED_IPS is not set."
    validate_cidr_list "WG_PEER_${id}_ALLOWED_IPS" "$peer_allowed"

    # wg merges peers that share a key, and a repeated prefix goes to the last claimant.
    [ "$peer_pubkey" = "$WG_PUBLIC_KEY" ] && \
      die "WG_PEER_${id}_PUBKEY is this interface's own public key, not a peer's."
    case " $seen_pubkeys " in
      *" $peer_pubkey "*) die "WG_PEER_${id}_PUBKEY is already used by another peer. Every peer needs its own key pair." ;;
    esac
    seen_pubkeys="${seen_pubkeys} ${peer_pubkey}"

    _pIFS="$IFS"; IFS=','
    # shellcheck disable=SC2086
    for _net in $peer_allowed; do
      trim_spaces "$_net"; _net="$_trimmed"
      # Keyed by the network, but differing prefix lengths stay distinct.
      network_key "$_net"; _net_key="$_norm"
      # Tagged with the claiming peer: one peer repeating a route is not a conflict.
      _owner=""
      IFS="$_pIFS"
      for _seen in $seen_networks; do
        [ "${_seen#*|}" = "$_net_key" ] || continue
        _owner="${_seen%%|*}"
        break
      done
      IFS=','
      if [ "$_owner" = "$id" ]; then
        warn "WG_PEER_${id}_ALLOWED_IPS entry '${_net}' is the route ${_net_key} an earlier entry in the same list already covers; wg keeps one of them."
      elif [ -n "$_owner" ]; then
        IFS="$_pIFS"; die "WG_PEER_${id}_ALLOWED_IPS entry '${_net}' is already assigned to peer ${_owner} (both cover ${_net_key})."
      fi
      # Only at full prefix length is the entry the address itself.
      case "$_net_key" in *:*) _full=128 ;; *) _full=32 ;; esac
      if [ "${_net_key#*/}" = "$_full" ]; then
        normalize_cidr "${_net%%/*}"
        case " $own_addresses " in
          *" ${_norm}|"*) IFS="$_pIFS"; die "WG_PEER_${id}_ALLOWED_IPS entry '${_net}' is this interface's own address from WG_ADDRESS." ;;
        esac
      fi
      # 0.0.0.0/0 on a peer is deliberate, so this warns rather than refuses.
      _plen="${_net_key#*/}"
      [ "$_plen" = "0" ] && _default_route=1
      if [ "$_plen" != "0" ]; then
        IFS="$_pIFS"
        for _own in $own_addresses; do
          network_key "${_own%%|*}/${_plen}"
          if [ "$_norm" = "$_net_key" ]; then
            warn "WG_PEER_${id}_ALLOWED_IPS entry '${_net}' covers this interface's own address ${_own#*|}; that peer can claim the server's tunnel address."
          fi
        done
        IFS=','
      fi
      seen_networks="${seen_networks} ${id}|${_net_key}"
    done
    IFS="$_pIFS"

    _peer_psk_label="WG_PEER_${id}_PSK"
    if [ -n "$peer_psk" ] && [ -n "$peer_psk_file" ]; then
      warn "WG_PEER_${id}_PSK and WG_PEER_${id}_PSK_FILE are both set; WG_PEER_${id}_PSK_FILE is ignored."
    fi
    if [ -z "$peer_psk" ] && [ -n "$peer_psk_file" ]; then
      [ -f "$peer_psk_file" ] || die "WG_PEER_${id}_PSK_FILE does not point to an existing file. To pass the key itself use WG_PEER_${id}_PSK."
      ( : < "$peer_psk_file" ) 2>/dev/null ||
        die "WG_PEER_${id}_PSK_FILE exists but is not readable: '$peer_psk_file'. Under cap_drop ALL the container cannot read a file it does not own unless it is world-readable, and on an SELinux host it also needs a label the container may read (chcon -t container_file_t)."
      peer_psk="$(tr -d '[:space:]' < "$peer_psk_file")"
      [ -z "$peer_psk" ] && die "WG_PEER_${id}_PSK_FILE is empty: '$peer_psk_file'."
      _peer_psk_label="WG_PEER_${id}_PSK_FILE"
    fi
    [ -n "$peer_psk" ] && validate_wg_key "$_peer_psk_label" "$peer_psk"

    if [ -n "$peer_endpoint" ]; then
      validate_endpoint "WG_PEER_${id}_ENDPOINT" "$peer_endpoint"
      peer_endpoint="$_endpoint"
    fi

    if [ -n "$peer_keepalive" ]; then
      validate_keepalive "WG_PEER_${id}_KEEPALIVE" "$peer_keepalive"
      [ "$peer_keepalive" -gt "$MAX_KEEPALIVE" ] && MAX_KEEPALIVE="$peer_keepalive"
    fi

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
    unset "WG_PEER_${id}_PSK" "WG_PEER_${id}_PSK_FILE" 2>/dev/null || true

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
  unset WG_PSK WG_PSK_FILE
fi

# Neither auto nor off takes wg-quick's plain branch: no fwmark, no ip rule.
case "$WG_TABLE" in
  ''|auto|off) ;;
  *)
    if [ "$_default_route" = "1" ]; then
      warn "WG_TABLE is ${WG_TABLE} and an AllowedIPs entry covers the whole address space. wg-quick puts that route in table ${WG_TABLE} and adds no ip rule pointing at it, so nothing will use it. Leave WG_TABLE unset for a full tunnel, or add the rule yourself from a hook."
    fi
    ;;
esac

# --- Start WireGuard ---
IFACE_UP=0
# Set on entering wg-quick up; IFACE_UP comes later and means the tunnel came up.
IFACE_OURS=0

cleanup() {
  trap - INT TERM EXIT
  [ "$IFACE_UP" = "1" ] && log "Shutting down ${WG_IFACE}..."
  if [ -n "${MONITOR_PID:-}" ]; then
    kill "${MONITOR_PID}" 2>/dev/null || true
    wait "${MONITOR_PID}" 2>/dev/null || true
  fi
  if [ "$IFACE_OURS" = "1" ]; then
    # Wider than the reclaim at startup: an empty answer means it went away under us.
    _live_key="$(wg show "$WG_IFACE" public-key 2>/dev/null || true)"
    case "$_live_key" in
      ''|'(none)'|"$WG_PUBLIC_KEY")
        # Replayed because a PreDown hook is the usual reason and wg-quick names it.
        if ! _down_out="$(wg-quick down "$WG_IFACE" 2>&1)"; then
          # The device decides the wording; IFACE_UP is a latch that is never cleared.
          if ip link show dev "$WG_IFACE" >/dev/null 2>&1; then
            warn "wg-quick down ${WG_IFACE} failed and the interface is still there."
            [ -n "$_down_out" ] && printf '%s\n' "$_down_out" >&2
          elif [ "$IFACE_UP" = "1" ]; then
            warn "wg-quick down ${WG_IFACE} failed, but ${WG_IFACE} is already gone; a PostDown hook may not have run."
            [ -n "$_down_out" ] && printf '%s\n' "$_down_out" >&2
          fi
        fi
        ;;
      *)
        warn "Interface ${WG_IFACE} carries another public key now; leaving it to whoever took it over."
        ;;
    esac
  fi
  # Only once the interface is gone, or a second entrypoint reclaims a live tunnel.
  release_claim
  # Kept while a device by that name is there, because wg-quick down rereads it.
  ip link show dev "$WG_IFACE" >/dev/null 2>&1 || rm -f "$CFG"
}
# A returning handler would resume the startup sequence.
on_signal() { cleanup; exit "$1"; }

# The interface survives a SIGKILLed container. Late, because a leftover carries traffic.
if ip link show dev "$WG_IFACE" >/dev/null 2>&1; then
  # '(none)' is a device wg-quick created and never configured; empty is not ours.
  _left_key="$(wg show "$WG_IFACE" public-key 2>/dev/null || true)"
  case "$_left_key" in
    '(none)'|"$WG_PUBLIC_KEY")
      warn "Interface ${WG_IFACE} is a leftover from an earlier run; removing it."
      # Not in the other arm: wg-quick down refuses outright without a config file.
      commit_config
      # wg-quick first: `ip link del` strands the policy rules and the nft table.
      wg-quick down "$WG_IFACE" >/dev/null 2>&1 || true
      if ip link show dev "$WG_IFACE" >/dev/null 2>&1; then
        ip link del "$WG_IFACE" || die "Interface ${WG_IFACE} is a leftover but could not be removed."
      fi
      ;;
    *)
      die "Interface ${WG_IFACE} already exists and belongs to something else. Pick a free name via WG_IFACE, or remove it with 'ip link del ${WG_IFACE}' on the host if it is a leftover of yours."
      ;;
  esac
fi
commit_config

trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap cleanup EXIT

if [ -n "$WG_DNS" ]; then
  # A SIGKILL leaves openresolv's subscriber list under /run, and `resolvconf -a`
  # then finds nothing changed.
  resolvconf -d "$WG_IFACE" >/dev/null 2>&1 || true
  # openresolv refuses a resolv.conf without its marker; Docker writes its own.
  if ! head -n 1 /etc/resolv.conf 2>/dev/null | grep -q '^# Generated by resolvconf$'; then
    _resolv="$(cat /etc/resolv.conf 2>/dev/null || true)"
    printf '# Generated by resolvconf\n%s\n' "$_resolv" > /etc/resolv.conf ||
      die "WG_DNS is set, but /etc/resolv.conf is not writable, so wg-quick cannot apply it."
  fi
fi

log "Starting WireGuard (${WG_ROLE}) on ${WG_ADDRESS}..."
IFACE_OURS=1
# wg-quick prints diagnostics but no hint, and set -e would end the script here.
wg-quick up "$WG_IFACE" ||
  die "wg-quick could not bring up ${WG_IFACE} (see its output above). Common causes: the wireguard kernel module is not loaded on the host (modprobe wireguard), the container lacks NET_ADMIN, an Endpoint hostname that does not resolve (wg refuses the whole config over a single one), or a hook command failed."
# Straight after the call: a signal during the check below would tear down a live one.
IFACE_UP=1

wg show "$WG_IFACE" >/dev/null 2>&1 || die "WireGuard interface ${WG_IFACE} failed to start."
log "Interface ${WG_IFACE} is up (port $(wg show "$WG_IFACE" listen-port))."

# Client: wait for initial handshake
if [ "$WG_ROLE" = "client" ]; then
  log "Waiting for peer handshake..."
  _attempts=0
  while [ "$_attempts" -lt 15 ]; do
    _hs="$(wg show "$WG_IFACE" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')"
    if [ -n "$_hs" ] && [ "$_hs" != "0" ]; then
      log "Peer handshake established - tunnel is live."
      break
    fi
    _attempts=$(( _attempts + 1 ))
    sleep 1
  done
  [ "$_attempts" -eq 15 ] && warn "No peer handshake after 15s. Tunnel may not be fully connected yet."
fi

# Background monitor: logs peer connection changes every 30s
monitor_connection() {
  _state="unknown"
  _gone=0
  # Same window as the Dockerfile healthcheck: a handshake is renewed past 120s.
  _window=185
  [ "$MAX_KEEPALIVE" -gt 60 ] && _window=$(( MAX_KEEPALIVE + 125 ))
  while sleep 30; do
    _now="$(date +%s)"
    if ! _hs_data="$(wg show "$WG_IFACE" latest-handshakes 2>/dev/null)"; then
      # The counters below cannot express a missing interface.
      [ "$_gone" = "0" ] && warn "Interface ${WG_IFACE} is gone; no peer status available."
      _gone=1
      _state="unknown"
      continue
    fi
    _gone=0
    [ -z "$_hs_data" ] && continue
    _counts="$(printf '%s\n' "$_hs_data" | awk -v now="$_now" -v win="$_window" '
      NF>=2 { total++; if ($2!="0" && (now-$2)<=win) connected++ }
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
        disconnected) warn "All peers disconnected (no handshake within ${_window}s)." ;;
      esac
    fi
    _state="$_cur"
  done
}

monitor_connection &
MONITOR_PID=$!

sleep infinity &
wait $!
