import AppKit

// 20-20-20: during work hours, every 20 minutes every display goes dark for 20 seconds.
// Requirements and the reasons behind them are in SPEC.md.

// MARK: - Timing

struct Timing {
    var work: TimeInterval = 20 * 60
    var rest: TimeInterval = 20
    /// Dark time before the 20 seconds start counting, so there is time to get to a window.
    var leadIn: TimeInterval = 10
    var breakLength: TimeInterval { leadIn + rest }
    /// A lock or sleep at least this long is itself a break.
    var awayCountsAsBreak: TimeInterval = 20
    /// How long after a pause ends before another pause can be chosen.
    var pauseLock: TimeInterval = 2 * 60 * 60
    var pauseChoices: [TimeInterval] = [30 * 60, 60 * 60, 120 * 60]

    static func configured() -> Timing {
        var timing = Timing()
        #if TESTBUILD
        // Only the test build can shorten anything; the installed build has no such switch.
        let arguments = UserDefaults.standard
        if arguments.double(forKey: "workSeconds") > 0 { timing.work = arguments.double(forKey: "workSeconds") }
        if arguments.double(forKey: "restSeconds") > 0 { timing.rest = arguments.double(forKey: "restSeconds") }
        if arguments.bool(forKey: "fastPause") {
            timing.pauseChoices = [30, 60, 120]
            timing.pauseLock = 120
        }
        #endif
        return timing
    }
}

// MARK: - Clock

protocol Clock {
    /// Seconds since 1970 by the app's own clock.
    var now: TimeInterval { get }
    var calendar: Calendar { get }
}

/// The date, time and time zone as they were when first read in this boot session.
struct ClockReading: Codable, Equatable {
    var bootSession: String
    var wallTime: TimeInterval
    var elapsedSinceBoot: TimeInterval
    var timeZone: String
}

/// Reads the system clock once per boot session and counts elapsed time from there,
/// so changing the system clock or time zone afterwards moves nothing.
struct BootClock: Clock {
    let reading: ClockReading
    let calendar: Calendar

    /// Reuses `saved` when it was taken in this boot session, so a killed and
    /// restarted app never looks at the system clock again.
    init(saved: ClockReading?, bootSession: String = BootClock.currentBootSession()) {
        if let saved, saved.bootSession == bootSession, TimeZone(identifier: saved.timeZone) != nil {
            reading = saved
        } else {
            reading = ClockReading(
                bootSession: bootSession,
                wallTime: Date().timeIntervalSince1970,
                elapsedSinceBoot: BootClock.elapsedSinceBoot(),
                timeZone: TimeZone.current.identifier)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: reading.timeZone)!
        self.calendar = calendar
    }

    var now: TimeInterval {
        reading.wallTime + BootClock.elapsedSinceBoot() - reading.elapsedSinceBoot
    }

    /// Keeps counting while the Mac sleeps and ignores changes to the system clock.
    static func elapsedSinceBoot() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }

    static func currentBootSession() -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else {
            fatalError("20-20-20 cannot read kern.bootsessionuuid")
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else {
            fatalError("20-20-20 cannot read kern.bootsessionuuid")
        }
        return String(cString: buffer)
    }
}

// MARK: - Work hours

struct WorkHours: Codable, Equatable {
    /// Minutes after midnight.
    var startMinute: Int
    var endMinute: Int
    /// Calendar numbering: 1 = Sunday … 7 = Saturday.
    var weekdays: Set<Int>

    static let everyDay8to18 = WorkHours(startMinute: 8 * 60, endMinute: 18 * 60, weekdays: Set(1...7))

    var isValid: Bool {
        0 <= startMinute && startMinute < endMinute && endMinute <= 24 * 60
            && !weekdays.isEmpty && weekdays.isSubset(of: Set(1...7))
    }

    func contains(_ time: TimeInterval, in calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: Date(timeIntervalSince1970: time))
        let minute = parts.hour! * 60 + parts.minute!
        return weekdays.contains(parts.weekday!) && startMinute <= minute && minute < endMinute
    }

    /// When work starts on the day beginning at `dayStart`, or nil when that is not a work day.
    func start(onDayStarting dayStart: Date, in calendar: Calendar) -> TimeInterval? {
        guard weekdays.contains(calendar.component(.weekday, from: dayStart)) else { return nil }
        return calendar.date(bySettingHour: startMinute / 60, minute: startMinute % 60, second: 0, of: dayStart)?
            .timeIntervalSince1970
    }
}

// MARK: - Saved state

enum Phase: Codable, Equatable {
    /// Outside work hours.
    case off
    case working(dueAt: TimeInterval)
    case onBreak(endsAt: TimeInterval, thenPauseFor: TimeInterval?)
    case paused(until: TimeInterval)
}

struct SavedState: Codable, Equatable {
    var clock: ClockReading?
    var phase: Phase = .off
    var pauseLockedUntil: TimeInterval = 0
    /// Nil until the onboarding step is confirmed.
    var hours: WorkHours?
    /// Changed hours waiting for the day they start.
    var nextHours: WorkHours?
    var nextHoursFrom: TimeInterval?
}

protocol StateStore {
    func load() -> SavedState
    func save(_ state: SavedState)
}

struct FileStateStore: StateStore {
    let url: URL

    /// A missing or unreadable file is a first startup, so onboarding runs again.
    func load() -> SavedState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return SavedState() }
        return state
    }

    func save(_ state: SavedState) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
        } catch {
            NSLog("20-20-20 could not save its state: \(error)")
        }
    }
}

// MARK: - Break cycle

/// The only owner of the cycle. Everything else displays what it says.
/// Nothing leads out of a break except time passing.
final class BreakCycle {
    enum Event { case breakStarted, breakEnded }
    enum AwayReason { case locked, displaysAsleep, systemAsleep }

    let timing: Timing
    private let clock: Clock
    private let store: StateStore
    private(set) var state: SavedState
    private var awaySince: [AwayReason: TimeInterval] = [:]

    init(state: SavedState, resumedInSameBootSession: Bool, clock: Clock, store: StateStore, timing: Timing) {
        var state = state
        if !resumedInSameBootSession {
            // Saved deadlines belong to the previous boot session.
            state.phase = .off
            state.pauseLockedUntil = 0
        } else if case .onBreak(_, let pause) = state.phase {
            // The app was killed during a break: the break starts over in full.
            state.phase = .onBreak(endsAt: clock.now + timing.breakLength, thenPauseFor: pause)
        }
        self.state = state
        self.clock = clock
        self.store = store
        self.timing = timing
        store.save(state)
    }

    /// Starts the cycle from disk with the clock for this boot session.
    static func launch(store: StateStore, timing: Timing) -> BreakCycle {
        var state = store.load()
        let clock = BootClock(saved: state.clock)
        let resumed = state.clock == clock.reading
        state.clock = clock.reading
        return BreakCycle(state: state, resumedInSameBootSession: resumed, clock: clock, store: store, timing: timing)
    }

    var phase: Phase { state.phase }
    var isOnboarded: Bool { state.hours != nil }
    /// Until onboarding is confirmed the default hours are enforced, so leaving the form open gains nothing.
    private var enforcedHours: WorkHours { state.hours ?? .everyDay8to18 }
    var now: TimeInterval { clock.now }
    var calendar: Calendar { clock.calendar }

    /// Moves the cycle to where the clock says it should be. Safe to call at any time.
    @discardableResult
    func tick() -> [Event] {
        let before = state
        let now = clock.now
        var events: [Event] = []

        if let next = state.nextHours, let from = state.nextHoursFrom, now >= from {
            state.hours = next
            state.nextHours = nil
            state.nextHoursFrom = nil
        }
        let inWorkHours = enforcedHours.contains(now, in: clock.calendar)

        var settled = false
        while !settled {
            settled = true
            switch state.phase {
            case .off:
                if inWorkHours { state.phase = .working(dueAt: now + timing.work) }
            case .working(let dueAt):
                if !inWorkHours {
                    state.phase = .off
                } else if now >= dueAt {
                    state.phase = .onBreak(endsAt: now + timing.breakLength, thenPauseFor: nil)
                    events.append(.breakStarted)
                }
            case .onBreak(let endsAt, let pause):
                if now >= endsAt {
                    events.append(.breakEnded)
                    if let pause {
                        state.phase = .paused(until: now + pause)
                        state.pauseLockedUntil = now + pause + timing.pauseLock
                    } else {
                        state.phase = inWorkHours ? .working(dueAt: now + timing.work) : .off
                    }
                    settled = false
                }
            case .paused(let until):
                if !inWorkHours {
                    state.phase = .off
                } else if now >= until {
                    state.phase = .onBreak(endsAt: now + timing.breakLength, thenPauseFor: nil)
                    events.append(.breakStarted)
                }
            }
        }
        if state != before { store.save(state) }
        return events
    }

    func breakNow() -> [Event] {
        switch state.phase {
        case .off, .working:
            state.phase = .onBreak(endsAt: clock.now + timing.breakLength, thenPauseFor: nil)
            store.save(state)
            return [.breakStarted]
        case .onBreak, .paused:
            return []
        }
    }

    var canPause: Bool {
        if case .working = state.phase { return clock.now >= state.pauseLockedUntil }
        return false
    }

    /// A pause starts with a break, so it never removes the break that was coming.
    func pause(for duration: TimeInterval) -> [Event] {
        guard canPause else { return [] }
        state.phase = .onBreak(endsAt: clock.now + timing.breakLength, thenPauseFor: duration)
        store.save(state)
        return [.breakStarted]
    }

    /// Drops an absence without counting it, for a lock whose unlock was never reported.
    func forgetAbsence(_ reason: AwayReason) {
        awaySince[reason] = nil
    }

    func screenBecameUnavailable(_ reason: AwayReason) {
        if awaySince[reason] == nil { awaySince[reason] = clock.now }
    }

    func screenBecameAvailable(_ reason: AwayReason) -> [Event] {
        let now = clock.now
        if let since = awaySince.removeValue(forKey: reason), now - since >= timing.awayCountsAsBreak {
            switch state.phase {
            case .working:
                state.phase = .working(dueAt: now + timing.work)
            case .onBreak(let endsAt, let pause):
                state.phase = .onBreak(endsAt: min(endsAt, now), thenPauseFor: pause)
            case .off, .paused:
                break
            }
            store.save(state)
        }
        return tick()
    }

    /// The first hours (onboarding) apply at once. Every later change starts the next day.
    func setWorkHours(_ hours: WorkHours) {
        guard hours.isValid else { return }
        if state.hours == nil {
            state.hours = hours
        } else if hours == state.hours {
            state.nextHours = nil
            state.nextHoursFrom = nil
        } else {
            state.nextHours = hours
            state.nextHoursFrom = startOfDay(offsetBy: 1).timeIntervalSince1970
        }
        store.save(state)
    }

    /// The next time work hours start, taking changed hours into account from the day they apply.
    func nextWorkStart() -> TimeInterval? {
        let hours = enforcedHours
        let now = clock.now
        for offset in 0...7 {
            let dayStart = startOfDay(offsetBy: offset)
            var hoursThatDay = hours
            if let next = state.nextHours, let from = state.nextHoursFrom, dayStart.timeIntervalSince1970 >= from {
                hoursThatDay = next
            }
            if let start = hoursThatDay.start(onDayStarting: dayStart, in: clock.calendar), start > now {
                return start
            }
        }
        return nil
    }

    private func startOfDay(offsetBy days: Int) -> Date {
        let today = clock.calendar.startOfDay(for: Date(timeIntervalSince1970: clock.now))
        return clock.calendar.date(byAdding: .day, value: days, to: today)!
    }
}

// MARK: - Blackout

/// Covers a display without ever taking keyboard focus, so a running dictation keeps its target.
final class BlackoutWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class BlackoutView: NSView {
    private let counter = NSTextField(labelWithString: "")

    /// `count` runs from minus the lead-in up to the 20 seconds.
    func display(count: Int) {
        counter.stringValue = count < 0 ? "−\(-count)" : "\(count)"
    }

    init(count: Int) {
        super.init(frame: .zero)
        let message = NSTextField(labelWithString: "Look at something 20 feet away")
        message.font = .systemFont(ofSize: 34, weight: .medium)
        message.textColor = NSColor(white: 1, alpha: 0.85)
        counter.font = .monospacedDigitSystemFont(ofSize: 160, weight: .thin)
        counter.textColor = .white
        display(count: count)

        let stack = NSStackView(views: [message, counter])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
    }
}

@MainActor
final class Blackout {
    private var windows: [BlackoutWindow] = []
    private var views: [BlackoutView] = []

    var isShowing: Bool { !windows.isEmpty }
    var windowNumbers: [Int] { windows.map(\.windowNumber) }

    func show(count: Int) {
        hide()
        for screen in NSScreen.screens {
            let window = BlackoutWindow(
                contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            // Above full-screen apps, the menu bar, the Dock and Mission Control, on every Space.
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            let view = BlackoutView(count: count)
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            windows.append(window)
            views.append(view)
        }
    }

    func update(count: Int) {
        for view in views { view.display(count: count) }
    }

    func hide() {
        for window in windows { window.close() }
        windows = []
        views = []
    }
}

// MARK: - Work hours form

func clockText(_ minute: Int) -> String {
    String(format: "%02d:%02d", minute / 60, minute % 60)
}

/// Monday first.
let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

func describe(_ hours: WorkHours) -> String {
    let symbols = Calendar.current.shortWeekdaySymbols
    let days = hours.weekdays.count == 7
        ? "every day"
        : weekdayOrder.filter(hours.weekdays.contains).map { symbols[$0 - 1] }.joined(separator: " ")
    return "\(clockText(hours.startMinute))–\(clockText(hours.endMinute)), \(days)"
}

final class WorkHoursForm: NSView {
    var onConfirm: ((WorkHours) -> Void)?
    var onCancel: (() -> Void)?

    private let startPicker = NSDatePicker()
    private let endPicker = NSDatePicker()
    private var dayBoxes: [(weekday: Int, box: NSButton)] = []
    private let problem = NSTextField(labelWithString: " ")
    private var confirmButton: NSButton!

    /// The pickers hold plain minutes after midnight, kept free of any real time zone.
    private static let pickerCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    init(shown: WorkHours, isOnboarding: Bool, footnote: String) {
        super.init(frame: .zero)
        let width: CGFloat = 400

        var rows: [NSView] = []
        if isOnboarding {
            let heading = NSTextField(labelWithString: "When should 20-20-20 apply?")
            heading.font = .systemFont(ofSize: 15, weight: .semibold)
            let body = NSTextField(wrappingLabelWithString:
                "During these hours every display goes dark for 20 seconds every 20 minutes. A break cannot be skipped.")
            body.preferredMaxLayoutWidth = width
            rows += [heading, body]
        }

        configure(startPicker, minute: shown.startMinute)
        configure(endPicker, minute: shown.endMinute)
        let timeRow = NSStackView(views: [
            NSTextField(labelWithString: "From"), startPicker, NSTextField(labelWithString: "to"), endPicker,
        ])
        timeRow.spacing = 8
        rows.append(timeRow)

        let symbols = Calendar.current.shortWeekdaySymbols
        for weekday in weekdayOrder {
            let box = NSButton(checkboxWithTitle: symbols[weekday - 1], target: self, action: #selector(changed))
            box.state = shown.weekdays.contains(weekday) ? .on : .off
            dayBoxes.append((weekday, box))
        }
        let dayRow = NSStackView(views: dayBoxes.map(\.box))
        dayRow.spacing = 12
        rows.append(dayRow)

        let note = NSTextField(wrappingLabelWithString: footnote)
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = width
        rows.append(note)

        problem.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        problem.textColor = .systemRed
        rows.append(problem)

        confirmButton = NSButton(title: isOnboarding ? "Confirm" : "Save", target: self, action: #selector(confirm))
        confirmButton.keyEquivalent = "\r"
        var buttons: [NSView] = [confirmButton]
        if !isOnboarding {
            let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
            cancel.keyEquivalent = "\u{1b}"
            buttons.insert(cancel, at: 0)
        }
        let buttonRow = NSStackView(views: buttons)
        buttonRow.spacing = 8

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(buttonRow)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            widthAnchor.constraint(equalToConstant: width + 48),
            buttonRow.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 8),
            buttonRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            buttonRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
        ])
        validate()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var current: WorkHours {
        WorkHours(
            startMinute: minute(of: startPicker), endMinute: minute(of: endPicker),
            weekdays: Set(dayBoxes.filter { $0.box.state == .on }.map(\.weekday)))
    }

    private func configure(_ picker: NSDatePicker, minute: Int) {
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .hourMinute
        picker.calendar = WorkHoursForm.pickerCalendar
        picker.timeZone = WorkHoursForm.pickerCalendar.timeZone
        picker.dateValue = Date(timeIntervalSinceReferenceDate: TimeInterval(minute * 60))
        picker.target = self
        picker.action = #selector(changed)
    }

    private func minute(of picker: NSDatePicker) -> Int {
        let parts = WorkHoursForm.pickerCalendar.dateComponents([.hour, .minute], from: picker.dateValue)
        return parts.hour! * 60 + parts.minute!
    }

    private func validate() {
        let hours = current
        if hours.weekdays.isEmpty {
            problem.stringValue = "Tick at least one day."
        } else if hours.startMinute >= hours.endMinute {
            problem.stringValue = "The start time must be before the end time."
        } else {
            problem.stringValue = " "
        }
        confirmButton.isEnabled = hours.isValid
    }

    @objc private func changed() { validate() }
    @objc private func confirm() { if current.isValid { onConfirm?(current) } }
    @objc private func cancel() { onCancel?() }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let cycle: BreakCycle
    private let blackout = Blackout()
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let breakNowItem = NSMenuItem(title: "Break now", action: #selector(breakNow), keyEquivalent: "")
    private var pauseItems: [NSMenuItem] = []
    private let pauseLockLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var hoursWindow: NSWindow?
    private var timer: Timer?
    private var menuIsOpen = false

    private static let screenLocked = Notification.Name("com.apple.screenIsLocked")
    private static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")

    static var stateURL: URL {
        #if TESTBUILD
        let folder = "20-20-20-test"
        #else
        let folder = "20-20-20"
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(folder).appendingPathComponent("state.json")
    }

    override init() {
        let store = FileStateStore(url: AppDelegate.stateURL)
        cycle = BreakCycle.launch(store: store, timing: Timing.configured())
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        observeScreenAvailability()
        #if TESTBUILD
        // Lets an unattended test run skip the onboarding window and run at any hour.
        if UserDefaults.standard.string(forKey: "testHours") == "allDay", !cycle.isOnboarded {
            cycle.setWorkHours(WorkHours(startMinute: 0, endMinute: 24 * 60, weekdays: Set(1...7)))
        }
        #endif
        if !cycle.isOnboarded { showWorkHours() }
        advance(cycle.tick())
    }

    // MARK: Menu

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "20-20-20")
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        breakNowItem.target = self
        menu.addItem(breakNowItem)
        menu.addItem(.separator())

        let pauseHeader = NSMenuItem(title: "A pause starts and ends with a break", action: nil, keyEquivalent: "")
        pauseHeader.isEnabled = false
        menu.addItem(pauseHeader)
        for duration in cycle.timing.pauseChoices {
            let item = NSMenuItem(title: "Pause \(durationText(duration))", action: #selector(pause(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = duration
            pauseItems.append(item)
            menu.addItem(item)
        }
        pauseLockLine.isEnabled = false
        menu.addItem(pauseLockLine)
        menu.addItem(.separator())

        let hoursItem = NSMenuItem(title: "Work hours…", action: #selector(showWorkHours), keyEquivalent: "")
        hoursItem.target = self
        menu.addItem(hoursItem)

        #if TESTBUILD
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit (test build)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        #endif
        statusItem.menu = menu
    }

    private func durationText(_ duration: TimeInterval) -> String {
        duration >= 60 ? "\(Int(duration / 60)) min" : "\(Int(duration)) s"
    }

    private func refreshMenu() {
        let now = cycle.now
        statusLine.title = statusText(now: now)
        switch cycle.phase {
        case .off, .working: breakNowItem.isEnabled = true
        case .onBreak, .paused: breakNowItem.isEnabled = false
        }
        let canPause = cycle.canPause
        for item in pauseItems { item.isEnabled = canPause }
        if case .working = cycle.phase, now < cycle.state.pauseLockedUntil {
            pauseLockLine.title = "Pause available again at \(timeText(cycle.state.pauseLockedUntil, withDay: false))"
            pauseLockLine.isHidden = false
        } else {
            pauseLockLine.isHidden = true
        }
    }

    private func statusText(now: TimeInterval) -> String {
        switch cycle.phase {
        case .off:
            guard let start = cycle.nextWorkStart() else { return "Off" }
            return "Off until \(timeText(start, withDay: true))"
        case .working(let dueAt):
            return "Next break in \(countdownText(dueAt - now))"
        case .onBreak:
            return "Break in progress"
        case .paused(let until):
            return "Paused until \(timeText(until, withDay: false)), then a break"
        }
    }

    private func countdownText(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    private func timeText(_ time: TimeInterval, withDay: Bool) -> String {
        let formatter = DateFormatter()
        formatter.calendar = cycle.calendar
        formatter.timeZone = cycle.calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(withDay ? "EEEHHmm" : "HHmm")
        return formatter.string(from: Date(timeIntervalSince1970: time))
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        advance(cycle.tick())
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        scheduleTimer()
    }

    @objc private func breakNow() { advance(cycle.breakNow()) }

    @objc private func pause(_ sender: NSMenuItem) {
        guard let duration = sender.representedObject as? TimeInterval else { return }
        advance(cycle.pause(for: duration))
    }

    // MARK: Work hours window

    @objc private func showWorkHours() {
        if hoursWindow == nil {
            let onboarding = !cycle.isOnboarded
            let shown = cycle.state.nextHours ?? cycle.state.hours ?? .everyDay8to18
            let form = WorkHoursForm(shown: shown, isOnboarding: onboarding, footnote: hoursFootnote())
            form.onConfirm = { [weak self] hours in
                guard let self else { return }
                self.cycle.setWorkHours(hours)
                self.hoursWindow?.close()
                self.advance(self.cycle.tick())
            }
            form.onCancel = { [weak self] in self?.hoursWindow?.close() }

            // The onboarding step has no close button: it ends only by confirming.
            let window = NSWindow(
                contentRect: .zero, styleMask: onboarding ? [.titled] : [.titled, .closable],
                backing: .buffered, defer: false)
            window.title = "Work hours"
            window.contentView = form
            window.setContentSize(form.fittingSize)
            window.isReleasedWhenClosed = false
            window.level = .floating
            if onboarding { window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary] }
            window.delegate = self
            window.center()
            hoursWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        hoursWindow?.makeKeyAndOrderFront(nil)
    }

    private func hoursFootnote() -> String {
        guard let inForce = cycle.state.hours else {
            return "Until you confirm, \(describe(.everyDay8to18)) applies. What you confirm applies at once; "
                + "any later change starts the next day."
        }
        if cycle.state.nextHours != nil {
            return "These hours start tomorrow at 00:00. Today stays \(describe(inForce))."
        }
        return "A change starts tomorrow at 00:00. Today stays \(describe(inForce))."
    }

    func windowWillClose(_ notification: Notification) {
        hoursWindow = nil
    }

    // MARK: Screen availability

    private func observeScreenAvailability() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
            NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
        ] {
            workspace.addObserver(self, selector: #selector(screenAvailabilityChanged(_:)), name: name, object: nil)
        }
        for name in [AppDelegate.screenLocked, AppDelegate.screenUnlocked] {
            // Delivered at once: the default would hold these back while the app is in the background.
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(screenAvailabilityChanged(_:)), name: name, object: nil,
                suspensionBehavior: .deliverImmediately)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(displaysChanged), name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
    }

    @objc private func screenAvailabilityChanged(_ notification: Notification) {
        switch notification.name {
        case NSWorkspace.screensDidSleepNotification:
            cycle.screenBecameUnavailable(.displaysAsleep)
        case NSWorkspace.screensDidWakeNotification:
            advance(cycle.screenBecameAvailable(.displaysAsleep))
        case NSWorkspace.willSleepNotification:
            cycle.screenBecameUnavailable(.systemAsleep)
        case NSWorkspace.didWakeNotification:
            advance(cycle.screenBecameAvailable(.systemAsleep))
        case AppDelegate.screenLocked:
            // Any process can post this notification, so the lock is confirmed with the system first.
            if AppDelegate.screenIsLocked() { cycle.screenBecameUnavailable(.locked) }
        case AppDelegate.screenUnlocked:
            if !AppDelegate.screenIsLocked() { advance(cycle.screenBecameAvailable(.locked)) }
        default:
            break
        }
    }

    private static func screenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    @objc private func displaysChanged() {
        // Rebuild so a display plugged in during a break is covered too.
        if blackout.isShowing {
            blackout.hide()
            render()
        }
    }

    // MARK: Rendering

    private func advance(_ events: [BreakCycle.Event]) {
        render()
    }

    /// Shows what the cycle says. Decides nothing.
    private func render() {
        let now = cycle.now
        if case .onBreak(let endsAt, _) = cycle.phase {
            // The counter starts at minus the lead-in and runs up to the 20 seconds.
            let timing = cycle.timing
            let elapsed = timing.breakLength - (endsAt - now)
            let count = Int((elapsed - timing.leadIn).rounded(.down))
            let shown = min(Int(timing.rest), max(-Int(timing.leadIn), count))
            if blackout.isShowing {
                blackout.update(count: shown)
            } else {
                blackout.show(count: shown)
                #if TESTBUILD
                perform(#selector(recordScreenCheck), with: nil, afterDelay: 1)
                #endif
            }
        } else {
            blackout.hide()
        }

        // The last minute counts down in the menu bar, so a break never comes without warning.
        if case .working(let dueAt) = cycle.phase, dueAt - now <= 60 {
            statusItem.button?.title = " " + countdownText(dueAt - now)
        } else {
            statusItem.button?.title = ""
        }

        if menuIsOpen { refreshMenu() }
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let now = cycle.now
        var interval: TimeInterval = 30
        switch cycle.phase {
        case .onBreak:
            interval = 0.5
        case .working(let dueAt):
            let remaining = dueAt - now
            interval = remaining <= 60 ? 1 : min(30, remaining - 60)
        case .paused(let until):
            interval = min(30, max(1, until - now))
        case .off:
            interval = 30
        }
        if menuIsOpen { interval = min(interval, 1) }
        let next = Timer(timeInterval: interval, target: self, selector: #selector(timerFired), userInfo: nil, repeats: false)
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    #if TESTBUILD
    @objc private func recordScreenCheck() {
        writeScreenCheck(
            overlayWindowNumbers: blackout.windowNumbers,
            to: AppDelegate.stateURL.deletingLastPathComponent().appendingPathComponent("screen-check.json"))
    }
    #endif

    @objc private func timerFired() {
        // A recorded lock that the system no longer reports must not be credited later as a long absence.
        if !AppDelegate.screenIsLocked() { cycle.forgetAbsence(.locked) }
        advance(cycle.tick())
    }
}

// MARK: - Start

#if TESTBUILD
if CommandLine.arguments.contains("--self-test") {
    exit(runSelfTests() ? 0 : 1)
}
#endif

// Top-level code runs on the main thread.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    #if TESTBUILD
    if CommandLine.arguments.contains("--reset-state") {
        try? FileManager.default.removeItem(at: AppDelegate.stateURL.deletingLastPathComponent())
        exit(0)
    }
    if let flag = CommandLine.arguments.firstIndex(of: "--render-previews"), CommandLine.arguments.count > flag + 1 {
        renderPreviews(into: CommandLine.arguments[flag + 1])
        exit(0)
    }
    #endif
    let appDelegate = AppDelegate()
    application.delegate = appDelegate
    application.setActivationPolicy(.accessory)
    // Without this macOS may nap a windowless background app and deliver its timers late.
    let awake = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep, reason: "Break timing")
    // NSApplication holds its delegate weakly.
    withExtendedLifetime((appDelegate, awake)) { application.run() }
}
