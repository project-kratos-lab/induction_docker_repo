#!/bin/bash
# ── Kratos Dev Environment Entrypoint ───────────────────────────────
# Runs as root. Creates a user matching the host UID/GID with sudo access.
# Starts VNC → fluxbox → noVNC → rosbridge, then keeps the container alive.

BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${BLUE}[kratos]${NC} $1"; }
ok()   { echo -e "${GREEN}[kratos]${NC} $1"; }
fail() { echo -e "${RED}[kratos]${NC} $1" >&2; }

# ── Create user matching host UID/GID ───────────────────────────────
# HOST_UID and HOST_GID are passed in by the kratos launcher.
# This user owns /workspace files and has passwordless sudo.
HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"
UNAME="kratos"

log "Setting up user ${UNAME} (UID=${HOST_UID}, GID=${HOST_GID})..."

# Create group if it doesn't exist
if ! getent group "$HOST_GID" &>/dev/null; then
    groupadd -g "$HOST_GID" kratosgrp
fi
GNAME=$(getent group "$HOST_GID" | cut -d: -f1)

# Create user if it doesn't exist
if ! id "$UNAME" &>/dev/null; then
    useradd -m -u "$HOST_UID" -g "$HOST_GID" -s /bin/bash -d /workspace "$UNAME" 2>/dev/null || true
fi

# Give passwordless sudo
echo "${UNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/kratos
chmod 0440 /etc/sudoers.d/kratos
ok "User ${UNAME} created with passwordless sudo"

# ── Set up home directory ───────────────────────────────────────────
export HOME=/workspace
mkdir -p "$HOME/.vnc" "$HOME/.config/fluxbox" "$HOME/.ros" "$HOME/.gazebo" "$HOME/.rviz2"
chown -R "$HOST_UID:$HOST_GID" "$HOME/.vnc" "$HOME/.config" "$HOME/.ros" "$HOME/.gazebo" "$HOME/.rviz2" 2>/dev/null || true

# Xvnc needs /tmp/.X11-unix
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix

# ── Start Xvnc (virtual display) ───────────────────────────────────
log "Starting VNC server on display :1 ..."
Xvnc :1 \
    -geometry 1600x900 \
    -depth 24 \
    -rfbport 5901 \
    -SecurityTypes None \
    -AlwaysShared \
    -AcceptKeyEvents \
    -AcceptPointerEvents \
    -SendCutText \
    -AcceptCutText &
VNC_PID=$!
sleep 1

if ! kill -0 $VNC_PID 2>/dev/null; then
    fail "VNC server failed to start. Check logs above."
    exit 1
fi
ok "VNC server running (PID $VNC_PID)"

# ── Window manager ──────────────────────────────────────────────────
log "Starting fluxbox window manager..."
fluxbox &>/dev/null &
sleep 0.5

# ── noVNC web proxy ─────────────────────────────────────────────────
log "Starting noVNC proxy on port 6080..."
/opt/novnc/utils/novnc_proxy \
    --vnc localhost:5901 \
    --listen 6080 &>/dev/null &
sleep 0.5
ok "noVNC proxy ready"

# ── ROS2 ────────────────────────────────────────────────────────────
log "Sourcing ROS2 Humble..."
source /opt/ros/humble/setup.bash

# Source workspace overlay if it exists (user-built packages)
if [ -f /workspace/install/setup.bash ]; then
    log "Found workspace overlay, sourcing..."
    source /workspace/install/setup.bash
fi

# ── Rosbridge WebSocket server ──────────────────────────────────────
log "Launching rosbridge on ws://0.0.0.0:9090 ..."
ros2 launch rosbridge_server rosbridge_websocket_launch.xml \
    port:=9090 &>/dev/null &
sleep 1
ok "Rosbridge WebSocket server running"

# ── Ready ───────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║       Kratos Dev Environment Ready           ║${NC}"
echo -e "${GREEN}${BOLD}╠══════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}${BOLD}║${NC}  Desktop:   ${BOLD}http://localhost:6080/vnc.html${NC}   ${GREEN}${BOLD}║${NC}"
echo -e "${GREEN}${BOLD}║${NC}  Rosbridge: ${BOLD}ws://localhost:9090${NC}             ${GREEN}${BOLD}║${NC}"
echo -e "${GREEN}${BOLD}║${NC}  ROS2:      ${BOLD}humble${NC}                         ${GREEN}${BOLD}║${NC}"
echo -e "${GREEN}${BOLD}║${NC}  User:      ${BOLD}${UNAME}${NC} (sudo enabled)         ${GREEN}${BOLD}║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ── Keep container alive ────────────────────────────────────────────
log "Container running. Attach with: kratos shell"
wait $VNC_PID
