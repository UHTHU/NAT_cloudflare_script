#!/usr/bin/env bash
#
# NAT Tunnel Manager — ngrok-like access to your intranet via Cloudflare Tunnel.
#
# Wraps `cloudflared` so you can expose local / intranet services through a
# custom domain (hostname) that you own on Cloudflare.
#
# Commands:
#   install   Install cloudflared (Linux: .deb/.rpm, macOS: brew).
#   update    Update cloudflared to the latest version.
#   login     Authenticate cloudflared to your Cloudflare account (opens browser).
#   setup     Create a named tunnel + DNS route + generate cloudflared config.yml.
#   quick     Instant "ngrok-style" tunnel with a random trycloudflare.com URL.
#   start     Start the configured tunnel in the background (nohup + pid file).
#   stop      Stop the running tunnel.
#   restart   Stop then start the tunnel.
#   status    Show running status + your public URLs.
#   list      List services configured in config.json.
#   delete    Delete a service from config (and regenerate config.yml).
#   cleanup   Delete the tunnel and its DNS routes.
#   help      Show this help.
#
# Examples:
#   ./nat-tunnel.sh install
#   ./nat-tunnel.sh login
#   ./nat-tunnel.sh setup -s web -h app.example.com -u http://localhost:3000
#   ./nat-tunnel.sh start
#   ./nat-tunnel.sh status
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${CONFIG_PATH:-$SCRIPT_DIR/config.json}"
HOME_CLOUDFLARED="$HOME/.cloudflared"
CERT_FILE="$HOME_CLOUDFLARED/cert.pem"
PID_FILE="$SCRIPT_DIR/.tunnel.pid"
LOG_DIR="$SCRIPT_DIR/logs"
CONFIG_DIR="$SCRIPT_DIR/cloudflared"
GENERATED_YAML="$CONFIG_DIR/config.yml"
TUNNEL_NAME="${TUNNEL_NAME:-nat-tunnel}"

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
cyan()  { printf '\033[36m%s\033[0m\n' "$*"; }

step() { printf '\n==> %s\n' "$*" | cyan; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    OK: %s\n' "$*" | green; }
warn() { printf '    WARN: %s\n' "$*" | yellow; }
err()  { printf '    ERROR: %s\n' "$*" | red; }

ensure_cloudflared() {
  if ! command -v cloudflared >/dev/null 2>&1; then
    err "cloudflared was not found in PATH."
    info "Run: ./nat-tunnel.sh install"
    exit 1
  fi
}

get_tunnel_id() {
  local name="$1"
  cloudflared tunnel list 2>/dev/null \
    | awk -v n="$name" '$2 == n { print $1; exit }'
}

get_local_config() {
  if [ ! -f "$CONFIG_PATH" ]; then
    step "No config.json found - creating a default one at $CONFIG_PATH"
    cat > "$CONFIG_PATH" <<EOF
{
  "tunnelName": "$TUNNEL_NAME",
  "services": [
    { "name": "default", "hostname": "", "url": "http://localhost:8080" }
  ]
}
EOF
  fi
}

show_urls() {
  printf '\n  %s\n' "Your public URLs:" | green
  python3 - "$CONFIG_PATH" <<'PY' 2>/dev/null || jq -r '.services[] | "    https://\(.hostname)  ->  \(.url)"' "$CONFIG_PATH"
import json,sys
cfg=json.load(open(sys.argv[1]))
for s in cfg["services"]:
    if s.get("hostname"):
        print(f"    https://{s['hostname']}  ->  {s['url']}")
PY
  printf '\n'
}

write_cloudflared_config() {
  local tunnel
  tunnel=$(python3 -c "import json,sys;print(json.load(open('$CONFIG_PATH'))['tunnelName'])" 2>/dev/null || jq -r '.tunnelName' "$CONFIG_PATH")
  local tunnel_id
  tunnel_id="$(get_tunnel_id "$tunnel")"
  if [ -z "$tunnel_id" ]; then
    err "Tunnel '$tunnel' not found. Run 'setup' first."
    exit 1
  fi
  local cred_file="$HOME_CLOUDFLARED/$tunnel_id.json"
  if [ ! -f "$cred_file" ]; then
    err "Credentials file not found: $cred_file"
    exit 1
  fi

  mkdir -p "$CONFIG_DIR"
  {
    echo "tunnel: $tunnel"
    echo "credentials-file: $cred_file"
    echo ""
    echo "ingress:"
    python3 - "$CONFIG_PATH" <<'PY'
import json,sys
cfg=json.load(open(sys.argv[1]))
for s in cfg["services"]:
    if s.get("hostname"):
        print(f"  - hostname: {s['hostname']}")
        print(f"    service: {s['url']}")
print("  - service: http_status:404")
PY
    echo ""
  } > "$GENERATED_YAML"
  ok "Wrote $GENERATED_YAML"
}

# ------------------------------------------------------------------
# Commands
# ------------------------------------------------------------------
cmd_install() {
  if command -v cloudflared >/dev/null 2>&1; then
    ok "cloudflared already installed: $(command -v cloudflared)"
    return
  fi
  if command -v brew >/dev/null 2>&1; then
    step "Installing cloudflared via Homebrew..."
    brew install cloudflared
  elif [ -f /etc/debian_version ] && command -v dpkg >/dev/null 2>&1; then
    step "Installing cloudflared via .deb package..."
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflared.list
    sudo apt-get update && sudo apt-get install -y cloudflared
  elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    step "Installing cloudflared via .rpm package..."
    sudo curl -fsSL https://pkg.cloudflare.com/cloudflared-ascii.repo -o /etc/yum.repos.d/cloudflared.repo
    sudo dnf install -y cloudflared || sudo yum install -y cloudflared
  else
    err "Unsupported package manager. Install manually: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
  fi
}

cmd_login() {
  ensure_cloudflared
  if [ -f "$CERT_FILE" ]; then
    ok "Already logged in ($CERT_FILE)"
    return
  fi
  step "Opening your browser to authorize cloudflared..."
  info "Pick the domain you own in the Cloudflare dashboard and click 'Authorize'."
  cloudflared tunnel login 2>/dev/null
  if [ -f "$CERT_FILE" ]; then
    ok "Login successful. Certificate saved to $CERT_FILE"
  fi
}

cmd_update() {
  ensure_cloudflared
  step "Updating cloudflared..."
  if cloudflared update 2>/dev/null; then
    ok "cloudflared is up to date: $(cloudflared --version)"
  else
    warn "Self-update not supported for this install - trying the package manager..."
    if command -v brew >/dev/null 2>&1; then
      brew upgrade cloudflared
    elif command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update && sudo apt-get install -y cloudflared
    elif command -v dnf >/dev/null 2>&1; then
      sudo dnf update -y cloudflared || sudo dnf install -y cloudflared
    else
      err "Update failed. Download the latest manually: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
    fi
  fi
}

cmd_setup() {
  local service="$1" host="$2" target="$3"
  ensure_cloudflared
  if [ ! -f "$CERT_FILE" ]; then
    err "You are not logged in yet. Run: ./nat-tunnel.sh login"
    return
  fi
  if [ -z "$host" ]; then
    err "Please provide -h hostname (e.g. app.example.com)"
    info "Example: ./nat-tunnel.sh setup -s web -h app.example.com -u http://localhost:3000"
    return
  fi
  get_local_config

  local tunnel tunnel_id
  tunnel="$(python3 -c "import json,sys;print(json.load(open('$CONFIG_PATH'))['tunnelName'])" 2>/dev/null || jq -r '.tunnelName' "$CONFIG_PATH")"
  tunnel_id="$(get_tunnel_id "$tunnel")"

  if [ -z "$tunnel_id" ]; then
    step "Creating named tunnel '$tunnel'..."
    cloudflared tunnel create "$tunnel"
  else
    ok "Tunnel '$tunnel' already exists ($tunnel_id)"
  fi

  step "Routing DNS: $host -> tunnel '$tunnel'"
  cloudflared tunnel route dns "$tunnel" "$host"

  python3 - "$CONFIG_PATH" "$service" "$host" "$target" <<'PY'
import json,sys
path,svc,h,tgt=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
cfg=json.load(open(path))
for s in cfg["services"]:
    if s["name"]==svc:
        s["hostname"]=h; s["url"]=tgt; break
else:
    cfg["services"].append({"name":svc,"hostname":h,"url":tgt})
json.dump(cfg,open(path,"w"),indent=2)
PY

  write_cloudflared_config
  step "Done! Start the tunnel with:  ./nat-tunnel.sh start"
}

cmd_quick() {
  ensure_cloudflared
  step "Starting quick tunnel to $URL (random trycloudflare.com URL, no login needed)"
  info "Press Ctrl+C to stop."
  cloudflared tunnel --url "$URL"
}

cmd_start() {
  get_local_config
  write_cloudflared_config

  local running=""
  [ -f "$PID_FILE" ] && running="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "$running" ] && kill -0 "$running" 2>/dev/null; then
    warn "Tunnel is already running (PID $running)."
    return
  fi

  ensure_cloudflared
  mkdir -p "$LOG_DIR"
  nohup cloudflared tunnel --config "$GENERATED_YAML" run "$TUNNEL_NAME" \
    >"$LOG_DIR/cloudflared.out.log" 2>"$LOG_DIR/cloudflared.err.log" &
  local pid=$!
  echo "$pid" > "$PID_FILE"
  ok "Tunnel started with PID $pid"
  info "Logs: $LOG_DIR/cloudflared.out.log"

  sleep 4
  if ! kill -0 "$pid" 2>/dev/null; then
    err "cloudflared exited early. Check the log:"
    tail -n 15 "$LOG_DIR/cloudflared.err.log" 2>/dev/null || true
  else
    show_urls
  fi
}

cmd_stop() {
  local running=""
  [ -f "$PID_FILE" ] && running="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -z "$running" ] || ! kill -0 "$running" 2>/dev/null; then
    warn "No running tunnel found."
    return
  fi
  kill "$running" 2>/dev/null || true
  rm -f "$PID_FILE"
  ok "Tunnel stopped (PID $running)."
}

cmd_status() {
  local running=""
  [ -f "$PID_FILE" ] && running="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "$running" ] && kill -0 "$running" 2>/dev/null; then
    ok "Tunnel is RUNNING (PID $running)"
  else
    warn "Tunnel is NOT running."
  fi
  get_local_config
  show_urls
  step "Cloudflare named tunnels:"
  cloudflared tunnel list
  step "Configured local services:"
  python3 -c "import json,sys; [print(f'  [{s[\"name\"]}] {s[\"url\"]}  =>  https://{s[\"hostname\"]}') for s in json.load(open('$CONFIG_PATH'))['services']]" 2>/dev/null \
    || jq -r '.services[] | "  [\(.name)] \(.url)  =>  https://\(.hostname)"' "$CONFIG_PATH"
}

cmd_delete() {
  local service="$1"
  get_local_config
  python3 - "$CONFIG_PATH" "$service" <<'PY'
import json,sys
path,svc=sys.argv[1],sys.argv[2]
cfg=json.load(open(path))
before=len(cfg["services"])
cfg["services"]=[s for s in cfg["services"] if s["name"]!=svc]
if len(cfg["services"])==before:
    print("NOT_FOUND"); sys.exit(1)
json.dump(cfg,open(path,"w"),indent=2)
PY
  if [ $? -eq 1 ]; then
    err "No service named '$service' in config.json."
    return
  fi
  write_cloudflared_config
  ok "Removed service '$service' from config."
  info "Note: the DNS CNAME record still exists in Cloudflare - delete it from the dashboard if you no longer need it."
}

cmd_cleanup() {
  cmd_stop
  get_local_config
  local tunnel
  tunnel="$(python3 -c "import json,sys;print(json.load(open('$CONFIG_PATH'))['tunnelName'])" 2>/dev/null || jq -r '.tunnelName' "$CONFIG_PATH")"
  step "Deleting DNS routes & tunnel '$tunnel'..."
  cloudflared tunnel cleanup "$tunnel" 2>/dev/null || true
  if cloudflared tunnel delete "$tunnel" --force; then
    ok "Tunnel '$tunnel' deleted."
  else
    err "Could not delete tunnel automatically. Delete the CNAME records in the dashboard, then run: cloudflared tunnel delete $tunnel"
  fi
  rm -f "$PID_FILE"
}

usage() {
  grep -E '^#( |$)' "$0" | sed -n '1,40p' | sed 's/^# \{0,1\}//'
}

# ------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------
CMD="${1:-help}"
shift || true

SERVICE="default"
HOST=""
URL="http://localhost:8080"

while [ $# -gt 0 ]; do
  case "$1" in
    -s|--service) SERVICE="$2"; shift 2 ;;
    -h|--hostname) HOST="$2"; shift 2 ;;
    -u|--url) URL="$2"; shift 2 ;;
    *) shift ;;
  esac
done

case "$CMD" in
  install)  cmd_install ;;
  update)   cmd_update ;;
  login)    cmd_login ;;
  setup)    cmd_setup "$SERVICE" "$HOST" "$URL" ;;
  quick)    cmd_quick ;;
  start)    cmd_start ;;
  stop)     cmd_stop ;;
  restart)  cmd_stop; cmd_start ;;
  status)   cmd_status ;;
  list)     get_local_config; python3 -c "import json,sys; [print(s['name'], s['url']) for s in json.load(open('$CONFIG_PATH'))['services']]" 2>/dev/null || jq -r '.services[] | "\(.name) \(.url)"' "$CONFIG_PATH" ;;
  delete)   cmd_delete "$SERVICE" ;;
  cleanup)  cmd_cleanup ;;
  help|*)   usage ;;
esac
