# IoT Wi-Fi

The host's otherwise unused MediaTek MT7921 (`wlp2s0`) serves a **2.4 GHz-only**
SSID for smart-home devices. They are routed off a separate subnet and can only
reach the internet.

The reason it exists: the router advertises 2.4 GHz and 5 GHz under one SSID,
and some 2.4-only devices refuse to associate because of it. A dedicated
2.4 GHz SSID fixes that, and routing it separately keeps those devices off the
LAN without relying on the router's guest-network isolation.

```text
Tapo / Idoo / filter ── 2.4 GHz WPA2 ── wlp2s0 192.168.179.1/24
                                             │  hostapd + dnsmasq
                                             ├─ NAT → eno1 → router → internet
                                             └─ LAN / VPN / Docker / host: denied
```

## Addressing

| item | value |
| --- | --- |
| SSID | `HomeLab-IoT` (`IOT_WIFI_SSID`) |
| band / mode | 2.4 GHz, 802.11n, 20 MHz |
| security | WPA2-PSK, CCMP only, PMF off |
| host address | `192.168.179.1/24` |
| DHCP pool | `192.168.179.50` – `192.168.179.200`, 24 h |
| DNS | `192.168.179.1` → router `192.168.178.1`, `9.9.9.9` backup |
| NAT | `192.168.179.0/24` → `eno1` (iptables, `homelab-iot-firewall.service`) |
| IPv6 | disabled on `wlp2s0` |

### Isolation policy

| from IoT | verdict |
| --- | --- |
| DHCP (67/udp) and DNS (53) on the host | allowed |
| internet via `eno1` | allowed |
| `192.168.178.0/24` (LAN, router UI, other hosts) | denied |
| `100.64.0.0/10` (WireGuard) | denied |
| `10.0.0.0/8`, `172.16.0.0/12`, `169.254.0.0/16` | denied |
| another IoT client | denied |
| Docker-published ports (Caddy, Forgejo, Syncthing, …) | denied via `DOCKER-USER` |
| every other host service (SSH, Dockge, wg-easy, …) | denied by ufw's input policy |

There is no mDNS/SSDP reflection across the boundary. The devices are
cloud-only, so that is deliberate; local discovery would need an avahi
reflector and a narrower allowlist.

ufw's stock `before.rules` accepts ICMP echo-request in the input and forward
chains before any user rule, so `homelab-iot-firewall.service` also installs a
small nftables table (`inet homelab_iot`, hook priority `-10`) that drops
private destinations, client-to-client traffic and ICMP from the AP before ufw
sees it. Without it, pings to the LAN and to the host's LAN address succeed
even though the same destinations are denied over TCP.

## Files

| path | written by | purpose |
| --- | --- | --- |
| `/etc/hostapd/iot.conf` | `render-secrets.sh` | full hostapd config, including the WPA passphrase (0600) |
| `/run/homelab/secrets/hostapd-iot.conf` | `iot-channel.sh` | runtime copy with the chosen channel |
| `/etc/dnsmasq-iot.conf` | `bootstrap.sh` | DHCP/DNS for the segment |
| `/etc/network/interfaces.d/iot-ap` | `bootstrap.sh` | assigns `192.168.179.1/24` at boot |
| `/etc/NetworkManager/conf.d/99-homelab-iot.conf` | `bootstrap.sh` | keeps NM away from `wlp2s0` |
| `/etc/modprobe.d/mt7921e.conf` | `bootstrap.sh` | disables ASPM on the MT7921 |
| `/var/lib/homelab/iot-channel` | `iot-channel.sh` | last chosen channel, used for ties and fallback |
| `/var/lib/misc/dnsmasq-iot.leases` | dnsmasq | DHCP leases |

Units: `homelab-iot-ap.service` (hostapd), `homelab-iot-dhcp.service`
(dnsmasq), `homelab-iot-firewall.service` (NAT, the `DOCKER-USER` rule and the
early nft drop).

## Enable it

Host-level changes are not applied by `deploy.sh`; run bootstrap once after the
commit lands:

```bash
sudo /opt/homelab/scripts/bootstrap.sh
sudo /opt/homelab/scripts/render-secrets.sh
```

`bootstrap.sh` installs the packages and units, writes the UFW/NAT policy and
enables the units. `render-secrets.sh` writes `/etc/hostapd/iot.conf` from sops
and starts `homelab-iot-ap.service` (which pulls in the DHCP unit).

Read the passphrase to enter on the devices:

```bash
sudo /opt/homelab/scripts/sops.sh -d secrets/secrets.yaml \
  | jq -r .iot_wifi_passphrase
```

## Add a device

1. Use the vendor app. Most require the phone to be on a 2.4 GHz network, so
   join `HomeLab-IoT` on the phone for onboarding (it still has internet).
2. Enter the passphrase and let the device join.
3. Put the phone back on the main SSID. The device keeps working; it only talks
   to its cloud.

Tapos and similar devices need no inbound ports, so the NAT is invisible to
them. Devices that require inbound connections or UPnP (P2P cameras, some
printers) will not work on this segment.

## Operations

```bash
systemctl status homelab-iot-ap homelab-iot-dhcp homelab-iot-firewall
journalctl -u homelab-iot-ap -u homelab-iot-dhcp -b
iw dev wlp2s0 info                 # type AP, channel, ssid
cat /var/lib/misc/dnsmasq-iot.leases
sudo /opt/homelab/scripts/healthcheck.sh
```

### Channel selection

`IOT_WIFI_CHANNEL` in `/etc/homelab/host.env` controls it:

| value | behaviour |
| --- | --- |
| `auto` (default) | scan at every AP start, pick the quietest of 1/6/11, fall back to the last good channel, then 1 |
| `1`, `6`, `11` | pin it |

`auto` runs only when the AP starts, so a running SSID never changes channel
under its clients. To re-evaluate, restart the unit (all clients reconnect).

```bash
sudo systemctl restart homelab-iot-ap.service
```

Do not use hostapd's own ACS here: it is a compile-time option, it refuses to
start the AP when the driver reports no survey data, and it can pick channels
12/13, which many 2.4-only IoT radios never scan.

### Rotate the passphrase

```bash
sudo /opt/homelab/scripts/sops.sh set secrets/secrets.yaml \
  '["iot_wifi_passphrase"]' '"NEWPASS"'
git -C /opt/homelab add secrets/secrets.yaml
sudo /opt/homelab/scripts/render-secrets.sh
```

`render-secrets.sh` restarts the AP only when the rendered config changed, so a
deploy that touches other secrets does not drop the devices. Use 8–63
alphanumeric characters; punctuation trips up some cheap firmware.

### Disable it

```bash
sudo systemctl disable --now homelab-iot-ap.service homelab-iot-dhcp.service
```

The NAT and `DOCKER-USER` rules are harmless with no AP running, so this is
enough to stop serving the SSID. Removing the rules themselves is manual:

```bash
sudo iptables -t nat -D POSTROUTING -s 192.168.179.0/24 -o eno1 -j MASQUERADE
sudo iptables -D DOCKER-USER -i wlp2s0 -d 172.16.0.0/12 -j DROP
sudo iptables -D DOCKER-USER -i wlp2s0 -d 10.0.0.0/8 -j DROP
sudo ufw route delete allow in on wlp2s0 out on eno1
# and the deny rules from scripts/bootstrap.sh
```

## Tests

```bash
# On the host
iw dev wlp2s0 info | grep -E 'ssid|channel|type'
ss -lunp | grep -E ':53|:67'
iptables -t nat -S POSTROUTING | grep 192.168.179
iptables -S DOCKER-USER | grep wlp2s0 || true

# From a device on HomeLab-IoT
#   pings 192.168.179.1            -> works
#   pings 192.168.178.200 / .1     -> fails
#   curl https://example.com       -> works
```

## Sharp edges

- **The AP depends on the host.** It cannot start without the LUKS unlock, so
  after a power loss the devices are offline until the host is unlocked and
  booted. Accepted for plugs, a planter and a filter.
- **One radio, one band.** 2.4 GHz only; there is no 5 GHz SSID. DFS channels
  are unsupported in AP mode anyway.
- **Docker bypasses ufw.** That is what `homelab-iot-firewall.service` is for.
  If Docker is reinstalled or its firewall chain is reset, re-run the unit.
- **ufw accepts ICMP by default.** Its `before.rules` accepts echo-request in
  both the input and forward chains, before user rules. The `inet homelab_iot`
  nftables chain exists so pings to the LAN fail as the table above says; if
  that chain is missing, the pings come back even though TCP is still denied.
- **The passphrase sits in `/etc/hostapd/iot.conf`** (0600 root, on the
  LUKS-encrypted root). hostapd cannot read it from a file, and it has to exist
  at boot, so `/run` is not an option. sops remains the source of truth.
- **An authenticated VPN client can still reach the LAN.** A phone on this
  SSID with its WireGuard tunnel up reaches `192.168.178.0/24` through
  `wg0`, not through `wlp2s0`, so the AP rules do not apply and that is by
  design. Disable the tunnel when testing the segment from a phone. IoT devices
  do not hold VPN credentials.
- **`disable_aspm` needs a reboot.** It is set in `/etc/modprobe.d` while the
  module is already in use; the next boot picks it up.
- **The MT7921 is a client part.** AP mode is supported and fine for ten
  low-traffic devices, but it is not an access point for a house full of
  clients. If the device count grows past roughly 20, use a dedicated AP.
- **The router may move onto our channel.** `auto` only runs at AP start; the
  devices tolerate it at this traffic level. Pinning the router's 2.4 GHz
  channel is the stable combination.
