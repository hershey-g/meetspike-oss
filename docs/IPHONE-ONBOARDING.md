# Meetspike on your iPhone

This walks you through the iPhone app, from install to your first live heart rate. You do not need to code.

The app does two things. It shows the same dashboard as your Worker's web page (Today, Dates, People, Ask). It also listens to your WHOOP strap over Bluetooth during meetings and sends the heart rate to your Worker. The phone never uploads the meeting titles in its calendar. Everything it sends goes to your own Worker: heart rate and meeting times, what you do in the app (meeting choices, calendar picks, searches, company names, Ask questions, your AI key), crash reports (you can turn those off), and the token Apple gives it for push reminders. When you use Ask, your Worker sends the question and the data it needs to Anthropic.

The app is not on the App Store. You install it through TestFlight.

## What you need first

- **A running Worker.** That is your own copy of Meetspike on Cloudflare. If you do not have one yet, follow [Set it up](../README.md#set-it-up) in the README first.
- **An iPhone on iOS 17 or later.**
- **A WHOOP strap**, with the WHOOP app on the same phone, for live heart rate. No WHOOP? See [Without a WHOOP](#without-a-whoop).
- **Your meetings on this iPhone.** Add the Google account that holds your meetings to the iPhone's Calendar app. The app reads meetings from there.

## Get the app

1. Ask whoever runs your Meetspike for a TestFlight invite to the Meetspike app.
2. Install the **TestFlight** app from the App Store.
3. Open the invite on your iPhone and tap **Install**.

If you would rather build it yourself, see [If you build it yourself](#if-you-build-it-yourself).

## First open: the setup guide

The first time you open Meetspike, it shows six short screens. Each one says why it needs something before iOS asks.

| Screen | What to do |
| --- | --- |
| **Meetspike** | Tap **Continue**. |
| **Turn on HR Broadcast** | In the **WHOOP app** (not Meetspike), go to **Menu → Device Settings** and turn on **HR Broadcast**. Then tap **Continue**. |
| **Know when meetings start** | Tap **Allow Calendar Access**. |
| **Hear your WHOOP** | Tap **Allow Bluetooth**. |
| **Get a nudge** | Tap **Allow Notifications**, or **Not Now** to skip it. |
| **Ready when you are** | Check the list (Calendar, Bluetooth, Reminders, Meetspike sync). Tap **Get Started**. If sync is not set up yet, tap **Set Up Sync**. |

If you tap **Not Now** or deny something, you can change it later under **Menu → Phone settings**, or in the iOS Settings app.

## Connect to your Worker (setup code)

Pairing is the easy way to connect the phone. The code holds no secrets. It works once and expires after 10 minutes.

**On your computer:**

1. Open your Worker's address and add `/setup` to the end.
2. Go to step **8, Connect your iPhone**, and tap **Show setup code**. A QR code appears.

   If it says something is missing, finish [Worker settings for the phone](#worker-settings-for-the-phone) first.

**On your iPhone:**

3. In Meetspike, go to **Menu → Phone settings → Scan setup code**. You can also point the iPhone Camera app at the code, and it opens Meetspike.
4. Allow the camera if iOS asks.
5. Tap **Connect** when Meetspike asks to connect to your server.
6. Go back to **Phone settings** and tap **Test connection**. You want **Connected**. If it says **Blocked by Cloudflare Access**, the phone has no service token yet. See the settings below.

If the code does not work, make a new one on the setup page and scan again.

### Worker settings for the phone

A fresh install does not have these yet. Add them once in Cloudflare (Workers & Pages → your app → Settings → Variables and Secrets), then deploy.

| Name | What it is |
| --- | --- |
| `WHOOP_WEB_HR` | Set to `enabled`. It ships as `off`, and while it is off the Worker stores no live heart rate and sends no reminders. It is a plain variable: change it in your `wrangler` config too, or the next deploy turns it off again. |
| `INGEST_ADMIN_SECRET` | A long random password you make up. The phone gets it from the setup code. |
| `ACCESS_TEAM_DOMAIN`, `ACCESS_AUD` | Prove you are signed in when you make a setup code. The [README](../README.md#access) says where to find them. |
| `PHONE_ACCESS_CLIENT_ID`, `PHONE_ACCESS_CLIENT_SECRET` | A Cloudflare Access service token, so the phone gets past your sign-in page. In Cloudflare: Zero Trust → Access → Service auth → create a token, then add a **Service Auth** rule for it on the Access app that covers `/api/*`. You can also type the token in **Phone settings → Meetspike sync** instead. |

After changing any of these, make a new setup code.

## Permissions and what each one is for

| Permission | What it is for |
| --- | --- |
| **Calendar** (full access) | Reads your meeting times so the phone knows when to listen. Titles stay on the phone. All-day and declined events are skipped. Optional: **Go live now** works without it. |
| **Bluetooth** | Receives the heart-rate broadcast from your WHOOP. Required for heart rate. |
| **Camera** | Scans the setup code. Only used for pairing. |
| **Notifications** | Reminders to turn on HR Broadcast, and a note when you can turn it off. Optional. |

## Turn on WHOOP HR Broadcast

1. In the WHOOP app, go to **Menu → Device Settings** and turn on **HR Broadcast**.
2. Keep the WHOOP app connected to your strap. That is fine.
3. Do not pair the strap in the iOS Bluetooth settings. There is nothing to pair.
4. Close other apps that read WHOOP heart rate, such as Peloton and Zwift. The strap sends to one listener at a time. If your Mac or another app is using the broadcast, pause that reader and retry.
5. After a WHOOP firmware update, check HR Broadcast again. It can turn itself off.

## First test: Go live now

1. Open the **Live** tab and tap **Go live now**. The button changes to **Stop listening**.
2. Wait for a BPM number and a **Last reading** time. The chart shows the last 15 minutes.
3. Lock the phone for a few minutes, then unlock it. Check that the readings kept coming.
4. Tap **Stop listening** when you are done.

**Go live now** listens outside meetings until you stop it or quit the app. Meetings also start listening on their own, from 5 minutes before each one until 10 minutes after.

Keep Meetspike open until it connects at the start of a meeting. After that, you can lock the phone. iOS can drop the connection while the app is closed, so open Meetspike again if the readings stop.

## The tabs

| Tab | What you see |
| --- | --- |
| **Today** | The day's meetings, the next-morning numbers, and how today compares with your usual. Step a day with the arrows, or tap the date to pick one. |
| **Dates** | Pick two dates, or a quick pick: Today, Yesterday, Last 7 days, Last 30 days, This month, Last month. Compares the morning after heavy days with lighter days. |
| **People** | Everyone you met, for the past 7 days, 28 days, 90 days or year. Search by name or email. A **Show** switch changes the list to **Companies**. |
| **Ask** | Chat about your meetings and recovery. Needs your AI key (**Menu → Ask your data → AI key**) and the AI setup on your Worker. |
| **Live** | Live BPM, the last 15 minutes, **Go live now**, and upcoming meetings. |

## The Menu

The **≡** button in the top-left of each tab opens **Menu**.

- **Data.** **Sync calendar** re-reads the last 3 weeks and the next month. **Show data** switches WHOOP and Oura on or off. Hidden data keeps syncing.
- **Connections.** Google Calendar, WHOOP and Oura, each marked **Connected** or **Connect**. Tapping one opens your Worker's setup page.
- **Calendars.** Your Google accounts and which calendars count as meetings. **Add Google account** opens sign-in in Safari. Every account counts as you, and a meeting on two calendars counts once.
- **Ask your data.** **AI key**: add, change or remove it.
- **Setup.** **Setup guide** and **Privacy**.
- **This iPhone.** **Phone settings**, **Lock Screen heart rate**, and **Crash reports**.
- **About.** **What's new** and the version number.

**Phone settings** has four sections:

- **Connect.** **Scan setup code** and **Test connection**. Test connection shows one of: **Connected**, **Wrong ingest secret (401)**, **Blocked by Cloudflare Access**, or **Can't reach server**.
- **Meetspike sync.** Your Meetspike URL, the ingest secret, and the Access client ID and secret if your Worker uses them. Save with **Save sync settings**.
- **Meetings.** Calendar access, **Calendars that start listening**, **Broadcast reminders**, and **Lock Screen heart rate**.
- **Heart-rate broadcaster.** Shows the WHOOP you remembered, with **Forget WHOOP**.

**Crash reports** has a **Send crash reports** switch and a **Send a test report** row. Reports go only to your own Worker, with no meeting names or heart rates.

## Meeting choices

You can fix a meeting that is wrong. Long press it on **Today**, or open it and tap **...**.

- **I didn't join.** The meeting stays in the list, dimmed, as **Didn't join**. It has no score and is left out of averages.
- **Don't link this meeting.** Same idea, shown as **Not linked**.
- **Meeting times.** Set a start and end, or tap **Use calendar times** to go back.
- **Undo** puts it back.

For a meeting in a series, the app asks **Just this one** or **All of them**.

If your Mac never saw Zoom for a meeting, you may see a quiet note: **Looks like you didn't join. Unlink it?** Yes leaves it out. No keeps it and stops asking.

Your calendar is never changed. If you are offline, the choice shows **Sends when you are online** and is sent later.

## Lock Screen and widgets

- **Live Activity.** The Lock Screen and Dynamic Island show your BPM, **In meeting** with the meeting name, the time left, and the state: **Live** or **Reconnecting**. **Still going** adds 15 minutes. **Ended now** ends it.
- **Lock Screen heart rate** (in **Menu → This iPhone**, **Phone settings**, or the line on the **Live** tab) picks when it shows:
  - **During meetings** (the default): from 5 minutes before a meeting until it ends. Back-to-back meetings count as one. It ends with the meeting, with no extra 10 minutes, and never shows for **Go live now** outside a meeting.
  - **Whenever listening**: from 5 minutes before a meeting to 10 minutes after, and during **Go live now**.
  - **Off**: never.

  Heart rate is still recorded either way. Swiping it away hides it until this meeting ends.
- **Widget: Next meeting.** Available as small and medium Home Screen widgets, and as Lock Screen rectangular and circular widgets. It shows your next meeting, its countdown, and your latest BPM.

The Live Activity starts only while the app is open. If a listening window starts while the phone is locked, open Meetspike once.

## Reminders

These are the rules from build 11 on.

**When your Worker sends them** (push is set up, and the switch says **On, from your server**):

- A reminder comes only when no heart rate is coming in. Your Worker checks first, from any device, so nothing is sent while you are live.
- **Two minutes before** a meeting: a reminder to turn on HR Broadcast, if there is still no heart rate.
- **One minute in:** one follow-up, if there is still no heart rate.
- **After the meeting:** a note that you can turn HR Broadcast off. It only comes if heart rate is still coming in.

**When your phone sends them** (no push on your Worker, which is how a fresh install starts):

- The phone plans them ahead and knows only about its own readings, so you can get one while your Mac is live.
- The note after the meeting always comes.

**Broadcast reminders** in Phone settings shows who sends them: **On, from your server**, **On, from this iPhone**, or **Sent by your Mac**.

Only one device sends reminders at a time. To set up push, see **Push is optional** under [If you build it yourself](#if-you-build-it-yourself).

## Without a WHOOP

With an Oura ring, your Worker still works for the dashboard. **Today**, **Dates**, **People**, **Ask** and **Menu** show your Oura data, and meeting heart rate comes from Oura's own sync.

The **Live** tab, live BPM, reminders and the Lock Screen need a WHOOP strap. The phone only listens to WHOOP's broadcast.

## Updating

- The app checks for a new build when you open it, at most every 30 minutes. When one is ready, you see **Update available**. Tap **Update** to open it in TestFlight.
- You can also open TestFlight and install the new build there.
- **Menu → About → What's new** shows what changed.

## Troubleshooting

| What you see | What to try |
| --- | --- |
| **Wrong ingest secret (401)** | Make a new setup code on your Worker's setup page and scan it again. |
| **Blocked by Cloudflare Access** | Add the Access client ID and secret in **Meetspike sync**, or check your Access rules. |
| **Can't reach server** | Check your Meetspike URL and your connection. Try the URL in Safari. |
| **Couldn't connect** after scanning | The code may have expired (10 minutes) or been used. Make a new one. |
| **Can't scan here** | Use the iPhone Camera app on the code, or turn on Camera for Meetspike in iOS Settings. |
| **Waiting for readings** on Live | Check that HR Broadcast is on in WHOOP. Close other apps and the Mac that read the strap. |
| **Live sync retrying · HTTP 409** | `WHOOP_WEB_HR` is off on your Worker. Set it to `enabled` (see [Worker settings](#worker-settings-for-the-phone)). |
| Heart rate stops when the phone is locked | Open Meetspike again. Do not force quit it during a meeting. |
| **Calendar access is off** | Allow Calendar in iOS Settings. Or use **Go live now**. |
| **No meetings on the calendar.** | Tap **Menu → Data → Sync calendar**, and check **Calendars that start listening**. |
| No reminders | Check **Broadcast reminders** in Phone settings, and allow Notifications in iOS Settings. |
| **Sends when you are online.** | The phone is offline. The choice is sent when it reconnects. |
| **Not available yet.** | Your Worker is still updating. Try again in a few minutes. |
| Ask stops and clears the chat | The AI key was missing or rejected. Add it again under **Menu → Ask your data → AI key**. |

## If you build it yourself

Build it only if you want your own copy. You need a Mac with Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and your own Apple Developer team.

1. Run `brew install xcodegen`, then `cd ios/MeetspikeHR` and `xcodegen generate`. Open `MeetspikeHR.xcodeproj`.
2. In `project.yml`, set `DEVELOPMENT_TEAM` for the app and the widgets to your own team.
3. Change the bundle IDs to ones your team owns. The defaults are `com.hersheyg.meetspike.hr` (app) and `com.hersheyg.meetspike.hr.widgets` (widgets).
4. Register an App Group in your team, and add it to both IDs. The default is `group.com.hersheyg.meetspike.hr`. If you rename it, change it in the entitlements and in the shared code.
5. Turn on Push Notifications for the app ID, since the app uses the push entitlement.
6. Run it on a real iPhone. The simulator cannot test Bluetooth or lock-screen behavior.

**Push is optional.** To have your Worker send reminders, set these Worker secrets (names only):

- `APNS_KEY_P8`: the Apple push key file (.p8 contents)
- `APNS_KEY_ID`: the key's ID
- `APNS_TEAM_ID`: your Apple team ID
- `APNS_TOPIC`: your app's bundle ID, if it is not the default `com.hersheyg.meetspike.hr`

Without them, the phone sends its own reminders, and nothing breaks.

More detail is in [ios/README.md](../ios/README.md).
