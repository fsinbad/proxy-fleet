# proxy-fleet

[中文文档](README_CN.md)

Manage multiple VPS proxy nodes from a single command line. Deploys [3x-ui](https://github.com/MHSanaei/3x-ui) + VLESS+Reality and generates a [Clash/Mihomo](https://github.com/MetaCubeX/mihomo) subscription URL that auto-updates when you add or remove nodes.

## Features

- **One-command deploy** — installs 3x-ui, picks an available port (scans for conflicts first), configures VLESS+Reality, opens the firewall, and updates your subscription file. All in one `deploy`.
- **Subscription sync** — queries every node's live API state and regenerates the Clash YAML, so the subscription always reflects reality.
- **Decoupled SNI / dest** — clients can keep `servername: www.microsoft.com` while the server defaults REALITY `dest` to `dl.google.com:443`, avoiding Microsoft certificate-size related REALITY failures
- **NAT support** — pass `--nat 10000-10009` and it picks the first free port in that range.
- **Fleet status** — parallel health check across all nodes with traffic stats.
- **Whitelist mode** — Uses [Loyalsoldier/clash-rules](https://github.com/Loyalsoldier/clash-rules) rule-providers for comprehensive China domain/IP direct routing, everything else proxied. AI services always proxied. Rules auto-update daily.

## Requirements

- Python 3.8+ (stdlib only, no pip dependencies)
- SSH access to your VPS nodes (key-based auth via `~/.ssh/config`)
- `curl` on your local machine (for connectivity checks)
- VPS running Debian/Ubuntu (other distros may work but are untested)

## Quick Start

```bash
# 1. Clone
git clone https://github.com/oaker-io/proxy-fleet.git
cd proxy-fleet

# 2. Interactive setup — creates config.json
python3 scripts/fleet.py init

# 3. Deploy to your first VPS
python3 scripts/fleet.py deploy my-vps --name "Tokyo" --emoji "🇯🇵"

# 4. Check status
python3 scripts/fleet.py status
```

## Commands

```
init                                    Interactive config setup
status                                  Show all nodes (parallel health check)
deploy <host> [host...]                 Deploy to one or more SSH hosts
deploy <host> --nat 10000-10009         Deploy on NAT machine with port range
deploy <host> --name "Name" --emoji "🇺🇸"  Deploy with custom display name
remove <host>                           Remove node from subscription
sync                                    Regenerate subscription from live state
```

## How It Works

### Deploy Flow

```
SSH connect → scan occupied ports → pick available port
  → install 3x-ui (if needed) → set panel credentials
  → generate x25519 keys → create VLESS+Reality inbound via API
  → detect firewall (ufw/iptables) → open ports
  → verify connectivity → save to config → sync subscription
```

### Subscription Hosting

The generated Clash YAML is uploaded to one of your VPS nodes via SSH. You serve it with nginx + SSL (e.g., behind Cloudflare). Users import the URL in Clash Verge Rev / Mihomo and get all nodes + routing rules.

### Proxy Groups

| Group | Purpose |
|-------|---------|
| 🤖 AI Services | OpenAI, Claude, Gemini, Copilot, Cursor, Midjourney, etc. — routes to US nodes first |
| 🚀 Proxy | Unmatched foreign traffic — routes to nearest nodes first |
| 🐟 Final | Catch-all fallback (defaults to proxy in whitelist mode) |

## File Structure

```
proxy-fleet/
├── config.json              # Your fleet state (gitignored — contains credentials)
├── config.example.json      # Template for new users
├── scripts/
│   └── fleet.py             # Main CLI script
└── templates/rules/
    ├── ai.yaml              # AI services (must proxy)
    └── direct.yaml          # Custom direct (China AI, supplements)
```

## Updating Rules

Edit any file in `templates/rules/`, then:

```bash
python3 scripts/fleet.py sync
```

Users refresh their subscription in Clash Verge Rev to pick up the changes.

## Tech Notes

- **Xray v26 key format**: `x25519` outputs `PrivateKey` / `Password` (= public key) / `Hash32`. Older versions use `Private key` / `Public key`. The script handles both.
- **REALITY defaults**: `defaults.sni` is the client-facing SNI / `serverNames`, while `defaults.reality_dest` is the actual upstream `dest`. By default the project keeps `www.microsoft.com` as SNI but uses `dl.google.com:443` as `dest` to avoid the known Xray REALITY bug triggered by oversized Microsoft certificate records.
- **3x-ui install script** is interactive and can't reliably receive piped input. We install with defaults, then reset credentials via the CLI.
- **3x-ui API**: the script prefers local `apiToken` auth for `/panel/api/inbounds/{add,update,del,list}`.
- **Reality fallback status codes**: depending on the chosen `dest`, non-VLESS probes may return `200/301/302/400/404`. The connectivity check treats all of them as "alive".
- **Port conflicts** are the #1 deploy failure. The script scans ports before configuring.

## License

[MIT](LICENSE)
