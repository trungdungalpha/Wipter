#!/bin/bash
set -euo pipefail

# ====== 0) YÊU CẦU BIẾN ======
: "${WIPTER_EMAIL:?Error: WIPTER_EMAIL environment variable is not set.}"
: "${WIPTER_PASSWORD:?Error: WIPTER_PASSWORD environment variable is not set.}"

WEB_ACCESS_ENABLED="${WEB_ACCESS_ENABLED:-false}"
VNC_PASSWORD="${VNC_PASSWORD:-}"
KEYRING_PASS="${KEYRING_PASS:-}"
AUTO_LOGIN_ONCE="${AUTO_LOGIN_ONCE:-true}"
CLOSE_GUI_AFTER_LOGIN="${CLOSE_GUI_AFTER_LOGIN:-true}"
LOGIN_MARK="${LOGIN_MARK:-$HOME/.wipter-configured}"

# ====== 1) D-BUS + KEYRING ======
eval "$(dbus-launch --sh-syntax)" || true
if [[ -n "$KEYRING_PASS" ]]; then
  echo "$KEYRING_PASS" | gnome-keyring-daemon --unlock --replace || true
else
  gnome-keyring-daemon --replace >/dev/null 2>&1 || true
fi

# ====== 2) DỌN LOCK X ======
rm -f /tmp/.X1-lock || true
rm -rf /tmp/.X11-unix || true

# ====== 3) VNC / noVNC (nội bộ) ======
mkdir -p "$HOME/.vnc"
if [[ -z "$VNC_PASSWORD" ]]; then
  VNC_PASSWORD="$(tr -dc '[:alnum:]' < /dev/urandom | fold -w 10 | head -n1)"
fi
echo -n "$VNC_PASSWORD" | /opt/TurboVNC/bin/vncpasswd -f > "$HOME/.vnc/passwd"
chmod 400 "$HOME/.vnc/passwd"

VNC_PORT=${VNC_PORT:-5900}
WEBSOCKIFY_PORT=${WEBSOCKIFY_PORT:-6080}

/opt/TurboVNC/bin/vncserver -rfbauth "$HOME/.vnc/passwd" -geometry 1200x800 \
  -rfbport "${VNC_PORT}" -wm openbox :1 || {
    echo "Error: Failed to start TurboVNC server on port ${VNC_PORT}"
    exit 1
  }

if [[ "$WEB_ACCESS_ENABLED" == "true" ]]; then
  /opt/venv/bin/websockify --web=/noVNC "${WEBSOCKIFY_PORT}" "localhost:${VNC_PORT}" &
fi

export DISPLAY=:1

# ====== 4) AUTO-LOGIN LẦN ĐẦU ======
auto_login_if_needed() {
  if [[ "$AUTO_LOGIN_ONCE" == "true" && -f "$LOGIN_MARK" ]]; then
    return 0
  fi
  echo "[INFO] Waiting Wipter window…"
  local tries=0
  while ! xdotool search --name "Wipter" >/dev/null 2>&1; do
    sleep 5
    ((tries++))
    ((tries>120)) && { echo "[WARN] Wipter window not found; skip auto-login."; return 0; }
  done
  local target; target="$(xdotool search --name 'Wipter' | tail -n1)"
  xdotool windowfocus "$target" || true
  sleep 1.5
  xdotool key Tab sleep 0.2 key Tab sleep 0.2 key Tab
  sleep 0.3
  xdotool type --delay 20 --clearmodifiers "$WIPTER_EMAIL"
  sleep 0.3
  xdotool key Tab
  sleep 0.2
  xdotool type --delay 20 --clearmodifiers "$WIPTER_PASSWORD"
  sleep 0.2
  xdotool key Return
  sleep 5
  [[ "$AUTO_LOGIN_ONCE" == "true" ]] && touch "$LOGIN_MARK"
  [[ "$CLOSE_GUI_AFTER_LOGIN" == "true" ]] && xdotool windowclose "$target" || true
}

# ====== 5) WATCHDOG + 24H RESTART ======
APP_BIN="/root/wipter/wipter-app"
BACKOFF=5
MAX_BACKOFF=60
REFRESH_SEC=${REFRESH_SEC:-86400}   # 24h mặc định; set 0 để tắt

graceful_stop=false
trap 'graceful_stop=true' SIGTERM SIGINT

run_once() {
  echo "[INFO] Starting Wipter…"
  cd /root/wipter/ || true
  "$APP_BIN" &
  local pid=$!
  echo "[INFO] pid=${pid}"
  sleep 3
  auto_login_if_needed
  local start_ts now
  start_ts=$(date +%s)
  while kill -0 "$pid" >/dev/null 2>&1; do
    $graceful_stop && break
    if (( REFRESH_SEC > 0 )); then
      now=$(date +%s)
      if (( now - start_ts >= REFRESH_SEC )); then
        echo "[INFO] 24h reached → soft-restart Wipter"
        kill -TERM "$pid" >/dev/null 2>&1 || true
        wait "$pid" || true
        return 99
      fi
    fi
    sleep 3
  done
  wait "$pid" || true
  $graceful_stop && return 0
  return 1
}

while :; do
  run_once
  rc=$?
  $graceful_stop && break
  if [[ $rc -eq 99 ]]; then
    echo "[INFO] Restarting after 24h refresh…"
    BACKOFF=5
    continue
  fi
  echo "[WARN] Wipter exited unexpectedly. Restarting in ${BACKOFF}s…"
  sleep "$BACKOFF"
  BACKOFF=$(( BACKOFF*2 )); (( BACKOFF > MAX_BACKOFF )) && BACKOFF=$MAX_BACKOFF
done

echo "[INFO] Exiting start.sh"
