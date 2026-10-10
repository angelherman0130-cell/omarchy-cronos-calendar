import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "ReminderQueue.js" as ReminderQueue

// Date/time label for the bar, and the host for the calendar popup.
//
// Left click reveals the calendar — asking "what is the date?" is what a
// click on a clock means — right click walks the common label formats, and
// middle click opens the timezone picker.
BarWidget {
  id: root
  moduleName: "omarchy.clock"

  property date displayDate: clock.date

  readonly property string configuredFormat: vertical
    ? setting("verticalFormat", "HH\n—\nmm")
    : setting("format", "dddd HH:mm")
  readonly property string configuredAltFormat: vertical
    ? setting("verticalFormatAlt", "dd\nMMM\n'W'ww\n''yy")
    : setting("formatAlt", "d MMMM 'W'ww yyyy")

  readonly property var formatRing: Model.clockFormatRing(configuredFormat, configuredAltFormat, Model.clockFormats(vertical))

  // What the bar shows is what shell.json stores, so a cycled format is the
  // format from then on rather than something that reverts on restart.
  readonly property string activeFormat: configuredFormat
  readonly property string displayText: formatted(displayDate)
  readonly property var verticalLines: displayText.split("\n")

  function refresh() {
    displayDate = new Date()
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function cycleFormat() {
    var current = String(configuredFormat)
    var next = Model.nextClockFormat(formatRing, current)
    if (next === "" || next === current) return

    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry[vertical ? "verticalFormat" : "format"] = next

    // Applied locally first so the label changes on the click itself; the
    // shell.json write comes back through the bar as the same value.
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // The label is English whatever the system's locale is. The presets are full
  // of `dddd` and `MMM`, so on an es_ES desktop Qt would otherwise write the
  // weekday and month in Spanish right here in the bar — the one piece of this
  // plugin that is always on screen. labelLocale is the same object the panel's
  // own headings use, so the two cannot drift apart.
  readonly property var labelLocale: Qt.locale("en_US")

  function formatted(date) {
    return labelLocale.toString(date, activeFormat.replace(/ww/g, Model.isoWeekLiteral(date.getFullYear(), date.getMonth(), date.getDate())))
  }

  // ---- Calendar popup. Shape contract for shell.summon/hide/toggle
  //      routing: Bar.findPanelWidget requires open/close/opened on the
  //      bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function toggleWeekStart() {
    if (panelLoader.item) panelLoader.item.toggleWeekStart()
  }

  // The clock fills more slot than it paints a mark for, at both
  // orientations: horizontally it is a text label in a padded slot, so the
  // dot takes the label width; vertically it is a stack of icon-sized lines,
  // so the dot takes one line — the same mark every icon widget gets, rather
  // than a rule running the height of the whole stack.
  readonly property real openPanelIndicatorWidth: button.labelWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity: Bar.requestPopout prefers closeForPopoutSwitch over close, and
  // KeyboardPanel reads popoutSwitchClosing back off its owner.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: root.displayDate = date
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // ---- Reminders, widget side.
  //
  // ClockReminders.sh decides *what* is due and writes it here; this side
  // decides *how it is shown*, and the split is deliberate. Posting the
  // reminder as a notification would hand the task title to the session's
  // notification host, which persists every popup it is given by re-running a
  // shell with the whole JSON as an argument — a command line any other local
  // account can read off /proc while it lasts. Reading a 0600 file and
  // painting the card here keeps the title inside the widget's own address
  // space: file, QML, screen, with no process in between to leak it.
  readonly property string reminderQueuePath: Color.stateHome + "/omarchy/clock-reminders.json"

  // The batch on screen, and the id of the batch that put it there. The id
  // exists so a file event that re-reports the same batch cannot show it
  // twice; the array is what the card renders.
  property var reminderItems: []
  property string reminderRun: ""

  FileView {
    id: reminderQueue
    path: root.reminderQueuePath
    watchChanges: true
    printErrors: false
    // fileChanged only announces that the file moved; reload() is what makes
    // the new bytes readable, and reading text() here would see the old ones.
    onFileChanged: reload()
    onLoaded: root.consumeReminders(text())
  }

  // Whether to show a batch — and why not, when not — is ReminderQueue's call,
  // not this file's: it is the same kind of pure, Qt-free decision as Tasks.js,
  // so it is unit-tested under plain node instead of being read off a screen.
  // The only thing decided here is what to do with the answer.
  function consumeReminders(raw) {
    var verdict = ReminderQueue.pick(raw, Date.now() / 1000, root.reminderRun)
    if (!verdict.show) {
      // "empty" is the ordinary state of a machine with nothing outstanding,
      // and "no-items" is a batch the script never writes: logging either
      // would be a line per shell start saying nothing happened.
      if (verdict.reason !== "empty" && verdict.reason !== "no-items")
        console.log("Cronos-Calendar: queue not shown (" + verdict.reason + ")")
      return
    }

    // The batch is rare — hourly at most, and only while something is
    // outstanding — so one line in the shell log costs nothing and is the
    // only trace there is that a reminder reached the screen.
    console.log("Cronos-Calendar: showing", verdict.items.length, "reminder(s)")
    root.reminderRun = verdict.run
    root.reminderItems = verdict.items
  }

  ReminderPopup {
    id: reminderPopup
    anchorItem: button
    bar: root.bar
    items: root.reminderItems
    onDismissed: root.reminderItems = []
  }

  IpcHandler {
    target: "omarchy.clock"

    function refresh(): void { root.broadcast("refresh") }
    function cycleFormat(): void { root.cycleFormat() }
    function toggleWeekStart(): void { root.toggleWeekStart() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? "" : root.displayText
    labelVisible: !root.vertical
    hasVisualContent: root.vertical ? root.verticalLines.length > 0 : text !== ""
    fixedHeight: root.vertical ? root.verticalLines.length * Style.bar.iconSlot : -1
    horizontalMargin: 8.75
    verticalPadding: 8.75

    onPressed: function(b) {
      if (b === Qt.RightButton) root.cycleFormat()
      else if (b === Qt.MiddleButton) { if (root.bar) root.bar.run("omarchy-menu-timezone") }
      else root.togglePanel()
    }

    Column {
      visible: root.vertical
      anchors.fill: parent

      Repeater {
        model: root.verticalLines

        OpticalGlyph {
          required property string modelData
          width: button.width
          height: Style.bar.iconSlot
          text: modelData
          fontFamily: button.fontFamily
          fontSize: modelData.length > 3
            ? button.fontSize * 0.9
            : button.fontSize
          color: button.foreground
        }
      }
    }
  }
}
