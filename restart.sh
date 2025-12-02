#!/bin/bash
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

echo "==================================================================="
echo "Restarting Huawei SUN2000 Services"
echo "==================================================================="

# Kill processes if they exist
echo "Stopping services..."
pkill -f "dbus-huaweisun2000-pvinverter.py" 2>/dev/null && echo "✓ Killed PV inverter process"
pkill -f "dbus-grid-meter.py" 2>/dev/null && echo "✓ Killed grid meter process"
sleep 2

# Check if managed by service manager
if [ -d "/service/dbus-huaweisun2000-pvinverter" ]; then
    echo "Services managed by daemontools - restarting via svc..."
    svc -t /service/dbus-huaweisun2000-pvinverter 2>/dev/null
    svc -t /service/dbus-huaweisun2000-grid 2>/dev/null
    sleep 2
    echo "✓ Services restarted by service manager"
else
    echo "⚠ Services not managed - they should auto-restart via daemontools"
fi

# Verify services are running
sleep 3
echo ""
echo "Checking service status..."
if pgrep -f "dbus-huaweisun2000-pvinverter.py" > /dev/null; then
    echo "✓ PV inverter service is running (PID: $(pgrep -f 'dbus-huaweisun2000-pvinverter.py' | head -1))"
else
    echo "✗ PV inverter service NOT running"
fi

if pgrep -f "dbus-grid-meter.py" > /dev/null; then
    echo "✓ Grid meter service is running (PID: $(pgrep -f 'dbus-grid-meter.py' | head -1))"
else
    echo "⚠ Grid meter service NOT running (OK if no meter connected)"
fi

echo ""
echo "==================================================================="
echo "Restart complete!"
echo "==================================================================="
echo "Check logs: tail -f /var/log/dbus-huaweisun2000/current | tai64nlocal"
echo "==================================================================="
