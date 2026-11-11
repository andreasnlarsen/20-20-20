import AppKit

// Compiled into the test build only (./build.sh test).
//   --self-test                 checks the cycle's rules against a fake clock, without showing anything
//   --render-previews <folder>  writes pictures of the blackout and the Work hours form, without showing them
//   --reset-state               deletes the test build's own saved state
// While running, each blackout writes screen-check.json next to the test state: whether every display is
// covered, what the system has stacked above the blackout, and whether keyboard focus stayed where it was.

final class FakeClock: Clock {
    var now: TimeInterval = 0
    let calendar: Calendar

    /// `text` is local time in Europe/Oslo, for example "2026-11-11 10:00:00" (a Wednesday).
    init(_ text: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Oslo")!
        self.calendar = calendar
        set(text)
    }

    func set(_ text: String) {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        now = formatter.date(from: text)!.timeIntervalSince1970
    }

    func advance(_ seconds: TimeInterval) { now += seconds }
}

final class MemoryStore: StateStore {
    var state = SavedState()
    func load() -> SavedState { state }
    func save(_ state: SavedState) { self.state = state }
}

private var failures = 0

private func check(_ condition: Bool, _ what: String, line: Int = #line) {
    if condition {
        print("  ok    \(what)")
    } else {
        failures += 1
        print("  FAIL  \(what)  (SelfTests.swift:\(line))")
    }
}

/// A cycle that has been through onboarding with `hours`, at the fake clock's current time.
private func onboardedCycle(_ clock: FakeClock, _ store: MemoryStore, hours: WorkHours = .everyDay8to18) -> BreakCycle {
    let cycle = BreakCycle(
        state: store.load(), resumedInSameBootSession: true, clock: clock, store: store, timing: Timing())
    cycle.setWorkHours(hours)
    cycle.tick()
    return cycle
}

/// The app being killed and restarted by launchd in the same boot session.
private func restarted(_ clock: FakeClock, _ store: MemoryStore, sameBoot: Bool = true) -> BreakCycle {
    BreakCycle(state: store.load(), resumedInSameBootSession: sameBoot, clock: clock, store: store, timing: Timing())
}

func runSelfTests() -> Bool {
    print("R1  break every 20 minutes")
    do {
        let clock = FakeClock("2026-11-11 10:00:00"), store = MemoryStore()
        let cycle = onboardedCycle(clock, store)
        check(cycle.phase == .working(dueAt: clock.now + 1200), "starts working with 20:00 on the clock")
        clock.advance(1199)
        check(cycle.tick().isEmpty && cycle.phase == .working(dueAt: clock.now + 1), "no break at 19:59")
        clock.advance(1)
        check(cycle.tick() == [.breakStarted], "break starts at 20:00")
        check(cycle.phase == .onBreak(endsAt: clock.now + 30, thenPauseFor: nil), "break lasts 30 seconds: 10 to get to a window, then the 20")
        clock.advance(29)
        check(cycle.tick().isEmpty, "break still running after 29 seconds")
        clock.advance(1)
        check(cycle.tick() == [.breakEnded], "break ends after 30 seconds")
        check(cycle.phase == .working(dueAt: clock.now + 1200), "clock restarts at 20:00 after the break")
    }

    print("R1  lock and sleep")
    do {
        let clock = FakeClock("2026-11-11 10:00:00"), store = MemoryStore()
        let cycle = onboardedCycle(clock, store)
        let due = clock.now + 1200
        clock.advance(600)
        cycle.screenBecameUnavailable(.locked)
        clock.advance(5)
        _ = cycle.screenBecameAvailable(.locked)
        check(cycle.phase == .working(dueAt: due), "a 5-second lock does not restart the clock")
        cycle.screenBecameUnavailable(.locked)
        clock.advance(25)
        _ = cycle.screenBecameAvailable(.locked)
        check(cycle.phase == .working(dueAt: clock.now + 1200), "a 25-second lock restarts the clock")
        _ = cycle.screenBecameAvailable(.displaysAsleep)
        check(cycle.phase == .working(dueAt: clock.now + 1200), "a wake with no sleep before it changes nothing")
        let dueBeforeStaleLock = clock.now + 1200
        cycle.screenBecameUnavailable(.locked)
        clock.advance(2)
        cycle.forgetAbsence(.locked)
        clock.advance(600)
        _ = cycle.screenBecameAvailable(.locked)
        check(cycle.phase == .working(dueAt: dueBeforeStaleLock), "a lock whose unlock was never reported is not credited later")
        clock.advance(598)
        cycle.tick()
        clock.advance(30)
        cycle.tick()

        _ = cycle.breakNow()
        cycle.screenBecameUnavailable(.displaysAsleep)
        clock.advance(5)
        check(cycle.screenBecameAvailable(.displaysAsleep).isEmpty, "5 seconds of display sleep does not end a break")
        cycle.screenBecameUnavailable(.systemAsleep)
        clock.advance(25)
        check(cycle.screenBecameAvailable(.systemAsleep) == [.breakEnded], "sleeping through a break ends it")
    }

    print("R3  no exit from a break")
    do {
        let clock = FakeClock("2026-11-11 10:00:00"), store = MemoryStore()
        let cycle = onboardedCycle(clock, store)
        _ = cycle.breakNow()
        let during = cycle.phase
        check(cycle.breakNow().isEmpty && cycle.phase == during, "Break now does nothing during a break")
        check(!cycle.canPause && cycle.pause(for: 1800).isEmpty && cycle.phase == during, "no pause during a break")
        cycle.setWorkHours(WorkHours(startMinute: 0, endMinute: 1, weekdays: [1]))
        check(cycle.tick().isEmpty && cycle.phase == during, "changing work hours does not end a break")
    }

    print("R4  killing the app gains nothing")
    do {
        let clock = FakeClock("2026-11-11 10:00:00"), store = MemoryStore()
        var cycle = onboardedCycle(clock, store)
        let due = clock.now + 1200
        clock.advance(300)
        cycle = restarted(clock, store)
        check(cycle.phase == .working(dueAt: due), "killed mid-cycle: same time remaining")

        _ = cycle.breakNow()
        clock.advance(15)
        cycle = restarted(clock, store)
        check(cycle.phase == .onBreak(endsAt: clock.now + 30, thenPauseFor: nil), "killed mid-break: the full break again")

        clock.advance(30)
        cycle.tick()
        clock.advance(1300)
        cycle = restarted(clock, store)
        check(cycle.tick() == [.breakStarted], "killed past the due time: the break starts at once")

        cycle = restarted(clock, store, sameBoot: false)
        cycle.tick()
        check(cycle.phase == .working(dueAt: clock.now + 1200), "after a restart of the Mac: a fresh 20:00")
    }

    print("R6  pause")
    do {
        let clock = FakeClock("2026-11-11 10:00:00"), store = MemoryStore()
        var cycle = onboardedCycle(clock, store)
        check(cycle.canPause, "pause is available while working")
        check(cycle.pause(for: 1800) == [.breakStarted], "choosing a pause starts a break first")
        check(!cycle.canPause, "no second pause during that break")
        clock.advance(10)
        cycle = restarted(clock, store)
        check(cycle.phase == .onBreak(endsAt: clock.now + 30, thenPauseFor: 1800), "killed in that break: full break, pause kept")
        clock.advance(30)
        check(cycle.tick() == [.breakEnded], "the break before the pause ends")
        check(cycle.phase == .paused(until: clock.now + 1800), "the pause runs for 30 minutes")
        check(!cycle.canPause && cycle.pause(for: 7200).isEmpty, "a pause cannot be extended")
        check(cycle.breakNow().isEmpty, "Break now does nothing during a pause")
        clock.advance(900)
        cycle = restarted(clock, store)
        check(cycle.phase == .paused(until: clock.now + 900), "killed during the pause: same pause")
        clock.advance(899)
        check(cycle.tick().isEmpty, "still paused one second before the end")
        clock.advance(1)
        let pauseEnded = clock.now
        check(cycle.tick() == [.breakStarted], "a break starts the moment the pause ends")
        clock.advance(30)
        cycle.tick()
        check(!cycle.canPause, "no new pause right after one")
        clock.now = pauseEnded + 7200 - 1
        cycle = restarted(clock, store)
        check(!cycle.canPause, "still locked just under 2 hours later, even after being killed")
    }
    do {
        let clock = FakeClock("2026-11-11 10:00:00"), store = MemoryStore()
        let cycle = onboardedCycle(clock, store)
        _ = cycle.pause(for: 1800)
        clock.advance(30)
        cycle.tick()
        clock.advance(1800)
        cycle.tick()
        clock.advance(30)
        cycle.tick()
        clock.advance(7200)
        cycle.tick()
        if case .onBreak = cycle.phase { clock.advance(30); cycle.tick() }
        check(cycle.canPause, "pause is available again 2 hours after the last one ended")
    }

    print("R8  work hours")
    do {
        let clock = FakeClock("2026-11-11 10:00:00"), store = MemoryStore()
        let fresh = BreakCycle(
            state: store.load(), resumedInSameBootSession: true, clock: clock, store: store, timing: Timing())
        fresh.tick()
        check(!fresh.isOnboarded && fresh.phase == .working(dueAt: clock.now + 1200),
              "until onboarding is confirmed, every day 08:00–18:00 is enforced")
        fresh.setWorkHours(.everyDay8to18)
        fresh.tick()
        check(fresh.isOnboarded && fresh.state.nextHours == nil, "hours confirmed in onboarding apply at once")

        let lateStore = MemoryStore()
        let late = BreakCycle(
            state: lateStore.load(), resumedInSameBootSession: true, clock: clock, store: lateStore, timing: Timing())
        late.tick()
        late.setWorkHours(WorkHours(startMinute: 11 * 60, endMinute: 18 * 60, weekdays: Set(1...7)))
        late.tick()
        check(late.phase == .off, "onboarding hours that start later take effect the same day")

        let shorter = WorkHours(startMinute: 8 * 60, endMinute: 10 * 60 + 1, weekdays: Set(1...7))
        fresh.setWorkHours(shorter)
        check(fresh.state.hours == .everyDay8to18 && fresh.state.nextHours == shorter, "a later change waits")
        clock.set("2026-11-11 17:30:00")
        fresh.tick()
        check(fresh.phase != .off, "today keeps the old hours")
        fresh.setWorkHours(.everyDay8to18)
        check(fresh.state.nextHours == nil, "saving today's hours again drops the waiting change")
        fresh.setWorkHours(shorter)
        fresh.setWorkHours(WorkHours(startMinute: 600, endMinute: 540, weekdays: [2]))
        fresh.setWorkHours(WorkHours(startMinute: 540, endMinute: 600, weekdays: []))
        check(fresh.state.nextHours == shorter, "hours that make no sense are refused")
        clock.set("2026-11-11 23:59:59")
        fresh.tick()
        check(fresh.state.hours == .everyDay8to18, "the change has not started at 23:59:59")
        clock.set("2026-11-12 00:00:00")
        fresh.tick()
        check(fresh.state.hours == shorter && fresh.state.nextHours == nil, "the change starts at 00:00 the next day")
        clock.set("2026-11-12 10:00:30")
        fresh.tick()
        check(fresh.phase != .off, "the new end time is not reached at 10:00")
        clock.set("2026-11-12 10:01:00")
        fresh.tick()
        check(fresh.phase == .off, "off at the new end time")
    }
    do {
        let clock = FakeClock("2026-11-11 19:00:00"), store = MemoryStore()
        let cycle = onboardedCycle(clock, store)
        check(cycle.phase == .off, "off outside work hours")
        let tomorrowStart = FakeClock("2026-11-12 08:00:00").now
        check(cycle.nextWorkStart() == tomorrowStart, "next start is tomorrow 08:00")
        check(!cycle.canPause, "no pause outside work hours")
        clock.set("2026-11-12 07:59:59")
        cycle.tick()
        check(cycle.phase == .off, "still off one second before the start")
        clock.set("2026-11-12 08:00:00")
        cycle.tick()
        check(cycle.phase == .working(dueAt: clock.now + 1200), "at the start time the clock begins at 20:00")

        clock.set("2026-11-12 17:59:50")
        cycle.tick()
        _ = cycle.breakNow()
        clock.set("2026-11-12 18:00:05")
        check(cycle.tick().isEmpty, "a break running at the end time keeps running")
        clock.set("2026-11-12 18:00:20")
        check(cycle.tick() == [.breakEnded] && cycle.phase == .off, "then it finishes and the app is off")
    }
    do {
        let clock = FakeClock("2026-11-11 17:00:00"), store = MemoryStore()
        let cycle = onboardedCycle(clock, store)
        _ = cycle.pause(for: 3600)
        clock.advance(30)
        cycle.tick()
        clock.set("2026-11-11 18:00:30")
        check(cycle.tick().isEmpty && cycle.phase == .off, "a pause that ends outside work hours brings no break")
    }
    do {
        let weekdaysOnly = WorkHours(startMinute: 8 * 60, endMinute: 16 * 60, weekdays: [2, 3, 4, 5, 6])
        let clock = FakeClock("2026-11-13 12:00:00"), store = MemoryStore()   // a Friday
        let cycle = onboardedCycle(clock, store, hours: weekdaysOnly)
        check(cycle.phase != .off, "Friday is a work day")
        clock.set("2026-11-14 12:00:00")
        cycle.tick()
        check(cycle.phase == .off, "Saturday is not")
        check(cycle.nextWorkStart() == FakeClock("2026-11-16 08:00:00").now, "next start is Monday 08:00")
    }

    print("R8  the clock is read once per restart of the Mac")
    do {
        let first = BootClock(saved: nil, bootSession: "boot-A")
        var moved = first.reading
        moved.wallTime -= 3600
        moved.timeZone = "Asia/Tokyo"
        let resumed = BootClock(saved: moved, bootSession: "boot-A")
        check(abs(resumed.now - (first.now - 3600)) < 1, "same boot: the saved reading is used, not the system clock")
        check(resumed.calendar.timeZone.identifier == "Asia/Tokyo", "same boot: the saved time zone is used")
        let rebooted = BootClock(saved: moved, bootSession: "boot-B")
        check(abs(rebooted.now - Date().timeIntervalSince1970) < 1, "new boot: the system clock is read again")
        check(rebooted.reading.bootSession == "boot-B", "new boot: a new reading is taken")
    }

    print("Saved state")
    do {
        let temporary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
        let folder = temporary.appendingPathComponent("20-20-20-selftest-\(UUID().uuidString)")
        let store = FileStateStore(url: folder.appendingPathComponent("state.json"))
        check(store.load() == SavedState(), "no file: first startup")
        var state = SavedState()
        state.phase = .onBreak(endsAt: 123, thenPauseFor: 1800)
        state.hours = .everyDay8to18
        state.pauseLockedUntil = 456
        store.save(state)
        check(store.load() == state, "state survives being written and read")
        try? Data("not json".utf8).write(to: store.url)
        check(store.load() == SavedState(), "unreadable file: first startup")
        try? FileManager.default.removeItem(at: folder)
    }

    print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
    return failures == 0
}

// MARK: - Previews

private final class Backdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
}

@MainActor
func renderPreviews(into folder: String) {
    let folderURL = URL(fileURLWithPath: folder)
    try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

    func write(_ view: NSView, size: NSSize, as name: String) {
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let url = folderURL.appendingPathComponent(name)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: url)
        print("wrote \(url.path)")
    }

    func form(_ name: String, shown: WorkHours, onboarding: Bool, footnote: String) {
        let form = WorkHoursForm(shown: shown, isOnboarding: onboarding, footnote: footnote)
        let size = form.fittingSize
        let backdrop = Backdrop(frame: NSRect(origin: .zero, size: size))
        form.frame = backdrop.bounds
        backdrop.addSubview(form)
        write(backdrop, size: size, as: name)
    }

    write(BlackoutView(count: -7), size: NSSize(width: 1440, height: 900), as: "blackout.png")
    form("hours-onboarding.png", shown: .everyDay8to18, onboarding: true,
         footnote: "These hours apply as soon as you confirm. Any later change starts the next day.")
    form("hours-change.png", shown: WorkHours(startMinute: 9 * 60, endMinute: 17 * 60, weekdays: [2, 3, 4, 5, 6]),
         onboarding: false,
         footnote: "A change starts tomorrow at 00:00. Today stays \(describe(.everyDay8to18)).")
    form("hours-invalid.png", shown: WorkHours(startMinute: 9 * 60, endMinute: 17 * 60, weekdays: []),
         onboarding: false,
         footnote: "A change starts tomorrow at 00:00. Today stays \(describe(.everyDay8to18)).")
}

// MARK: - On-screen check

@MainActor
func writeScreenCheck(overlayWindowNumbers: [Int], to url: URL) {
    // The window list is front to back and uses a top-left origin on the main display.
    let mainHeight = NSScreen.screens.first?.frame.height ?? 0
    let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    var displays: [[String: Any]] = []
    for screen in NSScreen.screens {
        let frame = screen.frame
        let display = CGRect(x: frame.minX, y: mainHeight - frame.maxY, width: frame.width, height: frame.height)
        var above: [String] = []
        var covered = false
        for window in onScreen {
            guard let boundsValue = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsValue as CFDictionary),
                  bounds.intersects(display) else { continue }
            if overlayWindowNumbers.contains(window[kCGWindowNumber as String] as? Int ?? -1) {
                covered = bounds.contains(display)
                break
            }
            if (window[kCGWindowAlpha as String] as? Double ?? 1) <= 0 { continue }
            let owner = window[kCGWindowOwnerName as String] as? String ?? "?"
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            above.append("\(owner), layer \(layer), \(Int(bounds.width))x\(Int(bounds.height))")
        }
        displays.append(["size": "\(Int(frame.width))x\(Int(frame.height))", "coveredByBlackout": covered, "stackedAbove": above])
    }
    let report: [String: Any] = [
        "displays": displays,
        "appIsActive": NSApp.isActive,
        "appHasKeyWindow": NSApp.keyWindow != nil,
        "frontmostApp": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none",
        "blackoutLayer": Int(CGShieldingWindowLevel()),
    ]
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: url)
    }
}
