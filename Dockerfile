FROM alpine:3.24

# nftables is what wg-quick reaches for first on a 0.0.0.0/0 route. Without it it
# falls back to iptables-restore, which needs xt_comment and xt_mark loaded on the
# host - a container cannot load them itself.
RUN apk add --no-cache \
    wireguard-tools \
    iptables \
    ip6tables \
    nftables \
    iproute2 \
    openresolv \
    libqrencode-tools

COPY --chmod=0755 entrypoint.sh /entrypoint.sh

EXPOSE 51820/udp

# Shell form already runs under `sh -c`; a nested one would only add another
# layer of quoting for the awk script to survive.
# A handshake is renewed on the first keepalive past 120s, so a keepalive longer
# than that stretches the gap beyond the 185s default and the tunnel would be
# reported unhealthy while it works.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD iface="${WG_IFACE:-wg0}"; \
      wg show "$iface" >/dev/null 2>&1 || exit 1; \
      [ "${WG_ROLE:-}" != "client" ] && exit 0; \
      hs=$(wg show "$iface" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}'); \
      max=185; ka="${WG_KEEPALIVE:-25}"; \
      [ "$ka" -gt 60 ] && max=$(( ka + 125 )); \
      [ -n "$hs" ] && [ "$hs" != "0" ] && [ $(( $(date +%s) - hs )) -le "$max" ]

ENTRYPOINT ["/entrypoint.sh"]
