#!/usr/bin/env bash
# Pick the 2.4 GHz channel for the IoT AP and write the runtime hostapd config.
#
# hostapd's own ACS is deliberately not used. It is a compile-time option, it
# refuses to start the AP when the driver reports no survey data, and it is
# happy to choose channel 12/13, which many cheap IoT radios never scan. This
# script restricts the choice to 1/6/11 and always falls back to a usable
# channel.
#
# It is ExecStartPre= of homelab-iot-ap.service, so it runs before hostapd and
# is allowed to take the interface down to put it back into managed mode for
# the scan. Do not run it by hand while the AP is serving clients.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

IFACE="${IOT_WIFI_INTERFACE:-wlp2s0}"
STATIC_CONF=/etc/hostapd/iot.conf
RUNTIME_CONF="${RUNTIME_SECRETS_DIR}/hostapd-iot.conf"
LAST_FILE="${STATE_DIR}/iot-channel"

[[ -r "${STATIC_CONF}" ]] \
  || die "missing ${STATIC_CONF}; run render-secrets.sh before starting the AP"

configured="${IOT_WIFI_CHANNEL:-auto}"
fallback=1
if [[ -r "${LAST_FILE}" ]]; then
  last="$(cat "${LAST_FILE}")"
  case "${last}" in
    1|6|11) fallback="${last}" ;;
  esac
fi

case "${configured}" in
  auto) ;;
  1|6|11) fallback="${configured}" ;;
  *) die "IOT_WIFI_CHANNEL must be auto, 1, 6 or 11 (got '${configured}')" ;;
esac

# hostapd needs the interface in AP mode, but a scan only works in managed
# mode. Bringing it down is what allows the type change.
ip link set "${IFACE}" down 2>/dev/null || true
iw dev "${IFACE}" set type managed 2>/dev/null || true
# IPv4-only on purpose: the LAN's IPv6 prefix must not leak into this segment.
sysctl -q -w "net.ipv6.conf.${IFACE}.disable_ipv6=1" 2>/dev/null || true
# IoT clients must not be told about a LAN next hop.
sysctl -q -w "net.ipv4.conf.${IFACE}.send_redirects=0" 2>/dev/null || true
sysctl -q -w "net.ipv4.conf.${IFACE}.accept_redirects=0" 2>/dev/null || true
ip link set "${IFACE}" up
# Drop anything a previous config (or a quick manual ifup) left behind, so
# only the AP address can answer on this interface.
ip addr flush dev "${IFACE}" scope global 2>/dev/null || true
ip addr replace 192.168.179.1/24 dev "${IFACE}"

chosen="${fallback}"
report="fixed channel ${chosen}"

if [[ "${configured}" == "auto" ]]; then
  scan=""
  for _ in 1 2 3; do
    scan="$(iw dev "${IFACE}" scan 2>/dev/null || true)"
    [[ -n "${scan}" ]] && break
    sleep 1
  done

  if [[ -n "${scan}" ]]; then
    # Score each candidate by the BSSes that overlap it. A neighbour on the
    # same channel is worst; four channels away does not overlap at 20 MHz.
    # The last known good channel wins ties, which keeps the choice stable
    # across restarts when the band is empty.
    scored="$(printf '%s\n' "${scan}" | awk -v last="${fallback}" '
      function weight(s) {
        if (s >= -50) return 4.0
        if (s >= -65) return 2.0
        if (s >= -80) return 1.0
        return 0.5
      }
      /^BSS / {
        if (ch > 0) { n++; bch[n] = ch; bsig[n] = sig }
        ch = 0; sig = -100
        next
      }
      /^[ \t]+freq:/ {
        f = $2 + 0
        if (f >= 2412 && f <= 2472) ch = int((f - 2407) / 5)
        next
      }
      /^[ \t]+signal:/ { sig = $2 + 0; next }
      END {
        if (ch > 0) { n++; bch[n] = ch; bsig[n] = sig }
        split("1 6 11", c, " ")
        best = 0; bestscore = -1
        for (i = 1; i <= 3; i++) {
          score = 0
          for (j = 1; j <= n; j++) {
            d = bch[j] - c[i]; if (d < 0) d = -d
            if (d < 5) score += (5 - d) * weight(bsig[j])
          }
          s[i] = score
          if (bestscore < 0 || score < bestscore - 0.0001) {
            best = c[i]; bestscore = score
          } else if (score <= bestscore + 0.0001 && c[i] == last) {
            best = c[i]; bestscore = score
          }
        }
        printf "%d %.2f %.2f %.2f\n", best, s[1], s[2], s[3]
      }')"
    read -r chosen s1 s6 s11 <<<"${scored}"
    case "${chosen}" in
      1|6|11) ;;
      *) chosen="${fallback}" ;;
    esac
    report="scan: 1=${s1:-?} 6=${s6:-?} 11=${s11:-?}"
  else
    report="scan failed, falling back to ${fallback}"
  fi
fi

install -d -m 0700 "$(dirname "${RUNTIME_CONF}")"
sed "s/^channel=.*/channel=${chosen}/" "${STATIC_CONF}" >"${RUNTIME_CONF}.tmp"
# The static config always carries a channel= line, but appending is better
# than starting hostapd with no channel at all if that ever changes.
if ! grep -q "^channel=${chosen}$" "${RUNTIME_CONF}.tmp"; then
  printf 'channel=%s\n' "${chosen}" >>"${RUNTIME_CONF}.tmp"
fi
install -m 0600 -o root -g root "${RUNTIME_CONF}.tmp" "${RUNTIME_CONF}"
rm -f "${RUNTIME_CONF}.tmp"

install -d -m 0755 "${STATE_DIR}"
printf '%s\n' "${chosen}" >"${LAST_FILE}.tmp"
install -m 0644 -o root -g root "${LAST_FILE}.tmp" "${LAST_FILE}"
rm -f "${LAST_FILE}.tmp"

log "IoT AP on ${IFACE}: channel ${chosen} (${report})"
