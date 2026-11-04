# Weekly usage in the notch, and pace

Status: v2 and v3.1 approved by Ben and built 2026-11-04 (branch weekly-pace). Owner: Ben.

## Concepts brief

**Ask (Ben, 2026-11-04).** "Can we update the buddy application that shows percentages to have a toggle for weekly
limit as well, and if you're currently on pace to hit it?"

**What exists.** The notch pill shows the 5-hour session window beside Buddy: "≈64%" (estimate) or "64%" (exact)
over its reset time, tinted orange at 70% and red at 90%, with a countdown to the session reset just right of the
notch. The open list's top row shows a Session meter and, when exact usage is on, a Week meter with the weekday and
hour it resets. Exact usage (`ExactUsage.parse`) already reads Anthropic's `seven_day` window into
`UsageReading.week`; the local estimate (`UsageEstimate`) has no weekly figure. The left ear is 84 pt wide (12 pt
inset, the pup at 0.66 of the bar height, then the badge); nothing may reach under the camera.

**Goal.** Choose which window the pill shows (Session or Week), and show pace: how much of the window's usage is
gone against how much of its time has passed, carried forward to say where it ends up by the reset and, if it
runs out first, when. Ben, on the draft: "I like the on pace metric a lot actually, how much usage you've used as a
percent of your 5 hour or 7 day period with time passed taken into consideration to see when you'll run out of
usage".

## Design

### 1. The toggle

- Settings → Usage: a segmented control "In the notch: Session | Week", stored as `notchWindow` ("session" by
  default). The pill's right-click menu gets the same choice as "Show Week in the Notch" (a checkmark item), so it can
  be flipped without opening Settings.
- **Week needs exact usage.** With exact usage off, Week is disabled in Settings with the line "Weekly usage needs
  Exact usage from Anthropic", and the menu item is hidden. If exact usage stops reading (sign-in expired, offline)
  while Week is chosen, the pill falls back to the session estimate until the week reads again; the choice is kept.
- When Week is shown, the badge's second line is the reset weekday and hour ("Thu 3p") instead of a clock time, and
  the countdown right of the notch counts to the week's reset ("2d 4h", then the existing "4h 12m" and "14:25"
  forms). `Store.shortCountdown` gains a days form for intervals of 24 hours or more.

### 2. Pace

For a window of length L (5 hours or 7 days) that resets at R, with p percent used at time now:
- start = R − L, elapsed = now − start.
- No pace is shown until the window has run long enough for a rate to mean something: elapsed ≥ 30 minutes for the
  session, ≥ 12 hours for the week, and p ≥ 5.
- Projected use at reset = p × L / elapsed (the average rate so far, carried to the end of the window).
- **On pace to run out** when projected ≥ 100. The run-out time is start + elapsed × 100 / p, which is before R.
- A pure function `UsagePace.pace(percent:resetsAt:length:now:) -> Pace?` with `projected` and `runsOutAt`, tested
  in `Tests/main.swift` (both windows, the minimum-elapsed and minimum-percent cutoffs, exactly 100%, a reset already
  past, and a window that started before a clock change).

### 3. How pace shows

The pace number is the projected use at reset, rounded: "on pace for 130%" means the window would be used up and
then some at today's rate; "on pace for 60%" means about 40% would be left at the reset.

- **Pill:** when the shown window is on pace to run out, its second line becomes the run-out time in orange ("out
  Thu" for the week, "out 3:40" for the session) instead of the reset time, and the help text says "On pace to use
  your weekly limit by Thu 2 PM, before it resets Sat 9 AM". The percent keeps its own 70/90 tint.
- **Open list:** each meter gets a short line under it whenever pace is known: "On pace for 60% by Sat 9 AM" in
  the secondary color, or, when it runs out first, "On pace for 130%: runs out Thu 2 PM" in orange.
- Both windows get pace, since the math is the same; the pill only shows the chosen one.

### 4. Not in this change

- No weekly estimate from transcripts: weekly limits are hit rarely, so there is too little to calibrate on, and a
  wrong weekly number is worse than none.
- No notifications or sounds for pace; it is shown, not announced.
- The average-rate pace is simple and honest about what it is; a recent-rate pace (last 24 hours) would need stored
  history and is left for later if the average turns out misleading.

## Build

`Sources/Usage.swift` (UsagePace), `Sources/Model.swift` (`notchWindow` setting), `Sources/Views.swift` (badge,
countdown, meters, menu item), `Sources/UI.swift` (which window `showsUsage` and `resetCountdown` follow),
`Sources/SettingsView.swift` (the control), `Tests/main.swift`; `./build.sh demo` images refreshed for the README and
site. Version: a new user-facing feature, so a MINOR bump when it ships (0.11.0).

## v2: what the review changed (this section wins over the ones above)

**Pace is honest about what it is.**
- `UsagePace.pace(percent:resetsAt:length:now:) -> Pace?`, `struct Pace { projected: Double; runsOutAt: Date? }`,
  in `Usage.swift` (so the tests reach it). start = resetsAt − length, elapsed = now − start.
- nil when: `resetsAt` is nil or not after now; elapsed ≤ 0 or > length (a stale or moved reset); percent < 3 or
  percent ≥ 100 (at the limit the existing "limit reached" state speaks); or too early: elapsed under 1 hour for the
  session (20% of it) or under 24 hours for the week. A heavy first day would otherwise project a false "runs out".
- projected = percent × length / elapsed. `runsOutAt` only when the rounded projection is over 100: start + elapsed ×
  100 / percent, rounded to 5 minutes so a slightly moving reset time does not make it jitter.
- **Exact readings only.** The session estimate's window start is itself a guess, so no pace is shown on "≈".
- Words: "at this rate", never "you will". The number is "→130%": where the window ends up by its reset at the
  average rate so far.

**The pill.**
- One toggle, in the right-click menu: "Show Weekly Usage in the Notch" (a `Toggle`), shown only while exact usage is
  on. Stored as `Store.notchWindow` (enum `session`/`week`, defaults key `notchWindow`, default `session`). No Settings
  control.
- Which window the pill shows is a pure function in `Usage.swift`: the week only when Week is chosen, the reading is
  exact, the week window exists with a reset time, and no chat is paused by a limit (then the pill shows the session,
  so it matches the purple limit countdown beside it). Otherwise the session, with the help text saying "Weekly usage
  unavailable, showing session" when Week was chosen.
- Line 1: the percent as today; the week gets a small secondary "W" before it ("W 41%") so the two can never be
  confused. Line 2: the pace "→130%" when known (orange over 100, secondary otherwise), else the reset as today (clock
  time for the session, short weekday "Thu" for the week). All of these are at most five characters at the existing
  sizes, inside the badge's room (84 − 12 − pup − 12 pt), which `./build.sh demo` renders to check.
- The countdown right of the notch stays on the session reset (or the limit), the more actionable clock; no days
  format.
- Help text, full sentence: "Week: 41% used. At this rate, 130% of the limit by the reset (Sat 9 AM); runs out
  around Thu 2:05 PM." or "...; about 30% left at the reset."

**The open list.** Each meter adds "→NN%" after its reset text when pace is known (orange over 100), on the same line,
so the row keeps its 26 pt height and the swipe hit-testing is unchanged; the meter's help text carries the sentence.

**Tests (`Tests/main.swift`).** Session 50% at 2.5 h → 100, no run-out (not over 100); session 60% at 2.5 h → 120,
run-out 4 h 10 min after the window started; week 60% at 3.5 d → 120, run-out at 5 d 20 h; nil at 59 min (session), 23 h 59 min
(week), percent 2, percent 100, reset past, reset nil, elapsed over the length; the shown-window rule (exact off,
week missing, paused chats, week chosen and available).

**Ships as 0.11.0** (a new feature): `Info.plist` and `CHANGELOG.md`.

### Review log (v1)

- **Design:** early-week extrapolation would raise false alarms (24 h and 1 h minimums, "at this rate" wording);
  pace on the estimate had no basis (exact only); nil cases for a past, missing or moved reset and the 100% boundary
  (defined); a silent fallback and two different clocks during a limit pause (help text; session shown while paused);
  "out Thu" did not fit and read like the reset day (pace number instead); the open-list line broke the fixed row
  (same line).
- **Implementation readiness:** the function contract, the setting's home and key, the shown-window rule, the UI
  changes and the tests (all specified above); a segmented Settings picker cannot disable one segment (dropped).
- **Scope:** two toggle surfaces (menu only); pace hidden unless over 100 (the number is always shown when known);
  the days countdown and the clock-change test (dropped).

## v3 draft: pace that knows your hours

**Ask (Ben, 2026-11-04).** "Have buddy learn habits over time, like there will be zero usage from 2am-7am, so the
usage prediction can be optimized. Should be easy enough to build an internal usage model over time automatically,
right?"

**Idea.** v2 projects with the share of the window's *time* that has passed. v3 uses the share of your *usual usage*
that normally falls in that part of the window. If nothing ever happens 2-7 am, those hours count for almost
nothing, so a heavy evening no longer projects a run-out through the night, and a quiet morning before a usual busy
afternoon is not read as "plenty left".

**The model.**
- Source: the replies Buddy already reads from this Mac's transcripts (time and weighted tokens, `UsageEstimate`).
  It sees only this Mac; Claude used elsewhere (the web, a phone, another Mac) is in Anthropic's exact percent but not
  in the shape. Stated in the help text.
- Store: hourly totals keyed by local clock hour (`2026-11-04T14`), 28 days, in
  `~/Library/Application Support/Buddy/habits.json` (at most 672 numbers; no message text, no file names). Each scan
  rewrites the hours its 3-day reply window covers (so a reply is never counted twice) and leaves older hours alone.
  On first launch with no file, a background backfill reads 28 days of transcripts once (low priority, cancelled on
  quit, resumed next time).
- Profile: for each of the 168 hours of the week, the mean of that hour's totals over the weeks the store covers, plus
  a small floor (2% of the mean hourly total) so an hour you have never used still counts a little.
- **Habit share** for a window from start to reset at time now: S(now) / S(reset), where S(t) sums the profile from
  start to t (the current hour pro rata).
- projected = percent / habit share. Runs out where S(t) = S(now) × 100 / percent, found by walking the hours; rounded
  to 5 minutes as in v2.
- **When it is used:** only with at least 14 days of hours in the store and a window whose expected usage S(reset) is
  above the floor; otherwise v2's time-based pace. The help text says which one is shown ("by your usual hours" or
  "by time").
- The v2 minimums (1 hour of a session, 24 hours of a week, 3% used, exact readings only) stay.

**Tests.** A profile with nothing 2-7 am: a session that starts at midnight at 50% by 1 am projects lower than the
time-based pace; a weekday-heavy profile shifts a Monday projection up and a Saturday one down; fewer than 14 days
falls back; the store merges a re-scan without double counting and drops hours older than 28 days; DST (a 23- or
25-hour day) keeps the hour keys local and the profile intact.

**Not in v3.** No sharing of the profile anywhere, no network use, no setting to turn it off (it only changes the
projection, and the help text says when it applies).

## v3.1: what the v3 review changed (this wins over "v3 draft")

Two Sonnet Goldfish reviewers (design, implementation readiness) read v3. Changes:

**The week only.** A 5-hour session that has started is conditioned on activity, so an all-days hourly mean has the
wrong shape for it; the session keeps v2's time-based pace.

**The estimator.** v3's `percent / habit share` treated a surplus as a rate (a heavy Monday projected a whole week of
heavy Mondays). Now the future comes from your habits and the conversion from what actually happened:
- `local` = weighted tokens Buddy saw on this Mac since the week started; `k` = percent / `local` (percent of the
  limit per weighted unit, this week, which absorbs use on other devices as long as they keep a similar proportion).
- `ahead` = the profile's expected weighted tokens from now to the reset.
- **projected = percent + k × ahead.** Runs out where percent + k × (expected use from now to t) reaches 100, found
  by walking hours (linear within an hour), capped at the reset, rounded to 5 minutes.
- **Never below the recent burn:** projected is at least percent + k × (weighted tokens in the last 2 hours) ×
  min(time left, 2 h) / 2 h, so working off your usual hours (3 am) never reads as "plenty left".
- Falls back to v2's time-based pace when `local` is under 2% of a typical week's local use (the percent came mostly
  from elsewhere), or when the profile is not ready.

**The store.**
- `~/Library/Application Support/Buddy/habits.json`, mode 0600, written atomically:
  `{"version":1,"scannedThrough":<epoch>,"hours":{"<UTC hour epoch>":[weighted tokens, local UTC offset seconds]}}`.
  UTC keys, so a daylight-saving change or travel never merges or loses an hour; the profile places each hour by its
  own recorded offset.
- After each scan, Buddy rewrites only whole hours from the first full hour after the scan's 3-day cutoff up to the
  current hour (hours with no replies become 0), so the partial edge hour is never overwritten with a partial total.
- **Gaps:** when `scannedThrough` is more than 3 days old (first run, or Buddy was off), a catch-up reads the missing
  span (up to 28 days) in small time-sliced batches on the scanner's own serial queue, with message-id dedupe across
  files and transcripts read in chunks rather than whole, so the 3-minute refresh is never blocked for long. Hours
  older than 28 days are pruned.
- A right-click menu item "Forget Usage Habits" deletes the file. The help text says the shape comes from this Mac
  only, and that hours with the Mac asleep count as no use.

**The profile.** For each of the 168 local hours of the week, the median of that hour across the weeks stored (so a
holiday or a trip does not drag it), plus a floor of 2% of the mean hourly use over all stored hours. Ready once the
store spans at least 21 days.

**Words.** Habit mode says "At your usual pace" in the hover sentence ("At your usual pace, 130% of the limit by the
reset (Sat 9 AM); runs out around Thu 2:05 PM. Learned from Claude on this Mac."); time mode keeps "At this rate".
`UsagePace` carries `basis` (`.habits` or `.time`).

**Tests.** The estimator: a heavy first day does not project the heavy day forward (surplus case); 3 am work with
an empty-night profile is held up by the recent-burn floor; little local use falls back to time. The store: the
partial edge hour is not overwritten; a re-scan does not double count; a daylight-saving week keeps 167 or 169 hours
right; pruning; round-trip and a corrupt file starting empty; file mode 0600. The profile: median across weeks;
not ready under 21 days.

**Ships as 0.11.0** together with v2.

## As built (v3.1, 2026-11-04)

- `Sources/Habits.swift`: `HabitData` (the file), `HabitProfile` (median weekly shape, floor, 21-day readiness,
  `expected` and `reaches` walking UTC hours with each hour's local offset), `UsagePace.weekPace` (percent + k × the
  habit's expected use, never below the recent burn for 2 hours), `HabitKeeper` (load, atomic 0600 save, forget,
  `update` after each scan with a 0.4-second catch-up slice).
- `UsageScanner`: `hourTotals` (whole hours after the 3-day cutoff), `weight(since:)`, `catchUp` (time-sliced, 1 MB
  chunks, message-id dedupe) and the shared `replyWeight` the regular scan now uses too.
- The views use one `pace(_:week:)` for the pill and the open list, so they always agree: habits for the week when
  ready, else time. Right-click menu: "Forget Usage Habits".
- Tests (221 checks, from 203): the heavy-Monday case (about 122% by habits against 280% by time), the 3 am burn
  floor and its run-out time, little local use falling back, the first 24 hours, hour placement by recorded offset,
  the floor, readiness, set and prune, the 0600 file, a corrupt file, forget, the partial edge hour, and the catch-up
  reading a streamed reply once. Removing the burn floor or including the edge hour makes them fail (checked).

## v4 draft: ten improvements (Ben, 2026-11-04: "Do all 10, merge, release")

**Projection**
1. **Daily budget.** Week only: (100 − percent) / days left until the reset (fractional), shown as "≈12% a day to Sat
   9 AM" in the week meter's help, the pill's help, and the week strip's caption. Hidden when under 0.5% a day or
   with under 6 hours left.
2. **Learned share.** `HabitData` gains `weeks: [[resetEpoch, finalPercent, localTokens, meanAbsError]]` (last 8).
   When a new exact week reading's reset is later than the stored one, the finished week is recorded from the last
   reading before the change (its percent) and the store (its local tokens). `kLearned` = median of finalPercent /
   localTokens over recorded weeks with localTokens > 0. In `weekPace`, k = `kLearned` when this week's local use is
   under 10% of a typical week, else this week's k; with `kLearned` the minimum wait drops from 24 h to 6 h.
3. **Self-grading.** Each day the week's latest projection is kept (`dailyProjections: [dayIndex: projected]`, reset
   with the week). At the reset, mean |projected − final| over the days becomes that week's `meanAbsError`. Settings
   shows "Forecasts were off by 6 points on average over the last 4 weeks" once there is one finished week.
4. **Uncertainty.** A band of ± the median `meanAbsError` (default ± 20 points when no week is graded, ± 10 once
   three are), shrinking linearly to ± 0 at the reset. The help text gives the range ("→110–140%"); the pill and the
   meter show the single number, dimmed (60% opacity) while the band is over ± 15 points.
5. **Opus week.** `ExactUsage.parse` also reads `seven_day_opus`; `UsageReading.opusWeek`. When present the open list
   adds an "Opus" row with its own pace (time-based; habits are not split by model).

**UI**
6. **Week strip.** Under the meters, seven day columns (Mon to Sun in the week's window order, oldest left): the bar
   is this Mac's weighted use that day, scaled to the largest day; a faint outline behind it is the usual day from
   the habit profile once ready. Today's column is outlined. Caption: the daily budget. 34 pt tall; shown only when
   exact usage is on and the store has hours for the week. `usageSpace` includes it.
7. **Habits in Settings.** In Usage: "Learned from 26 days on this Mac" (or "Learning: 9 of 21 days"), the forecast
   accuracy line, and a Forget Usage Habits button (the menu item stays).
8. **Option-click** on the pill's header flips Session and Week (a plain click still opens the top chat).
9. **Heads-up.** Settings toggle "Warn me when the week will run out early" (off by default; turning it on asks for
   notification permission). One notification per week, when the week's pace says it runs out more than 24 hours
   before the reset: "At your usual pace your weekly limit runs out around Thu 6 PM, two days before it resets."
10. **Not color alone.** An `exclamationmark.triangle.fill` (9 pt) before the run-out time in the meter and before the
    pace in the pill when it runs out first; accessibility labels on the badge, meters and strip.

**Tests.** Budget arithmetic and its hiding rules; learned share recorded on a reset change and its median;
k switching and the 6-hour wait; grading over daily projections; the band and its shrink; Opus parsing; the strip's
day bucketing in the window's order; the heads-up's once-per-week rule. Ships as 0.11.0 with v2 and v3.1.

## v4.1: what the v4 review changed (this wins over "v4 draft")

- **Old habits files keep working.** `HabitData` decodes every field with a default (`init(from:)` with
  `decodeIfPresent`), so a 0.11.0 file written before v4 loads instead of being replaced by an empty one.
- **Week ends are detected on the scanner's queue.** `HabitKeeper.observe(_:now:)` runs on `scanQueue` after each
  successful exact reading. It keeps `lastWeek` (reset, percent, read time) in the file. A reset more than an hour
  later than the stored one ends the stored week, which is recorded only if its last reading was within 6 hours of
  its reset, the catch-up was finished and the store covers the whole week (else the share would be skewed). The
  same reset seen twice changes nothing. Recording does not wait for the profile.
- **Grading by lead time.** For the current week the store keeps the first projection made at or after day 2, 4
  and 6 of the window (24-hour slots from reset − 7 days), made in `observe` once per refresh. At the week's end each
  is graded as |min(projected, 100) − final|. Settings reports the day-4 error: "Mid-week forecasts were off by 6
  points on average (4 weeks)".
- **Learned share blends.** k = w × this week's k + (1 − w) × learned k, with w = this week's local use / 20% of a
  typical week, capped at 1; without a learned k, v3.1's 2% rule. Weeks that ended at 100% are left out of the
  learned k. With a learned k the minimum wait is 6 hours. The assumption that other devices keep a similar share is
  stated in the help.
- **The band** is the median error at the forecast's lead time over graded weeks: ±20 with none, moving linearly to
  that median by three. Shown as a range in the help text; the pill and meter dim to 75% while it is over ±15.
- **The heads-up** fires only on the habits basis when the low end of the range is still over 100% and the run-out
  is more than 24 hours before the reset; once per reset, remembered in UserDefaults (so Forget does not re-arm it).
  `UNUserNotificationCenter` with a delegate that presents banners while Buddy is frontmost; permission asked when
  the toggle is turned on; Settings shows "Notifications are off for Buddy in System Settings" when denied.
- **The daily budget** is labelled as even pacing ("about 12% a day at an even pace to Sat 9 AM"), for both weekly
  windows, hidden at or over 100%.
- **The strip** is seven 24-hour slots from the window's start, labelled with the weekday letter of each slot's start;
  bars and the usual-day outlines share one scale; today's outline is the usual use up to now. Its 40 pt is reserved
  whenever exact usage has a week, so the panel does not jump when data arrives.
- **Forget** clears weeks and projections too, and a generation number keeps an in-flight update from putting
  forgotten habits back.
- **Opus** row hidden when `seven_day_opus` is null or has no utilization; time-based pace only; not a notch choice.
- **Option-click** saves the choice like the menu toggle; the pill still shows the session while a limit pauses chats.
- "Learned from N days" is the span from the oldest stored hour to the last scan, not the number of hours.
