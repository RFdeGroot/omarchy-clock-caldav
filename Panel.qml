import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The Omarchy clock, grown a calendar.
//
// The bar label is the stock clock: a date/time string, right-click to walk the
// formats, middle-click for the timezone picker. What changed is the popup.
//
// The popup has three faces:
//   - "calendar": the stock month grid, now with a row of coloured dots under
//     every day that has something on it, and the selected day's agenda listed
//     underneath. Click a week number for the week timeline; click the big date
//     for the month-with-events view.
//   - "week": the day-column timeline from the CalDAV fork, seven days wide.
//   - "month": the wall-calendar grid with event chips.
//
// The events come from bin/calendar-widget (khal over a vdirsyncer vdir); the
// script is unchanged from the standalone rfdegroot.calendar-caldav plugin, so
// an existing sync keeps working untouched.
//
// Glyphs are \u escapes, because literal private-use characters do not always
// survive the trip to disk.
Panel {
  id: root

  // Cloned from omarchy.clock: the shell routes the bar slot and this IPC
  // target to us and hides the built-in.
  moduleName: "omarchy.clock"
  ipcTarget: "omarchy.clock"

  // The script that does the talking sits next to this file, so the plugin
  // runs from wherever it was installed without putting anything on $PATH.
  readonly property string script:
    Qt.resolvedUrl("bin/calendar-widget").toString().replace(/^file:\/\//, "")

  readonly property string iconCalendar: ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color contentFontColor: foreground

  // ---------------------------------------------------------------------------
  // Clock label
  // ---------------------------------------------------------------------------

  property date displayDate: new Date()
  readonly property bool vertical: bar ? bar.vertical : false

  readonly property string configuredFormat: vertical
    ? setting("verticalFormat", "HH\n—\nmm")
    : setting("format", "dddd HH:mm")
  readonly property string configuredAltFormat: vertical
    ? setting("verticalFormatAlt", "dd\nMMM\n'W'ww\n''yy")
    : setting("formatAlt", "d MMMM 'W'ww yyyy")
  readonly property var formatRing:
    Model.clockFormatRing(configuredFormat, configuredAltFormat, Model.clockFormats(vertical))
  readonly property string clockLabel: formattedClock(displayDate)
  readonly property var verticalLines: clockLabel.split("\n")

  function formattedClock(date) {
    return Qt.formatDateTime(date, String(configuredFormat).replace(
      /ww/g, Model.isoWeekLiteral(date.getFullYear(), date.getMonth(), date.getDate())))
  }

  // Applied locally first so the label changes on the click itself; the
  // shell.json write comes back through the bar as the same value.
  function cycleFormat() {
    var current = String(configuredFormat)
    var next = Model.nextClockFormat(formatRing, current)
    if (next === "" || next === current) return
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry[vertical ? "verticalFormat" : "format"] = next
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // ---------------------------------------------------------------------------
  // Which face of the popup is showing
  // ---------------------------------------------------------------------------

  // "calendar", "week" or "month". Always opens on the calendar.
  property string viewMode: "calendar"
  readonly property bool calendarView: viewMode === "calendar"
  readonly property bool weekView: viewMode === "week"
  readonly property bool monthView: viewMode === "month"
  // Week and month are the wide, day-columned layouts; the calendar is narrow.
  readonly property bool wideView: weekView || monthView

  // The data mode the script speaks: the calendar face is fed by a month
  // payload, same as the month face.
  readonly property string dataMode: calendarView ? "month" : viewMode

  // The paging offset. In the calendar and month faces it counts months; in
  // the week face it counts weeks. Reset to 0 on every face switch.
  property int dayOffset: 0

  property bool loading: false

  // ---------------------------------------------------------------------------
  // The month on screen, and the selected day within it (calendar face)
  // ---------------------------------------------------------------------------

  property date today: new Date()
  readonly property string todayKey: Model.keyForDate(today)

  readonly property date viewMonthDate: {
    var m = new Date(today.getFullYear(), today.getMonth() + dayOffset, 1)
    return m
  }
  readonly property int viewYear: viewMonthDate.getFullYear()
  readonly property int viewMonth: viewMonthDate.getMonth()
  readonly property bool viewingCurrentMonth: dayOffset === 0

  // The day whose agenda shows under the grid. Kept as a day-of-month plus the
  // number the user last asked for, so stepping Feb -> Mar brings the 31st back.
  property int selDay: today.getDate()
  property int desiredDay: today.getDate()
  readonly property date selectedDate: new Date(viewYear, viewMonth, selDay)
  readonly property bool selectedIsToday:
    selectedDate.getFullYear() === today.getFullYear()
    && selectedDate.getMonth() === today.getMonth()
    && selectedDate.getDate() === today.getDate()

  // Unset falls through to the locale's own first day. Clicking the grid's "W"
  // heading writes the choice to shell.json.
  readonly property int weekStart:
    Model.normalizedWeekStart(setting("weekStartDay", null), Qt.locale().firstDayOfWeek)
  readonly property var labelLocale: Qt.locale("en_US")
  readonly property string nextWeekStartLabel:
    labelLocale.dayName(Model.toggledWeekStart(weekStart), Locale.LongFormat)
  readonly property var weekdays: Model.weekdayOrder(weekStart)
  readonly property var weeks: Model.monthGrid(viewYear, viewMonth, weekStart, todayKey)

  readonly property real yearDone:
    Model.yearProgress(today.getFullYear(), today.getMonth(), today.getDate())
  readonly property int yearDonePercent:
    Model.yearProgressPercent(today.getFullYear(), today.getMonth(), today.getDate())
  readonly property int birthYear:
    Model.parseBirthYear(setting("birthYear", 0), today.getFullYear())
  readonly property int age: Model.ageFromBirthYear(birthYear, today.getFullYear())
  readonly property int lifeExpectancy: Model.parseLifeExpectancy(setting("lifeExpectancy", 0))
  readonly property real lifeDone: Model.lifeProgress(age, lifeExpectancy)
  readonly property int lifeDonePercent: Model.lifeProgressPercent(age, lifeExpectancy)
  property bool editingLife: false

  function weekdayLabel(weekday) {
    return String(labelLocale.dayName(weekday, Locale.ShortFormat)).toUpperCase()
  }

  // ---------------------------------------------------------------------------
  // Event data
  // ---------------------------------------------------------------------------

  // The current face's day list, straight from the script. Always a list of
  // days: the week draws the same column seven times, the month grid drives
  // off 42 entries, the calendar face indexes it by date.
  property var days: []

  // Kept between openings and switches so a face change shows its events at
  // once. Keyed by offset, because paging a month or a week is cheap to cache.
  property var monthByOffset: ({})
  property var weekByOffset: ({})
  property var todayCache: []

  property var upcoming: null
  property int nowMinutes: 0
  property bool reachable: true

  // Every calendar there is, and which of them you want to see.
  property var calendars: []
  property var visibleCalendars: []
  readonly property var checkedCalendars:
    (visibleCalendars && visibleCalendars.length > 0) ? visibleCalendars : calendars
  property bool writingCalendars: false

  // Looking at a colleague's agenda. Only for the face you are viewing.
  property bool showBorrowed: false
  property string borrowedCalendar: ""
  property string borrowedLabel: ""
  readonly property bool hasBorrowed: borrowedCalendar !== ""

  property string datePath: ""
  property string dateLabel: ""
  property string webBase: ""
  readonly property bool hasWeb: safeUrl(webBase) !== ""

  property string blockedReason: ""
  property bool copiedPrompt: false

  // The events for the selected day, dug out of whichever payload we have.
  readonly property var monthIndex: Model.indexByDatePath(days)
  readonly property var selectedEntry:
    monthIndex[Model.datePath(viewYear, viewMonth, selDay)] || null
  readonly property var selectedItems: Model.dayItems(selectedEntry)

  // ---------------------------------------------------------------------------
  // Layout maths for the week / month faces (from the CalDAV fork)
  // ---------------------------------------------------------------------------

  readonly property var allTimed: {
    var out = []
    for (var d = 0; d < days.length; d++)
      for (var t = 0; t < (days[d].events || []).length; t++) out.push(days[d].events[t])
    return out
  }

  readonly property bool emptyDay: {
    for (var d = 0; d < days.length; d++)
      if ((days[d].events || []).length > 0 || (days[d].allday || []).length > 0) return false
    return true
  }

  readonly property color urgentFill: "#f7768e"
  readonly property int urgentMinutes: 5
  readonly property int joinWindow: 5

  readonly property int minutesUntil: upcoming ? upcoming.start_minutes - nowMinutes : 0
  readonly property bool inMeeting: upcoming !== null && minutesUntil <= 0
  readonly property bool almostDue:
    upcoming !== null && minutesUntil > 0 && minutesUntil <= urgentMinutes

  readonly property var joinable: {
    if (!upcoming) return null
    if (safeUrl(upcoming.hangout) === "") return null
    if (inMeeting) return upcoming
    return minutesUntil <= joinWindow ? upcoming : null
  }
  readonly property bool hasJoin: joinable !== null

  function humanDelta(minutes) {
    var m = Math.max(0, minutes)
    if (m < 60) return m + "m"
    return Math.floor(m / 60) + "h" + (m % 60 < 10 ? "0" : "") + (m % 60) + "m"
  }

  readonly property string countdown: {
    if (!upcoming) return ""
    if (inMeeting) return humanDelta(upcoming.end_minutes - nowMinutes) + " left"
    return "in " + humanDelta(minutesUntil)
  }

  readonly property int dayStart: {
    var earliest = 7 * 60
    for (var i = 0; i < allTimed.length; i++)
      earliest = Math.min(earliest, allTimed[i].start_minutes - 30)
    return Math.max(0, Math.min(earliest, nowMinutes - 60))
  }
  readonly property int dayEnd: {
    var latest = 23 * 60
    for (var i = 0; i < allTimed.length; i++)
      latest = Math.max(latest, allTimed[i].end_minutes + 30)
    return Math.min(24 * 60, Math.max(latest, nowMinutes + 60))
  }
  readonly property int daySpan: Math.max(60, dayEnd - dayStart)

  readonly property int hourHeight: {
    var hours = Math.max(1, daySpan / 60)
    var chrome = headerBar.height + dayNamesRow.height + alldayRow.height
                 + calendarPicker.height + borrowedToggle.height
                 + content.spacing * (root.hasBorrowed ? 5 : 4)
                 + panel.verticalContentInset + Style.space(10)
    var room = panel.maxCardHeight - chrome
    return Math.max(Style.space(16), room / hours)
  }

  readonly property int gutter: weekView ? Style.space(34) : 0
  readonly property real columnWidth: content.width > 0
    ? (content.width - gutter) / (weekView ? Math.max(1, days.length) : 7) : 0

  readonly property int monthWeeks: monthView ? Math.max(1, Math.round(days.length / 7)) : 0
  readonly property int monthRowHeight: {
    if (!monthView) return 0
    var chrome = headerBar.height + monthWeekdayRow.height
                 + calendarPicker.height + borrowedToggle.height
                 + content.spacing * (root.hasBorrowed ? 4 : 3)
                 + panel.verticalContentInset + Style.space(10)
    var room = panel.maxCardHeight - chrome
    return Math.max(Style.space(56), room / Math.max(1, monthWeeks))
  }

  readonly property int alldayHeight: Style.space(17)
  readonly property int alldayRows: {
    var most = 0
    for (var d = 0; d < days.length; d++) most = Math.max(most, (days[d].allday || []).length)
    return most
  }

  readonly property string clockText: {
    var h = Math.floor(nowMinutes / 60)
    var m = nowMinutes % 60
    return (h < 10 ? "0" : "") + h + ":" + (m < 10 ? "0" : "") + m
  }

  function spanLabel(minutes) {
    var hours = Math.floor(minutes / 60)
    var rest = minutes % 60
    if (hours > 0 && rest > 0) return hours + "h " + rest + "m"
    if (hours > 0) return hours + "h"
    return rest + "m"
  }

  function sameEvent(a, b) {
    if (!a || !b) return false
    if (a.id && b.id && String(a.id) !== "") return a.id === b.id
    return a.title === b.title && a.calendar === b.calendar
           && a.start_epoch === b.start_epoch && a.allday === b.allday
  }

  // ---------------------------------------------------------------------------
  // Bar sizing
  // ---------------------------------------------------------------------------

  readonly property int barSlot: clockLabel === ""
    ? Style.bar.iconSlot
    : Math.ceil(labelMetrics.advanceWidth) + Style.space(22)

  TextMetrics {
    id: labelMetrics
    text: root.vertical ? "" : root.clockLabel
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  implicitWidth: bar && bar.vertical
    ? (bar ? bar.barSize : Style.bar.sizeHorizontal)
    : barSlot
  implicitHeight: bar && bar.vertical
    ? (root.verticalLines.length * Style.bar.iconSlot)
    : (bar ? bar.barSize : Style.bar.sizeHorizontal)

  // ---------------------------------------------------------------------------
  // Fetching
  // ---------------------------------------------------------------------------

  property bool refreshPending: false
  property bool aborting: false

  function argvFor(mode, offset) {
    var argv = [root.script, mode, String(offset)]
    if (showBorrowed && hasBorrowed) argv.push("--only", borrowedCalendar)
    return argv
  }

  function refresh() {
    if (listProc.running) {
      refreshPending = true
      aborting = true
      listProc.running = false
      return
    }
    listProc.command = argvFor(dataMode, dayOffset)
    listProc.running = true
    loading = true
  }

  // The grid is there before khal has said anything: the same days, the same
  // dates, only without appointments yet.
  function skeleton() {
    var todayD = new Date()
    var base = new Date()
    var count = 1
    var targetMonth = -1

    if (weekView) {
      base.setDate(base.getDate() - ((base.getDay() + 6) % 7) + dayOffset * 7)
      count = 7
    } else {
      // Calendar and month faces: the month's grid, Monday on or before the 1st
      // through Sunday on or after the last.
      var m = new Date(todayD.getFullYear(), todayD.getMonth() + dayOffset, 1)
      targetMonth = m.getMonth()
      var last = new Date(m.getFullYear(), m.getMonth() + 1, 0)
      base = new Date(m.getFullYear(), m.getMonth(), 1 - ((m.getDay() + 6) % 7))
      var span = new Date(last.getFullYear(), last.getMonth(),
                          last.getDate() + (6 - ((last.getDay() + 6) % 7)))
      count = Math.round((span - base) / 86400000) + 1
    }

    var locale = Qt.locale("en_US")
    var out = []
    for (var i = 0; i < count; i++) {
      var d = new Date(base.getFullYear(), base.getMonth(), base.getDate() + i)
      out.push({
        date_path: d.getFullYear() + "/" + (d.getMonth() + 1) + "/" + d.getDate(),
        date_label: d.toLocaleDateString(locale, "dddd d MMMM"),
        short_label: d.toLocaleDateString(locale, "ddd d"),
        range_label: d.toLocaleDateString(locale, "d MMM"),
        day_label: d.toLocaleDateString(locale, "d"),
        is_today: d.getFullYear() === todayD.getFullYear()
                  && d.getMonth() === todayD.getMonth()
                  && d.getDate() === todayD.getDate(),
        in_month: weekView ? true : d.getMonth() === targetMonth,
        events: [],
        allday: [],
      })
    }
    days = out

    if (weekView) {
      datePath = out[0].date_path
      dateLabel = out[0].range_label + " – " + out[6].range_label
    } else {
      datePath = out[0].date_path
      dateLabel = viewMonthDate.toLocaleDateString(locale, "MMMM yyyy")
    }
  }

  // Only about the bar's countdown: fetched even with the panel closed.
  function refreshToday() {
    if (listProc.running) return
    listProc.command = [root.script, "day", "0"]
    listProc.running = true
  }

  property double lastWarmAt: 0

  // Keep this month and this week warm on the side.
  function refreshWarm() {
    if (Date.now() - lastWarmAt < 120000) return
    lastWarmAt = Date.now()
    if (!weekProc.running) {
      weekProc.command = [root.script, "week", "0"]
      weekProc.running = true
    }
    if (!monthProc.running) {
      monthProc.command = [root.script, "month", "0"]
      monthProc.running = true
    }
  }

  function applyCalendars(values) {
    writingCalendars = true
    visibleCalendars = (values.length === calendars.length) ? [] : values
    var argv = [root.script, "set-calendars"]
    for (var i = 0; i < visibleCalendars.length; i++) argv.push(visibleCalendars[i])
    calendarProc.command = argv
    calendarProc.running = true
  }

  function toggleBorrowed() {
    if (!hasBorrowed) return
    showBorrowed = !showBorrowed
    skeleton()
    refresh()
  }

  // ---------------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------------

  function setView(mode) {
    if (mode === viewMode || (mode !== "calendar" && mode !== "week" && mode !== "month"))
      return
    viewMode = mode
    dayOffset = 0
    detailEvent = null
    var warm = mode === "week" ? (weekByOffset[0] || []) : (monthByOffset[0] || [])
    if (warm.length > 0) days = warm
    else skeleton()
    refresh()
  }

  function goToToday() {
    dayOffset = 0
    selDay = today.getDate()
    desiredDay = today.getDate()
    skeleton()
    applyWarm()
    refresh()
  }

  // Step the month (calendar / month faces) or the week (week face).
  function goDay(delta) {
    dayOffset += delta
    detailEvent = null
    if (!weekView) selDay = Model.clampDay(viewYear, viewMonth, desiredDay)
    skeleton()
    applyWarm()
    refresh()
  }

  function applyWarm() {
    var warm = weekView ? weekByOffset[dayOffset] : monthByOffset[dayOffset]
    if (warm && warm.length > 0) days = warm
  }

  // Pick a day in the calendar grid. A day from a neighbouring month steps the
  // view onto that month.
  function selectCell(cell) {
    if (!cell) return
    if (!cell.inMonth) {
      dayOffset = Model.monthDelta(today.getFullYear(), today.getMonth(),
                                   cell.year, cell.month)
      skeleton()
      applyWarm()
      refresh()
    }
    selDay = cell.day
    desiredDay = cell.day
  }

  function moveSelectedDay(deltaDays) {
    var d = new Date(selectedDate.getFullYear(), selectedDate.getMonth(),
                     selectedDate.getDate() + deltaDays)
    var monthStep = Model.monthDelta(viewYear, viewMonth, d.getFullYear(), d.getMonth())
    if (monthStep !== 0) {
      dayOffset += monthStep
      skeleton()
      applyWarm()
      refresh()
    }
    selDay = d.getDate()
    desiredDay = d.getDate()
  }

  // The ISO-week number in a grid row opens that week in the timeline.
  function openWeekFromRow(weekRow) {
    if (!weekRow || !weekRow.days || weekRow.days.length === 0) return
    // Grid rows start on `weekStart`, which may not be Monday, but every row
    // spans a full 7 days and so always contains exactly one — find it
    // directly rather than assuming it is the row's first day.
    var mondayCell = weekRow.days[0]
    for (var i = 0; i < weekRow.days.length; i++) {
      if (weekRow.days[i].weekday === 1) { mondayCell = weekRow.days[i]; break }
    }
    var monday = new Date(mondayCell.year, mondayCell.month, mondayCell.day)
    viewMode = "week"
    dayOffset = Model.weekDelta(today, monday)
    detailEvent = null
    days = weekByOffset[dayOffset] || []
    if (days.length === 0) skeleton()
    refresh()
  }

  // The big date opens the month-with-events face for the month on screen.
  function openMonthView() {
    if (monthView) return
    var keepOffset = calendarView ? dayOffset : 0
    viewMode = "month"
    dayOffset = keepOffset
    detailEvent = null
    days = monthByOffset[dayOffset] || []
    if (days.length === 0) skeleton()
    refresh()
  }

  function backToCalendar() {
    if (calendarView) return
    viewMode = "calendar"
    dayOffset = 0
    detailEvent = null
    selDay = Model.clampDay(viewYear, viewMonth, desiredDay)
    days = monthByOffset[0] || []
    if (days.length === 0) skeleton()
    refresh()
    refreshWarm()
  }

  // A day cell in the month-with-events face drops back to the calendar with
  // that day selected.
  function selectDayFromMonth(day) {
    if (!day) return
    var parts = String(day.date_path).split("/")
    if (parts.length !== 3) return
    var target = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
    viewMode = "calendar"
    dayOffset = Model.monthDelta(today.getFullYear(), today.getMonth(),
                                 target.getFullYear(), target.getMonth())
    selDay = target.getDate()
    desiredDay = target.getDate()
    detailEvent = null
    days = monthByOffset[dayOffset] || []
    if (days.length === 0) skeleton()
    refresh()
  }

  // ---------------------------------------------------------------------------
  // Payload
  // ---------------------------------------------------------------------------

  function applyPayload(text) {
    if (aborting) return
    try {
      var data = JSON.parse(text)
      reachable = data.ok === true
      blockedReason = data.ok === true ? "" : String(data.error || "")
      if (data.ok === true) copiedPrompt = false

      var incoming = data.days || []
      var ownAndCurrent = data.offset === 0 && !data.only_calendar

      if (data.mode === "day" && ownAndCurrent) todayCache = incoming
      if (data.mode === "week" && !data.only_calendar) {
        var w = weekByOffset
        w[data.offset] = incoming
        weekByOffset = w
      }
      if (data.mode === "month" && !data.only_calendar) {
        var mo = monthByOffset
        mo[data.offset] = incoming
        monthByOffset = mo
      }

      // Take it on screen only when the answer matches what is showing now.
      var wantMode = dataMode
      if (opened && data.mode === wantMode && data.offset === dayOffset
          && !!data.only_calendar === showBorrowed) {
        days = incoming
        if (data.date_label) dateLabel = data.date_label
        if (data.date_path) datePath = data.date_path
      }

      nowMinutes = data.now_minutes || 0
      lastFetchAt = Date.now()
      if (data.stamp !== undefined) vdirStamp = String(data.stamp)
      webBase = data.web_base || ""
      borrowedCalendar = (data.borrowed && data.borrowed.name) || ""
      borrowedLabel = (data.borrowed && data.borrowed.label) || ""
      calendars = data.calendars || []
      if (!writingCalendars) visibleCalendars = data.visible || []

      // The bar's countdown is always about today and your own calendar.
      if (data.is_today && !data.only_calendar) upcoming = data.upcoming || null
    } catch (e) {
      reachable = false
    }
  }

  function safeUrl(value) {
    var url = String(value || "")
    return /^https:\/\/[A-Za-z0-9.-]+\/[A-Za-z0-9._~:\/?#@!$&'()*+,;=%-]*$/.test(url) ? url : ""
  }

  function openAgenda() {
    if (!bar || !hasWeb) return
    close()
    // Util.execArgv, not bar.run: bar.run hands a concatenated string to
    // `bash -lc`, and webBase is worked out from vdirsyncer's record of a
    // synced CalDAV server -- not something this plugin fully controls.
    // execArgv passes it as its own argv entry with no shell re-parsing it.
    Util.execArgv(["omarchy-launch-webapp", safeUrl(webBase)])
  }

  // ---------------------------------------------------------------------------
  // Detail card
  // ---------------------------------------------------------------------------

  property var detailEvent: null
  property string detailConference: ""
  property var detailAttendees: []
  property bool loadingAttendees: false
  property int detailCursor: 0

  property real detailAnchorX: 0
  property real detailAnchorY: 0
  property real detailAnchorHeight: 0
  property var cursorItem: null

  readonly property var detailActions: {
    if (!detailEvent) return []
    var out = []
    var join = safeUrl(detailEvent.hangout) || safeUrl(detailConference)
    if (join !== "") out.push({ label: "Join the call", url: join })
    if (safeUrl(detailEvent.link) !== "")
      out.push({ label: "Open in browser", url: safeUrl(detailEvent.link) })
    else if (safeUrl(detailEvent.web) !== "")
      out.push({ label: "Open calendar", url: safeUrl(detailEvent.web) })
    return out
  }

  readonly property string detailWhen: {
    if (!detailEvent) return ""
    if (detailEvent.allday) return "All day"
    var minutes = detailEvent.minutes || 0
    return detailEvent.start + " to " + detailEvent.end + ", " + spanLabel(minutes)
  }
  readonly property string detailCalendar:
    detailEvent ? String(detailEvent.calendar || "") : ""

  function statusMark(status) {
    if (status === "accepted") return "✓"
    if (status === "declined") return "✗"
    if (status === "tentative") return "?"
    return "·"
  }
  function statusColor(status) {
    if (status === "declined") return root.urgent
    return root.foreground
  }

  function measureAnchor() {
    if (!cursorItem) {
      // Opened without a block to hang off (keyboard, agenda shortcut): float
      // the card over the grid rather than pinning it to the corner.
      detailAnchorX = Math.max(Style.space(10), keyCatcher.width / 2 - Style.space(180))
      detailAnchorY = Style.space(90)
      detailAnchorHeight = 0
      return
    }
    var point = cursorItem.mapToItem(keyCatcher, 0, 0)
    detailAnchorX = point.x
    detailAnchorY = point.y
    detailAnchorHeight = cursorItem.height
  }

  function showDetail(event) {
    if (!event) return
    measureAnchor()
    detailEvent = event
    detailCursor = 0
    detailAttendees = []
    detailConference = ""
    var id = String(event.id || "")
    var calendar = String(event.calendar || "")
    if (id === "" || calendar === "") return
    loadingAttendees = true
    attendeesProc.command = [root.script, "attendees", calendar, id]
    attendeesProc.running = true
  }

  function closeDetail() {
    detailAttendees = []
    detailConference = ""
    detailEvent = null
    cursorItem = null
  }

  function openEvent(event) { showDetail(event) }

  function openUrl(url) {
    var safe = safeUrl(url)
    if (!bar || safe === "") return
    close()
    // See openAgenda above: argv, never a shell string. `url` here is an
    // event's own link or a hangout/conference URL pulled out of invite text
    // -- somebody else's data the moment it is a shared or work calendar, and
    // safeUrl()'s character class allows plenty that a shell would happily
    // execute (`$()`, `;`, `'`, ...).
    Util.execArgv(["omarchy-launch-webapp", safe])
  }

  function joinNow() {
    if (!joinable) return
    openUrl(joinable.hangout)
  }

  // ---------------------------------------------------------------------------
  // Blocked / setup states
  // ---------------------------------------------------------------------------

  readonly property string blockedTitle: {
    if (blockedReason === "khal-missing") return "khal is not installed"
    if (blockedReason === "no-calendars") return "No calendars synced yet"
    return "Calendar unreachable"
  }
  readonly property string blockedHint: {
    if (blockedReason === "khal-missing")
      return "This reads your calendars through khal.\nInstall it with: omarchy pkg add khal vdirsyncer"
    if (blockedReason === "no-calendars")
      return "Run the setup, or set up vdirsyncer yourself and run vdirsyncer sync.\nThe .ics files land in ~/.calendars. See the plugin README."
    return "khal is installed and calendars are synced, but it returned nothing."
  }
  readonly property string setupPrompt:
    "Help me set up the Clock + Calendar bar widget on this machine. It reads my calendars " +
    "over CalDAV and it is not working yet. The plugin lives in " +
    "~/.config/omarchy/plugins/rfdegroot.clock.\n\n" +
    "The fastest path is to have me run its own interactive setup in a terminal:\n" +
    "   ~/.config/omarchy/plugins/rfdegroot.clock/bin/calendar-setup\n" +
    "It installs the tools, asks which accounts and calendars to add, syncs, and enables the " +
    "timer. If it does not fit what I need, do it by hand:\n\n" +
    "1. Tell me to run this in a terminal window myself (it needs my password, so you cannot): " +
    "omarchy pkg add vdirsyncer khal\n\n" +
    "2. Copy the example sync config and help me fill it in:\n" +
    "   cp ~/.config/omarchy/plugins/rfdegroot.clock/vdirsyncer.example.conf ~/.config/vdirsyncer/config\n" +
    "   Then edit it for the accounts I actually use, and delete the rest. iCloud: " +
    "https://caldav.icloud.com/ with an app-specific password from appleid.apple.com. " +
    "Nextcloud: https://HOST/remote.php/dav/ with an app password from its security settings. " +
    "Google: needs 'omarchy pkg add python-aiohttp-oauthlib' plus an OAuth 'Desktop app' " +
    "client (client id + secret) from console.cloud.google.com with the CalDAV API enabled.\n\n" +
    "3. Have me run, in a terminal (metasync moves the calendar names and colours, sync " +
    "does not; Google opens a browser here to authorise): " +
    "vdirsyncer discover && vdirsyncer sync && vdirsyncer metasync\n\n" +
    "4. Enable the sync timer:\n" +
    "   cp ~/.config/omarchy/plugins/rfdegroot.clock/systemd/vdirsyncer.{service,timer} ~/.config/systemd/user/\n" +
    "   systemctl --user enable --now vdirsyncer.timer\n\n" +
    "5. Confirm it worked: khal list today 7d should print my events, and the widget fills in " +
    "within a minute.\n\n" +
    "The widget writes its own khal config, so there is nothing else to configure. It reads " +
    "~/.calendars by default; set \"calendarDir\" in ~/.config/calendar-caldav/config.json " +
    "if the vdir root is elsewhere."

  function copySetupPrompt() {
    copyProc.command = ["wl-copy", "--", root.setupPrompt]
    copyProc.running = true
    copiedPrompt = true
  }

  readonly property color joinFill: Qt.rgba(urgentFill.r, urgentFill.g, urgentFill.b, 0.38)
  readonly property color joinFillHot: Qt.rgba(urgentFill.r, urgentFill.g, urgentFill.b, 0.52)
  readonly property color joinBorder: Qt.darker(urgentFill, 2.1)
  readonly property color joinInk: Qt.lighter(urgentFill, 1.35)

  // ---------------------------------------------------------------------------
  // Life-expectancy editor (from the stock clock)
  // ---------------------------------------------------------------------------

  function startEditingLife() {
    root.editingLife = true
    Qt.callLater(function() {
      bornField.text = root.birthYear > 0 ? String(root.birthYear) : ""
      expectancyField.text = String(root.lifeExpectancy)
      bornField.selectAll()
      bornField.forceActiveFocus()
    })
  }
  function cancelEditingLife() {
    root.editingLife = false
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }
  function handleLifeKey(event, other) {
    if (event.key === Qt.Key_Escape) { root.cancelEditingLife(); event.accepted = true }
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.commitLife(); event.accepted = true
    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      other.selectAll(); other.forceActiveFocus(); event.accepted = true
    }
  }
  function clearLife() {
    if (root.birthYear <= 0) return
    persistSettings({ birthYear: 0 })
  }
  function commitLife() {
    var born = Model.parseBirthYear(bornField.text, today.getFullYear())
    var span = Model.parseLifeExpectancy(expectancyField.text)
    if (born !== root.birthYear || span !== root.lifeExpectancy)
      persistSettings({ birthYear: born, lifeExpectancy: span })
    cancelEditingLife()
  }
  function setWeekStart(day) {
    var next = Model.normalizedWeekStart(day, root.weekStart)
    if (next === root.weekStart) return
    persistSettings({ weekStartDay: Model.weekStartSettingName(next) })
  }
  function toggleWeekStart() { setWeekStart(Model.toggledWeekStart(root.weekStart)) }

  // ---------------------------------------------------------------------------
  // Freshness: local clock tick, cheap stamp, khal only when it matters
  // ---------------------------------------------------------------------------

  property string vdirStamp: ""
  property double lastFetchAt: 0
  property bool syncing: false

  readonly property bool nearBoundary: {
    if (!upcoming) return false
    return Math.abs(upcoming.start_minutes - nowMinutes) <= 1
        || Math.abs(upcoming.end_minutes - nowMinutes) <= 1
  }

  function fullFetch() {
    lastFetchAt = Date.now()
    opened ? refresh() : refreshToday()
    if (opened) refreshWarm()
  }

  // Pulls the vdir up to date against the CalDAV server right now, instead
  // of waiting for the vdirsyncer timer's next run.
  function syncNow() {
    if (syncing || vdirsyncProc.running) return
    syncing = true
    vdirsyncProc.command = ["bash", "-lc", "vdirsyncer sync && vdirsyncer metasync"]
    vdirsyncProc.running = true
  }

  onOpenedChanged: {
    if (opened) {
      viewMode = "calendar"
      dayOffset = 0
      showBorrowed = false
      detailEvent = null
      selDay = today.getDate()
      desiredDay = today.getDate()
      var cached = monthByOffset[0] || []
      if (cached.length > 0) days = cached
      else skeleton()
      refresh()
      refreshWarm()
    }
  }

  SystemClock {
    id: sysClock
    precision: SystemClock.Minutes
    onDateChanged: {
      root.displayDate = sysClock.date
      if (Model.keyForDate(sysClock.date) !== String(root.todayKey)) {
        var followToday = root.viewingCurrentMonth && root.calendarView
        root.today = sysClock.date
        if (followToday) root.goToToday()
      }
    }
  }

  Timer {
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      var d = new Date()
      root.nowMinutes = d.getHours() * 60 + d.getMinutes()
      root.displayDate = d
      var sinceFetch = (Date.now() - root.lastFetchAt) / 60000
      if (!root.reachable || root.nearBoundary
          || sinceFetch >= (root.opened ? 3 : 10)) {
        root.fullFetch()
      } else if (!stampProc.running) {
        stampProc.command = [root.script, "stamp"]
        stampProc.running = true
      }
    }
  }

  Timer {
    interval: 1800000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshWarm()
  }

  Process { id: copyProc }
  Process {
    id: attendeesProc
    stdout: StdioCollector {
      onStreamFinished: {
        root.loadingAttendees = false
        try {
          var parsed = JSON.parse(text)
          if (Array.isArray(parsed)) {
            root.detailAttendees = parsed
          } else if (parsed && typeof parsed === "object") {
            root.detailAttendees = Array.isArray(parsed.attendees) ? parsed.attendees : []
            root.detailConference = String(parsed.conference || "")
          }
        } catch (e) { root.detailAttendees = [] }
      }
    }
    onExited: function(exitCode) { root.loadingAttendees = false }
  }
  Process {
    id: calendarProc
    onExited: function(exitCode) {
      root.writingCalendars = false
      root.skeleton()
      root.refresh()
      root.refreshWarm()
    }
  }
  Process {
    id: vdirsyncProc
    onExited: function(exitCode) {
      root.syncing = false
      root.skeleton()
      root.refresh()
      root.refreshWarm()
    }
  }
  Process {
    id: weekProc
    stdout: StdioCollector { onStreamFinished: root.applyPayload(text) }
  }
  Process {
    id: monthProc
    stdout: StdioCollector { onStreamFinished: root.applyPayload(text) }
  }
  Process {
    id: listProc
    stdout: StdioCollector { onStreamFinished: root.applyPayload(text) }
    onExited: function(exitCode) {
      root.loading = false
      if (root.aborting) root.aborting = false
      else if (exitCode !== 0) root.reachable = false
      if (root.refreshPending) { root.refreshPending = false; root.refresh() }
    }
  }
  Process {
    id: stampProc
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var stamp = String(JSON.parse(text).stamp || "")
          if (stamp !== "" && stamp !== "0" && stamp !== root.vdirStamp) root.fullFetch()
        } catch (e) {}
      }
    }
  }

  IpcHandler {
    target: "rfdegroot.clock.test"
    function state(): string {
      return JSON.stringify({ viewMode: root.viewMode, dayOffset: root.dayOffset,
                              selDay: root.selDay, reachable: root.reachable,
                              days: root.days.length, calendars: root.calendars })
    }
    function setView(mode: string): string {
      root.setView(mode)
      return JSON.stringify({ viewMode: root.viewMode })
    }
    function openFirst(): string {
      var pool = root.calendarView ? root.selectedItems
        : (root.days.length > 0
            ? (root.days[root.days.length > 4 ? 4 : 0].events || [])
                .concat(root.days[root.days.length > 4 ? 4 : 0].allday || [])
            : [])
      if (pool.length > 0) root.openEvent(pool[0])
      return JSON.stringify({ opened: !!root.detailEvent })
    }
    // Screen-space geometry of the popup card, for pixel-perfect screenshots.
    function geom(): string {
      return JSON.stringify({ x: Math.round(panel.cardOrigin.x),
                              y: Math.round(panel.cardOrigin.y),
                              w: Math.round(panel.contentWidth),
                              h: Math.round(panel.contentHeight),
                              barH: Math.round(panel.barH),
                              screenW: Math.round(panel.screenW),
                              screenH: Math.round(panel.screenH) })
    }
  }

  // ---------------------------------------------------------------------------
  // Bar button
  // ---------------------------------------------------------------------------

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: root.barSlot
    opticalSize: root.clockLabel === "" ? Style.bar.iconCanvas : root.barSlot
    active: root.inMeeting
    tooltipText: ""

    iconComponent: Component {
      Item {
        Rectangle {
          anchors.centerIn: parent
          width: barContent.implicitWidth + Style.space(8)
          height: Style.space(18)
          radius: Style.cornerRadius
          visible: root.almostDue
          color: root.urgentFill
        }

        Column {
          id: barVertical
          visible: root.vertical
          anchors.centerIn: parent
          Repeater {
            model: root.verticalLines
            OpticalGlyph {
              required property string modelData
              width: button.width
              height: Style.bar.iconSlot
              text: modelData
              fontFamily: root.fontFamily
              fontSize: modelData.length > 3 ? Style.bar.iconFont * 0.9 : Style.bar.iconFont
              color: root.almostDue ? Color.background : root.foreground
            }
          }
        }

        Row {
          id: barContent
          visible: !root.vertical
          anchors.centerIn: parent
          spacing: Style.space(5)

          // A dot in the meeting's calendar colour while something is close but
          // not yet urgent; the whole pill colours once it is.
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.upcoming !== null && root.minutesUntil <= 15
                     && root.minutesUntil > 0 && !root.almostDue
            width: Style.space(7)
            height: Style.space(7)
            radius: width / 2
            color: root.upcoming ? root.upcoming.color : "transparent"
          }

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: root.clockLabel
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            renderType: Text.NativeRendering
            color: root.almostDue ? Color.background
                                  : (root.inMeeting ? root.urgent : root.foreground)
          }
        }
      }
    }

    onPressed: function(b) {
      if (b === Qt.RightButton) root.cycleFormat()
      else if (b === Qt.MiddleButton) { if (root.bar) root.bar.run("omarchy-menu-timezone") }
      else root.toggle()
    }
  }

  // ---------------------------------------------------------------------------
  // Popup
  // ---------------------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher

    readonly property int desiredWidth:
      Style.space(!root.reachable ? 460 : (root.wideView ? 1000 : 560))
    contentWidth: Math.min(desiredWidth,
      panel.availableCardWidth > 0 ? panel.availableCardWidth : desiredWidth)
    readonly property real maxCardHeight: Math.min(Style.space(680),
      availableCardHeight > 0 ? availableCardHeight : Style.space(680))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, maxCardHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingLife || calendarPicker.popupOpen
      onCloseRequested: {
        if (root.detailEvent) root.closeDetail()
        else if (!root.calendarView) root.backToCalendar()
        else root.close()
      }
      onMoveRequested: function(dx, dy) {
        if (root.detailEvent) return
        if (root.calendarView) {
          if (dx !== 0) root.moveSelectedDay(dx)
          else if (dy !== 0) root.moveSelectedDay(dy * 7)
        } else {
          if (dx !== 0) root.goDay(dx)
        }
      }
      onActivateRequested: {
        if (root.detailEvent) {
          var action = root.detailActions[root.detailCursor]
          if (action) root.openUrl(action.url)
        } else if (root.calendarView) {
          if (root.selectedItems.length > 0) root.openEvent(root.selectedItems[0])
          else root.openMonthView()
        }
      }
      onTextKey: function(t) {
        if (root.detailEvent) return
        if (t === "[") root.goDay(-1)
        else if (t === "]") root.goDay(1)
        else if (t === "t" || t === "T") root.goToToday()
        else if ((t === "w" || t === "W") && root.calendarView) root.toggleWeekStart()
      }

      Item {
        id: scroll
        anchors.fill: parent

        Column {
          id: content
          width: scroll.width
          spacing: Style.space(8)

          // ---------------------------------------------------------------
          // Header: hero+nav for the calendar face, a back bar for the rest
          // ---------------------------------------------------------------
          Item {
            id: headerBar
            width: parent.width
            height: root.calendarView ? heroRow.height
                                      : Math.max(backRow.height, Style.space(24))

            // -- Calendar face: the big date, centred, opens the month view
            Row {
              id: heroRow
              visible: root.calendarView
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(18)

              Text {
                textFormat: Text.PlainText
                anchors.baseline: heroDate.baseline
                text: "󰃭" // nf-md-calendar_text
                color: heroMouse.containsMouse
                  ? Style.hoverStateColor(root.foreground, Color.accent) : root.foreground
                font.family: root.fontFamily
                font.pixelSize: 40
              }

              Text {
                id: heroDate
                textFormat: Text.PlainText
                text: Qt.formatDate(root.selectedDate, "MMMM d")
                color: heroMouse.containsMouse
                  ? Style.hoverStateColor(root.foreground, Color.accent) : root.foreground
                font.family: root.fontFamily
                font.pixelSize: 44
                font.bold: true
              }
            }

            MouseArea {
              id: heroMouse
              visible: root.calendarView
              x: heroRow.x
              y: heroRow.y
              width: heroRow.width
              height: heroRow.height
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openMonthView()

              PanelToolTip {
                visible: heroMouse.containsMouse
                text: "Open month view"
                fontFamily: root.fontFamily
              }
            }

            // -- Calendar face: a manual "sync now" nudge, top-right of the hero
            Text {
              id: syncIcon
              textFormat: Text.PlainText
              visible: root.calendarView
              anchors.verticalCenter: heroRow.verticalCenter
              anchors.right: parent.right
              anchors.rightMargin: Style.space(4)
              text: "󰦖" // same glyph as the week/month loading spinner
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              color: syncMouse.containsMouse
                ? Style.hoverStateColor(root.foreground, Color.accent) : root.foreground
              opacity: root.syncing ? 1 : 0.55
              RotationAnimator on rotation {
                running: root.syncing
                from: 0; to: 360; duration: 1000; loops: Animation.Infinite
              }
              MouseArea {
                id: syncMouse
                anchors.fill: parent
                anchors.margins: -Style.space(6)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.syncNow()
              }
              PanelToolTip {
                visible: syncMouse.containsMouse
                text: root.syncing ? "Syncing…" : "Sync calendars now"
                fontFamily: root.fontFamily
              }
            }

            // -- Week / month faces: a back link, paging, and the range label
            Item {
              id: backRow
              visible: !root.calendarView
              width: parent.width
              height: Style.space(26)

              Item {
                id: backLink
                width: backChevron.width + backWord.width + Style.space(5)
                height: parent.height
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  id: backChevron
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: ""
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.foreground
                  opacity: backMouse.containsMouse ? 1 : 0.6
                }
                Text {
                  id: backWord
                  textFormat: Text.PlainText
                  anchors.left: backChevron.right
                  anchors.leftMargin: Style.space(5)
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Calendar"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.foreground
                  opacity: backMouse.containsMouse ? 1 : 0.6
                }
                MouseArea {
                  id: backMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.backToCalendar()
                }
              }

              Text {
                textFormat: Text.PlainText
                id: prevArrow
                anchors.left: backLink.right
                anchors.leftMargin: Style.space(16)
                anchors.verticalCenter: parent.verticalCenter
                text: ""
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.foreground
                opacity: 0.5
                MouseArea {
                  anchors.fill: parent
                  anchors.margins: -Style.space(6)
                  onClicked: root.goDay(-1)
                }
              }

              Text {
                textFormat: Text.PlainText
                id: rangeLabel
                anchors.centerIn: parent
                text: root.dateLabel
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.foreground
                opacity: root.dayOffset === 0 ? 1 : 0.7
              }

              Text {
                textFormat: Text.PlainText
                id: nextArrow
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: ""
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.foreground
                opacity: 0.5
                MouseArea {
                  anchors.fill: parent
                  anchors.margins: -Style.space(6)
                  onClicked: root.goDay(1)
                }
              }

              Text {
                textFormat: Text.PlainText
                anchors.right: nextArrow.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                visible: root.loading
                text: "󰦖"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.foreground
                opacity: 0.6
                RotationAnimator on rotation {
                  running: root.loading
                  from: 0; to: 360; duration: 1000; loops: Animation.Infinite
                }
              }
            }
          }

          // ===============================================================
          // CALENDAR FACE
          // ===============================================================

          // -- Year progress, doubling as the rule under the hero
          Item {
            visible: root.calendarView
            width: parent.width
            height: visible ? yearBlock.height + Style.space(6) : 0

            Item {
              id: yearBlock
              y: Style.space(2)
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: Math.max(yearLabel.implicitHeight, Style.space(10))

              TapHandler {
                enabled: !root.editingLife
                onDoubleTapped: root.startEditingLife()
              }

              Row {
                visible: root.editingLife
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(10)

                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: "BORN"
                  color: Qt.darker(root.foreground, 1.5)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }
                TextField {
                  id: bornField
                  width: Style.space(70)
                  anchors.verticalCenter: parent.verticalCenter
                  placeholderText: "year"
                  foreground: root.foreground
                  font.family: root.fontFamily
                  inputMethodHints: Qt.ImhDigitsOnly
                  Keys.onPressed: function(event) { root.handleLifeKey(event, expectancyField) }
                }
                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  leftPadding: Style.space(6)
                  text: "LIVE TO"
                  color: Qt.darker(root.foreground, 1.5)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }
                TextField {
                  id: expectancyField
                  width: Style.space(60)
                  anchors.verticalCenter: parent.verticalCenter
                  placeholderText: "90"
                  foreground: root.foreground
                  font.family: root.fontFamily
                  inputMethodHints: Qt.ImhDigitsOnly
                  Keys.onPressed: function(event) { root.handleLifeKey(event, bornField) }
                }
              }

              Text {
                id: yearLabel
                textFormat: Text.PlainText
                visible: !root.editingLife
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: root.today.getFullYear()
                color: Qt.darker(root.foreground, 1.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }
              Text {
                id: yearPercent
                textFormat: Text.PlainText
                visible: !root.editingLife
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.yearDonePercent + "%"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Rectangle {
                visible: !root.editingLife
                anchors.left: yearLabel.right
                anchors.right: yearPercent.left
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(6)
                radius: Style.cornerRadius > 0 ? height / 2 : 0
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
                Rectangle {
                  width: Math.round(parent.width * root.yearDone)
                  height: parent.height
                  radius: parent.radius
                  color: Style.selectedStateColor(root.foreground, Color.accent)
                  Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                }
              }
            }
          }

          // -- Memento mori
          Item {
            visible: root.calendarView && root.birthYear > 0
            width: parent.width
            height: visible ? lifeBlock.height : 0

            Item {
              id: lifeBlock
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: Math.max(lifeLabel.implicitHeight, Style.space(10))

              Text {
                id: lifeLabel
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "LIFE"
                color: Qt.darker(root.foreground, 1.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }
              Text {
                id: lifePercent
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.lifeDonePercent + "%"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Rectangle {
                anchors.left: lifeLabel.right
                anchors.right: lifePercent.left
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(6)
                radius: Style.cornerRadius > 0 ? height / 2 : 0
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
                Rectangle {
                  width: Math.round(parent.width * root.lifeDone)
                  height: parent.height
                  radius: parent.radius
                  color: Style.selectedStateColor(root.foreground, Color.accent)
                  Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                }
              }
              TapHandler { onDoubleTapped: root.clearLife() }
            }
          }

          // -- Month grid with week numbers and event dots
          Item {
            visible: root.calendarView
            width: parent.width
            height: visible ? gridColumn.y + gridColumn.height : 0

            WheelHandler {
              onWheel: function(event) {
                if (event.angleDelta.y === 0) return
                root.goDay(event.angleDelta.y > 0 ? -1 : 1)
              }
            }

            Column {
              id: gridColumn
              y: Style.space(12)
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(3)

              readonly property int cellW: Style.space(52)
              readonly property int cellH: Style.space(40)
              readonly property int cellSpacing: Style.space(2)
              readonly property int weekColW: Style.space(30)
              readonly property int gutterW: Style.space(14)

              Row {
                id: gridHeaderRow
                spacing: gridColumn.cellSpacing

                Rectangle {
                  width: gridColumn.weekColW
                  height: Style.space(16)
                  radius: Style.cornerRadius
                  color: weekStartMouse.containsMouse
                    ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
                  Text {
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    text: "W"
                    color: weekStartMouse.containsMouse
                      ? Style.hoverStateColor(root.foreground, Color.accent)
                      : Qt.darker(root.foreground, 1.9)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                    font.bold: true
                  }
                  MouseArea {
                    id: weekStartMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleWeekStart()
                  }
                  PanelToolTip {
                    visible: weekStartMouse.containsMouse
                    text: "Start weeks on " + root.nextWeekStartLabel
                    fontFamily: root.fontFamily
                  }
                }

                Item { width: gridColumn.gutterW; height: Style.space(16) }

                Repeater {
                  model: root.weekdays
                  Text {
                    textFormat: Text.PlainText
                    required property var modelData
                    width: gridColumn.cellW
                    height: Style.space(16)
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: root.weekdayLabel(modelData)
                    color: Qt.darker(root.foreground, 1.5)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                    font.bold: true
                  }
                }
              }

              Repeater {
                model: root.weeks

                Row {
                  id: gridWeekRow
                  required property var modelData
                  spacing: gridColumn.cellSpacing

                  // Week number: opens the timeline for this week.
                  Rectangle {
                    width: gridColumn.weekColW
                    height: gridColumn.cellH
                    radius: Style.cornerRadius
                    color: weekNumMouse.containsMouse
                      ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
                    Text {
                      textFormat: Text.PlainText
                      anchors.centerIn: parent
                      text: gridWeekRow.modelData.week
                      color: weekNumMouse.containsMouse
                        ? Style.hoverStateColor(root.foreground, Color.accent)
                        : Qt.darker(root.foreground, 1.9)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                    MouseArea {
                      id: weekNumMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.openWeekFromRow(gridWeekRow.modelData)
                      PanelToolTip {
                        visible: weekNumMouse.containsMouse
                        text: "Week " + gridWeekRow.modelData.week + "\nOpen the week view"
                        fontFamily: root.fontFamily
                      }
                    }
                  }

                  Item { width: gridColumn.gutterW; height: gridColumn.cellH }

                  Repeater {
                    model: gridWeekRow.modelData.days

                    Rectangle {
                      id: dayCell
                      required property var modelData
                      readonly property var entry:
                        root.monthIndex[modelData.year + "/" + (modelData.month + 1) + "/" + modelData.day] || null
                      readonly property var dots: Model.dayColors(entry, 3)
                      readonly property bool selected:
                        modelData.year === root.selectedDate.getFullYear()
                        && modelData.month === root.selectedDate.getMonth()
                        && modelData.day === root.selectedDate.getDate()

                      width: gridColumn.cellW
                      height: gridColumn.cellH
                      radius: Style.cornerRadius
                      color: selected
                        ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
                      border.width: modelData.today ? Style.spacing.hairline
                                                    : (selected ? 1 : 0)
                      border.color: Style.normalBorderFor(root.foreground, Color.accent)

                      MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.selectCell(dayCell.modelData)
                      }

                      Column {
                        anchors.centerIn: parent
                        spacing: Style.space(3)

                        Text {
                          textFormat: Text.PlainText
                          anchors.horizontalCenter: parent.horizontalCenter
                          text: dayCell.modelData.day
                          color: dayCell.modelData.inMonth
                            ? (dayCell.modelData.weekend
                                ? Qt.darker(root.foreground, 1.45) : root.foreground)
                            : Qt.darker(root.foreground, 2.2)
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.body
                          font.bold: dayCell.modelData.today
                        }

                        Row {
                          anchors.horizontalCenter: parent.horizontalCenter
                          spacing: Style.space(3)
                          height: Style.space(4)
                          Repeater {
                            model: dayCell.dots.colors
                            Rectangle {
                              required property var modelData
                              width: Style.space(4)
                              height: Style.space(4)
                              radius: width / 2
                              color: modelData
                              opacity: dayCell.modelData.inMonth ? 1 : 0.4
                            }
                          }
                          Text {
                            textFormat: Text.PlainText
                            visible: dayCell.dots.more
                            anchors.verticalCenter: parent.verticalCenter
                            text: "+"
                            color: root.foreground
                            opacity: 0.4
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                          }
                        }
                      }
                    }
                  }
                }
              }
            }

            // Hairline down the week-number gutter
            Rectangle {
              x: gridColumn.x + gridColumn.weekColW + gridColumn.cellSpacing
                 + Math.round((gridColumn.gutterW - width) / 2)
              y: gridColumn.y + gridHeaderRow.height + gridColumn.spacing
              width: Style.spacing.hairline
              height: gridColumn.height - gridHeaderRow.height - gridColumn.spacing
              color: root.foreground
              opacity: 0.1
            }
          }

          // -- Month stepping row (calendar face)
          Item {
            visible: root.calendarView
            width: parent.width
            height: visible ? monthNav.height : 0

            Item {
              id: monthNav
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: monthLabel.implicitHeight + Style.space(10)

              Text {
                id: monthLabel
                textFormat: Text.PlainText
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(140)
                horizontalAlignment: Text.AlignHCenter
                text: Qt.formatDate(root.viewMonthDate, "MMMM yyyy").toUpperCase()
                color: Qt.darker(root.foreground, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.letterSpacing: 1
              }

              PanelActionButton {
                anchors.left: parent.left
                anchors.leftMargin: -Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅁"
                tooltipText: "Previous month"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.goDay(-1)
              }
              PanelActionButton {
                anchors.right: parent.right
                anchors.rightMargin: -Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅂"
                tooltipText: "Next month"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.goDay(1)
              }

              Text {
                textFormat: Text.PlainText
                visible: root.dayOffset !== 0
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: monthLabel.bottom
                text: "Today"
                color: todayPillMouse.containsMouse
                  ? Style.hoverStateColor(root.foreground, Color.accent) : root.foreground
                opacity: 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                MouseArea {
                  id: todayPillMouse
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.goToToday()
                }
              }
            }
          }

          // -- Selected day's agenda (calendar face)
          Column {
            visible: root.calendarView && root.reachable
            width: parent.width
            spacing: Style.space(4)

            Row {
              width: parent.width
              spacing: Style.space(6)
              Text {
                textFormat: Text.PlainText
                text: Qt.formatDate(root.selectedDate, "dddd d MMMM")
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.foreground
                opacity: 0.85
              }
              Text {
                textFormat: Text.PlainText
                visible: root.selectedItems.length > 0
                anchors.verticalCenter: parent.verticalCenter
                text: root.selectedItems.length
                      + (root.selectedItems.length === 1 ? " item" : " items")
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.foreground
                opacity: 0.4
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: root.selectedItems.length === 0
              text: "Nothing planned"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: root.foreground
              opacity: 0.5
              topPadding: Style.space(4)
              bottomPadding: Style.space(4)
            }

            Flickable {
              width: parent.width
              visible: root.selectedItems.length > 0
              height: Math.min(agendaColumn.implicitHeight, Style.space(160))
              contentWidth: width
              contentHeight: agendaColumn.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              interactive: contentHeight > height

              Column {
                id: agendaColumn
                width: parent.width
                spacing: Style.space(1)

                Repeater {
                  model: root.selectedItems

                  Rectangle {
                    id: agendaRow
                    required property var modelData
                    width: agendaColumn.width
                    height: Style.space(24)
                    color: agendaMouse.containsMouse
                      ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
                    radius: Style.cornerRadius

                    Rectangle {
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(3)
                      height: parent.height - Style.space(8)
                      color: agendaRow.modelData.color
                    }

                    Text {
                      textFormat: Text.PlainText
                      id: agendaTime
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(12)
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(46)
                      text: agendaRow.modelData.allday ? "all day" : agendaRow.modelData.start
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      color: root.foreground
                      opacity: 0.6
                    }

                    Text {
                      textFormat: Text.PlainText
                      anchors.left: agendaTime.right
                      anchors.leftMargin: Style.space(8)
                      anchors.right: parent.right
                      anchors.rightMargin: Style.space(6)
                      anchors.verticalCenter: parent.verticalCenter
                      text: agendaRow.modelData.title
                      elide: Text.ElideRight
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      color: root.foreground
                    }

                    MouseArea {
                      id: agendaMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        root.cursorItem = agendaRow
                        root.openEvent(agendaRow.modelData)
                      }
                    }
                  }
                }
              }
            }
          }

          // ===============================================================
          // WEEK FACE  (day-column timeline)
          // ===============================================================

          Row {
            id: dayNamesRow
            width: parent.width
            height: visible ? implicitHeight : 0
            visible: root.weekView && root.reachable

            Item { width: root.gutter; height: 1 }

            Repeater {
              model: root.weekView ? root.days : []
              Item {
                id: dayHeader
                required property var modelData
                width: root.columnWidth
                height: dayName.implicitHeight + Style.space(4)

                Rectangle {
                  anchors.centerIn: parent
                  visible: modelData.is_today
                  width: dayName.implicitWidth + Style.space(12)
                  height: dayName.implicitHeight + Style.space(3)
                  radius: height / 2
                  color: Color.accent
                }
                Text {
                  textFormat: Text.PlainText
                  id: dayName
                  anchors.centerIn: parent
                  text: modelData.short_label
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: modelData.is_today ? Color.background : root.foreground
                  opacity: modelData.is_today ? 1 : 0.6
                }
              }
            }
          }

          Row {
            id: alldayRow
            width: parent.width
            height: visible ? implicitHeight : 0
            visible: root.alldayRows > 0 && root.reachable && root.weekView

            Item { width: root.gutter; height: 1 }

            Repeater {
              model: root.weekView ? root.days : []
              Item {
                id: alldayColumn
                required property var modelData
                width: root.columnWidth
                height: root.alldayRows * root.alldayHeight

                Column {
                  anchors.fill: parent
                  anchors.rightMargin: Style.space(2)
                  spacing: Style.space(2)

                  Repeater {
                    model: alldayColumn.modelData.allday
                    Rectangle {
                      id: allDayBlock
                      required property var modelData
                      width: parent.width
                      height: root.alldayHeight - Style.space(2)
                      readonly property color tint: Qt.lighter(modelData.color, 1.25)
                      color: Qt.rgba(tint.r, tint.g, tint.b, 0.24)

                      Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: Style.space(3)
                        color: allDayBlock.modelData.color
                      }
                      MouseArea {
                        id: allDayMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { root.cursorItem = allDayBlock; root.openEvent(allDayBlock.modelData) }
                        PanelToolTip {
                          visible: allDayMouse.containsMouse
                          text: allDayBlock.modelData.title + "\nAll day · " + allDayBlock.modelData.calendar
                          fontFamily: root.fontFamily
                        }
                      }
                      Text {
                        textFormat: Text.PlainText
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: Style.space(8)
                        anchors.rightMargin: Style.space(6)
                        text: allDayBlock.modelData.title
                        elide: Text.ElideRight
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        color: root.foreground
                        opacity: 0.85
                      }
                    }
                  }
                }
              }
            }
          }

          Item {
            id: timeline
            width: parent.width
            readonly property real spanHeight: root.daySpan / 60 * root.hourHeight
            height: visible ? spanHeight + Style.space(10) : 0
            visible: root.reachable && root.weekView

            function yFor(minutes) {
              return (minutes - root.dayStart) / root.daySpan * spanHeight
            }

            Repeater {
              model: root.weekView
                ? Math.floor(root.dayEnd / 60) - Math.ceil(root.dayStart / 60) + 1 : 0
              Item {
                required property int index
                readonly property int hour: Math.ceil(root.dayStart / 60) + index
                width: timeline.width
                height: 1
                y: timeline.yFor(hour * 60)

                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.left: parent.left
                  width: root.gutter - Style.space(6)
                  horizontalAlignment: Text.AlignRight
                  visible: Math.abs(root.nowMinutes - hour * 60) * root.hourHeight / 60 > Style.space(9)
                  text: String(hour).padStart(2, "0") + ":00"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.foreground
                  opacity: 0.4
                }
                Rectangle {
                  anchors.left: parent.left
                  anchors.leftMargin: root.gutter
                  anchors.right: parent.right
                  height: 1
                  color: root.foreground
                  opacity: 0.12
                }
              }
            }

            Row {
              x: root.gutter
              width: timeline.width - root.gutter
              height: timeline.spanHeight

              Repeater {
                model: root.weekView ? root.days : []
                Item {
                  id: dayColumn
                  required property var modelData
                  required property int index
                  width: root.columnWidth
                  height: timeline.spanHeight

                  Rectangle {
                    anchors.fill: parent
                    visible: dayColumn.modelData.is_today
                    color: Color.accent
                    opacity: 0.05
                  }
                  Rectangle {
                    visible: dayColumn.index > 0
                    width: 1
                    height: parent.height
                    color: root.foreground
                    opacity: 0.12
                  }
                  Rectangle {
                    visible: dayColumn.modelData.is_today
                             && root.nowMinutes >= root.dayStart && root.nowMinutes <= root.dayEnd
                    y: timeline.yFor(root.nowMinutes) - 1
                    width: dayColumn.width
                    height: 2
                    color: root.urgentFill
                    z: 11
                  }

                  Repeater {
                    model: dayColumn.modelData.events
                    Rectangle {
                      id: block
                      required property var modelData
                      readonly property bool today: dayColumn.modelData.is_today
                      readonly property bool isNow: today
                        && root.nowMinutes >= modelData.start_minutes
                        && root.nowMinutes < modelData.end_minutes
                      readonly property bool isPast: today && root.nowMinutes >= modelData.end_minutes
                      readonly property int lane: modelData.columns > 0 ? modelData.columns : 1
                      readonly property real laneWidth: (dayColumn.width - Style.space(2)) / lane

                      x: Style.space(2) + modelData.column * laneWidth
                      width: laneWidth - (lane > 1 ? Style.space(2) : 0)
                      y: timeline.yFor(modelData.start_minutes)
                      height: Math.max(Style.space(14),
                        timeline.yFor(modelData.end_minutes) - timeline.yFor(modelData.start_minutes) - 2)
                      readonly property color tint: Qt.lighter(modelData.color, 1.25)
                      color: Qt.rgba(tint.r, tint.g, tint.b, isNow ? 0.5 : 0.28)
                      opacity: isPast ? 0.4 : 1

                      Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: Style.space(3)
                        color: block.modelData.color
                      }
                      MouseArea {
                        id: blockMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { root.cursorItem = block; root.openEvent(block.modelData) }
                        PanelToolTip {
                          visible: blockMouse.containsMouse
                          text: block.modelData.start + " – " + block.modelData.end
                                + "\n" + block.modelData.title
                          fontFamily: root.fontFamily
                        }
                      }
                      Text {
                        textFormat: Text.PlainText
                        anchors.fill: parent
                        anchors.leftMargin: Style.space(8)
                        anchors.rightMargin: Style.space(4)
                        anchors.topMargin: Style.space(3)
                        anchors.bottomMargin: Style.space(3)
                        text: block.lane > 1 ? block.modelData.title : block.modelData.title
                        elide: Text.ElideRight
                        wrapMode: block.height > Style.space(30) ? Text.Wrap : Text.NoWrap
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        color: root.foreground
                      }
                    }
                  }
                }
              }
            }

            Item {
              width: timeline.width
              height: 1
              y: timeline.yFor(root.nowMinutes)
              visible: root.weekView && root.nowMinutes >= root.dayStart && root.nowMinutes <= root.dayEnd
              z: 10
              Rectangle {
                anchors.right: parent.left
                anchors.rightMargin: -root.gutter + Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                width: nowLabel.implicitWidth + Style.space(8)
                height: nowLabel.implicitHeight + Style.space(2)
                radius: Style.cornerRadius
                color: root.urgentFill
                Text {
                  textFormat: Text.PlainText
                  id: nowLabel
                  anchors.centerIn: parent
                  text: root.clockText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: Color.background
                }
              }
              Rectangle {
                anchors.left: parent.left
                anchors.leftMargin: root.gutter
                anchors.right: parent.right
                height: 1
                color: root.urgentFill
                opacity: 0.35
              }
            }
          }

          // ===============================================================
          // MONTH FACE  (wall calendar with event chips)
          // ===============================================================

          Row {
            id: monthWeekdayRow
            width: parent.width
            height: visible ? implicitHeight : 0
            visible: root.monthView && root.reachable

            Repeater {
              model: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
              Item {
                required property var modelData
                width: root.columnWidth
                height: weekdayName.implicitHeight + Style.space(4)
                Text {
                  textFormat: Text.PlainText
                  id: weekdayName
                  anchors.centerIn: parent
                  text: modelData
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.foreground
                  opacity: 0.6
                }
              }
            }
          }

          Column {
            id: monthGrid
            width: parent.width
            visible: root.reachable && root.monthView
            height: visible ? root.monthWeeks * root.monthRowHeight : 0
            spacing: 0

            Repeater {
              model: root.monthView ? root.monthWeeks : 0
              Row {
                id: mWeekRow
                required property int index
                width: parent.width
                height: root.monthRowHeight

                Repeater {
                  model: 7
                  Item {
                    id: mCell
                    required property int index
                    readonly property int dayIndex: mWeekRow.index * 7 + mCell.index
                    readonly property var day: root.days.length > dayIndex ? root.days[dayIndex] : null
                    width: root.columnWidth
                    height: root.monthRowHeight

                    readonly property var items: Model.dayItems(day)
                    readonly property int chipHeight: Style.space(15)
                    readonly property int dateStripHeight: Style.space(18)
                    readonly property int roomForChips:
                      Math.max(0, Math.floor((height - dateStripHeight - Style.space(2)) / chipHeight))
                    readonly property bool overflow: items.length > roomForChips
                    readonly property int shownChips: overflow ? Math.max(0, roomForChips - 1) : items.length

                    Rectangle {
                      anchors.fill: parent
                      color: "transparent"
                      border.width: 1
                      border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
                    }
                    Rectangle {
                      anchors.fill: parent
                      anchors.margins: 1
                      visible: mCell.day && mCell.day.is_today
                      color: Color.accent
                      opacity: 0.06
                    }
                    MouseArea {
                      id: mCellMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.selectDayFromMonth(mCell.day)
                      PanelToolTip {
                        visible: mCellMouse.containsMouse && mCell.day
                        text: mCell.day ? mCell.day.date_label + "\nOpen this day" : ""
                        fontFamily: root.fontFamily
                      }
                    }

                    Item {
                      id: mDateStrip
                      anchors.left: parent.left
                      anchors.top: parent.top
                      anchors.right: parent.right
                      anchors.margins: Style.space(3)
                      height: mCell.dateStripHeight

                      Rectangle {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        visible: mCell.day && mCell.day.is_today
                        width: Math.max(height, mDateNumber.implicitWidth + Style.space(8))
                        height: mDateNumber.implicitHeight + Style.space(2)
                        radius: height / 2
                        color: Color.accent
                      }
                      Text {
                        textFormat: Text.PlainText
                        id: mDateNumber
                        anchors.left: parent.left
                        anchors.leftMargin: (mCell.day && mCell.day.is_today) ? Style.space(4) : 0
                        anchors.verticalCenter: parent.verticalCenter
                        text: mCell.day ? String(mCell.day.day_label || mCell.day.short_label || "") : ""
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        color: (mCell.day && mCell.day.is_today) ? Color.background : root.foreground
                        opacity: (mCell.day && mCell.day.in_month === false) ? 0.35 : 0.8
                      }
                    }

                    Column {
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.top: parent.top
                      anchors.topMargin: mCell.dateStripHeight + Style.space(2)
                      anchors.leftMargin: Style.space(2)
                      anchors.rightMargin: Style.space(2)
                      spacing: 0

                      Repeater {
                        model: mCell.shownChips
                        Rectangle {
                          id: chip
                          required property int index
                          readonly property var ev: mCell.items[chip.index]
                          width: parent.width
                          height: mCell.chipHeight - Style.space(1)
                          readonly property color tint: Qt.lighter(ev.color, 1.25)
                          color: ev.allday ? Qt.rgba(tint.r, tint.g, tint.b, 0.22) : "transparent"

                          Rectangle {
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            width: Style.space(2)
                            color: chip.ev.color
                          }
                          Text {
                            textFormat: Text.PlainText
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: Style.space(6)
                            anchors.rightMargin: Style.space(3)
                            text: chip.ev.allday ? chip.ev.title : (chip.ev.start + "  " + chip.ev.title)
                            elide: Text.ElideRight
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            color: root.foreground
                            opacity: 0.9
                          }
                          MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { root.cursorItem = chip; root.openEvent(chip.ev) }
                          }
                        }
                      }
                      Text {
                        textFormat: Text.PlainText
                        visible: mCell.overflow
                        width: parent.width
                        height: mCell.chipHeight - Style.space(1)
                        verticalAlignment: Text.AlignVCenter
                        leftPadding: Style.space(6)
                        text: "+" + (mCell.items.length - mCell.shownChips) + " more"
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        color: root.foreground
                        opacity: 0.55
                      }
                    }
                  }
                }
              }
            }
          }

          // ===============================================================
          // Shared footer: calendar picker, borrowed toggle, empty / blocked
          // ===============================================================

          MultiSelect {
            id: calendarPicker
            visible: root.reachable
            width: parent.width
            height: root.reachable ? Style.spacing.controlHeight : 0
            label: "Calendars"
            showLabel: false
            triggerLabel: "Calendars"
            noSelectionText: "All calendars"
            emptyText: "No calendars found"
            options: root.calendars
            values: root.checkedCalendars
            fontFamily: root.fontFamily
            onChanged: function(values) { root.applyCalendars(values) }
          }

          Toggle {
            id: borrowedToggle
            visible: root.hasBorrowed
            width: parent.width
            height: root.hasBorrowed ? Style.space(24) : 0
            label: "Show " + root.borrowedLabel
            checked: root.showBorrowed
            foreground: root.foreground
            fontFamily: root.fontFamily
            titleSize: Style.font.caption
            property bool hot: false
            onHovered: function(isHovered) { hot = isHovered }
            color: hot ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
            borderSpec: Border.flat("transparent", 0)
            onClicked: root.toggleBorrowed()
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: root.reachable && !root.calendarView && root.days.length > 0 && root.emptyDay
            text: root.showBorrowed ? "Nothing on " + root.borrowedLabel : "Nothing planned"
            horizontalAlignment: Text.AlignHCenter
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            color: root.foreground
            opacity: 0.6
          }

          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: !root.reachable

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.blockedTitle
              horizontalAlignment: Text.AlignHCenter
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              color: root.foreground
              opacity: 0.85
            }
            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.blockedHint
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: root.foreground
              opacity: 0.6
            }
            Button {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.copiedPrompt ? "Copied, paste it to your agent" : "Copy setup instructions"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.copySetupPrompt()
            }
          }
        }
      }

      // -- Detail card
      MouseArea {
        id: detailShade
        anchors.fill: parent
        z: 20
        visible: !!root.detailEvent
        hoverEnabled: true
        onClicked: root.closeDetail()

        Rectangle {
          id: detailCard
          readonly property real margin: Style.space(10)
          readonly property real desired: Style.space(360)
          width: Math.min(desired, parent.width - margin * 2)
          height: detailColumn.implicitHeight + Style.space(24)
          x: Math.max(margin, Math.min(root.detailAnchorX, parent.width - width - margin))
          y: {
            var below = root.detailAnchorY + root.detailAnchorHeight + Style.space(6)
            if (below + height <= parent.height - margin) return below
            var above = root.detailAnchorY - height - Style.space(6)
            if (above >= margin) return above
            return Math.max(margin, parent.height - height - margin)
          }
          color: Color.popups ? Color.popups.background : Color.background
          radius: Style.cornerRadius
          border.width: Style.normalBorderWidth
          border.color: root.detailEvent ? root.detailEvent.color : root.foreground

          MouseArea { anchors.fill: parent }

          Column {
            id: detailColumn
            anchors.fill: parent
            anchors.margins: Style.space(12)
            spacing: Style.space(10)

            Row {
              width: parent.width
              spacing: Style.space(8)
              Rectangle {
                width: Style.space(3)
                height: detailTitle.implicitHeight
                radius: width / 2
                color: root.detailEvent ? root.detailEvent.color : root.foreground
              }
              Text {
                textFormat: Text.PlainText
                id: detailTitle
                width: parent.width - Style.space(11)
                text: root.detailEvent ? root.detailEvent.title : ""
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                color: root.foreground
                wrapMode: Text.WordWrap
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.detailCalendar !== ""
                ? root.detailWhen + "  ·  " + root.detailCalendar : root.detailWhen
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: root.foreground
              opacity: 0.75
              wrapMode: Text.WordWrap
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: text !== ""
              text: root.detailEvent ? String(root.detailEvent.location || "") : ""
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: root.foreground
              opacity: 0.75
              wrapMode: Text.WordWrap
            }

            Column {
              width: parent.width
              spacing: Style.space(3)
              visible: root.detailAttendees.length > 0 || root.loadingAttendees
              Text {
                textFormat: Text.PlainText
                text: root.loadingAttendees && root.detailAttendees.length === 0
                  ? "Loading attendees" : root.detailAttendees.length + " attendees"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.foreground
                opacity: 0.5
              }
              Repeater {
                model: root.detailAttendees
                delegate: Row {
                  width: detailColumn.width
                  spacing: Style.space(6)
                  Text {
                    textFormat: Text.PlainText
                    text: root.statusMark(modelData.status)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.statusColor(modelData.status)
                    opacity: 0.9
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: String(modelData.name || "")
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.foreground
                    opacity: modelData.status === "declined" ? 0.45 : 0.85
                  }
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: text !== ""
              text: root.detailEvent ? String(root.detailEvent.description || "") : ""
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: root.foreground
              opacity: 0.7
              wrapMode: Text.WordWrap
              maximumLineCount: 8
              elide: Text.ElideRight
            }

            Row {
              width: parent.width
              spacing: Style.space(8)
              visible: root.detailActions.length > 0
              Repeater {
                model: root.detailActions
                delegate: Button {
                  text: modelData.label
                  hasCursor: root.detailCursor === index
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.openUrl(modelData.url)
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Esc goes back"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: root.foreground
              opacity: 0.4
            }
          }
        }
      }
    }
  }
}
