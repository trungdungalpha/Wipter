#!/bin/bash

# Check if WIPTER_EMAIL and WIPTER_PASSWORD are set
if [ -z "$WIPTER_EMAIL" ]; then
    echo "Error: WIPTER_EMAIL environment variable is not set."
    exit 1
fi

if [ -z "$WIPTER_PASSWORD" ]; then
    echo "Error: WIPTER_PASSWORD environment variable is not set."
    exit 1
fi

# Start a D-Bus session (cần cho GNOME Keyring lưu login token)
eval "$(dbus-launch --sh-syntax)"

# Unlock the GNOME Keyring daemon (lưu session qua restart)
echo 'mypassword' | gnome-keyring-daemon --unlock --replace

# Enable job control
set -m

# Clean up lock files
rm -f /tmp/.X1-lock
rm -rf /tmp/.X11-unix

# Start Xvfb (thay TurboVNC - nhẹ hơn ~60MB RAM/container)
# 800x600x16: resolution nhỏ, 16-bit màu giảm CPU render
Xvfb :1 -screen 0 800x600x16 -nolisten tcp &
XVFB_PID=$!
echo "Started Xvfb (PID: $XVFB_PID)"

# Chờ Xvfb sẵn sàng
sleep 1

export DISPLAY=:1

# Khởi động openbox WM - cần thiết để wipter-app không exit khi đóng window
openbox &
sleep 1

echo "Starting Wipter....."
cd /root/wipter/
/root/wipter/wipter-app &

if ! [ -f ~/.wipter-configured ]; then
    WIPTER_LOG="$HOME/.config/wipter-app/logs/main.log"
    MAX_RETRIES=5
    LOGIN_SUCCESS=false

    for attempt in $(seq 1 $MAX_RETRIES); do
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Login attempt ${attempt}/${MAX_RETRIES}..."

        # Xóa log cũ để detect fresh errors
        rm -f "$WIPTER_LOG"

        # Wait for the wipter window to be available
        WAIT_COUNT=0
        while [[ "$(xdotool search --name Wipter 2>/dev/null | wc -l)" -lt 3 ]]; do
            sleep 10
            WAIT_COUNT=$((WAIT_COUNT + 1))
            if [ $WAIT_COUNT -gt 30 ]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S'): Timeout waiting for Wipter window"
                break
            fi
        done

        # Handle wipter login
        xdotool search --name Wipter 2>/dev/null | tail -n1 | xargs xdotool windowfocus 2>/dev/null
        sleep 5
        xdotool key Tab
        sleep 3
        xdotool key Tab
        sleep 3
        xdotool key Tab
        sleep 3
        xdotool type "$WIPTER_EMAIL"
        sleep 3
        xdotool key Tab
        sleep 3
        xdotool type "$WIPTER_PASSWORD"
        sleep 3
        xdotool key Return

        # Chờ wipter xử lý login
        sleep 30

        # Kiểm tra log xem login thành công chưa
        if [ -f "$WIPTER_LOG" ]; then
            if grep -q "Password attempts exceeded\|Error while trying to log in\|Error signing in" "$WIPTER_LOG"; then
                echo "$(date '+%Y-%m-%d %H:%M:%S'): ❌ Login FAILED (rate limited). Attempt ${attempt}/${MAX_RETRIES}"
                RETRY_DELAY=$((60 + RANDOM % 240))
                echo "$(date '+%Y-%m-%d %H:%M:%S'): Retrying in ${RETRY_DELAY}s..."
                xdotool search --name Wipter 2>/dev/null | tail -n1 | xargs xdotool windowclose 2>/dev/null || true
                sleep $RETRY_DELAY
                continue
            fi
        fi

        # Không có lỗi → login thành công
        echo "$(date '+%Y-%m-%d %H:%M:%S'): ✅ Login SUCCESS on attempt ${attempt}"
        LOGIN_SUCCESS=true
        # KHÔNG đóng window - để wipter-app tiếp tục chạy và generate traffic
        break
    done

    if [ "$LOGIN_SUCCESS" = true ]; then
        touch ~/.wipter-configured
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Wipter configured successfully."
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S'): ⚠️ WARNING: All ${MAX_RETRIES} login attempts failed!"
    fi
fi

################################################################################
# AUTO-RESTART WIPTER MỖI 24H - VERSION FIXED (ĐÓNG GUI CŨ)
################################################################################

restart_wipter() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): Restarting Wipter to clear memory..."

    # BƯỚC 1: Kill process wipter-app
    echo "Killing wipter-app process..."
    pkill -f "wipter-app"

    sleep 5

    # BƯỚC 2: Start wipter-app lại (session tự động load)
    echo "Starting wipter-app..."
    cd /root/wipter/
    /root/wipter/wipter-app &

    # Đợi server tái kết nối
    echo "Waiting for wipter-app to reconnect..."
    sleep 10
    echo "$(date '+%Y-%m-%d %H:%M:%S'): Wipter restarted successfully."
}

# Run auto-restart every 24 hours in background
(
    while true; do
        sleep 86400  # 24 hours
        restart_wipter
    done
) &

RESTART_PID=$!
echo "✅ Auto-restart monitor started (PID: $RESTART_PID, interval: 24h)"

# Keep container running by monitoring wipter process
while true; do
    if ! pgrep -f "wipter-app" > /dev/null; then
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Wipter process died, restarting..."
        cd /root/wipter/
        /root/wipter/wipter-app &
        sleep 10
    fi

    sleep 180
done
