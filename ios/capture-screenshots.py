#!/usr/bin/env python3
"""Capture Debug-only fixtures through simctl, without opening Simulator.app.

Run after building the Debug simulator app. Pass a simulator UDID and a short
device name. Only that simulator is used; no personal app settings are read.
"""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import time


ROOT = Path(__file__).resolve().parents[1]
BUNDLE = "com.hersheyg.meetspike.hr"
# `-demoSettingsState` values handled in SettingsView.applyDemoState().
SETTINGS_STATES = ["connected", "wrongSecret", "accessBlocked", "unreachable", "editing", "invalid", "removeAccess",
                   "scanUnavailable", "pairConfirm", "paired", "pairedAccessBlocked", "pairFailed"]


def sim(*args, check=True):
    return subprocess.run(["xcrun", "simctl", *args], check=check, capture_output=True, text=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("device", help="A booted simulator UDID")
    parser.add_argument("name", help="Filename prefix, e.g. se or pro-max")
    parser.add_argument("--smoke", action="store_true", help="Capture just the live dashboard")
    parser.add_argument("--only", nargs="+", help="Capture only these state names, e.g. chart-sync large-type-live")
    parser.add_argument("--skip-install", action="store_true", help="Use an already installed matching Debug build")
    options = parser.parse_args()
    output = ROOT / "docs/screenshots/ios"
    output.mkdir(parents=True, exist_ok=True)
    app = ROOT / ".build/DerivedData/Build/Products/Debug-iphonesimulator/MeetspikeHR.app"
    sim("terminate", options.device, BUNDLE, check=False)
    if not options.skip_install:
        sim("install", options.device, str(app))
    sim("status_bar", options.device, "override", "--time", "9:41", "--dataNetwork", "wifi",
        "--wifiMode", "active", "--wifiBars", "3", "--batteryState", "charged", "--batteryLevel", "100")

    current_appearance = None
    current_size = None
    first_capture = True

    def capture(name, scenario="live", *, step=0, bottom=False, chart=False, settings=False, settings_section="", settings_state="", size="large", appearance="dark"):
        nonlocal current_appearance, current_size, first_capture
        if options.only and name not in options.only:
            return
        sim("terminate", options.device, BUNDLE, check=False)
        if current_appearance != appearance:
            sim("ui", options.device, "appearance", appearance)
            current_appearance = appearance
        if current_size != size:
            sim("ui", options.device, "content_size", size)
            current_size = size
        result = sim("launch", options.device, BUNDLE,
                     "-demo", scenario, "-onboardingStep", str(step),
                     "-demoBottom", "YES" if bottom else "NO",
                     "-demoChart", "YES" if chart else "NO",
                     "-demoSettings", "YES" if settings else "NO",
                     "-demoSettingsSection", settings_section,
                     "-demoSettingsState", settings_state)
        # Covers initial layout, chart drawing, scroll positioning and sheet presentation.
        time.sleep(12 if first_capture else 4)
        first_capture = False
        path = output / f"{options.name}-{appearance}-{name}.png"
        for attempt in range(5):
            sim("io", options.device, "screenshot", str(path))
            if not shutil.which("tesseract"):
                break
            recognized = subprocess.run(
                ["tesseract", str(path), "stdout"], capture_output=True, text=True, check=True,
                env={**os.environ, "OMP_THREAD_LIMIT": "1"}
            ).stdout.lower()
            if any(word in recognized for word in ["meetspike", "eetspike", "heart", "live", "calendar",
                                                   "sync", "whoop", "continue", "connect", "broadcast", "settings", "ready"]):
                break
            if attempt == 4:
                raise RuntimeError(f"App did not finish rendering: {path.name}")
            time.sleep(3)
        print(path.relative_to(ROOT), result.stdout.strip(), flush=True)

    if options.smoke:
        capture("live")
        return

    for appearance in ["dark"]:  # the app is dark only
        for scenario in ["live", "countdown", "disconnected", "searching", "calendarDenied",
                         "calendarRequest", "bluetoothDenied", "setup", "empty", "cooldown", "connectedWaiting",
                         "liveElevated", "liveHigh", "liveMeeting", "noResting"]:
            capture(scenario, scenario, appearance=appearance)
        for name, scenario in [("chart-sync", "live"), ("sync-error", "disconnected"), ("storage-error", "storageError")]:
            capture(name, scenario, bottom=True, appearance=appearance)
        for name, scenario in [("chart-meeting", "liveMeeting"), ("chart-no-meeting", "noResting")]:
            capture(name, scenario, chart=True, appearance=appearance)
        for step, name in enumerate(["welcome", "broadcast", "calendar", "bluetooth", "notifications", "summary"]):
            capture(f"onboarding-{name}", "onboarding", step=step, appearance=appearance)
        capture("settings", settings=True, appearance=appearance)
        capture("settings-bottom", settings=True, settings_section="broadcaster", appearance=appearance)
        # Sync setup: pairing by QR code, Test connection results, Save and Remove Access states.
        for state in SETTINGS_STATES:
            # States about the Save button scroll to it; the rest show the Connect section on top.
            section = "save" if state in ("editing", "invalid") else ""
            capture(f"settings-{state}", settings=True, settings_state=state, appearance=appearance)
            capture(f"large-type-settings-{state}", settings=True, settings_state=state, settings_section=section,
                    size="accessibility-extra-extra-extra-large", appearance=appearance)
        for name, scenario, bottom in [("large-type-live", "live", False),
                                       ("large-type-bluetooth", "bluetoothDenied", False),
                                       ("large-type-chart-sync", "live", True)]:
            capture(name, scenario, bottom=bottom, size="accessibility-extra-extra-extra-large", appearance=appearance)
        capture("large-type-onboarding", "onboarding", size="accessibility-extra-extra-extra-large", appearance=appearance)
        capture("large-type-settings", settings=True, size="accessibility-extra-extra-extra-large", appearance=appearance)
        capture("large-type-chart", chart=True, size="accessibility-extra-extra-extra-large", appearance=appearance)
        capture("large-type-liveHigh", "liveHigh", size="accessibility-extra-extra-extra-large", appearance=appearance)
        capture("large-type-chart-meeting", "liveMeeting", chart=True,
                size="accessibility-extra-extra-extra-large", appearance=appearance)
    sim("ui", options.device, "content_size", "large")
    sim("terminate", options.device, BUNDLE, check=False)
    sim("status_bar", options.device, "clear")


if __name__ == "__main__":
    main()
