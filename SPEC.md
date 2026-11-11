# SPEC: 20-20-20

- **Status:** built and installed; rule checks pass; on-screen checks partly run (see Verification status)
- **Last updated:** 2026-11-11
- **Decision basis**
  - From Andreas: the purpose is to not let him skip the break. It must be impossible to game. No exit during a break. It works the same in meetings. A break must not break an ongoing dictation (Wispr Flow). Three real exceptions exist: recording the screen, presenting in person, watching a film. Minimum requirements, lightweight.
  - From Andreas on work hours: it applies only during work hours he can set; one start and end time on chosen weekdays; it starts as every day 08:00–18:00; a change to the hours can only start the next day, except on first startup, which is an onboarding step where he sets them.
  - From Andreas on the margin: 10 extra seconds of black screen before the 20 start, with the counter running from −10 up to 20. No sound. The text on the black screen stays as it is.
  - Chosen by Claude, open to change: the pause rules and their numbers (R6), the countdown in the menu bar during the last minute, reading the clock once per restart (R8).

## Goal

During work hours, every 20 minutes the Mac blacks out every display for 30 seconds: 10 to get to a window, then the 20. Nothing on the Mac ends, shortens, skips or postpones that break.

## Requirements

| ID | Requirement | Accepted when | How it is checked |
| --- | --- | --- | --- |
| R1 | **Break every 20 minutes.** The clock runs on elapsed real time, not the system clock. Only a lock or sleep lasting 20 seconds or more counts as a break and restarts it. | Changing the system date does not move the next break. A 5-second lock does not restart the clock; a 25-second lock does. | Test build with a 60-second interval: change the date, lock for 5 s, lock for 25 s, and read the menu each time. |
| R2 | **Blackout.** Every display is covered for 30 seconds: above full-screen apps, on every Space, over Mission Control, and on a display plugged in mid-break. Clicks do not reach anything. No sound. | Nothing underneath is readable or clickable on any display for the full 30 seconds. | "Break now" with a full-screen app, in Mission Control, and while plugging in a second display. Screenshot of each display. |
| R3 | **No exit.** No button, key, click or gesture ends a break early. | Every attempt fails. | During a break: click, double-click, Esc, Cmd+Q, Cmd+Tab, Cmd+Option+Esc, switch Space. |
| R4 | **Killing it gains nothing.** There is no Quit. If the app is killed it restarts by itself. The break clock survives the restart, and a break that was interrupted starts again from the beginning. | Killed mid-cycle: back within seconds with the same time remaining. Killed mid-break: the blackout returns and runs the full 30 seconds. | Kill the process from a terminal in both situations and time the result. |
| R5 | **Dictation survives.** A break never takes keyboard focus and never touches audio input. | A Wispr Flow dictation that is running when the break starts keeps recording, and its text lands in the app that had the cursor. | Start a dictation, choose "Break now", keep speaking through the blackout, read the result. |
| R6 | **Pause, for the three exceptions only.** The menu offers a pause of 30, 60 or 120 minutes. Choosing it starts a break immediately; the pause begins after that break. A break follows the moment the pause ends. A pause cannot be extended, and no new pause is available for 2 hours after one ends. All of this survives the app being killed. | A pause never removes the break that was coming. The pause items are disabled during a pause and for 2 hours after it. | Test build with shortened times: choose a pause, try to pause again, kill the app during the pause, and watch the break at the end. |
| R7 | **Always running.** Starts at login, sits in the menu bar only (no Dock icon), asks for no permissions. | The eye icon is present after logging in again; no permission prompt is ever shown. | Log out and in once. |
| R8 | **Work hours.** Breaks happen only inside work hours: one start time, one end time (start before end), and a tick per weekday. First startup is onboarding: the Work hours panel opens showing every day 08:00–18:00, it cannot be closed without confirming, and what you confirm applies at once. Until you confirm, every day 08:00–18:00 is enforced, so leaving the panel open gains nothing. Every later change starts at 00:00 the next day. The app reads the date, time and time zone once per restart of the Mac and counts elapsed time from there, so changing the system clock or time zone mid-session moves nothing. Outside work hours nothing happens, including the break that would follow a pause. A break already running at the end time finishes. | A change made today leaves today's hours as they were and shows as "from tomorrow" in the panel. Moving the system clock or time zone outside work hours does not stop the breaks. At the start time the clock begins at 20:00. | Self-test against a fake clock: change the hours mid-day, cross midnight, cross the start and end times, and resume with a saved clock reading and time zone. |
| R9 | **Margin to get to a window.** The first 10 seconds of every blackout are for getting to a window; the 20 seconds start after them. The counter runs from −10 up to 20. The text on screen is the same throughout: "Look at something 20 feet away". | The counter starts at −10, passes 0 after 10 seconds and the blackout ends at 20. | Test build: "Break now" and watch the counter. |

**Menu (the whole interface):** `Next break in 14:32` (outside work hours: `Off until Mon 08:00`), `Break now`, `Pause 30 min`, `Pause 60 min`, `Pause 120 min`, `Work hours…`. Above the pause items one line says a pause starts and ends with a break, and while pausing is locked another says when it is available again. During the last minute the countdown also shows in the menu bar itself.

**Icons:** the menu bar shows an eye. The app icon is the same eye, white on a dark plate; it appears wherever macOS lists the app, such as Login Items, Activity Monitor and menu bar managers.

**Work hours panel (the only setting):** start time, end time, seven weekday ticks, and one line saying when the shown hours take effect.

**Lightweight means:** one Swift source file, no third-party dependencies, no network use, no permissions, no settings beyond the Work hours panel.

## Meetings and shared screens

A call changes nothing. The blackout comes when it is due, and you still hear and can speak. People watching your shared screen will see it: macOS can no longer reliably hide a window from screen sharing (since 15.4, by Apple's own statement), and any softer behaviour in calls would be a way to skip the break.

Before a demo where 30 dark seconds would hurt, use a pause. It costs a break before and a break after.

## How each way around it is closed

| Attempt | Result |
| --- | --- |
| Dismiss or skip during the break | No exit exists (R3) |
| Quit or force-quit | No Quit; the app restarts and resumes, and an interrupted break starts over (R4) |
| Lock and unlock, or close and open the lid, to reset the clock | Only 20 seconds or more of lock or sleep counts, and that is a break (R1) |
| Change the system date or time | The clock runs on elapsed time (R1) |
| Move to another Space, display or full-screen app | All are covered (R2) |
| Hold a microphone open to look like a call | Calls get no special treatment |
| Launch with a longer interval | The interval is fixed in the installed build; only a separate test build can shorten it |
| Chain or extend pauses | One pause, then 2 hours without the option, with a break on both sides (R6) |
| Shorten the work hours to end now | A change starts the next day (R8) |
| Move the system clock or time zone outside work hours | The clock and zone are read once per restart (R8) |

**What it cannot close**

- **Removing it on purpose.** You own the Mac, so you can uninstall it from a terminal, wipe its saved state so it thinks it is starting for the first time, or switch it off under System Settings → General → Login Items. All are deliberate multi-step acts, not a dismiss button. Closing them would mean software running as root that you could still remove with your password.
- **Restarting the Mac.** It resets the 20-minute clock and the pause lock. It also takes longer than the break.
- **Changing the system date and then restarting.** After a restart the app has only the Mac's own clock to go by, so a false date set before restarting can put it outside work hours. Closing this needs the app to fetch the time from the network, which is cut.
- **A legitimate time-zone change** (travel) is picked up at the next restart, not before.
- **Freezing or kill-looping the process from a terminal.** A stopped process (`pkill -STOP`) gets no breaks until it is continued, and a loop that kills the app every second keeps the screen mostly usable. Neither can be closed from inside the app.
- **Working in another user account on the Mac.** The app runs in your account only.
- **Setting almost no work hours for tomorrow.** The form accepts any hours with a start before an end on at least one day, so one visit can make tomorrow nearly empty. The next-day rule is the only friction.
- **Staring at the black screen.** The app guarantees you cannot use the screen. It cannot see where your eyes are. Only the camera could check that, at the cost of a camera permission and the camera light coming on every 20 minutes. Not in this version.

## Cut on purpose

- Call, microphone, camera and screen-share detection
- Skip, snooze, postpone, Quit, statistics, any setting other than work hours
- Different hours per weekday, several blocks per day, hours that cross midnight
- Network time check
- Idle detection, automatic pausing for video or games
- Long breaks, posture and blink reminders
- Notarization, auto-update, App Store

## Technical decisions

- **Swift and AppKit**, compiled with `swiftc` by a build script that assembles `20-20-20.app` (menu-bar-only via `LSUIElement`). No Xcode project. The app is `Sources/main.swift`; `Tests/SelfTests.swift` is compiled into the test build only.
- **Kept alive by launchd.** A per-user LaunchAgent with `KeepAlive` starts the app at login and restarts it if it dies. This replaces a login item. The repository carries `install.sh` and `uninstall.sh`; the uninstall script is the one supported way to remove the app.
- **One owner of state.** A single object owns the cycle and the saved state. The app's one timer only asks it where things stand, and windows display what it says and decide nothing.

  | From | Event | To |
  | --- | --- | --- |
  | Working | 20 minutes elapsed, or "Break now" | Break |
  | Working | lock or sleep of 20 s or more ends | Working, 20:00 |
  | Working | pause chosen (when allowed) | Break, then Paused |
  | Break | 30 seconds elapsed | Working at 20:00, or Paused if a pause was chosen |
  | Paused | pause time elapsed, inside work hours | Break |
  | Off | work hours start | Working, 20:00 |
  | Working or Paused | work hours end | Off |
  | Break | 30 seconds elapsed, work hours have ended | Off |
  | Any | app killed and restarted | Same state, restored from disk; a Break restarts from the beginning |

  No other transition exists. In particular nothing leads from Break to Working or Off except time.

- **One clock.** At the first launch after a restart of the Mac the app records the date, time and time zone once, and from then on derives the time from elapsed time since boot. Work hours, the 20-minute cycle and the pause lock all read this clock and never the live system clock.
- **Saved state:** the current state, its deadline, when a pause is next allowed, the clock reading for this boot session, the work hours in force, and any changed work hours with the day they start. Written on every transition. A different boot session on launch means a fresh clock reading and, inside work hours, a fresh Working at 20:00.
- **Overlay:** one borderless, non-activating window per display at a window level above full-screen apps, joining all Spaces, rebuilt when the display configuration changes.
- **App icon:** drawn by the test build from the same system eye symbol as the menu bar and packed into `Resources/AppIcon.icns`, which is committed. `build.sh` copies it into the app.
- **Lock detection:** the lock and unlock notifications can be posted by any process, so each is confirmed against the system's own session state, and a recorded lock that the system no longer reports is dropped without being counted.
- **Timing:** the app holds a system activity for its whole life so macOS does not nap it and deliver its timers late.

## Commands

| Command | What it does |
| --- | --- |
| `./build.sh` | Builds `build/20-20-20.app` |
| `./build.sh test` | Builds the separate test build (shortened times, a Quit item, its own saved state) |
| `build/20-20-20-test.app/Contents/MacOS/20-20-20-test --self-test` | Runs the rule checks against a fake clock; shows nothing on screen |
| `./install.sh` | Builds, installs to `~/Applications`, and starts it under launchd |
| `build/20-20-20-test.app/Contents/MacOS/20-20-20-test --render-previews <folder>` | Writes pictures of the blackout and the Work hours form; shows nothing on screen |
| `build/20-20-20-test.app/Contents/MacOS/20-20-20-test --reset-state` | Deletes the test build's own saved state |
| `build/20-20-20-test.app/Contents/MacOS/20-20-20-test --render-icon build/AppIcon.iconset` then `iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns` | Redraws the app icon |
| `./uninstall.sh` | Stops and removes the app, its launchd agent, its saved state and the test build's saved state |

Test build switches: `-workSeconds 60`, `-restSeconds 5` (the 10-second margin stays), `-fastPause YES` (pauses of 30, 60 and 120 seconds, 2-minute lock), `-testHours allDay` (skips onboarding and runs at any hour).

Two seconds after launch the test build writes `status-item.json` next to its saved state, saying whether its menu bar icon is on screen. At each blackout it also writes `screen-check.json`: whether every display is covered, what the system has stacked above the blackout, and whether keyboard focus stayed where it was.

## Verification status

**Checked** (2026-11-11, macOS 26.6.2, one 1920x1080 display)

- **Rules (R1, R3, R4, R6, R8, R9).** The self-test passes against a fake clock: the 20-minute cycle, the 30-second break, short and long locks, no way out of a break, kill and restart in every phase, the pause rules, work hours and the next-day change, default hours before onboarding, and the once-per-restart clock.
- **Blackout on the real screen (R2).** The test build ran under launchd with shortened times. During a blackout the system's window list showed the blackout covering the whole display with nothing above it except two or three cursor-sized system items. The same held with Mission Control opened by command a few seconds before the blackout.
- **Focus (R5, in part).** During the blackout the app was not active and had no key window, and the frontmost app stayed the one in use before.
- **Kill and restart under launchd (R4).** Killed mid-cycle: back after 0.1 seconds with the due time unchanged. Killed with 9 seconds of a break left: back after 0.4 seconds with the full break ahead again, and the blackout then ended by itself.
- **Look.** The blackout and the Work hours form were rendered to pictures and inspected: onboarding, a later change, and the "no day ticked" error.
- **Install (R7, in part).** `install.sh` ran; launchd reports the app running from `~/Applications` with start-at-login set.
- **App icon.** The 1024-pixel icon was rendered and inspected, and the installed app carries it.
- **Menu bar icon.** The app creates it with its image, but on this Mac it was placed far off screen. Bartender is running and hides new menu bar items, so the eye and the last-minute countdown are not visible until 20-20-20 is set to always show in Bartender.
- **Independent review.** A separate review of the code looked for ways around a break and found none in the cycle's rules. Its findings on lock detection, on nothing being enforced before onboarding, on the app delegate's lifetime and on timer delays were fixed; the ones that cannot be closed are listed under "What it cannot close".

**Not checked**

1. **Clicks and keys during a blackout (R3).** No click, Esc, Cmd+Q or Cmd+Option+Esc was sent to the real screen, because that means taking over the pointer and keyboard. The code has no handler that ends a break.
2. **A full-screen app, a second display, and a display plugged in mid-break (R2).** None was present during the run.
3. **A real lock or sleep of 20 seconds or more (R1).** This Mac locks the moment the display sleeps, so the test would have locked it. If the system's lock state is not yet set when the notification arrives, a lock will not count, which errs toward more breaks, not fewer.
4. **A real Wispr Flow dictation through a blackout (R5).**
5. **Logging out and in (R7).**
