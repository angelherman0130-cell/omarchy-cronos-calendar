import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Tasks.js" as Tasks

// The clock's calendar popup: a month grid with ISO week numbers, built to
// sit beside the weather panel — same hero-over-detail composition, same
// spacing scale, same small-caps labels.
//
// The grid is mostly a read-out rather than a picker: today is the only
// marked day, and the only thing that moves is which month is on screen —
// the chevrons and the left/right arrows step it. What it does accept is
// work: a day can be selected, given tasks, and its tasks ticked off. Days
// carrying tasks keep a dot under the number, so the month reads at a glance
// as a map of where the commitments are.
//
// BarWidget.qml owns the bar label and hands this panel the button to
// anchor against.
Panel {
  id: root
  moduleName: "omarchy.clock"
  ipcTarget: "omarchy.clock"
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel. Everything the bar identifies a panel by has to be that
  // widget: the popout coordinator (and with it the open-panel dot under the
  // pill) compares against `slot.activeItem`, and switchPanelFrom looks the
  // slot up the same way.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Today. SystemClock keeps this honest across midnight so the
  //      highlight rolls over without the panel being reopened.
  property date today: new Date()
  readonly property string todayKey: Model.keyForDate(today)

  // The month on screen. Stepping moves this and nothing else: the grid is
  // mostly a read-out, so there is no per-day cursor to keep in sync beyond
  // the selected day, which the task list below the grid is about.
  property int viewYear: today.getFullYear()
  property int viewMonth: today.getMonth()

  // ---- Tasks. Plain JS objects throughout, replaced wholesale rather than
  //      mutated: QML will not re-evaluate a binding whose only dependency is
  //      a JS object it considers unchanged, so an in-place edit would redraw
  //      nothing.
  readonly property string taskStorePath: Color.stateHome + "/omarchy/clock-tasks.json"
  property var taskStore: Tasks.empty()
  property bool taskStoreLoaded: false
  // Monotonic within a session, so two tasks typed in the same millisecond
  // still get distinct ids — a repeated id would leave the second one
  // untickable.
  property int taskSequence: 0
  // How many days before the task the reminder should start, null for none. A
  // property rather than the chip row's own state because the chip row is
  // drawn from it and the value has to survive redraws; the deadline hour, by
  // contrast, is the field's own text, the same way the task text is.
  //
  // Typed as a var on purpose. As an int, null becomes 0 on assignment, and 0
  // is a real answer here — the task's own day — so the two would be the same
  // value and "no chip selected" would be indistinguishable from "selected the
  // day-of chip".
  property var draftRemindDays: null
  // What the composer will write for the task's priority and tags. They live
  // here rather than on the two controls that set them for the same reason
  // the reminder does: the control is drawn from the value, and a value held
  // only by the control would not survive the panel redrawing underneath it.
  //
  // `draftPopover` is a string and not a pair of booleans because only one
  // mini-window can be open at a time. Two of them is two cards stacked with
  // no answer to which one Escape belongs to, and a click that closes one and
  // opens the other is a surprise dressed as a toggle.
  property var draftPriority: null
  property var draftTags: []
  property string draftPopover: ""
  // Whether the deadline field holds anything, and whether it holds a time.
  // Both are asked of the field's own text rather than of a copy, so the icon
  // cannot claim a deadline is set while the field is empty. The second one
  // exists so a mistyped hour is refused visibly: cleanTime drops it silently
  // on commit, and a deadline that quietly becomes no deadline is how you end
  // up relying on a reminder you thought you had set.
  readonly property bool dueFieldFilled: String(dueField.text || "").replace(/[\s:.]/g, "") !== ""
  readonly property bool dueFieldValid: !root.dueFieldFilled || Tasks.cleanTime(dueField.text) !== ""
  // The deadline as it will actually be stored. The stepper and the summary
  // line both read this rather than the raw field text, so a half-typed "1"
  // cannot have one of them disagree with what commit will save.
  readonly property string draftDue: Tasks.cleanTime(dueField.text)

  // The two optional extras, each said back in words instead of only encoded in
  // a control. A bare "3" beside a clock says three of something; "Starts
  // Fri 11 Sep" says three days before this task, which is the part that was
  // actually ambiguous.
  readonly property string draftDueSummary: {
    if (root.dueFieldFilled && !root.dueFieldValid) return "Unreadable time"
    if (root.draftDue === "") return "No deadline"
    return "Due " + root.dayPhrase(root.selectedKey) + " at " + root.draftDue
  }
  readonly property string draftRemindSummary: {
    if (root.draftRemindDays === null) return "No reminder"
    var phrase = root.dayPhrase(Tasks.reminderDayKey(root.selectedKey, root.draftRemindDays))
    if (phrase === "") return "No reminder"
    return "Starts " + phrase
  }
  // An unreadable hour is the one of these that earns the red, and it is the
  // same red as everything else still owed: an hour that silently disappears on
  // commit is the most consequential of the three states, not a cosmetic one.
  // The two empty states stay quiet rather than shouting "unset".
  readonly property color draftDueSummaryColor: root.dueFieldFilled && !root.dueFieldValid
    ? root.pendingTaskColor
    : root.dueFieldFilled
      ? Qt.alpha(root.contentForeground, 0.62)
      : Qt.darker(root.contentForeground, 2)
  readonly property color draftRemindSummaryColor: root.draftRemindDays !== null
    ? Qt.alpha(root.contentForeground, 0.62)
    : Qt.darker(root.contentForeground, 2)

  // Parsed back out of the key so headers and tooltips can name the day.
  // Local midnight, never UTC: a UTC parse would show the wrong day for
  // anyone west of Greenwich in the evening.
  function dateForKey(key) {
    var parts = String(key).split("-")
    if (parts.length !== 3) return new Date()
    return new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
  }

  // ---- Which tasks the list is about. Two views of the same store, and the
  //      default is the wider one: every outstanding task in it, soonest first,
  //      because the whole point of a list spanning several days is the one
  //      thing no single day can answer — what is about to be due.
  //
  //      Picking a day narrows it to that day. The day is still `selectedKey`
  //      either way, because the composer writes to it and a task in the wider
  //      view can be ticked off or thrown away; narrowing the *list* is not the
  //      same thing as narrowing the *store*, and keeping them one property is
  //      what lets a global row be acted on without moving the cursor.
  property bool allDays: true
  readonly property var pendingGroups: Tasks.pendingGroups(taskStore)
  readonly property var pendingAll: Tasks.pendingGroupSummary(taskStore)
  // The pending tasks as one flat list, so the tag row can count them without
  // the groups' shape getting in the way. Tagged where the day view already
  // tags them, and gathered from the same groups in the wider view, so both
  // views offer the same chips for the same reasons.
  readonly property var tagPool: {
    if (!root.allDays) return root.selectedPendingTagged
    var out = []
    for (var i = 0; i < root.pendingGroups.length; i++) {
      var group = root.pendingGroups[i]
      if (group && Array.isArray(group.tasks)) out = out.concat(group.tasks)
    }
    return out
  }

  // ---- Searching the list.
  //
  //      The needle the list is narrowed by, or "" when there is none. It is
  //      never folded into `allDays` or `selectedKey`: filtering is a third
  //      question again — "which of these" — and sharing a property with the
  //      day or the view would make clearing a search look like going back to
  //      all pending, or like picking a day that was never picked.
  //
  //      Every derived list below is computed here rather than at each
  //      Repeater, so the list, its headings and its header all answer the
  //      same needle and cannot drift apart.
  property string searchQuery: ""
  readonly property bool searchActive: Tasks.searchNeedle(searchQuery) !== ""
  // The tag the list is following, or "" for all of them. Kept beside the
  // search because it is the same act — narrowing what is drawn — and because
  // a second filter on the other side of the panel would be a filter nobody
  // could see both of at once.
  property string tagFilter: ""
  readonly property bool tagActive: Tasks.tagNeedle(tagFilter) !== ""
  // The two filters compose rather than replace: a search inside a tag is the
  // ordinary case for finding one thing among the things already filed under a
  // subject, and making the second one clear the first would mean choosing
  // between them.
  readonly property bool narrowActive: root.searchActive || root.tagActive
  // What to say when a narrowed list comes back empty. The filter in force is
  // named rather than described, because "Nothing pending" would be a second
  // answer to a different question — the store may well be full, and only the
  // needle is not in it. The tag goes first when both are set, since it is the
  // narrower of the two and the one whose name is short enough to read at a
  // glance.
  readonly property string emptyNarrowText: root.tagActive
    ? root.searchActive
      ? "No task tagged #" + Tasks.tagNeedle(root.tagFilter)
        + " matches “" + Tasks.searchNeedle(root.searchQuery) + "”."
      : "Nothing tagged #" + Tasks.tagNeedle(root.tagFilter) + " here."
    : "No task matches “" + Tasks.searchNeedle(root.searchQuery) + "”."
  // The groups the wider view draws, the day's own open work, and that day's
  // finished block — all narrowed the same way. The finished block is included
  // because a search that leaves it alone is a search that hides results
  // below a list of things it did not filter.
  readonly property var listGroups: Tasks.filterGroups(root.pendingGroups, root.searchQuery, root.tagFilter)
  readonly property var listDayPending: Tasks.filterByTag(Tasks.filterTasks(root.selectedPendingTagged, root.searchQuery), root.tagFilter)
  readonly property var listDayDone: Tasks.filterByTag(Tasks.filterTasks(root.selectedDoneTagged, root.searchQuery), root.tagFilter)
  readonly property var listSummary: Tasks.groupSummary(root.listGroups)
  readonly property int listPending: root.listDayPending.length
  readonly property int listDone: root.listDayDone.length

  // Every tag still worth offering, counted over what is pending rather than
  // over what is drawn: counted over the drawn list, the chip for the tag
  // being followed would be the one tag missing from the row, since following
  // it is what removed everything else. The tag in force is put back at the
  // head if that happens, so there is always a chip to click to stop.
  readonly property var tagCatalog: Tasks.tagCounts(root.tagPool)
  readonly property var tagChips: {
    var list = root.tagCatalog.slice()
    var active = Tasks.tagNeedle(root.tagFilter)
    if (active === "") return list
    for (var i = 0; i < list.length; i++) {
      if (list[i].tag === active) return list
    }
    list.unshift({ tag: active, count: 0 })
    return list
  }

  // The day the task list is about. Starts on today and follows it across
  // midnight, but a day picked by hand stays picked.
  property string selectedKey: todayKey
  readonly property var selectedTasks: Tasks.tasksFor(taskStore, selectedKey)
  readonly property var selectedPendingTasks: Tasks.pendingFor(taskStore, selectedKey)
  readonly property var selectedDoneTasks: Tasks.doneFor(taskStore, selectedKey)
  // Every task on screen already knows which day it belongs to — it was
  // selected out of that day — but a deadline is meaningless without it, since
  // the hour only means something on its own date. Tagged here rather than in
  // the row so that the row never has to be told what day it is drawing.
  readonly property var selectedPendingTagged: tagDay(selectedPendingTasks, selectedKey)
  readonly property var selectedDoneTagged: tagDay(selectedDoneTasks, selectedKey)
  readonly property int selectedPending: selectedPendingTasks.length
  readonly property int selectedDone: selectedDoneTasks.length

  // The finished block belongs to a single day. In the wider view it would sit
  // under tasks from other days, and a list of what is outstanding with one
  // day's worth of receipts bolted to the bottom of it is two lists pretending
  // to be one. Clicking a day is how you go and read a day.
  //
  // Counted off the filtered list rather than the store's, so a search that
  // hides every finished task also takes away the rule and heading above them
  // instead of leaving a finished block with nothing in it.
  readonly property bool showDoneSection: !root.allDays && root.listDone > 0

  // The completed section shows a few and folds the rest away, so a long day
  // cannot push the composer off the panel. `doneExpanded` is the user's own
  // toggle and is deliberately never reset by an edit: adding a task should
  // not slam the list shut under them.
  readonly property int collapsedDoneLimit: 5
  property bool doneExpanded: false

  // The stats block, closed by default. Every figure on this panel is already
  // stated somewhere — the count in the header, the badge on the row — and a
  // block that is always open would add a fourth place to read the same
  // numbers. Closed until asked for is what keeps it from being noise, and
  // keeping it open once it is open is the reader's own decision, never
  // reset by an edit or a page-turn.
  property bool statsExpanded: false

  // The four figures, as one list so the block draws them all the same way.
  //
  // The first three are about today and not about the day on screen: a streak
  // that changed when you clicked next Thursday would be a streak about
  // nothing. The last is about what is on the list right now, which is the
  // only figure here that a filter can move — and it should move, because the
  // priorities of the tasks you are looking at are the ones you are sorting.
  readonly property var statsFigures: {
    if (!root.taskStoreLoaded) return []
    var streak = Tasks.streak(root.taskStore, root.todayKey)
    var today = Tasks.countDone(root.taskStore, root.todayKey)
    var week = Tasks.countDoneInRange(root.taskStore,
      Tasks.dayKeyShift(root.todayKey, -6), root.todayKey)
    var pri = Tasks.countByPriority(root.tagPool)
    var weekTip = "Finished on each of the last seven days, counted back from today."
    return [
      { value: String(streak), label: streak === 1 ? "DAY STREAK" : "DAY STREAK",
        tip: streak === 0
          ? "Nothing finished today yet — the streak starts with one."
          : "A task finished on " + streak + " consecutive days, ending today." },
      { value: String(today), label: "DONE TODAY",
        tip: "Tasks ticked off on today's date." },
      { value: String(week), label: "LAST 7 DAYS",
        tip: weekTip },
      { value: String(pri.high + " " + pri.medium + " " + pri.low), label: "HIGH MED LOW",
        tip: "Pending tasks by priority: " + pri.high + " high, "
          + pri.medium + " medium, " + pri.low + " low, "
          + pri.none + " with none set." }
    ]
  }

  // The delete waiting to be undone: the day it belonged to, the task itself
  // and the index it sat at, or null when there is nothing outstanding.
  //
  // The whole task and not just its id, because there is nothing left in the
  // store to look it up from the moment after it is gone — an id pointing at a
  // row that no longer exists restores nothing. Holding the copy is what makes
  // the undo independent of every other edit made in the meantime, so ticking
  // two other tasks off before pressing Undo still puts this one back exactly
  // as it was.
  //
  // One, not a stack. Only the last delete is reachable by a button that is
  // already on screen, and a queue of them would promise a way back through
  // every accident of the last six seconds when only the newest is wired up.
  property var pendingUndo: null

  readonly property var selectedDate: dateForKey(selectedKey)

  // Two colours, and only two: red for everything still owed, green for
  // everything finished. Neither can come from a theme role — on a neutral
  // theme such as Aether the accent is plain grey and there is no "red" or
  // "green" role at all — so the hues are pinned and only the lightness follows
  // the theme, which keeps the dots equally weighted and legible on a light or
  // a dark panel.
  //
  // One red rather than a separate alarm colour is deliberate. Outstanding work,
  // a deadline that has passed and an hour that could not be read are the same
  // message to whoever is looking — deal with this — so they wear the same
  // colour, and the green is left meaning exactly one thing. Splitting them
  // would mean a task that is both unfinished and overdue wearing two
  // different reds at once, which tells the reader nothing.
  //
  // Green rather than red on finished work: red on a ticked-off task reads as
  // "this went wrong", which is the opposite of what ticking it means.
  readonly property real foregroundLuma: 0.299 * root.contentForeground.r
    + 0.587 * root.contentForeground.g
    + 0.114 * root.contentForeground.b
  readonly property real taskDotLightness: root.foregroundLuma < 0.5 ? 0.62 : 0.42
  readonly property color pendingTaskColor: Qt.hsla(0.00, 0.72, root.taskDotLightness)
  readonly property color doneTaskColor: Qt.hsla(0.37, 0.62, root.taskDotLightness)

  // True while a text field owns the keyboard, whether it is one of the
  // composer's own or one of the two inside an open row editor. The panel's key
  // dispatcher stands down and letters reach the field instead of walking the
  // calendar.
  //
  // All of them, not just the task field. The deadline field used to be left out
  // of it, which was harmless while the only way into it was clicking — but a
  // stepper that takes the focus so the next digit has somewhere to land makes
  // "focused on the deadline" the normal state of typing a time, and with the
  // dispatcher still live a "t" would jump the calendar to today and a "w" would
  // move the week start out from under the cursor. The note field is the same
  // case one field further down: it takes focus by Tab or by click and then
  // expects letters.
  //
  // `editingRow` is in there for the row's own fields, and is a property of the
  // panel rather than a focus check: a row editor is dismissed by saving or by
  // Escape, and the moment between opening it and the field actually taking
  // focus is exactly when a stray key would be walked to the calendar instead of
  // ignored. Each field releases the focus on Escape, so standing down is not a
  // trap.
  readonly property bool editingTask: taskField.activeFocus || noteField.activeFocus
    || dueField.activeFocus || root.editingRow

  // The one row whose editor is open, as "day/id", or "" when none is.
  //
  // A single row rather than a flag per row, and it lives here rather than in
  // TaskRow because the rows cannot see each other. Two open editors would be two
  // sets of fields sharing one keyboard focus with nothing on screen saying
  // which one Escape belongs to — and in the wider view the rows are not even
  // adjacent, so the mistake would not be visible.
  //
  // Keyed by day as well as id: `find` matches on id within a day, so two days
  // holding the same id — a hand-edited file, or a task copied between days —
  // are two different tasks as far as the store is concerned.
  property string editingRowKey: ""

  readonly property bool editingRow: root.editingRowKey !== ""

  // Minutes since midnight, straight off the minute-precision clock. Bound to
  // the clock rather than to a timer of our own because the clock is already
  // ticking for the day rollover; a second source of "now" would be a second
  // thing to keep in step, and it is the one value a stale copy would show as
  // a task wrongly not yet overdue.
  readonly property int nowMinutes: Tasks.minutesNow(clock.date)

  readonly property date viewDate: new Date(viewYear, viewMonth, 1)

  // The big date at the top of the panel. The original pins this to the wall
  // clock, which is right until the month is browsed: page forward and a hero
  // still reading the old month is the grid contradicting the one line above
  // it, and the whole panel reads as if the month change did not take. So it
  // follows the day the panel is actually looking at, and falls back to the
  // 1st of the month on screen when the selection belongs to a month that is
  // no longer there — the grid only ever shows a month on either side, so the
  // two can disagree by exactly one step, and the grid wins.
  readonly property date heroDate:
    selectedDate.getFullYear() === viewYear && selectedDate.getMonth() === viewMonth
      ? selectedDate
      : viewDate
  readonly property bool viewingCurrentMonth: viewYear === today.getFullYear() && viewMonth === today.getMonth()

  // Pinned to today, not to the month being browsed — stepping through the
  // calendar does not change how much of the year is gone.
  readonly property real yearDone: Model.yearProgress(today.getFullYear(), today.getMonth(), today.getDate())
  readonly property int yearDonePercent: Model.yearProgressPercent(today.getFullYear(), today.getMonth(), today.getDate())

  // Memento mori, for anyone who goes looking: double-tapping the year bar
  // asks for a birth year and a life expectancy, and a second bar tracks one
  // against the other. A birth year rather than an age, so it keeps counting
  // on its own. Without one the bar stays hidden.
  readonly property int birthYear: Model.parseBirthYear(setting("birthYear", 0), today.getFullYear())
  readonly property int age: Model.ageFromBirthYear(birthYear, today.getFullYear())
  readonly property int lifeExpectancy: Model.parseLifeExpectancy(setting("lifeExpectancy", 0))
  readonly property real lifeDone: Model.lifeProgress(age, lifeExpectancy)
  readonly property int lifeDonePercent: Model.lifeProgressPercent(age, lifeExpectancy)
  property bool editingLife: false

  // Unset falls through to the locale's own first day, so a fresh install
  // starts out matching the rest of the desktop rather than a hardcoded
  // convention. Clicking the grid's "W" heading writes the choice back to
  // shell.json.
  readonly property int weekStart: Model.normalizedWeekStart(setting("weekStartDay", null), Qt.locale().firstDayOfWeek)
  // The interface is English throughout, so day names are not taken from the
  // system locale. Where the week starts still is: that is a regional
  // convention rather than a translation, and it stays overridable above.
  readonly property var labelLocale: Qt.locale("en_US")
  readonly property string nextWeekStartLabel: labelLocale.dayName(Model.toggledWeekStart(weekStart), Locale.LongFormat)
  readonly property var weekdays: Model.weekdayOrder(weekStart)
  readonly property var weeks: Model.monthGrid(viewYear, viewMonth, weekStart, todayKey)

  // ---- Which calendar is on screen.
  //
  // The week is the one you land on, and the month is one click away. The
  // reason is the panel's own shape: a week is seven cells big enough to read
  // and to hit, and it answers the question people open this for — what is
  // happening now — where a month answers a question they ask less often.
  // Nothing is lost by it, because the month is the very next control over
  // and it stays exactly where it was.
  //
  // "week" rather than a boolean so a third view can be added without
  // turning every test below into a pair of negations.
  property string calView: "week"

  // The day the week view is anchored on: the week containing it, and
  // therefore the week that steps when the chevrons are pressed. It follows
  // the day being looked at rather than a separate cursor of its own, so the
  // calendar and the list can never be showing two different days.
  property string weekAnchorKey: todayKey

  readonly property bool weekView: root.calView === "week"

  // What the grid draws. One row in the week view, the six the month always
  // drew in the month view — the same cell objects either way, so the grid's
  // delegate does not know which of the two it is drawing and cannot treat
  // them differently.
  readonly property var gridRows: {
    if (root.calView !== "week") return root.weeks
    var week = Model.weekGrid(root.weekAnchorKey, root.weekStart, root.todayKey)
    return week === null ? [] : [week]
  }

  // The first and last day of the week on screen, for the header. Read off
  // the row actually drawn rather than recomputed, so the label and the cells
  // cannot disagree about which days this week has.
  readonly property var weekSpan: {
    if (!root.weekView || root.gridRows.length === 0) return null
    var days = root.gridRows[0].days
    if (!days || days.length < 7) return null
    return { first: days[0], last: days[6] }
  }

  // The header's own line for the week, sized to sit where "SEPTEMBER 2026"
  // sits. The year is dropped whenever both ends share it — it is written in
  // full on the rail above, and repeating it here is what pushes a two-month
  // range off the edge.
  readonly property string weekRangeLabel: {
    if (root.weekSpan === null) return ""
    var a = root.weekSpan.first
    var b = root.weekSpan.last
    var from = root.labelLocale.toString(new Date(a.year, a.month, a.day), "d MMM")
    var to = root.labelLocale.toString(new Date(b.year, b.month, b.day), "d MMM")
    var same = a.year === b.year
    return (from + "–" + to + (same ? "" : " " + b.year)).toUpperCase()
  }


  // Guarded so the widget renders before the bar is injected (the bar-widget
  // contract instantiates it bare).
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int cellWidth: Style.space(52)
  readonly property int cellHeight: Style.space(34)
  readonly property int cellSpacing: Style.space(2)
  readonly property int weekColumnWidth: Style.space(32)
  readonly property int gutterWidth: Style.space(14)

  function open() {
    refresh()
    root.controller.show()
    // Set after showing, not before: showing hands the popout coordinator
    // over, which closes whichever panel was open, and that close clears the
    // shared flag. Deferring means the panel taking over always wins, while
    // a handoff to a panel that does not manage the flag still leaves it
    // cleared rather than stuck on.
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    // Dismissing the panel mid-edit would otherwise leave the inputs up,
    // waiting behind a closed popup for the next time it opens.
    if (root.editingLife) root.cancelEditingLife()
    root.commitDraftTask()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Summoning by hotkey moves no pointer, so a hover the bar was still
  // holding must not keep the center indicators revealed behind the panel.
  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function refresh() {
    root.today = new Date()
    root.goToToday()
  }

  // Goes to today without deciding which view of the task list that implies.
  // `t` and the TODAY button ask for today's date, not for today's task list, so
  // this moves the cursor and leaves `allDays` alone; run through selectDay
  // instead and a `t` pressed in the wider view would quietly close it down to
  // one day, and a `t` pressed on an already-selected today would open it back
  // up — the same key doing opposite things depending on what it found.
  function goToToday() {
    root.weekAnchorKey = todayKey
    var delta = Model.monthDistance(today.getFullYear(), today.getMonth(), viewYear, viewMonth)
    pageTo(today.getFullYear(), today.getMonth(), delta >= 0 ? 1 : -1)
    root.selectedKey = todayKey
  }

  // The chevrons, the arrow keys and `[`/`]` all come through here, and which
  // calendar they step is the whole difference between the two views. One
  // entry point means the two can never disagree about what a right-arrow is
  // worth — a month in one and a week in the other, depending on a test made
  // in three places.
  function moveStep(delta) {
    if (root.calView === "week") root.moveWeek(delta)
    else root.moveMonth(delta)
  }

  // A week at a time. Deliberately without the page-turn slide the month
  // uses: that animation moves the header and the grid together because both
  // are derived from viewYear/viewMonth, and in the week view only the anchor
  // changes — a slide would carry the header somewhere the grid had not gone.
  function moveWeek(delta) {
    var next = Tasks.dayKeyShift(root.weekAnchorKey, Number(delta) * 7)
    if (!Tasks.isDayKey(next)) return
    root.weekAnchorKey = next

    // The month follows the week rather than being left behind. It is not on
    // screen here, but it is where the month view opens when you go back to
    // it, and a header that said SEPTEMBER over a week in October would be
    // wrong twice over — once here and once the moment you switched.
    var date = Model.parseDayKey(next)
    if (date !== null) {
      root.viewYear = date.getFullYear()
      root.viewMonth = date.getMonth()
    }
  }

  function moveMonth(delta) {
    var next = Model.stepMonth(viewYear, viewMonth, delta)
    pageTo(next.year, next.month, delta >= 0 ? 1 : -1)
  }

  function moveYear(delta) {
    // Fifty-two weeks is exactly 364 days, so the week view lands on the same
    // weekday a year away rather than a day or two off it.
    if (root.calView === "week") {
      root.moveWeek(Number(delta) * 52)
      return
    }
    moveMonth(delta * 12)
  }

  // Switching to the week lands on the week holding the day being looked at,
  // or on one that is at least in the month on screen. The day picked last
  // month is not a sensible week to jump to when the panel is showing this
  // one — the reader's attention is on what is here now.
  function setCalView(view) {
    var next = view === "month" ? "month" : "week"
    if (next === root.calView) return

    if (next === "week") {
      var anchor = root.selectedKey
      var parsed = Model.parseDayKey(anchor)
      if (parsed === null
        || parsed.getFullYear() !== root.viewYear
        || parsed.getMonth() !== root.viewMonth) {
        var today = Model.parseDayKey(root.todayKey)
        anchor = today !== null
          && today.getFullYear() === root.viewYear
          && today.getMonth() === root.viewMonth
          ? root.todayKey
          : Model.dateKey(root.viewYear, root.viewMonth, 1)
      }
      root.weekAnchorKey = anchor
    }

    root.calView = next
    // Any half-finished page-turn belongs to the month that is no longer on
    // screen, and would start the next one off-centre.
    root.monthSlideX = 0
    if (monthSlideAnim) monthSlideAnim.stop()
  }

  // Applied locally first so the panel redraws on the click itself; the
  // shell.json write comes back through the bar as the same value. With no
  // writable entry (the widget is not in the layout) it stays a session-only
  // preference rather than doing nothing. The host widget builds its own
  // entry when the label format is cycled, so it has to be kept in step or
  // it would write this key straight back out from a stale copy.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function setWeekStart(day) {
    var next = Model.normalizedWeekStart(day, root.weekStart)
    if (next === root.weekStart) return
    persistSettings({ weekStartDay: Model.weekStartSettingName(next) })
  }

  // ---- Tasks
  //
  // Selecting a day is the only per-day cursor the grid carries, and it exists
  // for the task list rather than for the calendar: the month itself is still
  // stepped a month at a time.

  // Picking a day narrows the list to it. Picking the day already showing puts
  // it back, so the wider view is never a mode you can only leave by reloading:
  // the grid is the one control that is always on screen and always aimed at a
  // day, which makes it the right place for both directions of that toggle.
  function selectDay(key) {
    if (!Tasks.isDayKey(key)) return
    var day = String(key)
    if (day === root.selectedKey) root.allDays = true
    else {
      root.selectedKey = day
      root.allDays = false
    }
  }

  // The wider view again, from the list's own header rather than from the grid.
  // The grid can do it too, but a header that says which day you are looking at
  // and does nothing when pressed is a label pretending to be a button.
  function showAllDays() {
    root.allDays = true
  }

  // Narrowing to a specific day, from a group heading in the list rather than
  // from the grid. Not selectDay: that one toggles, because the grid is showing
  // a day that may already be the one on screen, and a heading in the list can
  // only ever be reached from the wider view. Reusing the toggling version would
  // mean pressing the heading for today threw the whole list open instead of
  // showing today.
  function jumpToDay(key) {
    if (!Tasks.isDayKey(key)) return
    root.selectedKey = String(key)
    root.allDays = false
  }

  // Clicking a day in a neighbouring month selects it and pulls the view
  // along, so the grid never shows a selection it is not displaying.
  function selectGridDay(cell) {
    root.selectDay(cell.key)
    if (!cell.inMonth) {
      // A day from the neighbouring month is a request to go there, so it
      // turns the page rather than leaving the grid on a month that is not the
      // one whose day was just pressed.
      var delta = Model.monthDistance(cell.year, cell.month, viewYear, viewMonth)
      pageTo(cell.year, cell.month, delta >= 0 ? 1 : -1)
    }
  }

  function focusTaskField() {
    taskField.forceActiveFocus()
  }

  // The search gets its own shortcut alongside the task field's `n`, because
  // the two are the same kind of act — reaching for a field rather than reading
  // the panel — and because a shortcut nobody can remember is not a shortcut.
  // `s` rather than `/`: every other key here is a bare letter, and `/` in a
  // list is a habit borrowed from somewhere else.
  function focusSearchField() {
    searchField.forceActiveFocus()
  }

  // Copy of `list` with each task carrying the day it was read from. A fresh
  // array on purpose: the row binds to `task.dueTime`, and handing it the very
  // objects the store holds means a tick that changed one would repaint every
  // row rather than just the one that changed.
  function tagDay(list, key) {
    var out = []
    for (var i = 0; i < list.length; i++) {
      var task = list[i]
      var tagged = {}
      for (var field in task) if (Object.prototype.hasOwnProperty.call(task, field)) tagged[field] = task[field]
      tagged.dayKey = String(key)
      out.push(tagged)
    }
    return out
  }

  function commitDraftTask() {
    var text = String(taskField.text || "")
    if (text.replace(/^\s+|\s+$/g, "") === "") return
    root.applyTask(Tasks.add(
      root.taskStore, root.selectedKey, text, root.nextTaskId(),
      String(dueField.text || ""), root.draftRemindDays, String(noteField.text || ""),
      root.draftPriority, root.draftTags))
    root.clearDraft()
  }

  // One mini-window at a time, and pressing the button that owns the open one
  // closes it. A control that can only ever open is one you have to go and
  // click somewhere else to be rid of, which is how a card ends up parked over
  // the list while you are trying to read it.
  function toggleDraftPopover(which) {
    root.draftPopover = root.draftPopover === which ? "" : which
    if (root.draftPopover === "") return
    // Focus rides with the window, and to the field inside it when there is
    // one: the panel's own Escape closes the whole card, so a window that did
    // not take focus would answer Escape by throwing away everything typed.
    Qt.callLater(function() {
      if (root.draftPopover === "tags") {
        if (tagDraftField) tagDraftField.forceActiveFocus()
      } else if (composerPopover) {
        composerPopover.forceActiveFocus()
      }
    })
  }

  // Trimmed and folded by `cleanTags` rather than by hand here: de-duplication
  // and the stripping of a leading `#` are the same two rules the row's editor
  // obeys, and a composer that spelled them differently would create a tag the
  // filter then refused to match.
  //
  // Split on commas first, because that is how the editor already takes them
  // and how anyone with three tags to add will paste them. One field that
  // answers both ways is one field; two would be two things to remember about
  // a box that looks the same either way.
  function addDraftTag(raw) {
    var parts = String(raw || "").split(",")
    root.draftTags = Tasks.cleanTags(root.draftTags.concat(parts))
  }

  function removeDraftTag(tag) {
    var folded = String(tag).toLowerCase()
    root.draftTags = root.draftTags.filter(function(t) {
      return t.toLowerCase() !== folded
    })
  }

  // Every half of a half-typed task is thrown away together. Leaving the note,
  // the chosen reminder, the priority or the tags behind would silently attach
  // them to the next task typed, which is how a task ends up with a deadline
  // nobody ever chose.
  function clearDraft() {
    taskField.text = ""
    noteField.text = ""
    dueField.text = ""
    root.draftRemindDays = null
    root.draftPriority = null
    root.draftTags = []
    root.draftPopover = ""
  }

  // Pressing the same chip twice turns the reminder off, so there is never a
  // state on screen that cannot be undone from the same place. Off is null and
  // not 0, because 0 is the day-of chip.
  function toggleRemindDays(days) {
    root.draftRemindDays = root.draftRemindDays === days ? null : days
  }

  // A day named the way a person would name it: "today", "tomorrow", "yesterday"
  // for the three that have names of their own, and a short date for anything
  // else. No article on the dated form — English does not carry one, and
  // "Starts Fri 11 Sep" is the whole of what it needs to say.
  function dayPhrase(key) {
    if (!Tasks.isDayKey(key)) return ""
    var day = String(key)
    var midnight = new Date(today.getFullYear(), today.getMonth(), today.getDate())

    if (day === root.todayKey) return "today"
    if (day === Model.keyForDate(new Date(midnight.getFullYear(), midnight.getMonth(), midnight.getDate() + 1))) return "tomorrow"
    if (day === Model.keyForDate(new Date(midnight.getFullYear(), midnight.getMonth(), midnight.getDate() - 1))) return "yesterday"

    // Assembled from dayName and monthName rather than from a "ddd d MMM"
    // pattern. The pattern is locale's to interpret, and it reorders — an
    // en_GB reader gets "Fri, Sep 12" where en_US gets "Fri, Sep 12" and other
    // locales put the month first — so the word order here would follow
    // whatever the reader's region happens to be. Spelling the order out keeps
    // one panel reading one way, and keeps the year out of it either way.
    var date = root.dateForKey(day)
    return String(root.labelLocale.dayName(date.getDay(), Locale.ShortFormat))
      + " " + date.getDate()
      + " " + String(root.labelLocale.monthName(date.getMonth(), Locale.ShortFormat))
  }

  // A day as a group heading: the same phrase the composer speaks, shouted.
  // Shout rather than set in title case because every other label in this panel
  // is uppercase and a group heading that breaks the pattern reads as a
  // different kind of thing — a caption, not a section.
  function groupHeading(key) {
    var phrase = root.dayPhrase(key)
    return phrase === "" ? "" : phrase.toUpperCase()
  }

  // Where the deadline starts when the stepper is pressed on an empty field: the
  // next half hour for a task due today, and a working morning for any other
  // day. Starting from a fixed 17:00 instead would put a task due this evening
  // in the past before it was saved.
  function defaultDueMinutes() {
    if (String(root.selectedKey) !== String(root.todayKey)) return 9 * 60
    // Capped rather than wrapped: at 23:45 the next half hour is tomorrow,
    // and a deadline stamped today at 00:00 reads as a mistake, not as soon.
    return Math.min(Math.ceil(Tasks.minutesNow(clock.date) / 30) * 30, 23 * 60 + 30)
  }

  // Nudging the deadline. Wraps rather than stops at the ends of the day —
  // Tasks.shiftTime owns that arithmetic so there is one answer to "what is an
  // hour" rather than two — and takes the focus afterwards, because a stepper
  // that leaves the caret somewhere else makes the next digit land nowhere.
  function shiftDue(deltaMinutes) {
    dueField.text = Tasks.shiftTime(dueField.text, deltaMinutes, root.defaultDueMinutes())
    dueField.forceActiveFocus()
  }

  // Monotonic within a session and unique across restarts: the millisecond
  // clock alone repeats two tasks typed in the same millisecond, and a
  // repeated id would make the second one untickable.
  function nextTaskId() {
    root.taskSequence++
    return Date.now().toString(36) + "-" + root.taskSequence.toString(36)
  }

  function applyTask(store) {
    root.taskStore = store
    if (root.taskStoreLoaded) saveTasks()
  }

  // These three take the day the row was drawn from rather than reading
  // `selectedKey`, because in the wider view a row can belong to any day and the
  // store is keyed by day. `resolveDay` keeps the signature honest for callers
  // that only ever have the selected day to hand.
  function resolveDay(dayKey) {
    return Tasks.isDayKey(dayKey) ? String(dayKey) : root.selectedKey
  }

  function toggleTask(dayKey, id) {
    root.applyTask(Tasks.toggle(root.taskStore, root.resolveDay(dayKey), id))
  }

  function removeTask(dayKey, id) {
    var key = root.resolveDay(dayKey)
    var index = Tasks.find(root.taskStore, key, id)
    var victim = index >= 0 ? Tasks.tasksFor(root.taskStore, key)[index] : null

    root.applyTask(Tasks.remove(root.taskStore, key, id))

    // Offered only when there was something to put back. A delete that matched
    // nothing is not an accident, and a toast promising to restore a task that
    // was never there would be a promise the undo button then failed to keep.
    root.pendingUndo = victim ? { dayKey: key, task: victim, index: index } : null
    if (victim) undoTimer.restart()
  }

  // The inverse of removeTask, and the only thing the toast can do.
  function undoDelete() {
    if (!root.pendingUndo) return
    var entry = root.pendingUndo
    root.pendingUndo = null
    undoTimer.stop()
    root.applyTask(Tasks.restore(root.taskStore, entry.dayKey, entry.task, entry.index))
  }

  // Letting the offer expire without acting on it. Nothing is written and
  // nothing is lost — the task stays gone, which is what the six seconds were
  // for.
  function dismissUndo() {
    root.pendingUndo = null
    undoTimer.stop()
  }

  // ---- Editing a task that already exists
  //
  // The same shape as every other write here: resolve the row's own day, go
  // through the store, and save. What is different is only who decides that the
  // edit is over, because the row cannot: two rows must not be open at once and
  // the rows cannot see each other.
  function rowKey(dayKey, id) {
    return root.resolveDay(dayKey) + "/" + String(id)
  }

  function editTask(dayKey, id) {
    root.editingRowKey = root.rowKey(dayKey, id)
  }

  // Saving leaves the row's day alone. Moving a task to another day is a
  // different gesture from fixing its wording — the store would have to drop it
  // from one day's list and add it to another's, and a task that changed both its
  // text and its date from one keystroke is harder to reason about afterwards
  // than one that changed its date on purpose.
  // What a press on the row's mark sends. It runs only the priority rule and
  // never the text or field ones, because it cannot change either: those
  // checks stop a name being emptied and an hour being typed wrong, and a
  // control that hands over a value `cleanPriority` has already accepted has
  // nothing left for them to decide.
  function setTaskPriority(dayKey, id, priority) {
    var next = Tasks.setPriority(root.taskStore, root.resolveDay(dayKey), id, priority)
    root.applyTask(next)
  }

  function saveTaskEdit(dayKey, id, text, note, dueTime, remindDaysBefore, priority, tags) {
    var day = root.resolveDay(dayKey)
    // Four writes because there are four rules to keep, and neither the
    // reason for the first two nor the reason for the second two is worth
    // re-spelling here: setContent is what refuses an empty name, setFields is
    // what turns "17" into "17:00" and a chip into the number behind it, and
    // the last two are what settle a value the editor has already cleaned but
    // that the store must be the one to say yes to. Chaining them means an
    // edit can change the hour without also getting to bypass the check on the
    // text.
    var next = Tasks.setContent(root.taskStore, day, id, text, note)
    next = Tasks.setFields(next, day, id, dueTime, remindDaysBefore)
    next = Tasks.setPriority(next, day, id, priority)
    next = Tasks.setTags(next, day, id, tags)
    root.applyTask(next)
    root.closeEditor()
  }

  function cancelTaskEdit() {
    root.closeEditor()
  }

  // Following a tag is a toggle in both directions. Clicking the one already
  // being followed is how the list goes back to showing everything — a filter
  // that can only be narrowed is a filter you have to clear from somewhere
  // else, and the chip that turned it on is the only place that knows it is on.
  function toggleTagFilter(tag) {
    var clean = Tasks.tagNeedle(tag)
    if (clean === "") return
    root.tagFilter = root.tagFilter === clean ? "" : clean
  }

  // The editor is closed by dropping the key, and the keyboard goes back to the
  // panel's own catcher. Without that the focus would be left on a field that is
  // about to be destroyed along with the row, and the next letter typed would go
  // nowhere — or, worse, to whatever took the focus by default.
  function closeEditor() {
    root.editingRowKey = ""
    if (keyCatcher) keyCatcher.forceActiveFocus()
  }

  // True when this row is the one being edited. Compared as strings on purpose:
  // the row and the panel agree on the format, and an id that happens to contain
  // the separator cannot collide because ids are generated here and never
  // contain a slash.
  function rowIsEditing(dayKey, id) {
    return root.editingRowKey !== "" && root.editingRowKey === root.rowKey(dayKey, id)
  }

  // Clearing a deadline or a reminder off a row that already exists. Going
  // through the store rather than straight at the timer is what keeps the
  // reconcile pass and the file from ever disagreeing about what is armed.
  function clearTaskField(dayKey, id, field) {
    var day = root.resolveDay(dayKey)
    var list = Tasks.tasksFor(root.taskStore, day)
    var index = Tasks.find(root.taskStore, day, id)
    if (index === -1) return
    root.applyTask(Tasks.setFields(root.taskStore, day, id,
      field === "dueTime" ? "" : list[index].dueTime,
      field === "remindDaysBefore" ? null : list[index].remindDaysBefore))
  }

  // ---- Reminders
  //
  // A reminder is not a row in this panel and not a timer this panel arms. It
  // is a systemd *service* that reads this store and notifies about whatever is
  // due, driven by one persistent user timer installed by ClockReminders.sh.
  //
  // The reason it is not done from here is the whole point of the design. A
  // timer armed from the widget — with systemd-run, per task, re-armed every
  // time the store changed — is *transient*: systemd keeps those in /run, which
  // is a tmpfs, so a reboot deletes every one of them and each reminder is
  // silently gone until the widget happens to notice and build them again. It
  // also means the reminder only works while the desktop shell is up.
  //
  // A unit file in ~/.config/systemd/user has neither problem. It is read at
  // every login whether or not any GUI is running, so a reminder survives a
  // reboot and even survives the bar being closed, and with Persistent=true it
  // still delivers a reminder whose moment passed while the machine was off.
  // The consequence for this file is that arming and cancelling stop being its
  // problem entirely: the store is the only thing either side has to agree on,
  // and the script re-reads it on every firing. So there is no reconcile pass
  // to run on every edit — only one install, and it is idempotent.

  // The store the script is pointed at, and the script itself.
  //
  // Qt.resolvedUrl is the only way a QML file can name a sibling file. What it
  // hands back is a url, and the three ways of turning that into something
  // execDetached can run were all checked rather than assumed: url.path is
  // undefined, url.toLocalFile() is not a function, so neither exists. That
  // leaves decoding the URL, and decodeURIComponent is available. It leaves a
  // literal '+' alone, which matters because a '+' in a home directory is not
  // a space and must not become one.
  readonly property string reminderScriptPath: decodeURIComponent(
    String(Qt.resolvedUrl("ClockReminders.sh"))).replace(/^file:\/\//, "")

  // Installed once per panel load. The script compares what it would write with
  // what is already on disk and only touches systemd when they differ, so this
  // is a no-op in the steady state rather than a daemon-reload per shell start.
  // Run through bash rather than executed directly so that a plugin copied out
  // of a git checkout without its executable bit still works.
  function installReminderTimer() {
    Quickshell.execDetached(["bash", root.reminderScriptPath, "install",
      root.taskStorePath])
  }

  function taskCountFor(key) {
    return Tasks.count(root.taskStore, key)
  }

  function taskPendingFor(key) {
    return Tasks.pendingCount(root.taskStore, key)
  }

  // Dots per day, capped so a row of them cannot outgrow its cell. The cap is
  // a property rather than a literal so the number in the tooltip and the
  // number on the grid are the same decision, made in one place.
  //
  // Six is the last count that still reads as six dots. The cell is 52px wide
  // and the dots run at 4px with 2px between them, so 6 takes 34px and leaves
  // 9px of air on each side; 8 already takes 46px, and 9 takes exactly 52px,
  // running from border to border with only the 2px gutter standing between it
  // and the day next door. Beyond that the dots are close enough together to
  // read as a dashed bar rather than as a count.
  readonly property int maxDayDots: 6

  // ---- Horizontal page-turn. monthSlideX is driven only by hand, never by a
  //      binding, because the whole animation depends on parking the incoming
  //      month off to one side *before* the grid rebuilds: set it to the side
  //      first, swap the month second, then let the animation walk it in. The
  //      outgoing month is never drawn sliding away — it is replaced outright,
  //      so the previous month is never on screen next to the new one.
  property real monthSlideX: 0

  NumberAnimation {
    id: monthSlideAnim
    target: root
    property: "monthSlideX"
    to: 0
    duration: 190
    easing.type: Easing.OutCubic
  }

  // Pages to a month, entering from `dir`: +1 slides in from the right, -1
  // from the left. Re-entering the same month is ignored, so a second click on
  // a day of the month already showing cannot restart the turn.
  function pageTo(year, month, dir) {
    if (year === root.viewYear && month === root.viewMonth) return

    var distance = gridColumn.width
    root.monthSlideX = dir * distance
    root.viewYear = year
    root.viewMonth = month
    monthSlideAnim.from = dir * distance
    monthSlideAnim.restart()
  }

  function taskDotFlags(key) {
    return Tasks.dotFlags(root.taskStore, key, root.maxDayDots)
  }

  function taskAllDoneFor(key) {
    return Tasks.allDone(root.taskStore, key)
  }

  function loadTasks(raw) {
    // The file is the source of truth, so every load applies — including the
    // one triggered by our own write, which parses back to the same store.
    // Guarding against re-reads would look safer but would also swallow a
    // change made outside the panel, which is exactly the case reload() exists
    // to pick up.
    root.taskStore = Tasks.parse(raw)
    root.taskStoreLoaded = true

    // A store written by an older version is rewritten in the current shape the
    // moment it is read, rather than waiting for the next edit. parse() has
    // already migrated the values, so what gets written is the same store the
    // user sees — only the version marker and the normalised fields change.
    // This write fires onFileChanged once more, and the second pass sees the
    // current version and stops, so it settles after one round trip.
    if (Tasks.needsRewrite(raw)) saveTasks()
  }

  function saveTasks() {
    tasksFile.setText(Tasks.serialize(root.taskStore))
  }

  // The store holds task names and notes, and $HOME is traversable by every
  // other local account, so a plain 0644 file here is readable by anyone on
  // the machine. atomicWrites replaces the file on every save, which hands it
  // back with the umask's mode, so the file is locked down on every read-back
  // rather than once at creation — that is also the first moment the file is
  // known to exist.
  function secureStore() {
    Quickshell.execDetached(["chmod", "600", root.taskStorePath])
  }

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

  // Shared by both fields: Tab hops to the other one, Enter commits the pair,
  // Escape drops the lot.
  function handleLifeKey(event, other) {
    if (event.key === Qt.Key_Escape) {
      root.cancelEditingLife()
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.commitLife()
      event.accepted = true
    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      other.selectAll()
      other.forceActiveFocus()
      event.accepted = true
    }
  }

  // Double-tapping the life bar puts it away again. The expectancy stays in
  // the config so setting a birth year again brings your own number back
  // rather than the default.
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

  function toggleWeekStart() {
    setWeekStart(Model.toggledWeekStart(root.weekStart))
  }

  // English short day names, matching the rest of the interface.
  function weekdayLabel(weekday) {
    return String(labelLocale.dayName(weekday, Locale.ShortFormat)).toUpperCase()
  }

  // The list header, phrased against today so the day being worked on is
  // obvious without reading the calendar. Spoken by the same dayPhrase the
  // composer's own sentences use rather than by a second date format: the
  // header sits directly above "Add task" and the reminder chips, and two
  // languages in the same card is one more thing to translate by eye.
  readonly property string selectedDayLabel: root.groupHeading(selectedKey)

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: {
      if (Model.keyForDate(clock.date) === String(root.todayKey)) return
      var previousKey = root.todayKey
      var followToday = root.viewingCurrentMonth
      root.today = clock.date
      if (followToday) root.goToToday()
      // A selection still sitting on the day that just ended is not a choice
      // anyone made, so it rolls over with today. One picked by hand is left
      // alone.
      else if (root.selectedKey === previousKey) root.selectedKey = root.todayKey
    }
  }

  // Installed once, when the widget first exists. There is deliberately no
  // counterpart on taskStoreChanged: the timer does not encode any task, so
  // adding, editing or completing a task cannot leave it stale, and there is
  // nothing to re-derive. The store is re-read from disk on every firing
  // instead, which is what makes the panel and the timer independent of each
  // other.
  Component.onCompleted: root.installReminderTimer()

  FileView {
    id: tasksFile
    path: root.taskStorePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      root.loadTasks(text())
      root.secureStore()
    }
    // First run: no file yet. loadTasks seeds an empty store, so the first
    // write is what creates it.
    onLoadFailed: root.loadTasks("")
    // fileChanged only announces that the file moved; the new bytes are not
    // readable until reload() re-reads them and onLoaded fires. Reading
    // text() here instead would see the previous contents.
    onFileChanged: reload()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(calendarColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingLife || root.editingTask || root.draftPopover !== ""
      onMoveRequested: function(dx, dy) {
        // Left and right step whatever is on screen: a week in the week view,
        // a month in the month view. The two calendars disagree about how
        // much one step is worth, so the key does not decide — one entry
        // point does, or the arrows would have to know the answer too.
        if (dx !== 0) root.moveStep(dx)
        if (dy !== 0) root.moveYear(dy)
      }
      onActivateRequested: root.goToToday()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "[") root.moveStep(-1)
        else if (t === "]") root.moveStep(1)
        else if (t === "{") root.moveYear(-1)
        else if (t === "}") root.moveYear(1)
        else if (t === "t" || t === "T") root.goToToday()
        else if (t === "w" || t === "W") root.toggleWeekStart()
        else if (t === "n" || t === "N") root.focusTaskField()
        else if (t === "s" || t === "S") root.focusSearchField()
        // One letter for the pair rather than two: the two views are one
        // choice seen twice, and a reader who remembers only that there is a
        // switch should not have to remember which of them is bound to it.
        else if (t === "v" || t === "V") root.setCalView(root.weekView ? "month" : "week")
      }

      Flickable {
        id: calendarScroll
        anchors.fill: parent
        contentWidth: calendarColumn.width
        contentHeight: calendarColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height || contentWidth > width

        Column {
          id: calendarColumn
          // Never narrower than the grid. The popup width is capped to what
          // the screen allows, and a fixed seven-column grid would otherwise
          // lose its last days off the edge instead of scrolling.
          width: Math.max(calendarScroll.width, gridColumn.width)
          spacing: Style.space(8)

          // ---- Hero: today, centered. Once the view has stepped back
          //      it is also the way home — clicking the date you are
          //      looking for beats hunting for a reset button.
          Item {
            width: parent.width
            height: heroRow.height

            Row {
              id: heroRow
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(22)

              Text {
                // Baseline-aligned, not center-aligned: "July 26" carries a
                // descender, so centering the two boxes leaves the icon
                // sitting visibly low against the digits.
                anchors.baseline: heroDate.baseline
                text: "󰃭"
                color: heroMouse.containsMouse
                  ? Style.hoverStateColor(root.contentForeground, Color.accent)
                  : root.contentForeground
                font.family: root.contentFontFamily
                // Decorative, and deliberately outside the Style.font.*
                // scale. Sized so the glyph reads at the cap height of the
                // date beside it rather than towering over it.
                font.pixelSize: 48
              }

              Text {
                id: heroDate
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: root.labelLocale.toString(root.heroDate, "MMMM d")
                color: heroMouse.containsMouse
                  ? Style.hoverStateColor(root.contentForeground, Color.accent)
                  : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: 52
                font.bold: true
              }
            }

            MouseArea {
              id: heroMouse
              x: heroRow.x
              y: heroRow.y
              width: heroRow.width
              height: heroRow.height
              enabled: !root.viewingCurrentMonth
              hoverEnabled: enabled
              cursorShape: Qt.PointingHandCursor
              onClicked: root.goToToday()

              PanelToolTip {
                visible: heroMouse.containsMouse
                text: "Back to today"
                fontFamily: root.contentFontFamily
              }
            }
          }

          // ---- Year progress, doubling as the rule under the hero:
          //      a plain hairline said nothing, and whole days done
          //      over days in the year says the same thing louder.
          Item {
            width: parent.width
            height: yearBlock.y + yearBlock.height

            Item {
              id: yearBlock
              y: Style.space(6)
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
                  anchors.verticalCenter: parent.verticalCenter
                  text: "BORN"
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }

                TextField {
                  id: bornField
                  width: Style.space(70)
                  anchors.verticalCenter: parent.verticalCenter
                  placeholderText: "year"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  inputMethodHints: Qt.ImhDigitsOnly

                  Keys.onPressed: function(event) { root.handleLifeKey(event, expectancyField) }
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.verticalCenterOffset: 0
                  leftPadding: Style.space(6)
                  text: "LIVE TO"
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }

                TextField {
                  id: expectancyField
                  width: Style.space(60)
                  anchors.verticalCenter: parent.verticalCenter
                  placeholderText: "90"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
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
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
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
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Rectangle {
                id: yearTrack
                visible: !root.editingLife
                anchors.left: yearLabel.right
                anchors.right: yearPercent.left
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(6)
                radius: Style.cornerRadius > 0 ? height / 2 : 0
                color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

                Rectangle {
                  width: Math.round(parent.width * root.yearDone)
                  height: parent.height
                  radius: parent.radius
                  color: Style.selectedStateColor(root.contentForeground, Color.accent)

                  Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                }
              }
            }
          }

          // ---- Memento mori. Only here once someone has gone looking and
          //      given an age; the same rail as the year above it, measured
          //      against a nominal lifetime.
          Item {
            visible: root.birthYear > 0
            width: parent.width
            height: visible ? lifeBlock.height : 0

            Item {
              id: lifeBlock
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: Math.max(lifeLabel.implicitHeight, Style.space(10))

              Text {
                id: lifeLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "LIFE"
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }

              Text {
                id: lifePercent
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.lifeDonePercent + "%"
                color: root.contentForeground
                font.family: root.contentFontFamily
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
                color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

                Rectangle {
                  width: Math.round(parent.width * root.lifeDone)
                  height: parent.height
                  radius: parent.radius
                  color: Style.selectedStateColor(root.contentForeground, Color.accent)

                  Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                }
              }

              TapHandler {
                onDoubleTapped: root.clearLife()
              }

              MouseArea {
                id: lifeMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton

                PanelToolTip {
                  visible: lifeMouse.containsMouse
                  text: "Memento Mori"
                  fontFamily: root.contentFontFamily
                }
              }
            }
          }

          // ---- Month grid: week numbers down a gutter on the left, then
          //      the seven day columns. Always six rows, so the popup is
          //      exactly as tall in February as it is in August.
          Item {
            x: root.monthSlideX
            width: parent.width
            height: gridColumn.y + gridColumn.height

            // No wheel handler on purpose. The grid is paged with the
            // chevrons and the left/right arrows — the same two things a
            // horizontal page-turn wants — and a vertical wheel no longer
            // steps the month. What the wheel is left for is the Flickable
            // below: once a day carries enough tasks to make the panel taller
            // than the screen, the wheel scrolls it instead of quietly
            // skipping you a month every notch.

            Column {
              id: gridColumn
              // The meter above is a solid rule; the grid needs room to
              // read as its own block rather than hanging off it.
              y: Style.space(18)
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(3)

              Row {
                id: headerRow
                spacing: root.cellSpacing

                // The week-number heading doubles as the week-start toggle.
                // It is the one control in the panel whose meaning is not
                // self-evident, so it carries a tooltip naming the day the
                // click will switch to.
                Rectangle {
                  width: root.weekColumnWidth
                  height: Style.space(16)
                  radius: Style.cornerRadius
                  color: weekStartMouse.containsMouse
                    ? Style.hoverFillFor(root.contentForeground, Color.accent)
                    : "transparent"

                  Text {
                    anchors.centerIn: parent
                    text: "W"
                    color: weekStartMouse.containsMouse
                      ? Style.hoverStateColor(root.contentForeground, Color.accent)
                      : Qt.darker(root.contentForeground, 1.9)
                    font.family: root.contentFontFamily
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
                    fontFamily: root.contentFontFamily
                  }
                }

                Item {
                  width: root.gutterWidth
                  height: Style.space(16)
                }

                Repeater {
                  model: root.weekdays

                  Text {
                    textFormat: Text.PlainText
                    required property var modelData
                    width: root.cellWidth
                    height: Style.space(16)
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: root.weekdayLabel(modelData)
                    color: Qt.darker(root.contentForeground, 1.5)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                    font.bold: true
                  }
                }
              }

              Repeater {
                model: root.gridRows

                Row {
                  required property var modelData
                  spacing: root.cellSpacing

                  Text {
                    textFormat: Text.PlainText
                    width: root.weekColumnWidth
                    height: root.cellHeight
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: modelData.week
                    color: Qt.darker(root.contentForeground, 1.9)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Item {
                    width: root.gutterWidth
                    height: root.cellHeight
                  }

                  Repeater {
                    model: modelData.days

                    Rectangle {
                      id: dayCell
                      required property var modelData

                      readonly property bool selected: modelData.key === root.selectedKey
                      readonly property int taskCount: root.taskCountFor(modelData.key)
                      readonly property int pendingTasks: root.taskPendingFor(modelData.key)
                      readonly property bool hasTasks: taskCount > 0
                      // Blue while the day still owes something, red once it
                      // is all ticked. A day that was used either way keeps its
                      // dot — the plain number cannot say that.
                      readonly property bool tasksDone: hasTasks && pendingTasks === 0

                      width: root.cellWidth
                      height: root.cellHeight
                      radius: Style.cornerRadius
                      // Today is outlined, not filled: a lit-up block shouts
                      // over a grid this quiet. The selected day is the one
                      // exception — it is filled faintly, because the task
                      // list below needs to say which day it belongs to.
                      color: selected
                        ? Style.selectedFillFor(root.contentForeground, Color.accent)
                        : (dayMouse.containsMouse ? Style.hoverFillFor(root.contentForeground, Color.accent) : "transparent")
                      border.width: modelData.today || selected ? Style.spacing.hairline : 0
                      border.color: selected
                        ? Style.selectedBorderFor(root.contentForeground, Color.accent)
                        : Style.normalBorderFor(root.contentForeground, Color.accent)

                      // The number sits above centre so the dots have a lane of
                      // their own underneath it, whether or not the day has
                      // anything on it — a day that gains a task should not
                      // shift its own number, and neither should a day that
                      // gains a fifth.
                      Text {
                        textFormat: Text.PlainText
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: Style.space(13)
                        text: modelData.day
                        color: modelData.inMonth
                          ? (modelData.weekend ? Qt.darker(root.contentForeground, 1.45) : root.contentForeground)
                          : Qt.darker(root.contentForeground, 2.2)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.body
                        font.bold: modelData.today
                      }

                      // One dot per task, blue while it is outstanding and
                      // red once ticked, in the order the tasks were added —
                      // up to a cap, because a row of dots wider than its own
                      // cell would collide with the day beside it. The cap
                      // costs nothing: the tooltip still carries the real
                      // count, and a day carrying more than this many is past
                      // the point where the exact number is what you are
                      // reading off the grid.
                      Row {
                        visible: dayCell.hasTasks
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: Style.space(5)
                        spacing: Style.space(2)

                        Repeater {
                          model: root.taskDotFlags(dayCell.modelData.key)

                          Rectangle {
                            required property var modelData

                            width: Style.space(4)
                            height: width
                            radius: width / 2
                            color: modelData === true ? root.pendingTaskColor : root.doneTaskColor
                          }
                        }
                      }

                      MouseArea {
                        id: dayMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.selectGridDay(dayCell.modelData)
                      }

                      PanelToolTip {
                        visible: dayMouse.containsMouse
                        text: dayCell.hasTasks
                          ? (dayCell.pendingTasks > 0
                              ? dayCell.pendingTasks + " left"
                                + (dayCell.taskCount > dayCell.pendingTasks ? " · " + (dayCell.taskCount - dayCell.pendingTasks) + " done" : "")
                              : dayCell.taskCount + " done")
                          : root.labelLocale.toString(root.dateForKey(dayCell.modelData.key), "d MMMM")
                        fontFamily: root.contentFontFamily
                      }
                    }
                  }
                }
              }
            }

            // Hairline down the week-number gutter, drawn only beside the
            // day rows so it does not cut through the header band.
            Rectangle {
              x: gridColumn.x + root.weekColumnWidth + root.cellSpacing + Math.round((root.gutterWidth - width) / 2)
              y: gridColumn.y + headerRow.height + gridColumn.spacing
              width: Style.spacing.hairline
              height: gridColumn.height - headerRow.height - gridColumn.spacing
              color: root.contentForeground
              opacity: 0.1
            }
          }

          // ---- Month stepping, spanning the grid it drives. The chevrons
          //      sit on the grid's outer bounds, the same edges the year
          //      rail above uses, so the row reads as the panel's other
          //      full-width rail instead of a cluster floating in space.
          //      The label is centered and fixed-width, so it holds still
          //      from "MAY" to "SEPTEMBER".
          Item {
            width: parent.width
            height: monthNav.height

            Item {
              id: monthNav
              // horizontalCenterOffset, not x: an anchor and an x on the same
              // item is a conflict Qt resolves by dropping the x, which would
              // leave the header behind every page-turn.
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.horizontalCenterOffset: root.monthSlideX
              width: gridColumn.width
              height: monthLabel.implicitHeight + viewToggle.height + Style.space(14)

              // What the chevrons are stepping over. A range in the week view
              // because "OCTOBER 2026" over a single week would be a heading
              // about seven times more than it is sitting on.
              //
              // Fixed width so the chevrons hold still between a
              // "MAY 2026" and a "SEPTEMBER 2026", and wide enough for the
              // widest range the week can produce.
              Text {
                id: monthLabel
                textFormat: Text.PlainText
                anchors.top: parent.top
                anchors.horizontalCenter: parent.horizontalCenter
                width: Style.space(150)
                horizontalAlignment: Text.AlignHCenter
                text: root.weekView
                  ? root.weekRangeLabel
                  : root.labelLocale.toString(root.viewDate, "MMMM yyyy").toUpperCase()
                color: Qt.darker(root.contentForeground, 1.4)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                font.letterSpacing: 1
              }

              PanelActionButton {
                // Pulled out by the button's own padding so the glyph, not
                // its hit box, lines up with the "2026" on the year rail.
                // On the label rather than on the header: the header grew a
                // second row, and centring on it would drop both chevrons
                // half a line below the word they move.
                anchors.left: parent.left
                anchors.leftMargin: -Style.space(8)
                anchors.verticalCenter: monthLabel.verticalCenter
                iconText: "󰅁"
                tooltipText: root.weekView ? "Previous week" : "Previous month"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.moveStep(-1)
              }

              PanelActionButton {
                anchors.right: parent.right
                anchors.rightMargin: -Style.space(8)
                anchors.verticalCenter: monthLabel.verticalCenter
                iconText: "󰅂"
                tooltipText: root.weekView ? "Next week" : "Next month"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.moveStep(1)
              }

              // ---- Which calendar. Two words rather than an icon, because
              //      a week and a month are shapes and not symbols, and a
              //      glyph small enough to fit here would be a guess at what
              //      it meant. The one in force is inverted, so the pair
              //      reads as a setting with a current answer rather than as
              //      two buttons that both might be pressed.
              Row {
                id: viewToggle
                anchors.top: monthLabel.bottom
                anchors.topMargin: Style.spacing.xs
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.spacing.xs

                Repeater {
                  model: [
                    { view: "week", label: "Week" },
                    { view: "month", label: "Month" }
                  ]

                  delegate: Rectangle {
                    required property var modelData

                    readonly property bool on_: root.calView === modelData.view

                    width: viewChipText.implicitWidth + Style.spacing.lg
                    height: viewChipText.implicitHeight + Style.spacing.xs
                    // Same corners as the system's windows: this tracks
                    // decoration:rounding live, so the chip follows whatever
                    // the desktop does instead of pinning a shape of its own.
                    radius: Style.cornerRadius
                    // Inverted when in force, and never in the pending red:
                    // that colour means work still owed, and choosing which
                    // calendar to look at owes nobody anything.
                    color: on_
                      ? root.contentForeground
                      : viewChipMouse.containsMouse
                        ? Style.hoverFillFor(root.contentForeground, Color.accent)
                        : Qt.alpha(root.contentForeground, 0.07)
                    border.width: on_ ? 0 : Style.normalBorderWidth
                    border.color: Qt.alpha(root.contentForeground, 0.18)

                    Text {
                      id: viewChipText
                      anchors.centerIn: parent
                      textFormat: Text.PlainText
                      text: modelData.label
                      color: on_
                        ? Color.popups.background
                        : Qt.alpha(root.contentForeground, 0.78)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: on_
                    }

                    MouseArea {
                      id: viewChipMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.setCalView(modelData.view)
                    }

                    PanelToolTip {
                      visible: viewChipMouse.containsMouse
                      text: modelData.view === "week"
                        ? "One week on screen, seven cells tall enough to hit"
                        : "The whole month on screen"
                    }
                  }
                }
              }
            }
          }

          // ---- Tasks for the selected day. The grid picks the day; this is
          //      where the work itself gets written down, ticked off, and
          //      cleared. Same small-caps label treatment as the year rail
          //      above, so it reads as the panel's third rail rather than a
          //      separate app dropped underneath.
          //
          //      Inside, three zones, each separated from the next by more
          //      air than any two lines within it: the composer (name,
          //      description, then the priority and tag buttons), the card
          //      that says when the task is due and when the reminder will
          //      speak, and the list itself — which starts under a rule, so
          //      the boundary is drawn and not only spaced.
          Item {
            width: parent.width
            height: taskBlock.y + taskBlock.implicitHeight

            Rectangle {
              anchors.top: parent.top
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: Style.spacing.hairline
              color: root.contentForeground
              opacity: 0.1
            }

            Column {
              id: taskBlock
              // The task list rides along with the page-turn: it belongs to the
              // month on screen, so leaving it behind would show another
              // month's tasks under a grid that has already moved on.
              anchors.horizontalCenterOffset: root.monthSlideX
              y: Style.space(14)
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              spacing: Style.space(8)

              // One row definition, bound once, used by both sections below.
              // Repeater.delegate takes a Component, which is the only way to
              // share it without duplicating the bindings per section.
              //
              // The wrapper exists only to receive the model role: a Repeater
              // injects `modelData` into the delegate's own root, so a
              // reusable component that does not itself declare it has to be
              // handed it from something that does.
              Component {
                id: taskRow

                Item {
                  required property var modelData

                  // Guarded rather than `parent.width`. A Repeater destroys its
                  // delegates when the model changes, and the group delegates
                  // below own a Column full of these rows, so switching out of
                  // the wider view tears down a whole tree at once. The binding
                  // is re-evaluated during that teardown with the parent already
                  // gone, which throws "Cannot read property 'width' of null"
                  // once per destroyed row and floods the log on every toggle.
                  // Reading it as 0 says the same thing about a row that is
                  // being deleted.
                  width: parent ? parent.width : 0
                  height: rowView.height

                  TaskRow {
                    id: rowView
                    width: parent.width
                    task: parent.modelData
                    contentForeground: root.contentForeground
                    contentFontFamily: root.contentFontFamily
                    pendingColor: root.pendingTaskColor
                    doneColor: root.doneTaskColor
                    // Bound to the clock rather than sampled once: an overdue
                    // task has to turn red on its own, without the panel being
                    // reopened, or the one thing the red is for is the thing
                    // that is most likely to be missed.
                    nowMinutes: root.nowMinutes
                    nowDayKey: root.todayKey
                    // In the wider view a future deadline is not yet overdue,
                    // but it is still owed, and the red is what the whole list
                    // is sorted to make you notice. Passed as a flag rather than
                    // left to TaskRow to infer from the clock: whether a
                    // deadline is outstanding depends on what else is on screen,
                    // and the row cannot see that.
                    contextAllDays: root.allDays
                    tagFilter: Tasks.tagNeedle(root.tagFilter)
                    onTagClicked: tag => root.toggleTagFilter(tag)
                    onToggled: id => root.toggleTask(parent.modelData.dayKey, id)
                    onPriorityRequested: (id, priority) => root.setTaskPriority(parent.modelData.dayKey, id, priority)
                    onRemoved: id => root.removeTask(parent.modelData.dayKey, id)
                    onFieldCleared: (id, field) => root.clearTaskField(parent.modelData.dayKey, id, field)
                    editing: root.rowIsEditing(parent.modelData.dayKey, parent.modelData.id)
                    onEditRequested: root.editTask(parent.modelData.dayKey, parent.modelData.id)
                    onEditSaved: (id, text, note, dueTime, remindDaysBefore, priority, tags) => root.saveTaskEdit(parent.modelData.dayKey, id, text, note, dueTime, remindDaysBefore, priority, tags)
                    onEditCancelled: root.cancelTaskEdit()
                  }
                }
              }

              // ---- The composer. One field, always there, so adding a task
              //      never needs a mode or a button to reveal. Its own `text`
              //      is the single source of truth: a `text: root.draftTask`
              //      binding would be broken by the clearing below, leaving
              //      the field and the property quietly out of step.
              TextField {
                id: taskField
                width: parent.width
                placeholderText: "Add task"
                foreground: root.contentForeground
                // The theme accent, not the pending red. `accent` here draws the
                // focus ring, and a field the cursor happens to be in owes
                // nobody anything; painting its focus red would spend the one
                // colour that means "unfinished" on a piece of chrome.
                accent: Color.accent
                font.family: root.contentFontFamily
                selectByMouse: true
                onAccepted: root.commitDraftTask()
                Keys.onEscapePressed: {
                  root.clearDraft()
                  keyCatcher.forceActiveFocus()
                }
              }

              // ---- The note, directly under the name it belongs to. Its own
              //      field rather than a second line inside the name field: a
              //      name is one line by definition, and letting Enter mean
              //      "new line" here would take away the shortcut that adds a
              //      task. Instead Enter still adds it, and Tab walks down into
              //      the note for the times a name alone is not the whole
              //      thought.
              //
              // Always visible, for the same reason the deadline and reminder
              // card is: a note behind a disclosure is a note that does not get
              // written.
              TextField {
                id: noteField
                width: parent.width
                placeholderText: "Description (optional)"
                foreground: root.contentForeground
                accent: Color.accent
                font.family: root.contentFontFamily
                // A notch below the name's own size. The name is the thing being
                // looked for; the note is detail hanging off it, and drawing
                // them at the same weight would make a row of tasks read as
                // twice as many tasks.
                font.pixelSize: Style.font.bodySmall
                selectByMouse: true
                onAccepted: root.commitDraftTask()
                Keys.onEscapePressed: {
                  root.clearDraft()
                  keyCatcher.forceActiveFocus()
                }
              }

              // ---- Row three: the two parts of a task the composer had no
              //      room for. Priority and tags are what a name cannot say
              //      and what nobody infers from it, and until now both only
              //      existed once the task did — behind an editor the reader
              //      had to already know was there.
              //
              //      Two buttons rather than a permanent row of chips: four
              //      priorities always on screen is four more things wedged
              //      between the name and the list, and the choice is made
              //      once and then read off the mark. Pressing one opens a
              //      window over the card instead of growing the composer, so
              //      choosing never moves the list you are about to add to.
              Row {
                id: draftMetaRow
                width: parent.width
                spacing: Style.spacing.sm

                Rectangle {
                  id: flagButton
                  height: Style.spacing.controlHeight
                  width: flagLabel.implicitWidth + flagGlyph.size
                    + Style.spacing.sm + Style.spacing.md * 2
                  radius: Style.cornerRadius
                  color: flagMouse.containsMouse
                    ? Style.hoverFillFor(root.contentForeground, Color.accent)
                    : Qt.alpha(root.contentForeground, 0.07)
                  border.width: Style.normalBorderWidth
                  border.color: Qt.alpha(root.contentForeground, 0.18)

                  Row {
                    anchors.centerIn: parent
                    spacing: Style.spacing.sm

                    FlagGlyph {
                      id: flagGlyph
                      flagColor: Tasks.priorityColor(root.draftPriority)
                      size: Style.space(14)
                    }

                    Text {
                      id: flagLabel
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      // "Priority" when there is none, and the level when there
                      // is: the button has to say what it will do and what it
                      // has done, and one word cannot be both.
                      text: Tasks.priorityLabel(root.draftPriority) === ""
                        ? "Priority"
                        : Tasks.priorityLabel(root.draftPriority)
                      color: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: root.draftPriority !== null
                    }
                  }

                  MouseArea {
                    id: flagMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      var p = flagButton.mapToItem(composerPopover, 0, 0)
                      composerPopover.popupX = p.x
                      composerPopover.popupY = p.y + flagButton.height + Style.spacing.xs
                      root.toggleDraftPopover("priority")
                    }
                  }

                  PanelToolTip {
                    visible: flagMouse.containsMouse
                    text: root.draftPriority === null
                      ? "Priority: none · click to choose"
                      : "Priority: " + Tasks.priorityLabel(root.draftPriority)
                        + " · click to change"
                  }
                }

                Rectangle {
                  id: tagButton
                  height: Style.spacing.controlHeight
                  // Clamped to what the row has left rather than to a fixed
                  // width: a tag list is the reader's and can be any length,
                  // and a button that ran past the panel would push its own
                  // edge off the card with nothing to reach it.
                  width: Math.min(tagProbe.implicitWidth + Style.spacing.md * 2,
                    draftMetaRow.width - flagButton.width - draftMetaRow.spacing)
                  radius: Style.cornerRadius
                  color: tagButtonMouse.containsMouse
                    ? Style.hoverFillFor(root.contentForeground, Color.accent)
                    : Qt.alpha(root.contentForeground, 0.07)
                  border.width: Style.normalBorderWidth
                  border.color: Qt.alpha(root.contentForeground, 0.18)

                  // Kept out of the Rectangle's layout — a Rectangle positions
                  // its children freely, so a hidden probe measures without
                  // ever being drawn, and the visible label can then elide
                  // against a width that does not depend on its own text.
                  Text {
                    id: tagProbe
                    visible: false
                    textFormat: Text.PlainText
                    text: root.draftTags.length === 0
                      ? "Tags"
                      : "#" + root.draftTags.join("  #")
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Text {
                    id: tagLabel
                    anchors.left: parent.left
                    anchors.leftMargin: Style.spacing.md
                    anchors.right: parent.right
                    anchors.rightMargin: Style.spacing.md
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: tagProbe.text
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    color: root.draftTags.length > 0
                      ? root.contentForeground
                      : Qt.alpha(root.contentForeground, 0.7)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: root.draftTags.length > 0
                  }

                  MouseArea {
                    id: tagButtonMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      var p = tagButton.mapToItem(composerPopover, 0, 0)
                      composerPopover.popupX = p.x
                      composerPopover.popupY = p.y + tagButton.height + Style.spacing.xs
                      root.toggleDraftPopover("tags")
                    }
                  }

                  PanelToolTip {
                    visible: tagButtonMouse.containsMouse
                    text: root.draftTags.length === 0
                      ? "Tags: none · click to add"
                      : "Tags: " + root.draftTags.join(", ") + " · click to edit"
                  }
                }
              }

              // ---- The two optional extras, always visible rather than behind
              //      a disclosure. A reminder set by hunting for a hidden
              //      control is a reminder that never gets set.
              //
              // They share one card, side by side rather than stacked, and each
              // half says its choice back in words under its own label. The
              // controls alone were the part that read as "simple": a chip
              // saying "3" beside a clock says three of something, and "Starts
              // Fri 12 Sep" is what says three days before this task — which is
              // the half that was always ambiguous.
              // One Column carries one spacing for every child, so the extra
              // breath between "writing the task" and "when it is due" is
              // bought with a zero-height child rather than by loosening the
              // rhythm inside either zone.
              Item {
                width: parent.width
                height: 0
              }
              Rectangle {
                id: optionCard
                width: parent.width
                height: optionBody.implicitHeight + Style.spacing.lg * 2
                // A quiet surface, not a card that competes with the task it is
                // about to create. The fill is barely there and the border does
                // the work of separating it from the panel.
                radius: Style.cornerRadius
                color: Qt.alpha(root.contentForeground, 0.03)
                border.width: Style.normalBorderWidth
                border.color: Qt.alpha(root.contentForeground, 0.1)

                Column {
                  id: optionBody
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.margins: Style.spacing.lg
                  spacing: Style.spacing.md

                  // The widest chip label, measured once so all six chips can
                  // share one width and read as a segmented control rather than
                  // a ragged line of differently sized pills. `visible: false`
                  // and not a zero size on purpose: implicitWidth comes from
                  // text metrics, so hiding it keeps the measurement while
                  // keeping the probe out of the Column's layout.
                  Text {
                    id: remindChipProbe
                    visible: false
                    // Must stay the widest string the chips below can render, or
                    // the row is sized for a word that is no longer there.
                    // "Today" against "1".."5" is, in this font at bodySmall.
                    text: "Today"
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                  }

                  // ---- One row for the two halves. They used to be stacked,
                  //      which bought nothing: both are a label, a line saying
                  //      what the control resolves to, and one line of controls.
                  //      Side by side the card answers "when is it due and when
                  //      will you hear about it" in one look instead of two.
                  //      The rule between them turned too: it was the hairline
                  //      that said "two groups", and a hairline lying down
                  //      between two columns is the wrong way round to say it.
                  Row {
                    id: optionColumns
                    width: parent.width
                    spacing: Style.spacing.md

                    // ---- The deadline. A field and not a picker because the
                    //      value people type is a wall-clock time, and a picker
                    //      would make "17:00" four interactions to express. The
                    //      steppers sit beside it rather than replacing it:
                    //      nudging an hour is the one change worth making without
                    //      opening the keyboard, and typing is still how anything
                    //      else arrives.
                    Column {
                      id: dueColumn
                      width: (optionColumns.width - Style.spacing.hairline
                        - optionColumns.spacing * 2) / 2
                      spacing: Style.spacing.xs

                      Text {
                        id: dueCaption
                        textFormat: Text.PlainText
                        text: "DEADLINE"
                        color: Qt.darker(root.contentForeground, 1.5)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.bodySmall
                        font.letterSpacing: 1
                      }

                      // The value in words, and on its own line. It used to sit to the right
                      // of the label, which is the one place a half-width column has no room
                      // left: "Due Fri 11 Sep at 17:00" would elide the hour away, and the
                      // hour is the half of it worth reading.
                      Text {
                        width: parent.width
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                        text: root.draftDueSummary
                        color: root.draftDueSummaryColor
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                      }

                      Row {
                        spacing: Style.spacing.xs

                        // Nothing wraps this in a MouseArea. That is deliberate,
                        // and it is the fix: a MouseArea filling the box and
                        // declared after the field sits on top of it, so it
                        // swallowed every click aimed at the text and the field
                        // could not be focused or have the caret placed by
                        // clicking it. qs.Ui.TextField already draws its own
                        // border and background and already handles its own
                        // hover, so a wrapper would only ever get in the way.
                        TextField {
                          id: dueField
                          // A fixed width rather than a clamp on implicitWidth,
                          // and for the reason the clamp needed a comment:
                          // `implicitWidth: Math.max(implicitWidth, ...)` reads
                          // the property it is assigned and the engine rightly
                          // calls that a binding loop. Sizing it outright sidesteps
                          // the whole question, and an empty field's
                          // implicitWidth tracks nothing anyway.
                          width: Style.space(68)
                          placeholderText: "17:00"
                          verticalPadding: Style.spacing.xs
                          foreground: root.contentForeground
                          // The theme accent, not the pending red. `accent` here
                          // draws the focus ring, and a field the cursor happens
                          // to be in owes nobody anything; painting its focus red
                          // would spend the one colour that means "unfinished" on
                          // a piece of chrome.
                          accent: Color.accent
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.bodySmall
                          selectByMouse: true
                          onAccepted: root.commitDraftTask()
                          Keys.onEscapePressed: {
                            root.clearDraft()
                            keyCatcher.forceActiveFocus()
                          }
                        }

                        // The two nudges, as a Repeater over their own data
                        // rather than as two hand-written buttons: the stepper is
                        // the one control whose whole description is a list of
                        // steps, and a list is what a Repeater wants.
                        Repeater {
                          model: [
                            { glyph: "−", delta: -60, tip: "One hour earlier" },
                            { glyph: "+", delta: 60, tip: "One hour later" }
                          ]

                          delegate: Rectangle {
                            required property var modelData

                            width: Style.space(22)
                            height: dueField.height
                            radius: Style.cornerRadius
                            color: stepMouse.containsMouse
                              ? Style.hoverFillFor(root.contentForeground, Color.accent)
                              : Qt.alpha(root.contentForeground, 0.07)
                            border.width: Style.normalBorderWidth
                            border.color: Qt.alpha(root.contentForeground, 0.18)

                            Text {
                              anchors.centerIn: parent
                              text: modelData.glyph
                              color: Qt.darker(root.contentForeground, 1.2)
                              font.family: root.contentFontFamily
                              font.pixelSize: Style.font.body
                            }

                            MouseArea {
                              id: stepMouse
                              anchors.fill: parent
                              hoverEnabled: true
                              cursorShape: Qt.PointingHandCursor
                              onClicked: root.shiftDue(modelData.delta)
                            }

                            PanelToolTip {
                              visible: stepMouse.containsMouse
                              text: modelData.tip
                              fontFamily: root.contentFontFamily
                            }
                          }
                        }
                      }
                    }

                    Rectangle {
                      width: Style.spacing.hairline
                      height: Math.max(dueColumn.height, remindColumn.height)
                      color: root.contentForeground
                      opacity: 0.12
                    }

                    // ---- The reminder, as one segmented run. The day-of option
                    //      is first and labelled, because it is the one that is
                    //      not a number of days before anything, and a row that
                    //      started "0" would promise the fifth of the month.
                    Column {
                      id: remindColumn
                      width: dueColumn.width
                      spacing: Style.spacing.xs

                      Text {
                        id: remindCaption
                        textFormat: Text.PlainText
                        text: "REMINDER"
                        color: Qt.darker(root.contentForeground, 1.5)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.bodySmall
                        font.letterSpacing: 1
                      }

                      // The same line of its own, for the reason above. Two halves that
                      // lay out differently are two halves to learn, and one rule that both
                      // follow is worth more than the twelve pixels it costs.
                      Text {
                        width: parent.width
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                        text: root.draftRemindSummary
                        color: root.draftRemindSummaryColor
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                      }

                      Flow {
                        width: parent.width
                        spacing: Style.spacing.xs

                        Repeater {
                          model: [0, 1, 2, 3, 4, 5]

                          delegate: Rectangle {
                            required property int modelData

                            readonly property bool on_: root.draftRemindDays === modelData

                            width: remindChipProbe.implicitWidth + Style.spacing.lg * 2
                            height: chipText.implicitHeight + Style.spacing.sm * 2
                            radius: Style.cornerRadius
                            // Inverted rather than coloured, and that is the point
                            // of the change: a selected chip used to wear the
                            // pending red, which is the one colour on this panel
                            // that means "still owed". Selection has to be legible
                            // on a theme whose accent is plain grey, which
                            // foreground-versus-background is and a tint is not.
                            color: on_
                              ? root.contentForeground
                              : chipMouse.containsMouse
                                ? Style.hoverFillFor(root.contentForeground, Color.accent)
                                : Qt.alpha(root.contentForeground, 0.07)
                            border.width: on_ ? 0 : Style.normalBorderWidth
                            border.color: Qt.alpha(root.contentForeground, 0.18)

                            Text {
                              id: chipText
                              anchors.centerIn: parent
                              text: modelData === 0 ? "Today" : String(modelData)
                              color: on_
                                ? Color.popups.background
                                : Qt.alpha(root.contentForeground, 0.78)
                              font.family: root.contentFontFamily
                              font.pixelSize: Style.font.bodySmall
                              font.bold: on_
                            }

                            MouseArea {
                              id: chipMouse
                              anchors.fill: parent
                              hoverEnabled: true
                              cursorShape: Qt.PointingHandCursor
                              onClicked: root.toggleRemindDays(modelData)
                            }

                            PanelToolTip {
                              visible: chipMouse.containsMouse
                              text: "Reminds every hour " + Tasks.remindDaysLabel(modelData)
                              fontFamily: root.contentFontFamily
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }

              // ---- Header: what the list is currently about. In the wider
              //      view that is the store as a whole, so the day names have
              //      moved down into the list itself where each one sits over
              //      the tasks it belongs to; here there is only a total.
              // ---- The rule between the composer and the list. The same
              //      treatment as the rail above the block, so the section
              //      reads as three zones rather than as one run of
              //      controls. `parent.width` and not a centred anchor: a
              //      Column assigns x to its children, and an anchor would
              //      fight it for the same property.
              Rectangle {
                width: parent.width
                height: Style.spacing.hairline
                color: root.contentForeground
                opacity: 0.1
              }
              Item {
                width: parent.width
                height: Math.max(taskDayLabel.implicitHeight, Style.space(10))

                Text {
                  id: taskDayLabel
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  // A button, not a label, whenever a day is narrowed to — the
                  // way back out of it. Drawn at a low alpha rather than
                  // underlined so it does not compete with the day headings
                  // inside the list, and because a heading the reader has to
                  // guess at is not a way back.
                  text: root.allDays ? "ALL PENDING" : root.selectedDayLabel + "  ↩"
                  color: root.allDays
                    ? Qt.darker(root.contentForeground, 1.5)
                    : Qt.alpha(root.contentForeground, 0.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1

                  MouseArea {
                    anchors.fill: parent
                    // Grown past the text's own box, because the glyphs are
                    // small and the padding is the only part of the header that
                    // says "press here".
                    anchors.margins: -Style.space(4)
                    visible: !root.allDays
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.showAllDays()
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  // The wider view's count is only meaningful when there is
                  // something in it: "ALL PENDING · 0" over an empty store reads
                  // like a fault rather than like an absence.
                  //
                  // A search that matches nothing gets a sentence of its own.
                  // An empty list under a count of "8 PENDING" would be two
                  // answers to one question, and "Nothing pending" would be a
                  // third — the store may well be full, only the needle is not
                  // in it.
                  visible: root.allDays
                    ? root.pendingAll.tasks > 0
                    : root.selectedTasks.length > 0
                  // "PENDING", "DONE" and "MATCHING" are invariant in English,
                  // so there is no singular/plural pair to choose between: one
                  // task reads "1 PENDING" and so do three. Only "DAY"/"DAYS"
                  // inflects.
                  //
                  // A tag narrows the count the same way a search does, because
                  // it is doing the same job — a list that says "4 PENDING" over
                  // two drawn rows has lost an argument somewhere.
                  text: root.allDays
                    ? !root.narrowActive
                      ? root.pendingAll.tasks + " PENDING"
                        + " · " + root.pendingAll.groups + (root.pendingAll.groups === 1 ? " DAY" : " DAYS")
                      : root.listSummary.tasks > 0
                        ? root.listSummary.tasks + " MATCHING · "
                          + root.listSummary.groups + (root.listSummary.groups === 1 ? " DAY" : " DAYS")
                        : "NO MATCHES"
                    : !root.narrowActive
                      ? root.selectedPending > 0
                        ? root.selectedPending + " PENDING"
                          + (root.selectedDone > 0 ? " · " + root.selectedDone + " DONE" : "")
                        : "ALL CLEAR"
                      : root.listPending + root.listDone > 0
                        ? root.listPending + " MATCHING"
                          + (root.listDone > 0 ? " · " + root.listDone + " DONE" : "")
                        : "NO MATCHES"
                  color: root.allDays
                    ? Qt.alpha(root.contentForeground, 0.75)
                    : root.narrowActive
                      ? Qt.alpha(root.contentForeground, 0.75)
                      : root.selectedPending > 0
                        ? Qt.alpha(root.contentForeground, 0.75)
                        : root.doneTaskColor
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                  font.bold: true
                }
              }

              // ---- The tags, as a row of chips over the list. The filter, and
              //      only that: in force when inverted, off again on a second
              //      click, with the count of what each one would show.
              //
              //      The two ways of narrowing now sandwich the list — tags
              //      above it, the field that narrows by name below it — and
              //      both sit apart from the way a tag gets set, which is row
              //      three of the composer. These chips used to double as the
              //      way in, and a reader could not tell which of the two they
              //      were about to hit.
              //
              //      A Flow rather than a Row: the set of tags is the reader's
              //      and can be any length, and a Row that ran past the panel
              //      would push the last chip off an edge with no way to reach
              //      it. Wrapping keeps every one of them on screen.
              Flow {
                id: tagRow
                width: parent.width
                spacing: Style.spacing.xs
                visible: tagChipRepeater.count > 0

                Repeater {
                  id: tagChipRepeater
                  model: root.tagChips

                  delegate: Rectangle {
                    required property var modelData

                    readonly property bool on_: Tasks.tagNeedle(root.tagFilter) === modelData.tag

                    width: tagChipText.implicitWidth + Style.spacing.md
                    height: tagChipText.implicitHeight + Style.spacing.xs
                    radius: Style.cornerRadius
                    // Inverted when in force, exactly as the editor inverts a
                    // selected chip. The one colour never used for it is the
                    // pending red, which would say this tag is overdue rather
                    // than active.
                    color: on_
                      ? root.contentForeground
                      : tagChipMouse.containsMouse
                        ? Style.hoverFillFor(root.contentForeground, Color.accent)
                        : Qt.alpha(root.contentForeground, 0.07)
                    border.width: on_ ? 0 : Style.normalBorderWidth
                    border.color: Qt.alpha(root.contentForeground, 0.18)

                    Text {
                      id: tagChipText
                      anchors.centerIn: parent
                      text: "#" + modelData.tag
                        + (modelData.count > 1 ? "  " + modelData.count : "")
                      color: on_
                        ? Color.popups.background
                        : Qt.alpha(root.contentForeground, 0.78)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: on_
                    }

                    MouseArea {
                      id: tagChipMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.toggleTagFilter(modelData.tag)
                    }

                    PanelToolTip {
                      visible: tagChipMouse.containsMouse
                      text: modelData.count === 0
                        ? "#" + modelData.tag + " · click to show all"
                        : "#" + modelData.tag + " · " + modelData.count
                          + (modelData.count === 1 ? " task" : " tasks")
                          + (root.tagActive ? " · click again to show all" : " · click to filter")
                    }
                  }
                }
              }

              // ---- The list, in two sections. Outstanding work comes first and
              //      finished work drops into a quieter block below it, because
              //      the things you still have to do are the only ones worth
              //      competing for attention. That is also the order the two
              //      Repeaters are declared in: a Repeater fills its slot in
              //      the Column it sits in, so declaring finished work first
              //      would put it above what is still open, which is the
              //      reverse of what the comment here used to claim.
              //
              //      Which days those sections draw from depends on `allDays`.
              //      The wider view groups its open work by day and leaves the
              //      finished block out — a per-day receipts list hung under
              //      other days' tasks would be describing a day the reader is
              //      not looking at.
              Text {
                textFormat: Text.PlainText
                width: parent.width
                // A search that matches nothing is its own absence, and saying
                // "Nothing pending" over it would be answering a different
                // question — the store may well be full. Naming the needle back
                // is what tells the reader the list is filtered rather than
                // empty.
                visible: root.taskStoreLoaded && (root.allDays
                  ? root.listSummary.tasks === 0
                  : root.listDone === 0 && root.listPending === 0 && root.selectedTasks.length > 0)
                text: !root.taskStoreLoaded ? ""
                  : root.allDays
                    ? root.narrowActive
                      ? root.emptyNarrowText
                      : "Nothing pending. Add something below."
                    : root.narrowActive
                      ? root.emptyNarrowText
                      : "Nothing planned for this day."
                color: Qt.darker(root.contentForeground, 1.9)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }

              // ---- The wider view. A Repeater of day groups, each with its own
              //      heading, so the list reads as "things, in order, grouped by
              //      when" rather than as one undifferentiated column of rows
              //      whose dates have to be inferred from each row's badge.
              //
              //      Flattening these into a single list of tasks with the date
              //      repeated on each one was the other option, and it is worse:
              //      the same date four times is four things to read instead of
              //      one, and the repetition makes the gaps between days harder
              //      to see than no repetition at all.
              Repeater {
                model: root.allDays ? root.listGroups : []

                delegate: Item {
                  required property var modelData

                  width: parent ? parent.width : 0
                  // Measured off the last child for the same reason the
                  // finished block measures its own: hand-summed heights go
                  // wrong the first time a spacing token changes.
                  height: groupList.y + groupList.height

                  // The id is not `groupHeading`: that name is root's function,
                  // and an id in an inner scope shadowing a property on the
                  // outer one is a trap for whoever edits this next.
                  Text {
                    id: groupLabel
                    textFormat: Text.PlainText
                    width: parent.width
                    height: implicitHeight
                    // Named by the same phrase the composer uses, so a day reads
                    // the same everywhere it appears: "TODAY", "TOMORROW", and a
                    // short date beyond that. The count is here rather than on
                    // the rows because it is the one number for the whole group.
                    text: root.groupHeading(modelData.dayKey)
                      + (modelData.tasks.length > 1 ? " · " + modelData.tasks.length + " PENDING" : " · 1 PENDING")
                    color: Qt.alpha(root.contentForeground, 0.45)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1.5
                    font.bold: true
                    elide: Text.ElideRight

                    MouseArea {
                      anchors.fill: parent
                      // Wider than the heading's own box, for the same reason
                      // the header's is: the words are the affordance, and they
                      // are small ones.
                      anchors.margins: -Style.space(2)
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.jumpToDay(modelData.dayKey)
                    }
                  }

                  Column {
                    id: groupList
                    // Guarded for the same reason the two delegates above are:
                    // this Column is destroyed with its rows still bound to it.
                    width: parent ? parent.width : 0
                    spacing: Style.spacing.xxs
                    y: groupLabel.height + Style.spacing.xs

                    Repeater {
                      model: modelData.tasks
                      delegate: taskRow
                    }
                  }
                }
              }

              // ---- A single day. The same row component as the groups above,
              //      so what a task looks like cannot drift between the two
              //      views; only which days are in the model changes.
              Repeater {
                model: root.allDays ? [] : root.listDayPending
                delegate: taskRow
              }

              // The completed section is capped: a day can easily end up with
              // more of them than pending, and an uncapped list would push the
              // composer itself off the panel. The count stays honest by
              // showing how many are folded away.
              Item {
                width: parent.width
                // Measured off the last child, not summed by hand. The old
                // expression added the heading and the two lists but skipped the
                // hairline above the heading and the spacing.md gap between
                // them, so it came out Style.spacing.md + hairline - spacing.sm
                // short — 6px at the default scale. This Item is a child of
                // taskBlock's Column, and the Column only reserves the height
                // declared here, so the finished list rendered past the bottom
                // of the panel's own content: clip: true sliced the last row
                // through the middle of its name and contentHeight was short by
                // the same amount, so there was nothing to scroll to bring it
                // back. Taking the bottom of the last child cannot drift when a
                // spacing token changes, because the tokens that position the
                // children are the same ones that measure them.
                height: root.showDoneSection
                  ? moreDoneLabel.y + moreDoneLabel.height
                  : 0
                visible: root.showDoneSection

                // A hairline with a gap on either side, so the finished block
                // separates from the open work without drawing a box around it.
                Rectangle {
                  id: doneRule
                  anchors.top: parent.top
                  anchors.horizontalCenter: parent.horizontalCenter
                  width: Math.max(parent.width - Style.spacing.xl * 2, 0)
                  height: Style.spacing.hairline
                  color: Qt.alpha(root.contentForeground, 0.18)
                }

                Text {
                  id: doneHeading
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: doneRule.bottom
                  anchors.topMargin: Style.spacing.md
                  height: implicitHeight
                  text: "DONE"
                  color: Qt.alpha(root.doneTaskColor, 0.85)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1.5
                  font.bold: true
                }

                Column {
                  id: doneList
                  width: parent.width
                  spacing: Style.spacing.xxs
                  y: doneHeading.y + doneHeading.height + Style.spacing.xs

                  Repeater {
                    model: root.doneExpanded
                      ? root.listDayDone
                      : root.listDayDone.slice(0, root.collapsedDoneLimit)
                    delegate: taskRow
                  }
                }

                Text {
                  id: moreDoneLabel
                  textFormat: Text.PlainText
                  width: parent.width
                  y: doneList.y + doneList.height
                  height: visible ? implicitHeight : 0
                  // Counted off the filtered list for the same reason the rows
                  // are drawn from it: a "Show 3 more" that would reveal three
                  // rows the search has already hidden is a button that lies.
                  visible: root.listDone > root.collapsedDoneLimit
                  text: root.doneExpanded
                    ? "Show less"
                    : "Show " + (root.listDone - root.collapsedDoneLimit) + " more"
                  color: Qt.darker(root.contentForeground, 1.6)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.doneExpanded = !root.doneExpanded
                  }
                }
              }

              // ---- Searching. Its own field rather than a mode, because
              //      looking for one task is not a different place to be — the
              //      list is the same list, narrowed. At the foot of it rather
              //      than over its head: the tasks are what this panel is for,
              //      and a field above them spent the first row on a box you
              //      only reach for when you already know what you want. It is
              //      always there — a search box behind a button is a search
              //      nobody uses.
              TextField {
                id: searchField
                width: parent.width
                placeholderText: "Search name, description or #tag"
                foreground: root.contentForeground
                accent: Color.accent
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                selectByMouse: true
                // No onAccepted: a search that has to be confirmed is a search
                // that shows you the wrong list while you finish typing.
                onTextChanged: root.searchQuery = text
                Keys.onEscapePressed: {
                  text = ""
                  keyCatcher.forceActiveFocus()
                }
              }
              // ---- Statistics, under the list rather than over it. Closed by
              //      default and opened by one word, because these numbers are
              //      the ones you go looking for — a streak is not something you
              //      need while you are writing a task down.
              //
              //      A Column rather than a fixed-height Item: the block's own
              //      height is what the collapsed state has to get right, and a
              //      hand-summed height here would be a second list of the
              //      pieces, kept in step by hand with the pieces themselves.
              Column {
                id: statsBlock
                width: parent.width
                spacing: Style.spacing.xs
                visible: root.statsFigures.length > 0

                Item {
                  id: statsHeaderRow
                  width: parent.width
                  height: Math.max(statsHeader.implicitHeight, Style.space(10))

                  // The same small-caps label as the rails above, so it reads as
                  // part of the panel's furniture rather than as a caption
                  // somebody left on.
                  Text {
                    id: statsHeader
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: root.statsExpanded ? "STATS  ▾" : "STATS  ▸"
                    color: Qt.darker(root.contentForeground, 1.7)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.letterSpacing: 1
                    font.bold: true
                  }

                  Text {
                    id: statsHint
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    // The word for what opening it will do, in the smallest type
                    // on the panel — a header that says what it is is a label, and
                    // a label does not need to advertise itself.
                    text: root.statsExpanded ? "Hide" : "Show"
                    color: Qt.alpha(root.contentForeground, 0.5)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.statsExpanded = !root.statsExpanded
                  }
                }

                Flow {
                  id: statsBody
                  width: parent.width
                  spacing: Style.spacing.xs
                  // A Flow so a narrow panel wraps the figures instead of
                  // running the last one off an edge with no way to reach it.
                  visible: root.statsExpanded

                  Repeater {
                    model: root.statsFigures

                    delegate: Rectangle {
                      required property var modelData

                      width: statText.implicitWidth + Style.spacing.md
                      height: statText.implicitHeight + Style.spacing.xs
                      radius: Style.cornerRadius
                      // A read-out, not a control: nothing here can be changed by
                      // pressing it, so it wears the quiet fill of an inert chip
                      // and never the inverted fill of a selected one.
                      color: Qt.alpha(root.contentForeground, 0.07)
                      border.width: Style.normalBorderWidth
                      border.color: Qt.alpha(root.contentForeground, 0.16)

                      Text {
                        id: statText
                        anchors.centerIn: parent
                        textFormat: Text.PlainText
                        text: modelData.value + "  " + modelData.label
                        color: Qt.alpha(root.contentForeground, 0.8)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }

                      HoverHandler { id: statHover }

                      PanelToolTip {
                        visible: statHover.hovered
                        text: modelData.tip
                      }
                    }
                  }
                }
              }
            }

          }
        }
      }

      // ---- The composer's two mini-windows: one layer over the whole card.
      //
      // A layer and not a child of the composer, for the same two reasons the
      // undo toast is one: a window opened from the middle of the panel has to
      // paint over the list below it, and the Column that lays the composer
      // out would either shove the list down to make room or clip a window
      // that is supposed to be floating. The Item fills the card; only its own
      // scrim swallows a click, and the window sits above the scrim so a press
      // inside lands on the choice rather than on the way to closing it.
      //
      // One window at a time is `draftPopover`'s whole job, and the position
      // is stored rather than bound: `mapToItem` reads the transform, which is
      // not a property anything can watch, so a binding on it would evaluate
      // once and then never follow the panel if it moved.
      Item {
        id: composerPopover
        anchors.fill: parent
        z: 90
        visible: root.draftPopover !== ""
        focus: visible
        Keys.onEscapePressed: root.draftPopover = ""

        property real popupX: 0
        property real popupY: 0

        readonly property real popupLeft: Math.max(Style.space(6),
          Math.min(popupX, width - Style.space(6)))

        MouseArea {
          anchors.fill: parent
          onClicked: root.draftPopover = ""
        }

        // ---- The four flags. Four rows, each saying its own answer in the
        //      colour the mark will wear, so the choice is read rather than
        //      remembered: red, amber, blue, grey, in the order the row's own
        //      cycle walks them.
        Rectangle {
          id: priorityPopup
          visible: root.draftPopover === "priority"
          x: composerPopover.popupLeft
          y: composerPopover.popupY
          width: Style.space(170)
          height: priorityList.height + Style.spacing.md * 2
          radius: Style.cornerRadius
          color: Color.popups.background
          border.width: Style.normalBorderWidth
          border.color: Color.popups.border

          // Declared before the rows and wider than them: it takes every press
          // the rows do not, which is the press meant for the scrim behind.
          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
          }

          Column {
            id: priorityList
            x: Style.spacing.md
            y: Style.spacing.md
            width: priorityPopup.width - Style.spacing.md * 2
            spacing: 0

            Repeater {
              model: [
                { value: null, label: "None" },
                { value: "high", label: "High" },
                { value: "medium", label: "Medium" },
                { value: "low", label: "Low" }
              ]

              delegate: Rectangle {
                required property var modelData

                readonly property bool on_: root.draftPriority === modelData.value

                width: parent.width
                height: Style.spacing.controlHeight
                radius: Style.cornerRadius
                color: priorityRowMouse.containsMouse
                  ? Style.hoverFillFor(root.contentForeground, Color.accent)
                  : on_
                    ? Qt.alpha(root.contentForeground, 0.12)
                    : "transparent"

                Row {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.spacing.sm
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.spacing.sm

                  FlagGlyph {
                    flagColor: Tasks.priorityColor(modelData.value)
                    size: Style.space(14)
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: modelData.label
                    color: Color.popups.text
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: on_
                  }
                }

                MouseArea {
                  id: priorityRowMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.draftPriority = modelData.value
                    root.draftPopover = ""
                  }
                }
              }
            }
          }
        }

        // ---- The tags, as a box to type into rather than a list to pick
        //      from. The set belongs to the reader and can be any length, so
        //      the only control that can be honest about it is a field — a
        //      menu of tags would have to know them in advance, and it is the
        //      one part of the task that has no fixed vocabulary.
        Rectangle {
          id: tagPopup
          visible: root.draftPopover === "tags"
          x: composerPopover.popupLeft
          y: composerPopover.popupY
          width: Style.space(240)
          height: tagBody.height + Style.spacing.md * 2
          radius: Style.cornerRadius
          color: Color.popups.background
          border.width: Style.normalBorderWidth
          border.color: Color.popups.border

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
          }

          Column {
            id: tagBody
            x: Style.spacing.md
            y: Style.spacing.md
            width: tagPopup.width - Style.spacing.md * 2
            spacing: Style.spacing.sm

            TextField {
              id: tagDraftField
              width: parent.width
              placeholderText: "Add #tag"
              foreground: Color.popups.text
              accent: Color.accent
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              selectByMouse: true
              // Enter adds and keeps the window open: tags come in ones and
              // twos, and a window that closed after each would make the
              // second one a second hunt for the button.
              onAccepted: {
                root.addDraftTag(text)
                text = ""
              }
              Keys.onEscapePressed: root.draftPopover = ""
            }

            Flow {
              id: tagDraftFlow
              width: parent.width
              spacing: Style.spacing.xs
              visible: root.draftTags.length > 0

              Repeater {
                model: root.draftTags

                delegate: Rectangle {
                  required property var modelData

                  width: tagDraftChip.implicitWidth + Style.spacing.md
                  height: tagDraftChip.implicitHeight + Style.spacing.xs * 2
                  radius: Style.cornerRadius
                  color: tagDraftChipMouse.containsMouse
                    ? Style.hoverFillFor(Color.popups.text, Color.accent)
                    : Qt.alpha(Color.popups.text, 0.1)

                  Text {
                    id: tagDraftChip
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: "#" + modelData
                    color: Color.popups.text
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }

                  MouseArea {
                    id: tagDraftChipMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.removeDraftTag(modelData)
                  }
                }
              }
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.draftTags.length === 0
                ? "Enter to add · comma separated · Esc to close"
                : "Click a tag to remove · Enter to add more"
              color: Qt.alpha(Color.popups.text, 0.55)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }
        }
      }

      // ---- Undo for the last delete.
      //
      // A toast rather than something inline, because a deleted row has no
      // inline left to put a button on — the row it belonged to is gone. It
      // rides over the bottom of the card, holds for six seconds and then
      // expires on its own: long enough to notice the mistake and reach for
      // it, short enough that it is not still sitting there tomorrow.
      //
      // The Item fills the card but swallows nothing — an Item without a
      // MouseArea lets clicks straight through to the calendar, so the panel
      // stays fully usable while the offer is on screen. Only the card itself
      // takes the pointer, so a click meant for Undo cannot land on a day.
      //
      // Never stacked. Only the newest delete is wired to the button, so a
      // second delete replaces the first rather than queueing a second
      // promise that nothing would honour.
      Item {
        id: undoToast
        anchors.fill: parent
        z: 100
        visible: root.pendingUndo !== null

        Timer {
          id: undoTimer
          interval: 6000
          repeat: false
          onTriggered: root.dismissUndo()
        }

        Rectangle {
          id: undoCard
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Style.space(18)
          implicitWidth: undoRow.implicitWidth + Style.space(32)
          implicitHeight: undoRow.implicitHeight + Style.space(18)
          radius: Style.cornerRadius
          color: Color.popups.background
          border.color: Color.popups.border
          border.width: Style.normalBorderWidth

          Row {
            id: undoRow
            anchors.centerIn: parent
            spacing: Style.spacing.md

            Text {
              text: root.pendingUndo ? "Task deleted" : ""
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: undoAction
              text: "Undo"
              // Underlined rather than merely recoloured: the accent alone is
              // easy to read as decoration next to a line of plain text, and
              // this is the one word on the card that does something.
              color: undoMouse.containsMouse ? Color.accent : Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.underline: undoMouse.containsMouse
              anchors.verticalCenter: parent.verticalCenter

              MouseArea {
                id: undoMouse
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.undoDelete()
              }
            }
          }
        }
      }
    }
  }
}
