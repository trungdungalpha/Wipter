#!/bin/bash

# Start a D-Bus session
eval "$(dbus-launch --sh-syntax)"


# Unlock the GNOME Keyring daemon (non-interactively)
# Replace 'mypassword' with a secure password or use an environment variable
echo 'mypassword' | gnome-keyring-daemon --unlock --replace


# Enable job control
set -m

# These files could be left-over if the container is not shut down cleanly. We just remove it since we should
# only be here during container startup.
rm -f /tmp/.X1-lock
rm -r /tmp/.X11-unix

# Set up the VNC password
if [ -z "$VNC_PASSWORD" ]; then
    echo "VNC_PASSWORD environment variable is not set. Using a random password. You"
    echo "will not be able to access the VNC server."
    VNC_PASSWORD="$(tr -dc '[:alpha:]' < /dev/urandom | fold -w "${1:-8}" | head -n1)"
fi
mkdir ~/.vnc
echo -n "$VNC_PASSWORD" | /opt/TurboVNC/bin/vncpasswd -f > ~/.vnc/passwd
chmod 400 ~/.vnc/passwd
unset VNC_PASSWORD

# TurboVNC by default will fork itself, so no need to do anything here

if [ "$WEB_ACCESS_ENABLED" == "true" ]; then
    /opt/TurboVNC/bin/vncserver -rfbauth ~/.vnc/passwd -geometry 1200x800 -rfbport 5900 -wm openbox :1 && /opt/venv/bin/websockify --web=/noVNC 6080 localhost:5900 &
else
    /opt/TurboVNC/bin/vncserver -rfbauth ~/.vnc/passwd -geometry 1200x800 -rfbport 5900 -wm openbox :1 &
fi

#sleep 5
export DISPLAY=:1

echo "Starting Wipter....."
# Start openbox as a minimal window manager
cd /root/wipter/
/root/wipter/wipter-app &

if ! [ -f ~/.wipter-configured ]; then
    # Wait for the wipter window to be available
    while [[ "$(xdotool search --name Wipter| wc -l)" -lt 3 ]]; do
        sleep 10
    done

    # Handle wipter login
    xdotool search --name Wipter | tail -n1 | xargs xdotool windowfocus
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

    touch ~/.wipter-configured
fi


fg %/root/wipter/wipter-app

