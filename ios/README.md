# Meetspike HR for iPhone

The iPhone app (shown as **Meetspike**) is the full Meetspike dashboard on your phone: Today, Dates, People, Ask, and a Live tab. During meetings it listens to your WHOOP over Bluetooth and shows live BPM, the last 15 minutes, meeting timing, and sync status. It requires iOS 17 or later. Use a physical iPhone to test WHOOP and lock-screen behavior. For the install-to-first-heart-rate walkthrough, see [docs/IPHONE-ONBOARDING.md](../docs/IPHONE-ONBOARDING.md).

## Build and run

On a Mac with Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen), run this from the repository root.

```sh
brew install xcodegen
cd ios/MeetspikeHR
xcodegen generate
open MeetspikeHR.xcodeproj
```

The project uses the local Swift package in `shared/MeetspikeHRCore`. Select the **MeetspikeHR** target in Xcode, open **Signing & Capabilities**, and choose your team. `project.yml` sets `DEVELOPMENT_TEAM` for the app and the widgets, so change it there to your team and regenerate. The bundle identifiers are `com.hersheyg.meetspike.hr` (app) and `com.hersheyg.meetspike.hr.widgets` (widgets). Use the same identifiers in Xcode and App Store Connect.

1. Run on your iPhone. The setup guide explains WHOOP HR Broadcast, then Calendar, Bluetooth and notification permissions before each system prompt. Calendar and reminders are optional. Without Calendar, use **Go live now**. Have the same meeting calendar available in Apple Calendar and connected to your Meetspike Worker.
2. Connect sync. On your computer open `/setup` on your Worker, press **Show setup code** in step 8, then in Meetspike HR open **Menu → Phone settings → Scan setup code** (or point the iPhone Camera at the code). The code holds no secret: the phone trades it once at `/hooks/pair` for the ingest secret, plus the Access service token if the Worker has `PHONE_ACCESS_CLIENT_ID` and `PHONE_ACCESS_CLIENT_SECRET` set. Otherwise enter the Access client ID and secret by hand. **Test connection** then reports Connected, Wrong ingest secret (401), Blocked by Cloudflare Access, or Can't reach server. You can still type the origin and secrets in **Settings**. The phone saves credentials in its Keychain and can use them while locked after the first unlock.
3. Turn on **HR Broadcast** in WHOOP under **Menu → Device Settings**. Return to Meetspike HR and wait for live BPM before locking the phone. Test outside a meeting with **Go live now** and turn it off when done. If the Mac or another app is using the broadcast and the iPhone cannot connect, pause that reader and retry.
4. Check BPM, the chart, and last live sync. Lock the phone during a short test meeting and check that new readings arrive in the web chart. Turn off the broadcast and verify the phone reconnects when you reopen Meetspike with broadcasting back on. Test two close meetings, a declined event, an all-day event, and a calendar edit.

## TestFlight

**Release:** bump `CURRENT_PROJECT_VERSION` in `project.yml`, then run `python3 ios/release-testflight.py` on the Mac. It archives, uploads, waits for App Store Connect to finish processing, then posts the build number to the Worker (`POST /api/whoop-web/app/ios`). Installed apps check that number when opened (at most every 30 minutes) and show **Update available** with an **Update** button that opens Meetspike in TestFlight. Secrets come from 1Password at run time.

First-time setup:

1. Register the app’s bundle identifier with Hershey’s Apple Developer team and create the iOS app record in App Store Connect. Generate the project and select that team in Xcode.
2. Use a version of Xcode accepted by App Store Connect. Select **Any iOS Device (arm64)** for the **MeetspikeHR** scheme and choose **Product → Archive**.
3. In Organizer, choose **Distribute App → App Store Connect → Upload**. Increase `CURRENT_PROJECT_VERSION` in `project.yml` and regenerate for each subsequent upload. [Apple upload requirements](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
4. In App Store Connect, finish the build’s export compliance and beta information. The app sends heart-rate readings to the configured Meetspike Worker for app functionality. It reads calendar data on the phone for scheduling. Add Hershey to an internal TestFlight group, assign the processed build, and install it from TestFlight. External testers require Apple’s beta review.

## Crash reports, dSYMs and release notes

- **Where reports go.** If the app crashes, hangs or hits a CPU or disk problem, iOS hands the app a report on the next launch and the app sends it to your own Meetspike Worker (`POST /api/whoop-web/app/diagnostics`). It is stored in R2 for 90 days. Meeting names and heart rates are stripped first. The menu has a **Send crash reports** switch and a **Send a test report** row.
- **How to read them.** `python3 ios/crash-reports.py` lists the newest 20 (`--limit` for more). `python3 ios/crash-reports.py --show <id>` prints one with the frames of the app symbolicated, plus the breadcrumbs from just before. It reads the secrets from 1Password when it runs, like the release script, and prints none.
- **Where the dSYMs live.** `release-testflight.py` copies each archive's dSYMs to `~/Library/Application Support/Meetspike/dSYMs/<build>/`. `crash-reports.py` finds the right one by UUID. A report from a build released before build 8 has no kept dSYM and shows raw offsets. Keep that folder: without the dSYM a crash cannot be read.
- **Dark only.** From build 8 the app is always dark (`UIUserInterfaceStyle` is Dark in `Info.plist`). There is no light theme to test.
- **Release notes.** `shared/MeetspikeHRCore/Sources/MeetspikeHRCore/Mobile/Diagnostics/ReleaseNotes.swift` is the one source. The app's **What's new** sheet reads it, and `release-testflight.py` copies the newest build's items into TestFlight's **What to Test** once the build is valid. Add the block for the new build before you release. If the notes or the upload to App Store Connect fail, the script warns and the release goes on.

## Simulator review

Generate with XcodeGen, then build without signing:

```sh
xcodebuild -project ios/MeetspikeHR/MeetspikeHR.xcodeproj -scheme MeetspikeHR \
  -sdk iphonesimulator -configuration Debug -derivedDataPath .build/DerivedData \
  -jobs 2 CODE_SIGNING_ALLOWED=NO build
```

Debug builds accept `-demo <scenario>` at launch. Fixtures cover live heart rate, upcoming meetings, cooldown, reconnecting and sync failure, searching, denied/requested Calendar access, denied Bluetooth, sync setup, an empty schedule, connected-without-readings, local storage failure and all six onboarding steps. Fixtures never start Bluetooth, request permissions, read credentials, upload, or save sync settings. With `-demoSettings YES`, `-demoSettingsState <state>` shows the sync setup states: `connected`, `wrongSecret`, `accessBlocked`, `unreachable`, `editing`, `invalid`, `removeAccess`, `scanUnavailable`, `pairConfirm`, `paired`, `pairedAccessBlocked` and `pairFailed`. Release builds ignore these launch arguments.

`python3 ios/capture-screenshots.py <booted-simulator-UDID> se` installs the Debug build and captures normal and maximum accessibility text sizes (dark only, like the app), without opening Simulator.app. Run once per simulator size. See [the screenshot index](../docs/screenshots/ios/README.md) for the captured states. Only the simulator given by UDID is used.

## Meeting choices (build 9)

- **What you can say.** On Today, long press a meeting (or open it and tap **...**): **I didn't join**, **Don't link this meeting**, **Meeting times** (start and end pickers, plus **Use calendar times**) and **Undo**. A meeting in a series first asks **Just this one** or **All of them**. A left out meeting stays in the day's list, dimmed, as **Didn't join** or **Not linked**, and a tap puts it back. It has no chart and no score, and it is never in an average. When the Mac never saw Zoom for a meeting, a quiet note asks **Looks like you didn't join. Unlink it?** (Yes leaves it out, No keeps it and stops asking). The calendar itself is never edited.
- **How a choice reaches the Worker.** Every menu item becomes one `PUT /api/meetings/:id/override` (`OverrideEdit` in the core package is exactly the body). It goes through a file outbox first (`Application Support/MeetspikeHR/Overrides/Outbox`), one waiting edit per meeting and scope, newest wins. Offline: it stays queued, the row says "Sends when you are online" and sends later (app active, any good load). 400 and 404 are dropped and said. 503 (the Worker has not had its database update yet) and a rejected sign-in keep what is waiting, and a choice made right then says "Not available yet." and leaves the old state. A save clears the saved answers for that day and loads Today, Dates and People again.
- **Listening follows the choices.** The phone remembers the Worker's meetings with their overrides (`remote-meetings.json` next to the outbox), lays the waiting edits over them, and matches them to Calendar meetings by original start (90 s) and title. Two matches means nothing is applied. Left out meetings are not listened to; moved or extended ones use the effective times (start up to 2 h early, end up to 4 h late, 12 h at most, the same rules as the Worker). If none of this can be loaded, it listens to the calendar. Broadcast reminders keep the calendar's own starts.
- **Still going and Ended now.** On the Live tab, on Today's live card and on the Lock Screen Live Activity and Dynamic Island. **Still going** adds 15 minutes (up to 4 h past the calendar end), **Ended now** ends it now. The Live Activity buttons are `LiveActivityIntent`s (`Glance/LiveAdjustIntents.swift`): iOS runs them in the app's process, the widget extension only draws them. Offline taps queue like any other choice.

## Locked phone and broadcast reminders

- The listening window runs from five minutes before the meeting through ten minutes after it. Five, not two, so the Worker can see a broadcast that is already on when it checks two minutes before the start. Overlapping windows share a single connection. Outside that window and with **Go live now** off, the app drops its connection and stops capture, scanning, and upload.
- An idle or suspended iPhone displays reminders (scheduled on the phone, or pushed by your Worker). Connect in Meetspike HR after turning on WHOOP broadcasting. iOS can keep an established Bluetooth subscription running with the screen locked. Open Meetspike HR again if the connection drops while locked. Force-quitting interrupts capture. [Apple Bluetooth background behavior](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)
- **Push from your Worker (build 11).** A per-minute Worker cron looks at the meetings the phone covers and sends an Apple push only when no heart rate arrived in the last 60 seconds, from any device. Two minutes before the start: a reminder to turn on HR Broadcast. One minute in: one follow-up, if there is still none. Nine minutes after the end: a note that you can turn broadcast off, only if heart rate is still coming in. While push works the phone schedules no reminders of its own. The phone sends its device token with the check-in (`push: {token, environment}`) and the reply says `push: true` when Apple accepted it. Settings then says **On, from your server**. If the Worker has no APNs keys, Apple rejects the token, or the Worker is older, the reply is `push: false` (or missing) and the phone goes back to local reminders.
- **Local reminders (fallback).** Two minutes before each meeting: a reminder to turn on HR Broadcast. If no heart rate arrives by one minute into the meeting, one follow-up. Heart rate arriving from five minutes before the start cancels that meeting's reminders. At the end of a block, a quiet note that you can turn broadcast off. Open WHOOP manually to change the setting. Scheduled reminders are refreshed when Meetspike runs and sees calendar edits.
- Only one device reminds. The iPhone checks in with the Worker (`POST /api/whoop-web/reminder/owner`) while it is signed in, past setup and allowed to notify. It sends the start times of the meetings it scheduled a reminder for (up to 60), and checks in again whenever that list changes. The Mac stays quiet only about those meetings and still reminds about anything else, like a meeting past the phone's 60-reminder limit or one on a calendar the iPhone does not have. The check-in lasts 7 days and is renewed when the app runs. When it lapses or the phone signs out, the Mac takes over and the phone schedules nothing past its last confirmed check-in. [WHOOP app guide](https://support.whoop.com/s/article/Navigating-the-WHOOP-Mobile-App?language=en_US)

## Design notes

- **Shared code.** The iPhone and Mac apps use one Swift package, `shared/MeetspikeHRCore`, for the WHOOP Bluetooth reader, EventKit scheduling, the seven-day SQLite buffer, live batching and replay. The iPhone app adds live BPM, a 15-minute Swift Charts trace, meeting name and countdown, and connection and sync status. The Mac keeps its menu bar, setup guide and strap selection.
- **Credentials and data.** Both apps use the existing ingest secret and the optional Cloudflare Access service-token headers. You enter them in Settings, and they are stored in the platform Keychain. Calendar titles stay on the device. Uploads send only timestamps and BPM to the configured Worker.
- **Meeting rules.** Meeting-only capture is on by default. All-day, declined, cancelled, zero-length and longer-than-eight-hour events are ignored. Each window runs from five minutes before a meeting until ten minutes after it, and touching or overlapping windows form one block. **Go live now** overrides the schedule until you switch it off or relaunch the app. On Mac, **Pause** takes precedence. If Calendar access is denied, the Mac shows **Calendar access needed** and listens continuously.
- **Worker coverage.** The Worker stores whatever part of a meeting a recording covers. A five-minute lead-in, or a late connection, still gives a meeting row, and later replays with more readings extend it. No D1 changes were needed.
- **Battery.** Outside an active window, both apps stop Bluetooth discovery and cancel the connection, live upload and replay. While active, they send live batches about every five seconds and replay every 30 minutes, with one more replay attempt in the last 30 seconds of a block. Unsent data replays in the next active window. On iPhone, an established subscription keeps delivering while the phone is locked, but discovery doesn't run while the app is in the background. Bluetooth callbacks enforce the meeting deadline even if iOS delays an app timer.
- **WHOOP broadcast.** Only the WHOOP app can switch **HR Broadcast** on or off. Third-party apps can only choose when to listen. WHOOP documents some universal links, but there is no verified public link that opens the broadcast setting, so the reminders give text instructions only. The Worker pushes time-sensitive reminders to the iPhone when no heart rate is coming in, and the iPhone schedules local ones only when push is not working. The Mac reminds only about meetings the iPhone did not schedule (see the [Mac README](../mac/MeetspikeHR/README.md#meeting-reminder)), so you get one nudge, not two.
- **Verification.** The shared package tests and both app targets have been built on macOS with Xcode 26.3. iOS Simulator screenshots cover the dark appearance (the only one), small and large phones, onboarding, errors, and maximum Dynamic Type. Simulator fixtures show synthetic readings and sync results. Real WHOOP Bluetooth, lock-screen capture, notification delivery, reconnecting and battery use still require a signed build on a physical iPhone.

## Live Activity and widgets

- **Live Activity.** While the phone listens (the meeting window or **Go live now**), the Lock Screen and Dynamic Island show the BPM with a heart, the meeting title, a timer such as "Ends in 12:40", a green ring for meeting progress and a short state: Live, Reconnecting or Waiting for WHOOP. Updates go out at most every 5 to 10 seconds and only when the BPM moves or the state changes, plus a keep-alive every 30 seconds. The activity ends at the window end or when **Go live now** is turned off. iOS only starts a Live Activity while the app is open, so a window that opens with the phone locked shows it once you open Meetspike (the broadcast reminder tap does this).
- **Widgets.** **Next meeting** comes in small, medium, Lock Screen rectangular and Lock Screen circular sizes. It shows the next meeting with its countdown, plus the latest BPM (from the last 10 minutes) or the last meeting's peak. The app writes a small snapshot to the App Group `group.com.hersheyg.meetspike.hr` and reloads timelines only when meetings, listening or the peak's meeting change, or every 5 minutes for a new BPM.
- **Extension.** `MeetspikeHRWidgets` (`com.hersheyg.meetspike.hr.widgets`) is embedded in the app. It takes `CURRENT_PROJECT_VERSION` and `MARKETING_VERSION` from the single project-level `settings` in `project.yml`, so one bump covers both.
- **Apple Developer setup.** Register the App Group and the widget bundle identifier on the same team as the app, and add the App Group to both identifiers, before the first signed build.
- **Simulator.** `-demo live -demoActivity YES` starts the real Live Activity from fixtures. `-demoGlanceGallery YES` renders every Live Activity and widget layout to `Documents/GlanceGallery` in the app container.

## Open questions

- Can the WHOOP strap broadcast to the iPhone and the Mac at the same time? The strap sends heart rate to one listener at a time ([root README](../README.md)), so pause the Mac's reader when the phone needs it.
- How long does a physical iPhone keep an established subscription through a meeting with the screen off? Check the reminders, background delivery, the cutoff, and reconnecting after a drop on the real setup.
