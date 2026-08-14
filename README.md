# 🌐 Cloudflare NAT Tunnel — ngrok-like intranet access

Access your **home / intranet services from anywhere** through a custom domain you own on Cloudflare — no public IP, no port forwarding, no DDNS, and **no ngrok account/subscription**.

This project provides two scripts that wrap [Cloudflare Tunnel (`cloudflared`)](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/):

| File | Platform |
|------|----------|
| `nat-tunnel.ps1` | Windows (PowerShell 5.1+) |
| `nat-tunnel.sh` | Linux / macOS (bash) |
| `config.json` | Your service map (hostname → local service) |
| `cloudflared/config.yml` | Auto-generated config consumed by `cloudflared` |

---

## How it works

```
                INTERNET                                    YOUR INTRANET
 Browser  ──►  https://app.example.com
                     │
              Cloudflare edge
                     │   (outbound connection only)
                     ▼
              cloudflared  ◄──── tunnel ────►  http://localhost:3000
              (this script starts it)
```

- `cloudflared` makes an **outbound-only** connection to Cloudflare — no ports are opened on your router, so it works behind NAT, CGNAT, or even a strict firewall.
- Cloudflare answers on your **custom hostname** (`app.example.com`) and forwards traffic down the tunnel to your local service.
- All traffic is encrypted with a free Cloudflare SSL/TLS certificate for your domain.

> **What you need on the dashboard:** a domain that is **already added to Cloudflare** (i.e. its nameservers point at Cloudflare — `*.ns.cloudflare.com`). This is required for named tunnels with custom hostnames.

---

## Step-by-step tutorial

### Step 0 — Prerequisites

1. A **Cloudflare account** and a **domain** that is active on Cloudflare (Status: **Active** in the dashboard).
2. A **local service** running on your intranet that you want to expose. For this tutorial we'll use a web server on `http://localhost:3000` (any port works).
3. The script files from this folder.

---

### Step 1 — Install `cloudflared`

**Windows** (PowerShell):

```powershell
.\nat-tunnel.ps1 install
```

or manually:

```powershell
winget install --id Cloudflare.cloudflared -e
```

**macOS**:

```bash
brew install cloudflared
```

**Linux (Debian/Ubuntu)**:

```bash
./nat-tunnel.sh install
```

or manually:

```bash
# one-liner for most distros
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared
chmod +x /usr/local/bin/cloudflared
```

Verify:

```bash
cloudflared --version
```

---

### Step 2 — Log in to Cloudflare

This authorizes `cloudflared` to create tunnels and DNS records on your account.

**Windows**:

```powershell
.\nat-tunnel.ps1 login
```

**Linux/macOS**:

```bash
./nat-tunnel.sh login
```

A browser window opens. **Sign in to Cloudflare**, select the domain you want to use, and click **Authorize**.

> This saves a certificate to `~/.cloudflared/cert.pem`. Run `login` once per machine.

---

### Step 3 — Create the tunnel + point your domain at it

Pick a hostname you own (e.g. `app.example.com`) and run:

**Windows**:

```powershell
.\nat-tunnel.ps1 setup -ServiceName web -Hostname app.example.com -Url http://localhost:3000
```

**Linux/macOS**:

```bash
./nat-tunnel.sh setup -s web -h app.example.com -u http://localhost:3000
```

What this does for you:

1. Creates a **named tunnel** called `nat-tunnel` (if it doesn't exist).
2. Creates a **DNS CNAME route** on `app.example.com` → `nat-tunnel.<uuid>.cfargotunnel.com` (this is the "custom domain" bit — the record appears in your Cloudflare dashboard under **DNS**).
3. Saves the mapping in `config.json`.
4. Generates `cloudflared/config.yml` with the ingress rules.

You can add more services later — one tunnel, many hostnames:

```powershell
.\nat-tunnel.ps1 setup -ServiceName nas -Hostname nas.example.com -Url http://192.168.1.50:5000
.\nat-tunnel.ps1 setup -ServiceName ssh -Hostname ssh.example.com -Url ssh://localhost:22
```

> **Troubleshooting:** if `route dns` says the record already exists, delete the old CNAME for that hostname in the dashboard first, or use a different subdomain.

---

### Step 4 — Start the tunnel

**Windows**:

```powershell
.\nat-tunnel.ps1 start
```

**Linux/macOS**:

```bash
./nat-tunnel.sh start
```

The tunnel runs in the background (PID saved to `.tunnel.pid`, logs in `logs/`).

Check it's healthy:

```powershell
.\nat-tunnel.ps1 status
```

```text
==> Your public URLs:
    https://app.example.com  ->  http://localhost:3000
```

> ⚠️ **The tunnel only works while `cloudflared` is running.** After a reboot (or if the process dies) you must run `start` again — see "Run automatically at boot" below to avoid this. Check the connection is live with `status`: each tunnel must show **at least one entry in the `CONNECTIONS` column**. An empty `CONNECTIONS` column means Cloudflare has the DNS route but no live connector, which produces **Error 1033**. A quick end-to-end test:
>
> ```powershell
> Invoke-WebRequest -Uri "https://app.example.com" -UseBasicParsing -TimeoutSec 20
> ```
>
> An `HTTP 200` means the full path (browser → Cloudflare → tunnel → your local service) is working.

---

### Step 5 — Test it

On **any device anywhere** (phone on 4G, another network, etc.):

```
https://app.example.com
```

You should see your local service, served over HTTPS with a valid Cloudflare certificate. 🎉

> If it doesn't load immediately, wait ~30s for the DNS record to propagate. `logs/cloudflared.err.log` is your friend.

---

### Everyday commands

| Task | Windows | Linux/macOS |
|------|---------|-------------|
| See status + URLs | `.\nat-tunnel.ps1 status` | `./nat-tunnel.sh status` |
| List services | `.\nat-tunnel.ps1 list` | `./nat-tunnel.sh list` |
| Update cloudflared | `.\nat-tunnel.ps1 update` | `./nat-tunnel.sh update` |
| Restart | `.\nat-tunnel.ps1 restart` | `./nat-tunnel.sh restart` |
| Stop | `.\nat-tunnel.ps1 stop` | `./nat-tunnel.sh stop` |
| Remove a service | `.\nat-tunnel.ps1 delete -ServiceName web` | `./nat-tunnel.sh delete -s web` |
| Tear down everything | `.\nat-tunnel.ps1 cleanup` | `./nat-tunnel.sh cleanup` |

---

## 🚀 "Quick" mode — instant random URL (no domain needed)

If you just want an ngrok-style throwaway URL **without** configuring a domain:

**Windows**:

```powershell
.\nat-tunnel.ps1 quick -Url http://localhost:3000
```

**Linux/macOS**:

```bash
./nat-tunnel.sh quick -u http://localhost:3000
```

You'll get a random URL like `https://random-words-1234.trycloudflare.com`. Note: this URL changes every restart and doesn't require login.

---

## 🔒 Security best practices (recommended)

1. **Protect your services with Cloudflare Access (Zero Trust)** — free for up to 50 users. It adds a login page in front of your tunnel so the **whole internet can't reach your intranet**.
   - Dashboard → **Zero Trust** → **Access** → **Applications** → Add app → select `app.example.com` → require your email domain or Google/GitHub login.
2. **Don't expose plain HTTP admin panels** without Access protection (e.g. your router/NAS admin UI).
3. Keep `cloudflared` updated: `cloudflared update` (Windows: re-run `winget upgrade --id Cloudflare.cloudflared -e`).

---

## 🔁 Run automatically at boot (optional)

**Linux (systemd)** — save to `/etc/systemd/system/cloudflared-nat.service`:

```ini
[Unit]
Description=Cloudflare NAT tunnel
After=network-online.target

[Service]
User=<your-user>
ExecStart=/usr/local/bin/cloudflared tunnel --config /home/<your-user>/NAT_cloudflare_script/cloudflared/config.yml run nat-tunnel
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now cloudflared-nat
```

**Windows** — use **Task Scheduler**:
- Action: Start a program → `cloudflared` → arguments: `tunnel --config C:\Users\<you>\NAT_cloudflare_script\cloudflared\config.yml run nat-tunnel`
- Trigger: **At startup**.

---

## 🧰 Manual `cloudflared` reference (what the scripts run)

```bash
cloudflared tunnel login                                  # Step 2
cloudflared tunnel create nat-tunnel                     # Step 3.1
cloudflared tunnel route dns nat-tunnel app.example.com  # Step 3.2
cloudflared tunnel list                                   # list tunnels
cloudflared tunnel --url http://localhost:3000            # quick mode
cloudflared tunnel --config cloudflared/config.yml run nat-tunnel   # start
cloudflared tunnel cleanup nat-tunnel                     # tidy stale connectors
cloudflared tunnel delete nat-tunnel --force              # remove tunnel
```

---

## 🐛 Troubleshooting

| Symptom | Fix |
|---------|-----|
| `WRN Your version ... is outdated` in red | Harmless — it's just cloudflared's notice on stderr; the scripts now hide it. Run `update` to upgrade. |
| `You are not logged in` | Run `login` and authorize the domain in the browser. |
| `route dns` says record exists | Delete the old CNAME in **DNS** → Records, then re-run `setup`. |
| `cloudflared exited early` | Read `logs/cloudflared.err.log` — usually a bad ingress rule or a missing credentials file. |
| `ERR_SSL_PROTOCOL_ERROR` on your domain | Make sure the domain is **Active** on Cloudflare (nameservers switched). |
| **Error 1033** (Cloudflare Tunnel error) | The DNS route exists but **no live connector** — the tunnel isn't running. See the dedicated section below. |
| Slow first load | DNS propagation can take up to a minute. Also try `cloudflared tunnel cleanup nat-tunnel`. |
| Tunnel shows `1: 0` healthy, still offline | Check the target URL is reachable locally first: `curl http://localhost:3000`. |

---

## 🚨 Error 1033 — "Cloudflare Tunnel error" (most common issue)

**What it means:** your hostname's DNS route is set up correctly, but **no `cloudflared` process is connected to the tunnel**. Cloudflare has the address but nothing to forward to.

```
# Error 1033
## Cloudflare Tunnel error
... Cloudflare is currently unable to resolve it.
```

**Diagnose it in two steps:**

1. Is the tunnel running? → `.\nat-tunnel.ps1 status`
2. In the `CONNECTIONS` column, does your tunnel have **any entry**?
   - **Empty `CONNECTIONS`** → that's the bug. Start it:
     ```powershell
     .\nat-tunnel.ps1 start
     ```
   - **Non-empty `CONNECTIONS`** → the tunnel is fine; check the local service instead (see the next table row).

**Why this happens:** the script's `start` spawns `cloudflared` in the background, but it stops when the PC reboots, the process is killed, or the script's PID file is lost. Another gotcha: if you have **multiple tunnels** (e.g. a pre-existing `CHAU_VPN`), a running `cloudflared` process might belong to *that* tunnel — not yours. `status` shows every tunnel and its live connections, so always verify the **right** tunnel shows connectors.

**After starting, verify the fix end-to-end** (should return `HTTP 200`):

```powershell
Invoke-WebRequest -Uri "https://app.example.com" -UseBasicParsing -TimeoutSec 20
```

To make it survive reboots, set up autostart (see the "Run automatically at boot" section).

---

## 📁 Generated files

```
NAT_cloudflare_script/
├── nat-tunnel.ps1            # Windows script
├── nat-tunnel.sh             # Linux/macOS script
├── config.json               # your service map (created on first run)
├── config.example.json       # template
├── cloudflared/
│   └── config.yml            # auto-generated, consumed by cloudflared
└── logs/                     # cloudflared output
```
