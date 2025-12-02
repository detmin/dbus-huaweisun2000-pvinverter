#!/bin/bash

echo "==================================================================="
echo "Huawei SUN2000 Services Diagnostic Tool"
echo "==================================================================="
echo ""

# Helper function to read DBus value
read_dbus_value() {
    dbus-send --print-reply --system --dest="$1" "$2" \
        com.victronenergy.BusItem.GetValue 2>/dev/null | \
        sed -n 's/.*variant.*\(int32\|double\) \([-0-9.]*\).*/\2/p; s/.*variant.*string "\(.*\)".*/\1/p'
}

# Check for duplicate processes (CRITICAL)
echo "1. Process Check (Duplicate Detection):"
echo "-------------------------------------------------------------------"
PV_PIDS=$(pgrep -f "dbus-huaweisun2000-pvinverter.py")
PV_COUNT=$(echo "$PV_PIDS" | wc -w)
GRID_PIDS=$(pgrep -f "dbus-grid-meter.py")
GRID_COUNT=$(echo "$GRID_PIDS" | wc -w)

if [ "$PV_COUNT" -eq 1 ]; then
    echo "✓ PV inverter: 1 instance running (PID: $PV_PIDS)"
elif [ "$PV_COUNT" -gt 1 ]; then
    echo "✗ WARNING: Multiple PV inverter instances detected!"
    echo "  PIDs: $PV_PIDS"
    echo "  This will cause Modbus connection conflicts!"
    echo "  Fix: pkill -f 'dbus-huaweisun2000-pvinverter.py' && sleep 2"
elif [ "$PV_COUNT" -eq 0 ]; then
    echo "✗ PV inverter: NOT running"
fi

if [ "$GRID_COUNT" -eq 1 ]; then
    echo "✓ Grid meter: 1 instance running (PID: $GRID_PIDS)"
elif [ "$GRID_COUNT" -gt 1 ]; then
    echo "✗ WARNING: Multiple grid meter instances detected!"
    echo "  PIDs: $GRID_PIDS"
elif [ "$GRID_COUNT" -eq 0 ]; then
    echo "⚠ Grid meter: NOT running (OK if no meter)"
fi
echo ""

# Check service symlinks
echo "2. Service Manager Status:"
echo "-------------------------------------------------------------------"
if [ -L "/service/dbus-huaweisun2000-pvinverter" ]; then
    echo "✓ PV inverter service symlink exists"
else
    echo "✗ PV inverter service symlink NOT found"
    echo "  Run: sh install.sh"
fi

if [ -L "/service/dbus-huaweisun2000-grid" ]; then
    echo "✓ Grid meter service symlink exists"
else
    echo "⚠ Grid meter service symlink NOT found"
fi
echo ""

# Check DBus registration
echo "3. DBus Service Registration:"
echo "-------------------------------------------------------------------"
if dbus-send --system --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>/dev/null | grep -q "com.victronenergy.pvinverter.sun2000"; then
    echo "✓ PV inverter registered on DBus"
    echo "  Service: com.victronenergy.pvinverter.sun2000"
else
    echo "✗ PV inverter NOT registered on DBus"
fi

if dbus-send --system --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>/dev/null | grep -q "com.victronenergy.grid.huawei_meter"; then
    echo "✓ Grid meter registered on DBus"
    echo "  Service: com.victronenergy.grid.huawei_meter"
else
    echo "⚠ Grid meter NOT registered (OK if no meter)"
fi
echo ""

# Check PV inverter data
echo "4. PV Inverter Data:"
echo "-------------------------------------------------------------------"
PV_POWER=$(read_dbus_value com.victronenergy.pvinverter.sun2000 /Ac/Power)
PV_STATUS=$(read_dbus_value com.victronenergy.pvinverter.sun2000 /Status)
if [ -n "$PV_POWER" ]; then
    echo "✓ PV inverter responding"
    echo "  AC Power: ${PV_POWER}W"
    echo "  Status: ${PV_STATUS:-Unknown}"
    echo "  Product: $(read_dbus_value com.victronenergy.pvinverter.sun2000 /ProductName)"
    echo "  Energy Forward: $(read_dbus_value com.victronenergy.pvinverter.sun2000 /Ac/Energy/Forward) kWh"
else
    echo "✗ PV inverter not responding or offline"
fi
echo ""

# Check meter data in PV service
echo "5. Meter Data (via PV Service):"
echo "-------------------------------------------------------------------"
METER_STATUS=$(read_dbus_value com.victronenergy.pvinverter.sun2000 /Meter/Status)
if [ -n "$METER_STATUS" ] && [ "$METER_STATUS" != "0" ]; then
    echo "✓ Meter detected! Status: $METER_STATUS"
    echo "  Meter Power: $(read_dbus_value com.victronenergy.pvinverter.sun2000 /Meter/Power) W"
    echo "  Import: $(read_dbus_value com.victronenergy.pvinverter.sun2000 /Meter/Energy/Import) kWh"
    echo "  Export: $(read_dbus_value com.victronenergy.pvinverter.sun2000 /Meter/Energy/Export) kWh"
else
    echo "⚠ No meter detected (Status: ${METER_STATUS:-0})"
fi
echo ""

# Check grid service data
echo "6. Grid Service Data:"
echo "-------------------------------------------------------------------"
GRID_POWER=$(read_dbus_value com.victronenergy.grid.huawei_meter /Ac/Power)
if [ -n "$GRID_POWER" ]; then
    echo "✓ Grid service responding"
    echo "  Grid Power: ${GRID_POWER}W"
    echo "  Import: $(read_dbus_value com.victronenergy.grid.huawei_meter /Ac/Energy/Forward) kWh"
    echo "  Export: $(read_dbus_value com.victronenergy.grid.huawei_meter /Ac/Energy/Reverse) kWh"
else
    echo "⚠ Grid service not responding"
fi
echo ""

# Check Modbus connectivity
echo "7. Network Connectivity:"
echo "-------------------------------------------------------------------"
MODBUS_HOST="192.168.0.30"
MODBUS_PORT="6607"
if ping -c 1 -W 2 $MODBUS_HOST > /dev/null 2>&1; then
    echo "✓ Inverter reachable: $MODBUS_HOST"
    if command -v nc > /dev/null 2>&1; then
        if nc -zv -w 2 $MODBUS_HOST $MODBUS_PORT 2>&1 | grep -q "open\|succeeded"; then
            echo "✓ Modbus port open: $MODBUS_PORT"
        else
            echo "✗ Modbus port not accessible: $MODBUS_PORT"
        fi
    fi
else
    echo "✗ Inverter NOT reachable: $MODBUS_HOST"
    echo "  Check network connection or inverter IP address"
fi
echo ""

# Check recent logs for errors
echo "8. Recent Logs (Last 15 lines):"
echo "-------------------------------------------------------------------"
echo "PV Inverter:"
if [ -f "/var/log/dbus-huaweisun2000/current" ]; then
    tail -15 /var/log/dbus-huaweisun2000/current | tai64nlocal 2>/dev/null | grep -E "ERROR|WARNING|Successfully connected|registered ourselves" || echo "  No recent errors or status messages"
else
    echo "  Log file not found"
fi

echo ""
echo "Grid Meter:"
if [ -f "/var/log/dbus-huaweisun2000-grid/current" ]; then
    tail -15 /var/log/dbus-huaweisun2000-grid/current | tai64nlocal 2>/dev/null | grep -E "ERROR|WARNING|registered ourselves|Grid meter connected" || echo "  No recent errors or status messages"
else
    echo "  Log file not found"
fi
echo ""

# Check GUI errors
echo "9. GUI DBus Errors (Last 20 lines):"
echo "-------------------------------------------------------------------"
if [ -f "/var/log/gui/current" ]; then
    GUI_ERRORS=$(tail -100 /var/log/gui/current | tai64nlocal 2>/dev/null | grep -i "noreply\|error" | grep -E "pvinverter.sun2000|grid.huawei_meter" | tail -20)
    if [ -n "$GUI_ERRORS" ]; then
        echo "⚠ Found DBus errors:"
        echo "$GUI_ERRORS"
    else
        echo "✓ No DBus NoReply errors found in recent GUI logs"
    fi
else
    echo "  GUI log file not found"
fi
echo ""

echo "==================================================================="
echo "Diagnostic Summary"
echo "==================================================================="

# Summary
ISSUES=0
if [ "$PV_COUNT" -ne 1 ]; then ISSUES=$((ISSUES+1)); fi
if [ "$GRID_COUNT" -gt 1 ]; then ISSUES=$((ISSUES+1)); fi
if [ -z "$PV_POWER" ]; then ISSUES=$((ISSUES+1)); fi

if [ $ISSUES -eq 0 ]; then
    echo "✓ All checks passed! Services operating normally."
else
    echo "⚠ Found $ISSUES issue(s) - review output above"
fi

echo ""
echo "Quick Actions:"
echo "  View live logs: tail -f /var/log/dbus-huaweisun2000/current | tai64nlocal"
echo "  Restart services: sh restart.sh"
echo "  Stop services: sh kill.sh"
echo "  System calculator check: sh diagnose_system.sh"
echo "==================================================================="
