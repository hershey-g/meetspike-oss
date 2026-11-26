# Meetspike for macOS

Meetspike listens for a WHOOP heart-rate broadcast over Bluetooth Low Energy. Your WHOOP strap stays connected to the WHOOP app on your iPhone. The Mac only listens to the strap's **HR Broadcast**, so there is nothing to pair. The menu bar shows a heart with your live heart rate, for example **♥ 72**. Open it for current BPM, a chart of the last 15 minutes, and live sync and replay status. When the Worker knows the current meeting, the chart can switch to its padded window. The last reading is marked stale after a disconnect or 45 seconds without a new reading. To reconnect, the app first asks macOS for the saved strap or an already connected WHOOP, and scans if that attempt does not connect.

## Build and install after merging

Use a Mac running macOS 14 or later with Xcode 15 or later or matching Command Line Tools. The Swift package uses the system SQLite library. From the repository root, run:

```sh
swift test --package-path shared/MeetspikeHRCore
./mac/MeetspikeHR/build-app.sh
```

The script creates and verifies a signed `.build/MeetspikeHR.app` for the Mac's current architecture. It uses ad hoc signing by default for local testing. Set `MEETSPIKE_SIGN_IDENTITY` to a local signing identity if you have one. Use the same identity for future builds so macOS can recognize updates when applying Bluetooth, Keychain, and login-item permissions.

Quit any previous copy of Meetspike, copy the bundle to `/Applications` or `~/Applications` using Finder, and open that installed copy. Open the bundle for Bluetooth permissions and login-item registration. If the build triggers an approval prompt, review the local build in System Settings and open it from Finder.

The core tests also run on Linux with Swift 5.9 or later and the system SQLite headers and library, such as `libsqlite3-dev`.

## Connect your WHOOP

The first time you open Meetspike, a setup guide opens. It comes back each time the app starts until the first heart rate reading arrives. To open it again later, choose **Settings… → Show Setup Guide…**, or **Setup Guide…** in the menu.

1. **Wear the strap.** It only sends heart rate while you're wearing it.
2. **Turn on HR Broadcast** in the WHOOP app on your phone: **Menu → Device Settings → HR Broadcast**. It can turn itself off after a WHOOP firmware update, so check it again after updates.
3. **Keep the WHOOP app on your phone connected.** Meetspike listens to the separate HR Broadcast.
4. **Close other apps that read WHOOP heart rate**, such as Peloton and Zwift. The strap sends heart rate to one listener at a time.
5. **Do not put the strap in pairing mode, and do not add it in the Mac's Bluetooth settings.** Pairing mode can pull the strap away from the WHOOP app on your phone, and HR Broadcast doesn't need pairing. If your WHOOP is listed in **System Settings → Bluetooth**, click ⓘ next to it and choose **Forget This Device**.
6. **Allow full Calendar access** from the Meetspike menu. Choose **Go live now** to test outside a meeting.
7. **Allow Bluetooth when macOS asks.** If you clicked Don't Allow, turn on Meetspike under **System Settings → Privacy & Security → Bluetooth**.

The guide shows live status for each part: Bluetooth permission, scanning, WHOOP found, first reading, and last upload. When the first reading arrives it says you're all set.

Meetspike remembers your strap after its first valid reading and then listens only for that strap. Keep only your own WHOOP broadcasting nearby the first time. If you replace the strap, choose **Forget WHOOP** in Settings.

### The menu bar icon

- **♥ 72** (filled heart and a number): live heart rate.
- **♡ –** (outline heart and a dash): no reading yet, or the last reading is more than 45 seconds old or from before a disconnect.
- **Heart with a slash**: Bluetooth is off or not allowed. Open the menu to see what to do.
- **Pause symbol**: you paused recording. Choose **Resume** in the menu.

### Troubleshooting

Open the menu bar heart to see the current status:

- **Bluetooth not allowed — open System Settings**: click **Open Bluetooth Privacy Settings** and turn on Meetspike.
- **Bluetooth is off — turn it on**: turn Bluetooth on in Control Center or System Settings.
- **Scanning for WHOOP…**: the app is listening. This normally takes a few seconds.
- **No WHOOP broadcast found — check HR Broadcast**: no WHOOP was heard after 20 seconds. Check that you're wearing the strap, that HR Broadcast is on in the WHOOP phone app (**Menu → Device Settings → HR Broadcast**), and that the strap is near the Mac. HR Broadcast can turn off after a WHOOP firmware update.
- **Found a WHOOP, but not your remembered strap**: if you replaced your strap, choose **Forget WHOOP** in Settings.
- **Connected — waiting for heart rate** or **Lost the WHOOP — trying again…**: make sure you're wearing the strap and quit other apps that read WHOOP heart rate, such as Peloton or Zwift.

While scanning, the menu and the setup guide count the heart rate broadcasters heard, for example "Heard 2 heart rate broadcasters, none from a WHOOP." They also list each one with its name (or "no name"), manufacturer data (company ID and the first bytes), and advertised services. A broadcaster counts as a WHOOP when its name contains "whoop" in any case. If it hears other devices but no WHOOP, HR Broadcast is usually off.

Some straps broadcast heart rate without a WHOOP name. If, after 20 seconds, exactly one heart rate broadcaster was heard and none was recognized as a WHOOP, the menu offers **Use this broadcaster**. Choose it only if you're wearing your WHOOP with HR Broadcast on and no other heart rate device is nearby. Meetspike remembers that broadcaster as your strap and connects to it. **Forget WHOOP** in Settings undoes this.

Each broadcaster heard is also written to the macOS log: `log show --last 1h --predicate 'subsystem == "com.meetspike.hr"'`. Names and company IDs are shown; the other details are redacted unless private logging is enabled.

Do not fix a missing broadcast by pairing. Don't put the strap in pairing mode, and don't add it in the Mac's Bluetooth settings. If it's already listed there, choose **Forget This Device**.

## Setup

1. Use a Meetspike Worker configured for the WHOOP wearable with `WHOOP_WEB_HR` enabled, the live buffer bound, and both `POST /api/whoop-web/live` and `POST /api/whoop-web/ingest` available. The app uses the Bluetooth standard Heart Rate Service and sends its readings to your Worker.
2. Connect your WHOOP as described above.
3. Open the heart icon in the menu bar and choose **Settings…**. Enter the Meetspike Worker HTTPS origin, such as `https://meetspike.example.com`, and the ingest secret for that Worker. If the route is protected by Cloudflare Access, fill in both fields for a service token already authorized for that route. Click **Save**. The app saves credentials in the macOS Keychain. Where the signing identity permits the data protection Keychain, items stay on the device and are available after the first unlock. Ad hoc builds that lack this entitlement use the login Keychain and its lock policy.
4. Leave the app running while taking meetings. To opt into automatic startup, choose **Enable** in Settings under **Open at login**. If macOS asks for approval, use **Open Login Items** and approve it there.

**Listen only around meetings** is on by default. Capture and upload run from five minutes before a meeting until ten minutes after it. All-day, declined, and cancelled events are excluded. Touching or overlapping listening windows form one block. Use **Go live now** from the menu to record outside meetings too, for example while you work, so you can line the readings up with Screenpipe by time later. It stays on, across relaunches, until you switch it off. While a reading is live the menu bar heart beats at your heart rate (it stays still with Reduce Motion on). Turn off **Listen only around meetings** in Settings for continuous capture. Meeting-only mode needs full Calendar access: if access is denied, the menu and Settings show **Calendar access needed** with a button to the Calendars privacy pane, and the app listens continuously until access is granted. The iPhone app can send reminders to switch the WHOOP broadcast on and off in the official WHOOP app.

**Pause** suspends capture and upload and persists across restarts. In meeting-only mode it can't eat a meeting: when the next meeting block starts the app resumes on its own and posts a "Meetspike resumed for <meeting>" notification. If you pause during a meeting, it stays paused for the rest of that block and resumes at the next one. Meetings less than about 15 minutes apart share a block, so a pause there holds until that whole run of meetings ends. While paused the menu shows when it will resume, and shows nothing when it won't on its own (continuous capture, no Calendar access, or no later meeting). An automatic resume also turns **Go live now** off, so recording stops when that meeting block ends. With continuous capture, Pause holds until you resume, even if you switch meeting-only on later in the same block. **Resume** returns to the active mode. **Quit** exits until you reopen the app or the next login if you enabled it.

## Retention and meeting coverage

- The app stores each reading at its observed timestamp in SQLite in `~/Library/Application Support/MeetspikeHR/`. A changed BPM at the same timestamp is queued as a new revision. An upgrade requeues readings still on disk whose earlier receipts predate raw storage, and imports the observations still present in the old minute format.
- During capture, live sync sends up to 60 points about every five seconds. It retries with a delay of up to one minute and keeps up to 15 minutes of unsent live points in memory. SQLite supplies replay through longer outages.
- Replay starts about five minutes after launch and runs every 30 minutes. It sends pending readings oldest first in batches of up to 4,000, regardless of age. A batch stays pending until the Worker returns HTTP 200 with `rawStored: true`. Failed uploads back off from five to sixty minutes. The app prunes readings 30 days after their raw storage receipt.
- Both transports store raw readings. Replay builds saved meeting rows from those readings, including the ten-minute pads. A late calendar import or schedule change can be filled by rebuilding that local calendar day. If capture begins at 9:45 for a 9:30 meeting, the meeting shows heart rate from 9:45.
- BLE supplies heart rate while the app can receive the broadcast. WHOOP history and Stress Monitor data come from separate sources. The app queues uploads for one Worker destination at a time.
- In meeting-only mode (the default) capture starts five minutes before a calendar meeting and runs ten minutes past the end. Outside those windows the app does not listen.

## Meeting reminder

When a Zoom meeting is open (Zoom's `CptHost` meeting process is running) or a Meetspike calendar meeting starts within 2 minutes, and no Bluetooth reading has arrived for 60 seconds, the app shows a notification with sound: **Turn on WHOOP Heart Rate Broadcast**. It reminds once per meeting, plus one follow-up if there is still no heart rate a minute after the start (and at least two minutes after the first reminder). The calendar check is `GET /api/whoop-web/reminder` with the same ingest secret, made at most once a minute and only while heart rate is silent. With **Also send to my phone (Pushover)** on, the app also calls `POST /api/whoop-web/reminder`; the Worker forwards it to Pushover only when the optional `PUSHOVER_TOKEN` and `PUSHOVER_USER` secrets are set. Both toggles are in Settings → Meeting reminder. Allow notifications for Meetspike the first time macOS asks. The check runs only while the app is listening, so with **Listen only around meetings** on it covers calendar meetings (from two minutes before the start, although capture starts five minutes before: in meeting-only mode the Mac holds reminders until then) and Zoom meetings during **Go live now**. Only one device reminds per meeting. The iPhone app tells the Worker which meetings it scheduled a reminder for, and the `owner` field of that GET is `phone` only for those. The Mac stays quiet about them and still reminds about every other meeting, including Zoom calls that are not on the calendar. The same GET answers `live`: whether the Worker saw heart rate from any device in the last minute (the iPhone, say). When it is `true` the Mac does not alert, even with no reading of its own, and it asks again every minute. When it is false, null or missing (an older Worker) the Mac behaves as before. Settings notes when the phone is checked in. When the phone's check-in lapses, the Mac takes over fully.

## Meeting choices and Zoom attendance (version 1.2, build 9)

**Menu buttons.** While a meeting is the current one (two minutes before it to ten minutes after), the menu shows **Still going** (15 minutes more, up to four hours past the calendar end), **Ended now** and **I didn't join**. **I didn't join** is always just that one meeting, even in a series. The listening window follows the new times at once. If the Worker can't be reached the choice is saved on the Mac and sent later; if the Worker refuses it, the menu says so and the old state stays. The buttons use the Worker's `/api/view` and `PUT /api/meetings/:id/override`, so they need the same Access token the Settings sync already uses. Without it the buttons stay out of the way and the Mac listens to the calendar, as before.

**Listening windows** use the effective times and skip meetings you left out, the same as the iPhone. The Mac keeps the Worker's last answer and any waiting choices on disk (`~/Library/Application Support/MeetspikeHR/Overrides`), so a relaunch offline still follows them. If they can't load, the calendar is used.

**Zoom attendance.** Every 15 seconds, whether or not the Mac is recording, the Mac checks if a Zoom call is open (the `CptHost` process) and, for calendar meetings with a Zoom link, tells the Worker when it saw you in one: `POST /api/whoop-web/app/attendance` with the ingest secret. It reports once per meeting, after it ends. Rules live in the shared `AttendanceTracker`. The Mac counts as watching only while it is awake: asleep, display off, locked or switched to another user is not watching. It reports "didn't see Zoom" only if it watched at least 90 percent of the meeting. Quitting or relaunching forgets everything, so a relaunch never produces "didn't see Zoom", and a call that was already running when the Mac started looking gets no report at all (its start would be wrong). Reports that can't be sent wait in `~/Library/Application Support/MeetspikeHR/Attendance/queue.json`: network and server errors retry up to five times, a 503 waits for later, any other 4xx is dropped, and anything older than three days is dropped. No new permission prompts. The Mac only sees Zoom's desktop app, so a call in a browser looks like "didn't join" (it is only a suggestion on the iPhone and the web, never an automatic exclusion).

## Native verification

Run `swift test --package-path shared/MeetspikeHRCore -j 2` and `swift build --package-path mac/MeetspikeHR --configuration release -j 2` from the repository root. Rebuild the signed bundle and check it from its installed location. Open Settings from the menu bar and verify Bluetooth permission, live BPM and age, the empty and stale states with VoiceOver, reconnect, pause, and wake. Check the menu bar icon in its live, waiting, Bluetooth-blocked, and paused states, the setup guide on first launch (reset with `defaults delete com.meetspike.hr setupComplete` and Forget WHOOP), each status message, and the **Open Bluetooth Privacy Settings** button. Verify login registration and removal if testing startup.

The transport tests use fixtures and dummy credentials without a real connection. For an end-to-end local check, use `http://localhost:<port>` with dummy credentials. The app's ATS exception applies only to `localhost`. Remote destinations require HTTPS. Check both transports with the configured Access token, an HTTP failure and retry, redirect refusal, and a 200 during ongoing readings. Check that the Mac and phone-width web charts update during a test meeting and show both pads, that pause and a disconnect leave gaps, and that sync recovers after resuming. Confirm that a later replay sends all pending samples and that a rebuild includes the stored readings across the meeting's padded window.
