#!/usr/bin/env python3

"""
Custom Consumption Calculator for Grid-Tied PV Systems without Multi/Quattro

This service calculates consumption for standalone grid-tied PV systems where
the Venus OS system calculator doesn't work properly due to lack of Multi/Quattro.

Calculation: Consumption = Grid Power (import) + PV Production

The grid meter measures net power from grid (after PV contribution).
To get total consumption, we add back the PV production.

Topology:
  [Grid] ← [Meter reads here] ← [PV Inverter] ← [Loads]
"""

from gi.repository import GLib
import platform
import logging
import sys
import os
import dbus

sys.path.insert(1, os.path.join(os.path.dirname(__file__), '/opt/victronenergy/dbus-systemcalc-py/ext/velib_python'))
from vedbus import VeDbusService, VeDbusItemImport
from dbus.mainloop.glib import DBusGMainLoop

class ConsumptionCalculator:
    def __init__(self, grid_service, pv_service, update_interval_ms=2000):
        self.grid_service = grid_service
        self.pv_service = pv_service

        # Create DBus service for publishing consumption
        self._dbusservice = VeDbusService('com.victronenergy.acload.consumption_calc', register=False)

        # Setup management paths
        self._dbusservice.add_path('/Mgmt/ProcessName', __file__)
        self._dbusservice.add_path('/Mgmt/ProcessVersion', 'v1.0 on Python ' + platform.python_version())
        self._dbusservice.add_path('/Mgmt/Connection', 'Calculated from Grid + PV')

        # Setup device identification
        self._dbusservice.add_path('/DeviceInstance', 100)
        self._dbusservice.add_path('/ProductId', 0)
        self._dbusservice.add_path('/ProductName', 'Consumption Calculator')
        self._dbusservice.add_path('/CustomName', 'AC Loads')
        self._dbusservice.add_path('/FirmwareVersion', 1.0)
        self._dbusservice.add_path('/HardwareVersion', 0)
        self._dbusservice.add_path('/Connected', 1)
        self._dbusservice.add_path('/Role', 'acload')
        self._dbusservice.add_path('/Serial', 'CALC001')

        # Consumption paths (AC loads)
        _w = lambda p, v: f"{round(v, 1)} W"
        self._dbusservice.add_path('/Ac/Power', 0, gettextcallback=_w)
        self._dbusservice.add_path('/Ac/L1/Power', 0, gettextcallback=_w)
        self._dbusservice.add_path('/Ac/L2/Power', 0, gettextcallback=_w)
        self._dbusservice.add_path('/Ac/L3/Power', 0, gettextcallback=_w)

        # Register the service
        self._dbusservice.register()

        # Setup DBus imports to read from other services
        dbusconn = dbus.SessionBus() if 'DBUS_SESSION_BUS_ADDRESS' in os.environ else dbus.SystemBus()

        self._grid_power = VeDbusItemImport(dbusconn, grid_service, '/Ac/Power')
        self._grid_l1_power = VeDbusItemImport(dbusconn, grid_service, '/Ac/L1/Power')
        self._pv_power = VeDbusItemImport(dbusconn, pv_service, '/Ac/Power')
        self._pv_l1_power = VeDbusItemImport(dbusconn, pv_service, '/Ac/L1/Power')

        # Start update timer
        GLib.timeout_add(update_interval_ms, self._update)

        logging.info(f"Consumption calculator initialized")
        logging.info(f"  Grid service: {grid_service}")
        logging.info(f"  PV service: {pv_service}")
        logging.info(f"  Update interval: {update_interval_ms}ms")

    def _update(self):
        try:
            # Read grid power (negative = import, positive = export)
            grid_power = self._grid_power.get_value()
            grid_l1_power = self._grid_l1_power.get_value()

            # Read PV power (always positive = production)
            pv_power = self._pv_power.get_value()
            pv_l1_power = self._pv_l1_power.get_value()

            # Default to 0 if values not available
            if grid_power is None:
                grid_power = 0
            if grid_l1_power is None:
                grid_l1_power = 0
            if pv_power is None:
                pv_power = 0
            if pv_l1_power is None:
                pv_l1_power = 0

            # Calculate consumption
            # Grid meter measures NET power from grid (after PV contribution)
            # Huawei meter sign convention (used by this grid meter service):
            #   NEGATIVE (-) = Import FROM grid (consuming, grid feeds home)
            #   POSITIVE (+) = Export TO grid (producing, home feeds grid)
            #
            # Consumption calculation:
            #   When IMPORTING (grid < 0): Consumption = |Grid Import| + PV Production
            #     Example: Grid=-2300W (importing), PV=+400W → Consumption=2300+400=2700W
            #
            #   When EXPORTING (grid > 0): Consumption = PV Production - Grid Export
            #     Example: Grid=+1715W (exporting), PV=+2417W → Consumption=2417-1715=702W
            #
            # Note: This is opposite of standard Venus OS convention, but matches Huawei meter behavior

            if grid_power < 0:  # Importing from grid (negative value)
                consumption_total = abs(grid_power) + pv_power
                consumption_l1 = abs(grid_l1_power) + pv_l1_power
            else:  # Exporting to grid (positive value)
                consumption_total = pv_power - grid_power
                consumption_l1 = pv_l1_power - grid_l1_power

            # Ensure consumption is never negative (safety check)
            consumption_total = max(0, consumption_total)
            consumption_l1 = max(0, consumption_l1)

            # Update DBus
            with self._dbusservice as s:
                s['/Ac/Power'] = consumption_total
                s['/Ac/L1/Power'] = consumption_l1
                s['/Ac/L2/Power'] = 0  # Not used in single-phase
                s['/Ac/L3/Power'] = 0  # Not used in single-phase

            logging.debug(f"Grid: {grid_power}W, PV: {pv_power}W, Consumption: {consumption_total}W")

        except Exception as e:
            logging.error(f"Error updating consumption: {e}")

        return True


def main():
    logging.basicConfig(
        format='%(asctime)s %(levelname)s %(message)s',
        datefmt='%Y-%m-%d %H:%M:%S',
        level=logging.INFO,
        handlers=[logging.StreamHandler()]
    )

    DBusGMainLoop(set_as_default=True)

    grid_service = 'com.victronenergy.grid.huawei_meter'
    pv_service = 'com.victronenergy.pvinverter.sun2000'

    logging.info("=" * 60)
    logging.info("Starting Consumption Calculator Service")
    logging.info("=" * 60)

    # Wait for required services to be available
    dbusconn = dbus.SessionBus() if 'DBUS_SESSION_BUS_ADDRESS' in os.environ else dbus.SystemBus()

    max_retries = 30
    for service_name in [grid_service, pv_service]:
        logging.info(f"Waiting for {service_name}...")
        retry_count = 0
        while retry_count < max_retries:
            try:
                dbusconn.get_object(service_name, '/')
                logging.info(f"  ✓ {service_name} found")
                break
            except dbus.exceptions.DBusException:
                retry_count += 1
                if retry_count >= max_retries:
                    logging.error(f"  ✗ {service_name} not found after {max_retries} retries")
                    sys.exit(1)
                import time
                time.sleep(2)

    try:
        calculator = ConsumptionCalculator(grid_service, pv_service)

        logging.info("Consumption calculator running")
        logging.info("Calculation: Consumption = Grid (import) + PV Production")
        logging.info("-" * 60)

        mainloop = GLib.MainLoop()
        mainloop.run()

    except Exception as e:
        logging.critical(f'Fatal error: {e}', exc_info=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
