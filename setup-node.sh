#!/usr/bin/env bash
# Run this on the NEW proxy node (fresh VPS)
# Usage: bash setup-node.sh <node-name> <emoji> [panel_port]
set -e

NAME="${1:-Node}"
EMOJI="${2:-🌐}"
PANEL_PORT="${3:-9453}"
SNI="www.microsoft.com"
REALITY_DEST="dl.google.com:443"

# 1. SSH key (for management machine to connect)
if [ ! -f /root/.ssh/id_ed25519 ]; then
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N ""
fi
cat /root/.ssh/id_ed25519.pub >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true

# 2. Install 3x-ui if needed
if ! command -v x-ui &>/dev/null || [ ! -f /usr/local/x-ui/x-ui ]; then
    echo "[+] Installing 3x-ui..."
    bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) <<'EOF'
y
EOF
else
    echo "[+] 3x-ui already installed"
fi

# 3. Generate random credentials
USER="admin"
PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 16)

# Set credentials
/usr/local/x-ui/x-ui setting -username "$USER" -password "$PASS" -port "$PANEL_PORT" -webBasePath /
systemctl restart x-ui
sleep 2

# 4. Pick an available port (prefer 443)
USED=$(ss -tlnp 2>/dev/null | awk 'NR>1{print $4}' | grep -oE '[0-9]+$' | sort -u)
PORT=""
for p in 443 2083 8443 2053 2087 2096; do
    if ! echo "$USED" | grep -q "^${p}$"; then
        PORT=$p
        break
    fi
done
if [ -z "$PORT" ]; then
    PORT=8443
fi

# 5. Open firewall
if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
    ufw allow "$PORT"/tcp 2>/dev/null || true
    ufw allow "$PANEL_PORT"/tcp 2>/dev/null || true
    ufw reload 2>/dev/null || true
    echo "[+] UFW: opened $PORT, $PANEL_PORT"
else
    echo "[+] No restrictive firewall detected"
fi

# 6. Generate keys and create inbound via API
python3 - "$PORT" "$NAME" "$PANEL_PORT" "$USER" "$PASS" "$SNI" "$REALITY_DEST" <<'PYEOF'
import json, subprocess, sys, urllib.request, ssl, secrets, glob

port = int(sys.argv[1])
remark = sys.argv[2]
panel_port = int(sys.argv[3])
username = sys.argv[4]
password = sys.argv[5]
sni = sys.argv[6]
reality_dest = sys.argv[7]

candidates = glob.glob("/usr/local/x-ui/bin/xray-linux-*")
XRAY = candidates[0] if candidates else "/usr/local/x-ui/bin/xray-linux-amd64"

keys_out = subprocess.check_output([XRAY, "x25519"]).decode()
kv = {}
for l in keys_out.strip().splitlines():
    if ": " in l:
        k, v = l.split(": ", 1)
        kv[k.strip()] = v.strip()

priv = kv.get("PrivateKey") or kv.get("Private key", "")
pub = kv.get("Password (PublicKey)") or kv.get("Password") or kv.get("Public key", "")

if not priv or not pub:
    print("[!] Failed to parse x25519 keys")
    sys.exit(1)

uuid = subprocess.check_output([XRAY, "uuid"]).decode().strip()
sid = secrets.token_hex(4)

panel = f"https://localhost:{panel_port}"
tok_out = subprocess.check_output(["/usr/local/x-ui/x-ui", "setting", "-getApiToken"]).decode().strip()
api_token = tok_out.replace("apiToken: ", "").strip()

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

def api_req(path, data=None, headers=None):
    h = {"Authorization": f"Bearer {api_token}"}
    if headers:
        h.update(headers)
    req = urllib.request.Request(f"{panel}{path}", data=data, headers=h)
    return urllib.request.urlopen(req, context=ctx)

# Delete existing VLESS inbounds
resp = api_req("/panel/api/inbounds/list")
existing = json.loads(resp.read())
for ib in existing.get("obj", []):
    if ib.get("protocol") == "vless":
        api_req(f"/panel/api/inbounds/del/{ib['id']}")

settings = json.dumps({
    "clients": [{"id": uuid, "flow": "xtls-rprx-vision", "email": "",
                 "limitIp": 0, "totalGB": 0, "expiryTime": 0, "enable": True,
                 "tgId": 0, "subId": "", "reset": 0}],
    "decryption": "none", "fallbacks": []
})
stream = json.dumps({
    "network": "tcp", "security": "reality", "externalProxy": [],
    "realitySettings": {
        "show": False, "xver": 0, "dest": reality_dest,
        "serverNames": [sni], "privateKey": priv,
        "minClient": "", "maxClient": "", "maxTimediff": 0, "shortIds": [sid],
        "settings": {"publicKey": pub, "fingerprint": "chrome", "serverName": "", "spiderX": "/"}
    },
    "tcpSettings": {"acceptProxyProtocol": False, "header": {"type": "none"}}
})
sniffing = json.dumps({"enabled": True, "destOverride": ["http", "tls", "quic", "fakedns"],
                        "metadataOnly": False, "routeOnly": False})

body = json.dumps({
    "up": 0, "down": 0, "total": 0, "remark": remark, "enable": True, "expiryTime": 0,
    "listen": "", "port": port, "protocol": "vless",
    "settings": settings, "streamSettings": stream, "sniffing": sniffing
}).encode()

resp = api_req("/panel/api/inbounds/add", data=body, headers={"Content-Type": "application/json"})
result = json.loads(resp.read())

if result.get("success"):
    info = {
        "name": remark,
        "emoji": "🇯🇵",
        "ssh_host": "NEW_HOST",
        "server": "NEW_IP",
        "port": port,
        "uuid": uuid,
        "public_key": pub,
        "short_id": sid,
        "sni": sni,
        "panel": {"user": username, "pass": password, "port": panel_port}
    }
    print(json.dumps(info, indent=2, ensure_ascii=False))
else:
    print("[!] Failed to create inbound:", result)
    sys.exit(1)
PYEOF

echo ""
echo "========================================"
echo "✅ Node setup complete!"
echo "========================================"
echo "Next steps:"
echo "  1. Copy the JSON above into your management machine's config.json 'nodes' array"
echo "  2. Replace NEW_HOST with your SSH host alias and NEW_IP with this server's public IP"
echo "  3. On management machine, run: python3 scripts/fleet.py sync"
echo "  4. Then run: python3 -c 'import sys; sys.path.insert(0, \"scripts\"); ...' to print YAML"
echo "========================================"
