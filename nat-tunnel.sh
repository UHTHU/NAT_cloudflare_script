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
# ─── Colored output ───
# NOTE: never pipe into a function that reads "$*" (e.g. "printf ... | red")
# — pipeline members run in a subshell where "$*" is empty, so the message
# would be lost. Instead, embed the ANSI color in the format string.
C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_CYAN='\033[36m'; C_RESET='\033[0m'

step() { printf "${C_CYAN}\n==> %s${C_RESET}\n" "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf "${C_GREEN}    OK: %s${C_RESET}\n" "$*"; }
warn() { printf "${C_YELLOW}    WARN: %s${C_RESET}\n" "$*"; }
err()  { printf "${C_RED}    ERROR: %s${C_RESET}\n" "$*"; }

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

# Read the tunnel name from config.json (jq preferred, python3 fallback).
config_tunnel_name() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '.tunnelName' "$CONFIG_PATH" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "import json,sys;print(json.load(open('$CONFIG_PATH'))['tunnelName'])" 2>/dev/null
  else
    return 1
  fi
}

config_service_count() {
  if command -v jq >/dev/null 2>&1; then
    jq '.services | length' "$CONFIG_PATH" 2>/dev/null || echo 0
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "import json,sys;print(len(json.load(open('$CONFIG_PATH'))['services']))" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

config_service_list() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '.services[] | "  [\(.name)] \(.url)  =>  https://\(.hostname)"' "$CONFIG_PATH" 2>/dev/null || true
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "import json,sys; [print(f'  [{s[\"name\"]}] {s[\"url\"]}  =>  https://{s[\"hostname\"]}') for s in json.load(open('$CONFIG_PATH'))['services']]" 2>/dev/null || true
  else
    warn "Cannot read $CONFIG_PATH (need jq or python3)."
  fi
}

config_service_list_brief() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '.services[] | "\(.name) \(.url)"' "$CONFIG_PATH" 2>/dev/null || true
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "import json,sys; [print(s['name'], s['url']) for s in json.load(open('$CONFIG_PATH'))['services']]" 2>/dev/null || true
  else
    warn "Cannot read $CONFIG_PATH (need jq or python3)."
  fi
}

# Add/update a service entry in config.json (jq preferred, python3 fallback).
update_service() {
  local name="$1" hostname="$2" url="$3"
  if command -v jq >/dev/null 2>&1; then
    jq --arg n "$name" --arg h "$hostname" --arg u "$url" '
      (.services | map(select(.name == $n)) | length) as $c |
      if $c > 0 then
        .services |= map(if .name == $n then (.hostname = $h | .url = $u) else . end)
      else
        .services += [{name: $n, hostname: $h, url: $u}]
      end' "$CONFIG_PATH" > "$CONFIG_PATH.tmp" 2>/dev/null && mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$CONFIG_PATH" "$name" "$hostname" "$url" <<'PY'
import json,sys
path,n,h,u=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
cfg=json.load(open(path))
for s in cfg["services"]:
    if s["name"]==n:
        s["hostname"]=h; s["url"]=u; break
else:
    cfg["services"].append({"name":n,"hostname":h,"url":u})
json.dump(cfg,open(path,"w"),indent=2)
PY
  else
    return 1
  fi
}

# Remove a service entry from config.json (jq preferred, python3 fallback).
delete_service() {
  local name="$1"
  if command -v jq >/dev/null 2>&1; then
    jq --arg n "$name" 'del(.services[] | select(.name == $n))' "$CONFIG_PATH" > "$CONFIG_PATH.tmp" 2>/dev/null && mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$CONFIG_PATH" "$name" <<'PY'
import json,sys
path,n=sys.argv[1],sys.argv[2]
cfg=json.load(open(path))
cfg["services"]=[s for s in cfg["services"] if s["name"]!=n]
json.dump(cfg,open(path,"w"),indent=2)
PY
  else
    return 1
  fi
}

# Emit the "ingress:" block body for config.yml (jq preferred, python3 fallback).
ingress_block() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '.services[] | select(.hostname != "") | "  - hostname: \(.hostname)\n    service: \(.url)"' "$CONFIG_PATH" 2>/dev/null || return 1
    echo "  - service: http_status:404"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$CONFIG_PATH" <<'PY' || return 1
import json,sys
cfg=json.load(open(sys.argv[1]))
for s in cfg["services"]:
    if s.get("hostname"):
        print(f"  - hostname: {s['hostname']}")
        print(f"    service: {s['url']}")
print("  - service: http_status:404")
PY
  else
    return 1
  fi
}

show_urls() {
  printf "${C_GREEN}\n  %s${C_RESET}\n" "Your public URLs:"
  if command -v jq >/dev/null 2>&1; then
    jq -r '.services[] | select(.hostname != "") | "    https://\(.hostname)  ->  \(.url)"' "$CONFIG_PATH" 2>/dev/null || true
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$CONFIG_PATH" <<'PY' 2>/dev/null || true
import json,sys
cfg=json.load(open(sys.argv[1]))
for s in cfg["services"]:
    if s.get("hostname"):
        print(f"    https://{s['hostname']}  ->  {s['url']}")
PY
  fi
  printf '\n'
}

write_cloudflared_config() {
  local tunnel="${1:-}"
  if [ -z "$tunnel" ]; then
    tunnel="$(config_tunnel_name || true)"
  fi
  if [ -z "$tunnel" ]; then
    err "Cannot read tunnelName from $CONFIG_PATH (need jq or python3)."
    return 1
  fi
  local tunnel_id
  tunnel_id="$(get_tunnel_id "$tunnel" || true)"
  if [ -z "$tunnel_id" ]; then
    err "Tunnel '$tunnel' not found. Run 'setup' first."
    return 1
  fi
  local cred_file="$HOME_CLOUDFLARED/$tunnel_id.json"
  if [ ! -f "$cred_file" ]; then
    err "Credentials file not found: $cred_file"
    return 1
  fi

  mkdir -p "$CONFIG_DIR"
  if ! ingress_block > "$GENERATED_YAML.tmp"; then
    err "Cannot generate ingress rules (need jq or python3)."
    rm -f "$GENERATED_YAML.tmp"
    return 1
  fi
  {
    echo "tunnel: $tunnel"
    echo "credentials-file: $cred_file"
    echo ""
    echo "ingress:"
    cat "$GENERATED_YAML.tmp"
    echo ""
  } > "$GENERATED_YAML"
  rm -f "$GENERATED_YAML.tmp"
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
    return 1
  fi
  if [ -z "$host" ]; then
    err "Please provide -h hostname (e.g. app.example.com)"
    info "Example: ./nat-tunnel.sh setup -s web -h app.example.com -u http://localhost:3000"
    return 1
  fi
  get_local_config

  local tunnel tunnel_id
  tunnel="$(config_tunnel_name || true)"
  if [ -z "$tunnel" ]; then
    err "Cannot read tunnelName from config.json (need jq or python3)."
    return 1
  fi
  tunnel_id="$(get_tunnel_id "$tunnel" || true)"

  if [ -z "$tunnel_id" ]; then
    step "Creating named tunnel '$tunnel'..."
    cloudflared tunnel create "$tunnel"
  else
    ok "Tunnel '$tunnel' already exists ($tunnel_id)"
  fi

  step "Routing DNS: $host -> tunnel '$tunnel'"
  cloudflared tunnel route dns "$tunnel" "$host"

  if ! update_service "$service" "$host" "$target"; then
    err "Cannot edit $CONFIG_PATH (need jq or python3)."
    return 1
  fi

  write_cloudflared_config "$tunnel" || return 1
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
  local tunnel running
  tunnel="$(config_tunnel_name || true)"
  if [ -z "$tunnel" ]; then
    err "Cannot read tunnelName from config.json (need jq or python3)."
    return 1
  fi

  running=""
  [ -f "$PID_FILE" ] && running="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "$running" ] && kill -0 "$running" 2>/dev/null; then
    warn "Tunnel is already running (PID $running)."
    return
  fi

  if ! write_cloudflared_config "$tunnel"; then
    return 1
  fi

  ensure_cloudflared
  mkdir -p "$LOG_DIR"
  nohup cloudflared tunnel --config "$GENERATED_YAML" run "$tunnel" \
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
  cloudflared tunnel list 2>/dev/null || true
  step "Configured local services:"
  config_service_list || true
}

cmd_delete() {
  local service="$1"
  get_local_config
  local before after
  before="$(config_service_count)"
  if ! delete_service "$service"; then
    err "Cannot edit $CONFIG_PATH (need jq or python3)."
    return 1
  fi
  after="$(config_service_count)"
  if [ "$after" -ge "$before" ]; then
    err "No service named '$service' in config.json."
    return 1
  fi
  write_cloudflared_config || return 1
  ok "Removed service '$service' from config."
  info "Note: the DNS CNAME record still exists in Cloudflare - delete it from the dashboard if you no longer need it."
}

cmd_cleanup() {
  cmd_stop
  get_local_config
  local tunnel
  tunnel="$(config_tunnel_name || true)"
  if [ -z "$tunnel" ]; then
    err "Cannot read tunnelName from config.json (need jq or python3)."
    return 1
  fi
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
    -s|--service)  if [ $# -ge 2 ]; then SERVICE="$2"; shift 2; else shift; fi ;;
    -h|--hostname) if [ $# -ge 2 ]; then HOST="$2"; shift 2; else shift; fi ;;
    -u|--url)      if [ $# -ge 2 ]; then URL="$2"; shift 2; else shift; fi ;;
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
  list)     get_local_config; config_service_list_brief ;;
  delete)   cmd_delete "$SERVICE" ;;
  cleanup)  cmd_cleanup ;;
  help|*)   usage ;;
esac
