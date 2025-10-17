#!/bin/bash
set -euo pipefail

# ====== 0) YÊU CẦU BIẾN MÔI TRƯỜNG ======
: "${WIPTER_EMAIL:?Error: WIPTER_EMAIL environment variable is not set.}"
: "${WIPTER_PASSWORD:?Error: WIPTER_PASSWORD environment variable is not set.}"

# Tuỳ chọn:
WEB_ACCESS_ENABLED="${WEB_ACCESS_ENABLED:-false}"   # true => mở noVNC/websockify
VNC_PASSWORD="${VNC_PASSWORD:-}"                    # nếu rỗng -> random (chỉ dùng nội bộ)
KEYRING_PASS="${KEYRING_PASS:-}"                    # nếu cần unlock gnome-keyring
AUTO_LOGIN_ONCE="${AUTO_LOGIN_ONCE:-true}"          # chỉ auto-login lần đầu
CLOSE_GUI_AFTER_LOGIN="${CLOSE_GUI_AFTER_LOGIN:-true}"  # đóng cửa sổ sau login
LOGIN_MARK="${LOGIN_MARK:-$HOME/.wipter-configured}"    # dấu mốc đã cấu hình

# ====== 1) D-BUS + KEYRING ======
eval "$(dbus-launch --sh-syntax)" || true
if [[ -n "$KEYRING_PASS" ]]; then
  echo "$KEYRING_PASS" | gnome-keyring-daemon --unlock --replace || true
else
  # tránh hard-code 'mypassword'
  gnome-keyring-daemon --replace >/dev/null 2>&1 || true
fi

# ====== 2) DỌN LOCK X ======
rm -f /tmp/.X1-lock || true
rm -rf /tmp/.X11-unix || true

# ====== 3) VNC / noVNC (nội bộ, không map port ra ngoài) ======
mkdir -p "$HOME/.vnc"
if [[ -z "$VNC_PASSWORD" ]]; then
  # random cho nội bộ; không log ra để an toàn
  VNC_PASSWORD="$(tr -dc '[:alnum:]' < /dev/urandom | fold -w 10 | head -n1)"
fi
echo -n "$VNC_PASSWORD" | /opt/TurboVNC/bin/vncpasswd -f > "$HOME/.vnc/passwd"
chmod 400 "$HOME/.vnc/passwd"

VNC_PORT=${VNC_PORT:-5900}
WEBSOCKIFY_PORT=${WEBSOCKIFY_PORT:-6080}

# display cố định :1 như bản gốc
/opt/TurboVNC/bin/vncserver -rfbauth "$HOME/.vnc/passwd" -geometry 1200x800 \
  -rfbport "${VNC_PORT}" -wm openbox :1 || {
    echo "Error: Failed to start TurboVNC server on port ${VNC_PORT}"
    exit 1
  }

if [[ "$WEB_ACCESS_ENABLED" == "true" ]]; then
  /opt/venv/bin/websockify --web=/noVNC "${WEBSOCKIFY_PORT}" "localhost:${VNC_PORT}" &
fi

export DISPLAY=:1

# ====== 4) HÀM AUTO-LOGIN (lần đầu) ======
auto_login_if_needed() {
  if [[ "$AUTO_LOGIN_ONCE" == "true" && -f "$LOGIN_MARK" ]]; then
    return 0
  fi

  echo "[INFO] Waiting Wipter window…"
  local tries=0
  while ! xdotool search --name "Wipter" >/dev/null 2>&1; do
    sleep 5
    tries=$((tries+1))
    if (( tries > 120 )); then
      echo "[WARN] Wipter window not found after ~10min; skip auto-login."
      return 0
    fi
  done

  local target
  target="$(xdotool search --name 'Wipter' | tail -n1)"
  xdotool windowfocus "$target" || true
  sleep 1.5

  # giống bản gốc: 3 lần Tab -> email -> Tab -> pass -> Enter
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

  if [[ "$CLOSE_GUI_AFTER_LOGIN" == "true" ]]; then
    xdotool windowclose "$target" || true
  fi
}

# ====== 5) WATCHDOG: TỰ CHẠY LẠI KHI WIPTER THOÁT ======
APP_BIN="/root/wipter/wipter-app"
BACKOFF=5
MAX_BACKOFF=60
REFRESH_SEC=$((24*3600))   # nếu muốn refresh 24h; set 0 để tắt

graceful_stop=false
trap 'graceful_stop=true' SIGTERM SIGINT

run_once() {
  echo "[INFO] Starting Wipter…"
  cd /root/wipter/ || true
  "$APP_BIN" &
  local pid=$!
  echo "[INFO] pid=${pid}"

  # chờ UI sẵn sàng rồi auto-login
  sleep 3
  auto_login_if_needed

  local start_ts
  start_ts=$(date +%s)

  # đợi tiến trình; nếu quá 24h thì restart mềm
  while kill -0 "$pid" >/dev/null 2>&1; do
    $graceful_stop && break
    if (( REFRESH_SEC > 0 )); then
      local now
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
  BACKOFF=$(( BACKOFF*2 ))
  (( BACKOFF > MAX_BACKOFF )) && BACKOFF=$MAX_BACKOFF
done

echo "[INFO] Exiting start.sh"
