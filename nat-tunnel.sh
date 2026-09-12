#!/usr/bin/env bash
#
# NAT Tunnel Manager — ngrok-like access to your intranet via Cloudflare Tunnel.
#
# Wraps `cloudflared` so you can expose local / intranet services through a
# custom domain (hostname) that you own on Cloudflare.
#
# Commands:
#   (no args) Run the interactive menu (recommended for beginners).
#   menu      Run the interactive menu explicitly.
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
#   ./nat-tunnel.sh            # interactive menu
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

# ------------------------------------------------------------------
# Interactive helpers
# ------------------------------------------------------------------
# Show a banner once at the top of an interactive session.
interactive_banner() {
  printf "${C_CYAN}\n  ┌─────────────────────────────────────────┐${C_RESET}\n"
  printf "${C_CYAN}  │   🌐  NAT Tunnel Manager  (interactive)   │${C_RESET}\n"
  printf "${C_CYAN}  └─────────────────────────────────────────┘${C_RESET}\n"
}

# Draw a numbered menu from a list of labels; return the chosen index (0-based)
# in $? and store the label in $MENU_CHOICE. Returns 130 if the user quits.
menu_pick() {
  local title="$1"
  shift
  local labels=("$@")
  local i
  printf "${C_CYAN}\n==> %s${C_RESET}\n" "$title"
  for i in "${!labels[@]}"; do
    printf "    ${C_GREEN}%d${C_RESET}) %s\n" "$((i + 1))" "${labels[$i]}"
  done
  printf "    Enter choice [1-%d, or 0/q to go back]: " "${#labels[@]}"
  local reply
  read -r reply
  case "$reply" in
  "" | q | Q | 0) return 130 ;;
  esac
  if ! [[ "$reply" =~ ^[0-9]+$ ]] || [ "$reply" -lt 1 ] || [ "$reply" -gt "${#labels[@]}" ]; then
    warn "Invalid choice: '$reply'"
    return 130
  fi
  MENU_CHOICE="${labels[$((reply - 1))]}"
  return 0
}

# Prompt for a value with an optional default. Empty input -> default (may be "").
# Reads the answer into $PROMPT_ANSWER. Returns 130 if the user presses Ctrl+C.
read_default() {
  local label="$1" default="$2"
  if [ -n "$default" ]; then
    printf "    %s [%s]: " "$label" "$default"
  else
    printf "    %s: " "$label"
  fi
  local ans
  if ! read -r ans; then
    printf '\n'
    return 130
  fi
  case "$ans" in
  q | Q | 0)
    printf '\n'
    return 130
    ;;
  esac
  if [ -n "$default" ] && [ -z "$ans" ]; then
    ans="$default"
  fi
  PROMPT_ANSWER="$ans"
}

# Validate a URL; accepts a scheme-prefixed local address.
# Repeats the prompt until valid (or the user cancels). Returns 130 on cancel.
get_valid_url() {
  local label="${1:-Local service URL}" default="$2"
  while :; do
    if ! read_default "$label" "$default"; then return 130; fi
    local v="$PROMPT_ANSWER"
    if [ -n "$v" ] && [[ "$v" == https://* || "$v" == http://* ]]; then
      PROMPT_ANSWER="$v"
      return 0
    fi
    err "Enter a full URL starting with http:// or https:// (e.g. http://localhost:8000)"
  done
}

# Validate a hostname (a domain you own on Cloudflare, no scheme/path).
# Repeats until valid (or cancelled). Returns 130 on cancel.
get_valid_hostname() {
  local default="$1"
  while :; do
    if ! read_default "Public hostname (your domain)" "$default"; then return 130; fi
    local h="$PROMPT_ANSWER"
    if [ -z "$h" ]; then
      err "Hostname cannot be empty (e.g. app.example.com)"
      continue
    fi
    if [[ "$h" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] &&
      [[ "$h" != *://* ]] && [[ "$h" != */* ]]; then
      PROMPT_ANSWER="$h"
      return 0
    fi
    err "Invalid hostname - use just the domain, no https:// and no path (e.g. app.example.com)"
  done
}

ensure_cloudflared() {
  if ! command -v cloudflared >/dev/null 2>&1; then
    err "cloudflared was not found in PATH."
    info "Run: ./nat-tunnel.sh install"
    exit 1
  fi
}

get_tunnel_id() {
  local name="$1"
  cloudflared tunnel list 2>/dev/null |
    awk -v n="$name" '$2 == n { print $1; exit }'
}

get_local_config() {
  if [ ! -f "$CONFIG_PATH" ]; then
    step "No config.json found - creating a default one at $CONFIG_PATH"
    cat >"$CONFIG_PATH" <<EOF
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
      end' "$CONFIG_PATH" >"$CONFIG_PATH.tmp" 2>/dev/null && mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"
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
    jq --arg n "$name" 'del(.services[] | select(.name == $n))' "$CONFIG_PATH" >"$CONFIG_PATH.tmp" 2>/dev/null && mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"
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
  if ! ingress_block >"$GENERATED_YAML.tmp"; then
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
  } >"$GENERATED_YAML"
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
  echo "$pid" >"$PID_FILE"
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
  if cloudflared tunnel delete --force "$tunnel"; then
    ok "Tunnel '$tunnel' deleted."
  else
    err "Could not delete tunnel automatically. Delete the CNAME records in the dashboard, then run: cloudflared tunnel delete $tunnel"
  fi
  rm -f "$PID_FILE"
}

# ------------------------------------------------------------------
# Interactive commands
# ------------------------------------------------------------------
# Start/stop/restart the configured tunnel with friendly output.
interactive_start() {
  get_local_config
  if ! write_cloudflared_config >/dev/null 2>&1; then
    err "Nothing configured yet. Add a service first."
    return 1
  fi
  cmd_start
}

interactive_stop() { cmd_stop; }
interactive_restart() {
  cmd_stop
  cmd_start
}

# Prompt for local URL + public hostname, then create/route/configure the tunnel.
interactive_add_service() {
  ensure_cloudflared
  if [ ! -f "$CERT_FILE" ]; then
    err "You are not logged in yet. Run: ./nat-tunnel.sh login"
    return 1
  fi
  get_local_config
  if ! get_valid_url "Local service URL" ""; then return; fi
  local target="$PROMPT_ANSWER"
  if ! get_valid_hostname ""; then return; fi
  local host="$PROMPT_ANSWER"

  # Suggest a service name from the hostname.
  local name
  name="$(printf '%s' "$host" | sed -E 's/\.[^.]+$//; s/[^A-Za-z0-9_-]/-/g')"
  [ -z "$name" ] && name="web"
  if ! read_default "Service name (label)" "$name"; then return; fi
  [ -z "$PROMPT_ANSWER" ] && PROMPT_ANSWER="$name"
  local service="$PROMPT_ANSWER"

  step "Adding '$host' -> $target (service: $service)..."
  cmd_setup "$service" "$host" "$target"
}

# Wrap an editing flow so Ctrl+C / 'q' returns cleanly instead of echoing errors.
interactive_edit_service() {
  local name="$1"
  local cur_url cur_host
  if command -v jq >/dev/null 2>&1; then
    cur_url="$(jq -r --arg n "$name" '.services[] | select(.name==$n) | .url' "$CONFIG_PATH" 2>/dev/null)"
    cur_host="$(jq -r --arg n "$name" '.services[] | select(.name==$n) | .hostname' "$CONFIG_PATH" 2>/dev/null)"
  elif command -v python3 >/dev/null 2>&1; then
    cur_url="$(python3 -c 'import json,sys;c=json.load(open(sys.argv[1]));
print([s["url"] for s in c["services"] if s["name"]==sys.argv[2]][0])' \
      "$CONFIG_PATH" "$name" 2>/dev/null)"
    cur_host="$(python3 -c 'import json,sys;c=json.load(open(sys.argv[1]));
print([s["hostname"] for s in c["services"] if s["name"]==sys.argv[2]][0])' \
      "$CONFIG_PATH" "$name" 2>/dev/null)"
  fi
  cur_url="${cur_url:-http://localhost:8080}"
  cur_host="${cur_host:-}"

  if ! get_valid_url "Local URL (current: $cur_url)" "$cur_url"; then return; fi
  local new_url="$PROMPT_ANSWER"
  if ! get_valid_hostname "$cur_host"; then return; fi
  local new_host="$PROMPT_ANSWER"

  step "Updating '$name': $new_host -> $new_url"
  if ! update_service "$name" "$new_host" "$new_url"; then
    err "Cannot edit $CONFIG_PATH (need jq or python3)."
    return 1
  fi
  if [ -n "$new_host" ] && [ "$new_host" != "$cur_host" ]; then
    step "Routing DNS: $new_host -> tunnel"
    local tunnel
    tunnel="$(config_tunnel_name || true)"
    [ -n "$tunnel" ] && cloudflared tunnel route dns "$tunnel" "$new_host" >/dev/null 2>&1 || true
  fi
  if ! write_cloudflared_config; then return 1; fi
  ok "Service '$name' updated."
}

interactive_delete_service() {
  local name="$1"
  step "Removing service '$name' from config..."
  if ! delete_service "$name"; then
    err "Cannot edit $CONFIG_PATH (need jq or python3)."
    return
  fi
  write_cloudflared_config >/dev/null 2>&1 || true
  ok "Removed service '$name'."
  info "Note: the DNS CNAME still exists in Cloudflare - delete it in the dashboard if unused."
}

# List services and let the user manage one (edit / delete) or add a new one.
interactive_manage() {
  get_local_config
  local tunnel_name
  tunnel_name="$(config_tunnel_name || true)"
  local running=no
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
    running=yes
  fi
  if [ -n "$tunnel_name" ]; then
    printf "${C_CYAN}  Tunnel:${C_RESET} %s  ${C_CYAN}Status:${C_RESET} %s\n" "$tunnel_name" "$running"
  fi
  local names=()
  if command -v jq >/dev/null 2>&1; then
    while IFS= read -r n; do [ -n "$n" ] && names+=("$n"); done \
      < <(jq -r '.services[]?.name' "$CONFIG_PATH" 2>/dev/null)
  elif command -v python3 >/dev/null 2>&1; then
    while IFS= read -r n; do [ -n "$n" ] && names+=("$n"); done \
      < <(python3 -c 'import json,sys
for s in json.load(open(sys.argv[1]))["services"]: print(s["name"])' \
        "$CONFIG_PATH" 2>/dev/null)
  else
    warn "Cannot read $CONFIG_PATH (need jq or python3)."
    return
  fi
  [ ${#names[@]} -eq 0 ] && warn "No services configured yet."

  local labels=()
  local i
  for i in "${!names[@]}"; do
    local h url
    if command -v jq >/dev/null 2>&1; then
      h="$(jq -r --arg n "${names[$i]}" '.services[] | select(.name==$n) | .hostname' "$CONFIG_PATH" 2>/dev/null)"
      url="$(jq -r --arg n "${names[$i]}" '.services[] | select(.name==$n) | .url' "$CONFIG_PATH" 2>/dev/null)"
    else
      h="$(python3 -c 'import json,sys;c=json.load(open(sys.argv[1]));
print([s["hostname"] for s in c["services"] if s["name"]==sys.argv[2]][0])' \
        "$CONFIG_PATH" "${names[$i]}" 2>/dev/null)"
      url="$(python3 -c 'import json,sys;c=json.load(open(sys.argv[1]));
print([s["url"] for s in c["services"] if s["name"]==sys.argv[2]][0])' \
        "$CONFIG_PATH" "${names[$i]}" 2>/dev/null)"
    fi
    if [ -n "$h" ]; then
      labels+=("Edit ${names[$i]}  ($h -> $url)")
    else
      labels+=("Edit ${names[$i]}  (no hostname -> $url)")
    fi
  done
  [ ${#names[@]} -gt 0 ] && labels+=("Add a new service")
  labels+=("Back to main menu")

  if ! menu_pick "Select a service to manage" "${labels[@]}"; then return; fi
  local pick="$MENU_CHOICE"
  if [ "$pick" = "Back to main menu" ]; then
    return
  fi
  if [ "$pick" = "Add a new service" ]; then
    interactive_add_service
    return
  fi

  # Extract the canonical service name (text between 'Edit ' and the first '  (').
  local svc="${pick#Edit }"
  svc="${svc%%  *}"

  if ! menu_pick "What do you want to do with '$svc'?" "Edit URL / hostname" "Remove service" "Cancel"; then return; fi
  case "$MENU_CHOICE" in
  "Edit URL / hostname") interactive_edit_service "$svc" ;;
  "Remove service") interactive_delete_service "$svc" ;;
  *) return ;;
  esac
}

# Main interactive menu - loops until the user chooses to exit.
cmd_interactive() {
  interactive_banner
  ensure_cloudflared
  while :; do
    printf "${C_YELLOW}\n  Tunnel: %s\n${C_RESET}" "$(config_tunnel_name 2>/dev/null || echo 'n/a')"
    if ! menu_pick "What would you like to do?" \
      "Start tunnel" \
      "Stop tunnel" \
      "Restart tunnel" \
      "Show status / URLs" \
      "Quick tunnel (no domain)" \
      "Add a service (local URL + domain)" \
      "Manage existing services" \
      "Login status" \
      "Exit"; then
      printf "${C_GREEN}  Goodbye!${C_RESET}\n"
      return
    fi
    case "$MENU_CHOICE" in
    "Start tunnel") interactive_start ;;
    "Stop tunnel") interactive_stop ;;
    "Restart tunnel") interactive_restart ;;
    "Show status / URLs") cmd_status ;;
    "Quick tunnel (no domain)")
      local qurl="http://localhost:8080"
      if ! get_valid_url "Local URL for quick tunnel" "http://localhost:8080"; then continue; fi
      qurl="$PROMPT_ANSWER"
      URL="$qurl"
      cmd_quick
      ;;
    "Add a service (local URL + domain)") interactive_add_service ;;
    "Manage existing services") interactive_manage ;;
    "Login status")
      if [ -f "$CERT_FILE" ]; then ok "Logged in ($CERT_FILE)"; else warn "Not logged in - run: ./nat-tunnel.sh login"; fi
      ;;
    *) return ;;
    esac
  done
}

usage() {
  grep -E '^#( |$)' "$0" | sed -n '1,40p' | sed 's/^# \{0,1\}//'
}

# ------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------
CMD="${1:-menu}"
shift || true

SERVICE="default"
HOST=""
URL="http://localhost:8080"

while [ $# -gt 0 ]; do
  case "$1" in
  -s | --service) if [ $# -ge 2 ]; then
    SERVICE="$2"
    shift 2
  else shift; fi ;;
  -h | --hostname) if [ $# -ge 2 ]; then
    HOST="$2"
    shift 2
  else shift; fi ;;
  -u | --url) if [ $# -ge 2 ]; then
    URL="$2"
    shift 2
  else shift; fi ;;
  *) shift ;;
  esac
done

case "$CMD" in
menu) cmd_interactive ;;
install) cmd_install ;;
update) cmd_update ;;
login) cmd_login ;;
setup) cmd_setup "$SERVICE" "$HOST" "$URL" ;;
quick) cmd_quick ;;
start) cmd_start ;;
stop) cmd_stop ;;
restart)
  cmd_stop
  cmd_start
  ;;
status) cmd_status ;;
list)
  get_local_config
  config_service_list_brief
  ;;
delete) cmd_delete "$SERVICE" ;;
cleanup) cmd_cleanup ;;
help | *) usage ;;
esac
