#!/usr/bin/env bash
set -uo pipefail

if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    exec dbus-run-session -- bash "$0" "$@"
fi

export DISPLAY=:99
Xvfb :99 -screen 0 1280x1024x24 -ac 2>/dev/null &
sleep 2

export NO_AT_BRIDGE=0
export AT_SPI_CLIENT=true
export ACCESSIBILITY_ENABLED=1
export GTK_MODULES=gail:atk-bridge
export QT_ACCESSIBILITY=1
gsettings set org.gnome.desktop.interface toolkit-accessibility true 2>/dev/null || true

/usr/libexec/at-spi-bus-launcher --launch-immediately 2>/dev/null &
sleep 1
/usr/libexec/at-spi2-registryd 2>/dev/null &
sleep 1

xfce4-panel --disable-wm-check 2>/dev/null &
PANEL_PID=$!
sleep 6

python3 /trayapp.py &
TRAY_PID=$!
sleep 6

names() {
    gdbus call --session -d org.freedesktop.DBus -o /org/freedesktop/DBus \
        -m org.freedesktop.DBus.ListNames 2>/dev/null | tr ',' '\n' | tr -d "()[]' " | sort -u
}

echo "### Session-bus names matching status/tray/kde/indicator:"
names | grep -iE "status|tray|kde|indicator|panel" || echo "  (none)"

echo
echo "### StatusNotifierWatcher.RegisteredStatusNotifierItems:"
gdbus call --session -d org.kde.StatusNotifierWatcher -o /StatusNotifierWatcher \
    -m org.freedesktop.DBus.Properties.Get org.kde.StatusNotifierWatcher \
    RegisteredStatusNotifierItems 2>&1 || true

echo "### StatusNotifierWatcher.IsStatusNotifierHostRegistered:"
gdbus call --session -d org.kde.StatusNotifierWatcher -o /StatusNotifierWatcher \
    -m org.freedesktop.DBus.Properties.Get org.kde.StatusNotifierWatcher \
    IsStatusNotifierHostRegistered 2>&1 || true

echo
echo "==================== AT-SPI2 DESKTOP DUMP ===================="
python3 /dump.py 14

echo
echo "==================== PRESS the SNI tray item (1155,13) ===================="
python3 /dump.py --press-at 1155 13
sleep 3
echo "---- desktop tree after pressing the SNI item ----"
python3 /dump.py 14
echo
echo "==================== session bus names after press ===================="
gdbus call --session -d org.freedesktop.DBus -o /org/freedesktop/DBus -m org.freedesktop.DBus.ListNames 2>/dev/null | tr ',' '\n' | tr -d "()[]' " | sort -u | head -40

kill $TRAY_PID $PANEL_PID 2>/dev/null || true
