# Meetspike mobile contract (slice0)

Everything the five tab tracks (Today, Dates, People, Ask, More) and the spec tests build on. Signatures
here are final. The `Mobile/<Tab>/` logic (section 7) is implemented and matches the public API listed there; the
SwiftUI screens build on it and do not change anything under `API/`.

Module: `MeetspikeHRCore` (`shared/MeetspikeHRCore`). Days are local `YYYY-MM-DD` strings in the Worker's
time zone. "today" always means the server's `ViewResponse.today`.

## 1. Errors

`public enum APIError: Error, Equatable, Sendable`
- `.accessRejected` redirect, 401, 403 or an HTML page: Cloudflare Access said no. Show the banner, offer Menu ("Open Menu").
  The `message` copy says "in Menu" (`APIError.accessRejected`, `.notConfigured`).
- `.http(status: Int, message: String)` Worker error. `message` is the Worker's own `error` sentence, safe to show.
- `.offline` no usable network (any URLError except cancel). Falls back to the cache through `load...`.
- `.decoding(String)` 2xx body is not the expected shape. The text names the type and key path, never values.
- `.invalidRequest(String)` request could not be built (bad path, empty Claude key).
- `.notConfigured` no origin saved yet (`UnconfiguredAPI`).
- `var message: String` short plain sentence for a banner. `var status: Int?` the HTTP status for `.http`.
Cancelling a task throws `CancellationError`, never an `APIError`.

## 2. Requests

`public struct APIRequest: Equatable, Sendable` method, path, query, body, timeout, cacheable.
- `static func encode(_ value: String) -> String` encode one path segment or query value (letters, digits, `-._~` only).
- `var cacheKey: String`, `var encodedQuery: String?`, `func url(origin: URL) -> URL?`
- Builders: `.view(date:)`, `.view(start:end:)`, `.meetingHR(id:fill:)` (fill false sends `fill=0`),
  `.liveHR(meetingID:since:)`, `.people(start:end:)`, `.searchPeople(query:)`,
  `.personMeetings(email:start:end:compact:)`, `.refresh(full:)`, `.calendarSync(full:)`, `.sourceDisplay`,
  `.setSourceDisplay(_:enabled:)` (exactly one key), `.askStatus`, `.saveAskKey(_:)`, `.deleteAskKey`, `.askStream(_:)`.

## 3. API protocol

`public protocol MeetspikeAPI: Sendable`. Screens hold `any MeetspikeAPI` (from `AppEnvironment.api`).
- `var responseCache: ResponseCache? { get }`
- `view(date:) -> ViewResponse` one day (`day` set, `range` nil)
- `view(start:end:) -> ViewResponse` a span (`range` set, `day` nil)
- `meetingHR(id:fill:) -> MeetingHRDetail` (default `fill: false` via the `meetingHR(id:)` overload)
- `liveHR(meetingID:since:) -> LiveHRReply` poll with the returned `cursor` as `since`
- `people(start:end:) -> PeopleResponse`
- `searchPeople(query:) -> [PersonMatch]` empty/blank query returns `[]` with no request
- `personMeetings(email:start:end:compact:) -> PersonMeetingsResponse` (default `compact: true`)
- `refresh(full:) -> RefreshResult` POST /api/refresh, falls back to POST /api/calendar/sync on 404, 409 needsGoogle is a result
- `sourceDisplay() -> SourceDisplay`, `setSourceDisplay(_:enabled:) -> SourceDisplay` (PATCH, one key)
- `askStatus() -> AskStatus`, `saveAskKey(_:) -> AskKeyResult`, `deleteAskKey() -> AskKeyResult`
- `askStream(_:) -> AsyncThrowingStream<AskEvent, Error>` see section 5

Offline helpers (protocol extension, same on every implementation):
- `loaded(_ request:, fetch:) -> Loaded<T>` network first; only `.offline` falls back to the last good answer.
- `loadView(date:)`, `loadView(start:end:)`, `loadMeetingHR(id:fill:)`, `loadPeople(start:end:)`,
  `loadPersonMeetings(email:start:end:compact:)`, `loadAskStatus()`, `loadSourceDisplay()` all `-> Loaded<T>`
- `cachedView(date:)`, `cachedView(start:end:) -> CachedValue<ViewResponse>?` instant paint from disk, no network.
- `Loaded<T>`: `value`, `savedAt`, `isFromCache`. `CachedValue<T>`: `value`, `savedAt`.

Implementations:
- `APIClient(origin: String, credentials: Credentials?, userAgent:, configuration:, cache:)` failable: bare https
  origin or http on localhost only. Also `init(destination:...)`. `urlRequest(for:)` shows the exact request.
  Ephemeral session, no cookies, redirects refused, Access headers only when both parts are valid header values,
  never the ingest bearer. Pass `URLSessionConfiguration` with `protocolClasses` to stub in tests.
- `DemoAPI(directory:latency:streamPacing:emptyDays:askKeySaved:)`, `DemoAPI.bundled(in:)`, `DemoAPI.demoToday`
  (2026-11-24, five meetings, heavy day). Any other single day is the empty-day fixture. `var failure: APIError?`
  makes every call throw (preview error states). `var showsEmptyDays: Bool`.
- `UnconfiguredAPI()` everything throws `.notConfigured`.

## 4. Response models (all `Decodable, Equatable, Sendable`, lenient)

Optionals where the web code treats the field as optional. Lists use `@Items` and default to `[]` when missing, null or
not an array (an array with a bad element still throws). Unknown keys are ignored. Build them by decoding fixtures.
- `ViewResponse`: ok, today, start, end, spanDays, timeZone, wearable, status, morningScores, day, range, usual,
  effect, costly, people, series, hits (nil = no per-meeting HR), baselineNote; `isSingleDay`.
- `WearableInfo`: source, label, readinessLabel, strainLabel, strainMax, hasIntradayHr, hrSource, ouraHr, whoopWebHr,
  tagline, note; `kind: WearableKind?` (`.whoop`/`.oura`), `scoreLabel` ("Recovery (WHOOP)").
- `ViewStatus`: displayTitle, sandbox, wearables `[WearableStatus]`, sourceDisplay, wearableConnected,
  googleConnected, lastSync `SyncStamp`. `WearableStatus`: source, label, displayEnabled, connected, expiresAt,
  lastDataDay, lastReceivedAt, history `WearableRange`.
- `MorningScore`: source, label, readinessLabel, morning, nextMorning, average, usual. `Usual`: from, to, days,
  recovery, sleep, hrv, restingHr, strain, meetingHours, afterHours. `DaySlice`, `HeavyEffect`, `HeavySide`,
  `CostlyDay`, `HeavyDayPerson`, `SeriesDay` (day, meetingCount, meetingHours, afterHours, recovery, sleep, strain, nextRecovery).
- `DayBriefing` (`view.day`): date, timeZone, calendar `DayCalendar` (counts, `events: [Meeting]`), priorNight,
  nextMorning, flags, summary, hr `DayHR?`, wearable, methodNote.
- `RangeBriefing` (`view.range`): start, end, spanDays, summary `RangeSummary`, recovery `RangeRecovery`,
  days `[RangeDay]`, wearable, grain, methodNote. `RangeDay`: day, counts, elevated/watching/restored/noHr, meanBpm,
  morning/nextMorning `RangeScores`, meetings.
- `Meeting`: id, title, kind, day, startUtc, endUtc, startLocal, endLocal, afterHours, earlyStart, attendeeCount,
  durationS, signals `MeetingSignals`, score, flags, hrStress `MeetingHR?`, attendees `[Attendee]`, sourceType, hasTranscript.
- `MeetingHR`: coverage ("ok"/"none"), source, gaps, meanBpm, maxBpm, zone, headline, story, impact, series `[HRPoint]`,
  partial `HRPartial?` (fromUtc, toUtc, lateStart, earlyEnd); `hasCoverage`. `HRPoint`: t, bpm, minutes, source; `time: Date?`.
- `InsightHit`: id, day, title, startLocal, sentence, badge, compare `[InsightCompare]`, hrStress, attendees.
- `MeetingHRDetail`: ok, enabled, meetingId, title, timeZone, window, hrStress, series, baseline `HRBaseline`, stress
  `StressSlice`, fill, message. A 404 arrives as `.http(404, ...)` (detail unavailable).
- `LiveHRReply`: window `LiveWindowMs` (startMs, endMs, fromMs, toMs), active, points `[LivePoint]` (ms, bpm), cursor.
  404 = live HR off (`.http(404, ...)`).
- `PeopleResponse`: start, end, wearable, sourceDisplay, people `[PersonSummary]` (email, name, meetings, days, avg),
  usualRecovery. `PersonMatch`: email, name.
- `PersonMeetingsResponse`: email, name, from, to, trend `PersonTrend`, trendsByHrSource `[PersonSourceTrend]`,
  meetings `[PersonMeeting]` newest first. `PersonTrend`: meetingCount, withCoverage, elevated, watching, restored,
  missingHr, medianAvgBpm, spark (newest first), badge, badgeNote. `PersonMeeting.companies` `[CompanyTag]`.
- Companies (tagged from attendee email domains, never the owner's own domain, free mail or calendar rooms):
  `CompanyTag` (domain, name; `displayName`) on `Meeting.companies`, `InsightHit.companies` and
  `PersonMeeting.companies`, `[]` from an older Worker. `CompaniesResponse`: start, end, spanDays, wearable,
  sourceDisplay, companies `[CompanySummary]` (domain, name, meetings, people, days, avg, trend `PersonTrend?`),
  usualRecovery. `CompanyMatch` = `CompanyTag`. `CompanyMeetingsResponse`: the person page shape with domain and
  name, plus people `[CompanyPerson]` (email, name, meetings); each meeting's `companyAttendees` are the attendees from
  that company. `CompanyNameResult`: ok, domain, name. API: `companies(start:end:)`, `searchCompanies(query:)`,
  `companyMeetings(domain:start:end:compact:)`, `renameCompany(domain:name:)`, plus `loadCompanies` and
  `loadCompanyMeetings`. Logic in `CompanyLogic.swift`: `PeopleMode`, `CompanySort`, `CompanyLogic.sorted/detail/
  hrSummary/initials/attendeeLine`, `CompanySearchCache`.
- Google accounts and calendars (`CalendarModels.swift`, Worker `src/routes/calendars.ts`): `GoogleCalendarsResponse`
  (ok, accounts `[GoogleAccount]`, connectPath, setupPath, legacyError; after a change also changed, hidden, shown,
  syncError, removed). `GoogleAccount` (email = id, connectedAt, lastSyncAt, error, calendars). `GoogleCalendar` (id,
  name, primary, selected, color, accessRole, lastSyncAt, error; `isPrimary`, `isSelected`). API:
  `googleCalendars(refresh:)` GET /api/calendars (`refresh=0` skips Google), `setGoogleCalendar(account:calendarId:selected:)`
  PUT /api/calendars/selection, `disconnectGoogleAccount(email:)` DELETE /api/calendars/accounts/:email. Never cached.
- `RefreshResult` (not decoded directly): calendar/whoop/oura `RefreshPart?`, syncedAt, usedCalendarFallback,
  needsGoogle; `calendarError: String?` (nil for needsGoogle), `whoopFailed`, `ouraFailed`, `wearableRefreshed`.
  Real HTTP failures throw; failed parts are reported here.
- `SourceDisplay` (existing): oura, whoop. Added: `SourceDisplay.make(oura:whoop:)`, `Encodable`.
- `AskStatus`: available, connected, tail, savedAt, model, sourceDisplay. `AskKeyResult`: connected, tail, savedAt.
- `APITime.parse(_:) -> Date?` ISO-8601 with or without fractional seconds.
- `DayMath` (all pure): `date(_:)`, `string(_:)`, `isValid(_:)`, `addDays(_:_:)`, `spanDays(_:_:)`,
  `today(in:now:)`, `shiftMonth(_:_:)`, `lastDay(ofMonth:)`.

## 5. Ask stream

- `AskRequest(question:history:sourceDisplay:start:end:allTime:ignorePeriod:)` Encodable. start and end are sent only
  together. `allTime` and `ignorePeriod` default false and are encoded only when true, so older Workers see the body they
  know. The Worker ranks the first of: a period in the question ("this month", "last 3 weeks", or all-history wording
  such as "all time", "all history", "since the beginning", a bare "ever"; all-history wording wins over a period, a period
  wins over a bare "ever"), `allTime: true`, the newest earlier user turn with a period (follow-up), start and end (a bad
  range is a 400 only when this step applies), then all history. `ignorePeriod: true` skips the question and follow-up
  steps ("Ask over all time" sends it with `allTime`). Baselines (usual and heavy-day numbers) always cover all history,
  per wearable; only the detail sent to Claude is limited to the ranked dates.
  `AskTurn(role: AskRole, content:)`, `AskRole` `.user/.assistant`.
- `AskEvent`: `.step(AskStep)`, `.text(String)`, `.range(AskRange)`, `.done(AskDone)`, `.error(AskFailure)`, `.cutOff`;
  `isTerminal` (not for `.range`). `AskStep(id,label,status: .active/.done)`,
  `AskDone(truncated,interrupted,refused,model,start,end)` plus `range: AskRange?` (nil from an older Worker),
  `AskFailure(message, needsKey)`.
- `range` stream event `{start, end, baselineStart, baselineEnd, rangeSource}`, sent once before the first step.
  `done` and the POST /api/ask JSON carry the same three extra fields (`baselineStart`, `baselineEnd`, `rangeSource`).
  `rangeSource` is `"question" | "allTime" | "followUp" | "tab" | "history"`. Baseline is history start to today.
  Older phones ignore the unknown event.
- `AskRange(start,end,baselineStart,baselineEnd,source: String?)` Equatable, Sendable, Codable. `source` is `rangeSource`
  (nil if the Worker does not say). `coversAllHistory(today:)`: ranked start is at or before the baseline start and the end
  reaches the baseline end or today. `range` with any of the four days missing or not a real day maps to no event;
  `done` then has `range` nil.
- `askStream` yields steps and text, then exactly one terminal event. Worker problems found before streaming (no key 409,
  bad range 400, too long 413) arrive as `.error`. Connection dropped or ended without done/error: `.cutOff` (partial
  text was already delivered). No network or Access rejected: the stream throws `APIError`. Cancelling the consuming
  task closes the connection and ends the stream quietly.
- `SSEParser`: `push(_ String|Data)`, `push(byte:)`, `finish()` return `[SSEMessage(event,data)]`. Handles any chunk split,
  UTF-8 split, CRLF, lone CR; ignores `:` comments and data-less events.
- `AskEventParser`: same inputs, returns `[AskEvent]`; `finish()` appends `.cutOff` when nothing terminal was seen.
  `AskEvent(SSEMessage)` maps one raw event.

## 6. Response cache

`actor ResponseCache(directory:maxEntries:now:)`, `ResponseCache.standard(origin:)` (Caches dir, one folder per origin).
`write(_:for:)`, `readData(for:) -> (body, savedAt)?`, `read(_:for:) -> CachedValue<T>?`, `clear()`,
`writeFailures`. Only successful GETs are stored (never live HR, POSTs or search). Use `load...` helpers, not this directly.

## 7. Mobile logic (implemented; public signatures below)

All under `Mobile/<Tab>/`, plain Swift, no UI types. Test classes are named with the track prefix: `Today*`, `Dates*`,
`People*`, `Ask*`, `More*`. "Day" strings are `YYYY-MM-DD`.

### Today (`TodayLogic.swift`, `TodayFormat.swift`)
- Value types: `TodayTone` `.good/.warn/.bad/.none`; `TodayBand(tone, word)`; `TodayHigherIs` `.better/.worse/.neutral`;
  `TodayTrendWords(up:down:)` (`.higherLower`, `.moreFewer`); `TodayTrend(direction: .up/.down/.usual/.none,
  tone: .good/.bad/.flat, text)`; `TodayHRSegment(provider, points)`; `TodayZonePill(tone, text, note)`;
  `TodayLiveStats(min,avg,max)`; `TodayLiveChart(current,last,stats,extent,segments)`;
  `TodayTimelineBar(left,width,afterHours)`.
- `TodayLogic.recoveryBand(score:wearable:) -> TodayBand?` WHOOP 67/34, Oura 85/70.
- `TodayLogic.isHeavyDay(totalDurationS:eventCount:) -> Bool` 4 h or 5 meetings.
- `TodayLogic.metricTrend(value:usual:step:higherIs:words:) -> TodayTrend?` nil hides the row. Steps: recovery 3, HRV 2,
  resting HR 1, meeting hours 0.5 (`recoveryStep`, `hrvStep`, `restingHrStep`, `meetingHoursStep`).
- `TodayLogic.hrSegments(_:meetingSource:) -> [TodayHRSegment]` gap 180 s WHOOP, 600 s otherwise.
- `TodayLogic.partialNote(_:timeZone:) -> String`, `hrProviderLabel(_:) -> String`, `zonePill(_:timeZone:) -> TodayZonePill`.
- `TodayLogic.liveWindow(startUtc:endUtc:sourceType:) -> LiveWindowMs?` 10 min pad, max 8 h, calendar events only.
- `TodayLogic.mergeLivePoints(_:_:) -> [LivePoint]`, `liveChart(points:window:nowMs:) -> TodayLiveChart` stale 45 s, gap 15 s.
- `TodayLogic.timelineBar(startLocal:durationS:) -> TodayTimelineBar?` 7 am to 9 pm strip.
- `TodayLogic.shouldAutoRefresh(lastSync:now:) -> Bool` false when synced under 120 s ago.
- `TodayLogic.liveWindowEnded(events:previous:now:) -> Bool` true when some calendar meeting's live window (meeting plus pads)
  ended after `previous` and by `now`, so the row pill needs a fresh load. `isStaleLoad(requested:selected:) -> Bool`
  true when the person has since moved to another day, so the answer is dropped.
- `TodayLogic.dateBar(day:today:) -> TodayDateBar(isToday, canGoNext)`. The screen passes `AppEnvironment.today`, never
  the `today` inside a `ViewResponse`: an offline copy of yesterday carries yesterday's today and would label itself Today.
  The same goes for every other label, "next" and live decision on the Today screen.
- `SyncOutcome.decide(_ RefreshResult, showWhoop:showOura:) -> SyncOutcome(calendar, wearableNotes)` (`Mobile/Sync/`), one
  decision for Today's footer and the Menu's Sync row. `calendar` is `.synced(changed:)`, `.pending` (still running in
  the background, never "done"), `.needsGoogle` or `.failed(String)`; `wearableNotes` is "WHOOP did not refresh." and
  "Oura did not refresh." for the shown wearables that failed, and is kept whatever the calendar says.
- Constants: `heavyDurationS`, `heavyMeetingCount`, `whoopGapSeconds`, `ouraGapSeconds`, `livePadMs`, `liveMaxMeetingMs`,
  `liveStaleMs`, `liveGapMs`, `refreshThrottleSeconds`, `timelineFromHour`, `timelineToHour`.
- `TodayFormat` (pure strings, port of the web helpers): `number(_:)`, `rounded(_:places:)`, `plural(_:_:)`,
  `hoursText(seconds:)`, `sleepText(seconds:)` (rounds total minutes first, so 28790 s is "8 h 0 m", never "7 h 60 m"),
  `clockFromLocal(_:)`, `lengthText(durationS:)`, `meetingMeta(_ Meeting)`,
  `shortSentence(_ InsightHit)`, `dayText(_:weekday:)`, `shortDay(_:today:)`,
  `liveMeetingID(events:now:) -> String?` (the meeting to open on its own: among meetings with `now` inside
  `[startMs, toMs)`, the latest start, preferring one with `now < endMs`).
- `TodayLiveSession(window:)` struct, the live card state. Fields `window`, `points`, `cursor`, `status` ("" = none),
  `failures` (read only). `apply(_ LiveHRReply, requestedCursor:)` merges a good poll (resets points when the window
  changed and the cursor was not 0; an inactive reply clears points and sets "Outside the live window").
  `apply(_ APIError) -> Bool` (false = stop polling, only for `.accessRejected`; 404 sets "Live heart rate unavailable";
  anything else "Reconnecting..."), `noteFailure()` for non-`APIError` failures, `pollDelay` / `pollDelay(failures:)`
  (5 s, 15 s after 3 failures in a row; constants `pollSeconds`, `backoffSeconds`, `backoffAfterFailures`),
  `message(for: TodayLiveChart) -> String` (header words).

### Dates (`DatesLogic.swift`, `DatesContent.swift`)
- `DatesSpan(start,end)`: `dayCount`, `isSingleDay`. `DatesChip(label, span)`. `DatesLowDay(index, day, value)`.
  `DatesDestination` `.today(String)` / `.dates(DatesSpan)`.
- `DatesLogic.shouldNoteToday(isFromCache:) -> Bool` true only for a live answer (an offline copy carries the day it was
  saved, which can be older than the real today, so it must not call `AppEnvironment.noteToday`).
- `DatesLogic.logCode(_ Error) -> String` short log label: the `APIError` case name, `"http <status>"` for a Worker error,
  `"unknown"` for anything else. Never the Worker's message, a decoding path or dates.
- `DatesLogic.shift(_:direction:today:) -> DatesSpan` full-span step, forward clamps to `today` keeping the day count.
- `DatesLogic.canGoNext(_:today:) -> Bool`, `quickChips(today:) -> [DatesChip]` (Today, Yesterday, Last 7 days,
  Last 30 days, This month, Last month), `lowestRecoveryDays(_:limit:) -> [DatesLowDay]`, `destination(for:) -> DatesDestination`.
- `DatesPicker(start:end:today:)` struct: `month`, `start`, `end`, `editing: .start/.end/nil`, `span`;
  `pick(_:)` (swaps when end before start), `select(_:)`, `clear()`, `moveMonth(_:today:)`, `choose(_:)`.
- `DatesContent.swift` (copy and chart math): `DatesFormat` (`weekdayIndex`, `weekdayDay`, `longDay`, `shortDay(_:today:)`,
  `rangeLabel(_:_:today:)`, `monthTitle`, `narrowWeekday`, `dayNumber`, `plural`, `number`, `percent`, `hoursText(seconds:)`,
  `initials`), `DatesCopy` (`headline(_ ViewResponse) -> (headline, lead)`, `stats(_:) -> [Stat(label,value)]`,
  `costlySubtitle`, `personSubtitle`, `shortSentence`, `meetingHits`), `DatesChartPoint(index, day, value)`,
  `DatesChartMath` (`segments`, `labelEvery(count:)`, `hoursMax`, `barWidth(count:width:)`, `labelledDays`, `markerSize(count:)`),
  `DatesCalendar` (`cells(month:) -> [String?]`, `note(_:today:)`, `applyTitle(_:today:)`).

### People (`PeopleLogic.swift`, `PeopleFormat.swift`)
- `PeopleRangePreset` `.days7/.days28/.days90/.year`: `menuLabel`, `scopeLabel`, `days`. `PeopleRange`
  `.preset(_)` / `.custom(start:end:)`, `PeopleRange.default` (28 days).
- `PeopleLogic.dates(for:today:) -> DatesSpan`, `validCustomDates(start:end:) -> Bool`,
  `sparkline(_:target:) -> [Double]` (about 120 points, oldest first), `perDayAverage(_:) -> PeoplePerDayAverage`
  (`average`, `mornings`, `isThin` when under 4 mornings; one value per day), constants `pageSize` 40,
  `searchCacheSeconds` 300, `searchCacheLimit` 40, `sparklineTarget` 120.
- `PeopleSearchCache`: `people(for:now:)`, `store(_:for:now:)`, `removeAll()`, `count`. `PeoplePager`: `visible(_:)`,
  `hasMore(total:)`, `showMore()`, `reset()`.
- `PeopleLoadGate(loadedSpan:loadedConnection:)`: remembers which span and connection the content on screen was loaded
  for, so returning to the screen (pop from a person page, back from another tab) keeps the content and refreshes quietly.
  `hasContent(for:connection:)` is true when that exact span and connection are loaded; `showsSpinner(for:connection:)`
  and `resetsPager(for:connection:)` are true only when they are not; `markLoaded(_:connection:)`, `clear()` (a failure
  replaced the content). `connection` is `AppEnvironment.connectionRevision` and defaults to 0, so a new Meetspike URL or
  token never keeps the old server's people on screen.
- `PeopleLogic.shouldReloadPerson(loadedEmail:loadedSpan:email:span:) -> Bool` true unless that same email and span are
  already loaded. `acceptsPersonAnswer(answerEmail:answerSpan:showingEmail:showingSpan:) -> Bool` false for a late answer
  for another person or span, which the person page drops.
- `PeopleFormat`: `plural(_:_:many:)`, `initials(name:email:)`, `clock(fromLocal:)`, `shortDay(_:today:)`,
  `hrLine(source:withCoverage:medianBpm:elevated:watching:restored:)`.

### Ask (`AskLogic.swift`, `AskScope.swift`, `AskStore.swift`)
- `AskHistory.cleaned(_:max:)` (last 12, 8000 chars each, starts with user), `stored(_:)` (last 30). Constants
  `maxSentTurns`, `maxTurnChars`, `maxStoredTurns`.
- `AskMarkdown.blocks(_:) -> [AskBlock]`, `inlines(_:) -> [AskInline]`; `AskBlock` `.paragraph([AskInline])`,
  `.bullets([[AskInline]])`, `.table(header:rows:)`; `AskInline` `.text`, `.bold`, `.lineBreak`.
- `AskChatTurn` (id, role, content, steps, truncated, interrupted, refused, stopped, `stoppedEarly` (Stop before any text),
  error, needsKey, isStreaming, model, start, end, and the newer fields `question` (the question an assistant turn
  answers), `scope: AskScope?` (the range it was asked over), `allTime: Bool` and `ignorePeriod: Bool` (the other settings it
  was asked with; Try again repeats question, scope and both), `range: AskRange?` (what the answer ranked and compared
  with, from the `range` event or `done`; nil from an older Worker or an old saved chat), `thought: Double?` (seconds
  before the answer started or Stop was pressed)).
- `AskChatSession` (`init(turns:)`, `init(restoring:)`): `turns`, `isStreaming`,
  `keyProblem: String?` (private set; the Worker said the key is missing or rejected. The question and its answer are
  removed from `turns` and the screen shows the key form with this sentence until `clearKeyProblem()`),
  `send(_:scope: AskScope? = nil, allTime: Bool = false, ignorePeriod: Bool = false) -> [AskTurn]?` (history to send, nil
  if ignored; stores `question`, `scope`, `allTime` and `ignorePeriod` on the assistant turn and clears `keyProblem`),
  `apply(_ AskEvent)` (`.range` sets the turn's `range`; `.done` sets it only when it carries one and never clears it;
  a needsKey `.error` sets `keyProblem` instead of an error turn), `stop()` (sets `stopped` and `stoppedEarly`), `fail(message:needsKey:)`, `noteThought(seconds:forTurn:)` (first
  value per turn wins), `clearKeyProblem()`, `reset()` (clears `keyProblem` too), `storedTurns`.
- `AskCopy`: `suggestions` (four starter questions; "Which meetings cost me the most, all time?" is second), `verbs`, `verbMilliseconds`, `verb(atMilliseconds:)`,
  `thoughtLabel(seconds:stoppedEarly:)` ("Thought for 6s" / "Stopped after 3s"),
  `rangeLine(_ AskRange, today: String) -> String` ("Ranking Nov 1 to Nov 25, compared with all history", or "Using all
  history, Jan 3 to Nov 25" when `coversAllHistory`; dates formatted by `AskScope.label`).
- `AskScope(start:end:label:)` failable (nil unless both ends are valid days), Codable. `label(start:end:)` ("Oct 1 to Oct 14",
  "Nov 24"), `headerText(_ AskScope?, allTime: Bool)` (all time: "Ranking all history"; a scope: "Ranking Oct 1 to Oct 14,
  compared with all history"; neither: "Using all history"). The one-argument `headerText` is gone.
  `AskScope.forVisit(from: AskOrigin, dates:people:) -> AskScope?` is the first-visit range. A Dates origin gives the Dates
  span, People gives the range People is showing (nil if it has none), anything else gives nil (Ask works out the dates
  from the question).
- `AskTableLayout` (pure, in `AskLogic.swift`): `style(columns:rows:accessibilitySize:) -> Style` (`.grid` for 1 to 3
  columns at normal text sizes, else `.stacked`; `maxGridColumns` is 3), `stacked(header:rows:)` one card per row of
  `(label: [AskInline], value: [AskInline])`. A short row has no entry for missing cells, an extra cell has an empty
  label, a blank value is skipped.
- `AskOrigin` `.dates/.people/.other`, `init(tabName: String?)` ("dates", "people", else `.other`). Mirrors `AppTab` without
  the app type.
- `AskSavedChat(sourceDisplay:turns:)` Codable: `turns(for: SourceDisplay)` returns the turns only when the source display
  setting is unchanged, else `[]`.
- `AskChatStore(directory:isDemo:)`: the saved chat as one JSON file per mode (`ask-chat.json`, `ask-chat-demo.json`) in
  Application Support/Meetspike (`defaultDirectory()`), atomic write, file protection, excluded from backup. `fileURL`,
  `load() -> AskSavedChat?`, `save(_:) throws` (the caller logs a failure with the triggering action), `clear()`,
  `migrateLegacy(from: UserDefaults, into:) -> Int` moves the old plaintext UserDefaults copy (`realKey`, `demoKey`) into
  files and deletes the keys; an existing file wins.
- `AskAnnouncement.message(for: AskChatTurn?, hadKeyProblem:, askTabSelected:) -> String?` is the VoiceOver text when an
  answer finishes ("Answer ready.", the error, or the dropped connection sentence); nil when quiet (key problem, or Ask
  not on screen). `removeKeyMessage` is the Remove confirmation copy.

### More (`MoreLogic.swift`)
- `MoreConnectionRow(id, title, isConnected, isDisplayed, lastDataDay)`.
- `MoreLogic.sourceToggleRequest(source:enabled:) -> APIRequest` PATCH with exactly one key.
- `MoreLogic.connectionRows(status:) -> [MoreConnectionRow]` (WHOOP, Oura from `status.wearables`, then an always-present
  Google Calendar row). `connectionDetail(for:status:) -> String`, `dayLabel(_:)` ("Mon, Nov 24"),
  `setupURL(origin:rowID:) -> URL?` (`/setup?wearable=<id>` or `/setup`; https only, nil otherwise).
- `MoreLogic.versionLabel(version:build:) -> String` "Version 1.0 (4)".
- `MoreLogic.askKeyStatus(_ AskStatus?) -> (text, isSet)` ("Key ...tail", "Not set up", "Add key").
- `MoreLogic.changedCount(_ RefreshResult) -> Int` calendar `written + removed`.
  `syncMessage(_:showWhoop:showOura:) -> String` built from `SyncOutcome.decide` ("Synced just now. N meetings updated.",
  the needsGoogle, failure and "Still syncing in the background" variants), always followed by any wearable that did not
  refresh.
  `shouldPostDataRefreshed(_ RefreshResult) -> Bool` true unless Google was missing and no wearable refreshed; it gates
  `.meetspikeDataRefreshed`.

### Calendars (`CalendarsLogic.swift`, `ListeningCalendars.swift`)
- `CalendarsLogic.addAccountURL(origin:)` (`/setup#calendars`), `calendarName(_:account:)` (the primary reads
  "Main calendar"), `calendarDetail`, `accountFooter`, `syncedText`, `shortError`, `summary`, `applying`, `removing`,
  `savedMessage`, `rgb`, `disconnectTitle`, `disconnectMessage`.
- `ListeningCalendarChoice` (Apple Calendar calendars that start listening, saved on the device as the ids left out;
  default every calendar): `includes`, `set`, `query(available:) -> .all | .some(ids) | .none`, `summary(available:)`,
  `grouped(_:)`, `load(from:)`, `save(to:)`. `DeviceCalendar(id, title, sourceTitle, colorHex)`.
  `MeetingCalendar.listening` applies it; `.none` never reaches EventKit (an empty list there means every calendar).

## 8. iPhone shell (`ios/MeetspikeHR/Sources/App/`)

- `AppTab` today, dates, people, ask, live (five tabs). The More screen is not a tab: it is a sheet, and its
  navigation title is "Menu" (the type is still `MoreScreen`). `RootTabView(model:env:)` presents it in a
  `.sheet(isPresented: $env.showMore)` with a Done button (it calls `dismiss`). Tab screens
  (`TodayScreen`, `DatesScreen`, `PeopleScreen`, `AskScreen`) and `MoreScreen` get `AppEnvironment` and `PhoneModel`
  through `@EnvironmentObject`.
- `MoreButton` and the `.moreButton()` view modifier (`App/MoreButton.swift`): a three-line menu icon
  (`line.3.horizontal`, accessibility label "Menu") in the leading top bar that calls `env.openMore()`. It is on all five
  tabs including Live. Today, Dates and People apply `.moreButton()`; Ask and the Live Dashboard each place
  `MoreButton()` directly in their own `ToolbarItem(placement: .topBarLeading)`. The connection banner and the
  "Open Menu" buttons also call `openMore()`.
- Banners are applied per tab, not once at the root: each tab adds `.tabBanners(_ tab: AppTab)` (`App/ConnectionBanner.swift`)
  to the root content inside its `NavigationStack`. It is a top safe-area inset holding the `ConnectionBanner` (when
  `env.issue` is set) and the `UpdateBanner` (when `PhoneModel.availableUpdate` is set, except on Live, which keeps its own
  update card). An inset outside the `TabView` would cover the navigation bar and the menu button.
- The AI key lives in the Menu sheet: the AI key row opens the key form (Change, via `openAskKeyForm()`) and, when a key
  is saved, a "Remove key" button asks for confirmation, deletes the key and the saved chat, and posts
  `.meetspikeAskKeyRemoved`.
- Ask error copy: the Worker's own Ask errors say "in More" (for example "Add your Claude API key in More, then ask
  again."; `DemoAPI`, `APIDemoTests`, `APISSEParserTests` and the fixtures mirror that text on purpose, it is right for
  the web). The app rewrites it for display with `AskLogic.appCopy(_ text: String) -> String`, a pure helper that replaces
  "in More" with "in Menu" as whole words only ("in Moreover" is untouched). Use it on error and failure text shown to
  the person, never on answer text. Call sites: `AskChatSession.finishWithError` (`AskLogic.swift`) applies it to the turn's
  `error` and to `keyProblem`; `AskAnnouncement.message(for:...)` (`AskStore.swift`) applies it to the spoken error;
  iOS `AskModel.message(for:)` applies it to `APIError.message`. The raw `AskFailure.message` from the stream stays as
  the Worker sent it.
- `AppEnvironment` (`@MainActor ObservableObject`): `api: MeetspikeAPI`, `isDemoData`, `selectedTab`, `selectedDay`
  (Today), `datesSpan` (Dates), `today`, `timeZone`, `issue: ConnectionIssue?`, `configurationNote`.
  `noteToday(_:isFromCache:timeZone:)` call with every `ViewResponse.today` (clamps day and span); `isFromCache` is
  required and an offline copy changes nothing. `connectionRevision: Int` (`@Published private(set)`, starts at 0) is
  bumped by `rebuild()` after `api` holds the new connection. `$api` publishes in willSet, so reload on the revision, not
  on `api`: People, PersonView and the Menu (`.task(id:)`) clear what they hold (search cache, gate, pager, status) and
  load again, and drop any answer that started on an older revision. `openDay(_:)`, `openSpan(_:)`
  switch tabs. `openPerson(_ email:)` switches to People and sets the published `pendingPerson: String?`; the People tab
  consumes it (pushes the person page) and sets it back to nil.
  `previousTab: AppTab?` (`@Published private(set)`) is the tab selected before the current one. It is set in
  `selectedTab`'s `willSet`, before the new tab's views see the change, so a lazily created tab can read it in `.task`
  on first appearance. Nil until the first tab change.
  `peopleSpan: DatesSpan?` (`@Published var`) is the range People is showing (preset or custom). nil until People sets
  it; People writes it whenever its range changes.
  `showMore: Bool` (`@Published var`, default false) is true while the Menu sheet is up. `openMore()` sets it true; the
  sheet's Done button and `openAskKeyForm()` clear it.
  `pendingAskKeyForm: Bool` (`@Published var`, default false) is a sticky flag. `openAskKeyForm()` closes the More sheet
  (`showMore = false`), sets the flag true, switches `selectedTab` to `.ask` and also posts `.meetspikeOpenAskKeyForm`. Ask consumes the flag (shows its key
  form) and sets it back to false. `report(_ error) -> Bool` (true = banner covers it, stay quiet), `noteLoaded(_ Loaded<T>)`,
  `noteOnline()`, `rebuild()`. It rebuilds the API itself when sync settings are saved.
- `ConnectionIssue` `.offline(dataFrom: Date?)`, `.accessRejected`. `ConnectionBanner`, `UpdateBanner` live in the root.
- Debug launch arguments: `-demo data` (tab screens read bundled fixtures, starts on Today), `-demo live` and the other
  scenarios unchanged (start on Live), `-tab today|dates|people|ask|live` jump to a tab; `-tab more` starts on the default tab with the More sheet open.
- Demo fixtures: `ios/MeetspikeHR/Resources/DemoData/` (bundled as a folder). A test checks each file equals the same
  file in `Tests/MeetspikeHRCoreTests/Fixtures/`. Change a fixture in both.

### Cross-tab notifications

Declared in `ios/MeetspikeHR/Sources/App/AppNotifications.swift` (the iOS app target, not this package). All on
`NotificationCenter.default`, posted on the main actor.

- `.meetspikeDisplaySourcesChanged` ("com.meetspike.displaySourcesChanged"): `userInfo["source"]` = "oura" | "whoop"
  (read with `Notification.displaySource`, post with `postDisplaySourcesChanged(source:)`). More posts it after a Show
  Oura / Show WHOOP toggle. Today, Dates and People refetch; Ask clears its chat.
- `.meetspikeDataRefreshed` ("com.meetspike.dataRefreshed"): posted after a calendar or wearable sync. Today, Dates and
  People refetch.
- `.meetspikeCompanyRenamed` ("com.meetspike.companyRenamed"): posted by a company page (`postCompanyRenamed()`) after
  a rename. Today, the Companies list (which also drops its saved search answers) and person and company pages refetch.
  Not a sync: Today does not reset its auto-refresh timer.
- `.meetspikeOpenAskKeyForm` ("com.meetspike.openAskKeyForm"): `openAskKeyForm()` (from the Menu's AI key row) posts it after
  closing the Menu sheet and switching to the Ask tab. Ask shows its key form.
- `.meetspikeAskKeyRemoved` ("com.meetspike.askKeyRemoved"): posted by the Menu (`postAskKeyRemoved()`) after Remove key
  deleted the key and the saved chat. A live Ask tab clears its in-memory chat (`AskModel` observes it).

`RefreshPart` also carries `written` and `removed` (meeting counts; the web shows their sum as "N meetings updated").

## 9. Fixtures (`Tests/MeetspikeHRCoreTests/Fixtures/`)

Fake names, example.com emails. Today is 2026-11-24 (EST). view-day, view-empty-day (2026-11-21), view-day-no-wearable,
view-range (2026-11-18 to 11-24), meeting-hr, live-hr, live-hr-inactive, people, people-search, person-meetings, refresh,
refresh-needs-google, calendar-sync, calendars, source-display, source-display-patched, ask-status, ask-status-nokey, ask-key-saved,
ask-key-deleted, err-needs-google, err-needs-key, err-too-long, ask-stream.sse, ask-stream-error.sse, ask-stream-cutoff.sse.
Load in tests with `APIFixture.data(_:)` / `APIFixture.decode(_:_:)` (see `APISupportTests.swift`) and stub the network with
`APIStub` + `APIClient.stubbed(host:)`.
