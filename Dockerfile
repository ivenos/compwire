FROM alpine:3.24

RUN apk add --no-cache \
    wireguard-tools \
    iptables \
    ip6tables \
    iproute2 \
    openresolv \
    libqrencode-tools

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 51820/udp

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD sh -c '\
    iface="${WG_IFACE:-wg0}"; \
    wg show "$iface" >/dev/null 2>&1 || exit 1; \
    [ "$WG_ROLE" != "client" ] && exit 0; \
    hs=$(wg show "$iface" latest-handshakes 2>/dev/null | awk "NR==1{print \$2}"); \
    [ -n "$hs" ] && [ "$hs" != "0" ] && [ $(( $(date +%s) - hs )) -le 185 ]'

ENTRYPOINT ["/entrypoint.sh"]
