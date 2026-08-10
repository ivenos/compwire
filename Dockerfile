FROM alpine:3.24

# nftables: wg-quick reaches for it first, and its iptables fallback needs
# xt_comment and xt_mark on the host.
RUN apk add --no-cache \
    wireguard-tools \
    iptables \
    ip6tables \
    nftables \
    iproute2 \
    openresolv

COPY --chmod=0755 entrypoint.sh /entrypoint.sh

EXPOSE 51820/udp

# '(none)' is a device wg-quick created but never keyed. Every input is checked
# before it reaches $(( )), the clock included.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD iface="${WG_IFACE:-wg0}"; \
      wg show "$iface" >/dev/null 2>&1 || exit 1; \
      case "$(wg show "$iface" public-key 2>/dev/null)" in ''|'(none)') exit 1 ;; esac; \
      [ "${WG_ROLE:-}" != "client" ] && exit 0; \
      hs=$(wg show "$iface" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}'); \
      case "$hs" in ''|*[!0-9]*) exit 1 ;; esac; \
      [ "$hs" != "0" ] || exit 1; \
      max=185; ka="${WG_KEEPALIVE:-25}"; \
      case "$ka" in ''|*[!0-9]*|0?*) ka=25 ;; esac; \
      [ "$ka" -gt 60 ] && max=$(( ka + 125 )); \
      now=$(date +%s); \
      case "$now" in ''|*[!0-9]*) exit 1 ;; esac; \
      [ $(( now - hs )) -le "$max" ]

ENTRYPOINT ["/entrypoint.sh"]
