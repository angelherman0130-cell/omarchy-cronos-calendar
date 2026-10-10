// One task in the selected day's list.
//
// Split out of Panel.qml because the list draws the same row twice — once for
// outstanding work, once for completed — and two copies of a row with a
// checkbox, a label and a delete button is exactly the kind of duplication
// that drifts apart after the first edit.
//
// The row is deliberately dumb: it holds no tasks and writes no files, only
// reports what was clicked. The panel passes the theme's foreground and font
// down rather than the row reaching for them, so a sibling component never has
// to know who owns it.
//
// Two exceptions, both reads: the row asks Tasks whether a deadline has gone by
// and what a reminder's short form says, rather than keeping its own copies of
// those rules. Two components each deciding what "overdue" means is how the list
// and the clock start disagreeing about the same task.

import QtQuick
import qs.Commons
import qs.Ui
import "Tasks.js" as Tasks

Item {
  id: row

  required property var task

  // Two colours with two jobs between them and no overlap: pendingColor is
  // everything still owed — outstanding, overdue, unreadable — and doneColor is
  // finished. A row that is both unfinished and overdue is therefore all red,
  // which is one message rather than two colours disagreeing on screen.
  property color contentForeground: "#ffffff"
  property string contentFontFamily: "sans-serif"
  property color doneColor: "#22c55e"
  property color pendingColor: "#ef4444"
  // Minutes since midnight and today's key, both supplied by the panel rather
  // than read here: the row is a drawing, and a row keeping its own copy of the
  // time would be one more thing to go stale while the panel's is live. An
  // absent today means the row cannot judge a deadline, and it declines to
  // rather than guessing.
  property int nowMinutes: 0
  property string nowDayKey: ""
  // Whether the row is drawn as part of the list spanning every day. In that
  // list a deadline that has not yet passed is still owed work, and the pending
  // colour is what makes it findable among rows from other days; in a single
  // day's list the same deadline is not overdue and must not shout. The row
  // cannot tell the two views apart by itself — the same task looks the same
  // either way — so the panel answers it.
  property bool contextAllDays: false

  // Whether this row is the one being edited. Owned by the panel rather than
  // kept here, because two rows open at once would be two editors competing for
  // the same keyboard with nothing on screen saying which one has it.
  property bool editing: false

  // Which tag the list is narrowed to, or "" for all of them. Handed down from
  // the panel so a chip on this row can show itself as the one being followed
  // — a filter you cannot see is a filter that looks like a task list with
  // parts missing.
  property string tagFilter: ""

  signal toggled(string id)
  signal removed(string id)
  signal fieldCleared(string id, string field)
  // The tag chip asks rather than acts: the row cannot narrow the list, only
  // the panel can, and a chip that filtered nothing would be a lie the moment
  // it was pressed.
  signal tagClicked(string tag)
  // The mark on the row is a control, not a read-out: one press walks it to
  // the next priority. It reports upwards for the same reason the tag chip
  // asks rather than acts — the row cannot write the store, only the panel
  // can, and a mark that changed only on screen would be undone by the next
  // reload. `priority` is `var` because none is how "no priority" is spelled.
  signal priorityRequested(string id, var priority)
  // Opening is reported upwards rather than handled here, because only the panel
  // knows which other row is open: two editors at once is one keyboard and no
  // visible way to tell which row has it.
  signal editRequested()
  // The deadline and the reminder travel with the text rather than arriving as
  // two signals of their own, because the editor saves them in one gesture: a
  // name, a note, an hour and a reminder are one task's worth of changes and
  // the row already has one Save button. `remindDaysBefore` is `var` and not an
  // int because null is how "no reminder" is spelled — an int would not carry it.
  signal editSaved(string id, string text, string note, string dueTime, var remindDaysBefore, var priority, var tags)
  signal editCancelled()

  readonly property bool overdue: Tasks.isOverdue(
    { dayKey: task.dayKey, dueTime: task.dueTime, done: task.done }, nowDayKey, nowMinutes)
  // The red this row wears, which is not the same question as "is it overdue".
  // In the wider view any deadline counts as owed: the list is sorted by how
  // soon things fall due, and the near ones are the ones being looked for. In a
  // single day's view only a deadline that has actually gone by counts.
  // Finished tasks are never outstanding, so this is false for them in both
  // views — a ticked row must not go red for having a deadline on it.
  readonly property bool outstanding: task.done !== true
    && (row.overdue || (row.contextAllDays && row.dueSet))
  readonly property bool dueSet: String(task.dueTime || "") !== ""
  // Not "> 0": 0 is the day-of reminder, which is on. Only null is off.
  readonly property bool remindSet: Tasks.hasReminder(task)

  // The note, as the row can afford to draw it: at most two lines. Two is the
  // whole budget — the row is 424px wide and already carries a checkbox, a
  // deadline and a reminder, and a third line of note turns the list into a
  // column of paragraphs. The cap lives in noteLines rather than here so the
  // stored note is never shortened by the fact that a row could not show all of
  // it: what was written down and what is legible are different questions.
  readonly property var noteShown: Tasks.noteLines(task.note, 2)
  readonly property bool noteShownAll: Tasks.hasNote(task)
    && row.noteShown.length === Tasks.noteLines(task.note, 99).length

  // How long is left, or "" when there is nothing left to count: a finished
  // task, a deadline that has already gone by, or no deadline at all.
  //
  // The badge shows this instead of the bare hour because in a list that spans
  // several days "17:00" does not answer the question the list is sorted by —
  // how soon. The hour itself does not go anywhere: it stays in the tooltip,
  // where a badge's narrow width had already pushed it out of reading range.
  //
  // Counted from `task.dayKey` rather than from today, so a task due a week
  // tomorrow reads as days rather than as the hours left of today. It is
  // recomputed every time the panel's minute-precision clock moves, which is
  // what keeps a countdown counting.
  readonly property string dueCountdown: !row.dueSet || row.task.done === true
    ? ""
    : Tasks.timeUntil(task.dayKey, task.dueTime, nowDayKey, nowMinutes)

  // What the row draws at its right edge, in reading order: when it is due, and
  // when it will start nagging. Built as data so both badges are drawn by one
  // repeater, and so a task with neither collapses to no badges at all rather
  // than to a gap.
  readonly property var badges: {
    var out = []
    // The tags first, because they are the ones a click sorts the list by and
    // the ones the reader is scanning for — a deadline to their right is a
    // constant, a tag is not.
    //
    // Capped at three. The row shares one line with the name, the deadline and
    // the reminder, and a task tagged a dozen ways would otherwise take the
    // whole line and leave the name an ellipsis. What is left over is counted
    // rather than hidden: "+2" is the difference between a list that shows what
    // it can and one that looks finished.
    var tags = Tasks.cleanTags(row.task.tags)
    var shown = tags.slice(0, 3)
    for (var i = 0; i < shown.length; i++) {
      out.push({
        key: "tag",
        tag: shown[i],
        text: "#" + shown[i],
        // The tag being followed wears the accent, the rest stay quiet. Not
        // red and not green: those two colours are already spoken for by work
        // owed and work finished, and a filter is neither.
        color: row.tagFilter === shown[i]
          ? Color.accent
          : Qt.alpha(row.contentForeground, 0.6),
        bold: row.tagFilter === shown[i],
        tip: row.tagFilter === shown[i]
          ? "#" + shown[i] + " · showing only these — click to show all"
          : "Filter the list to #" + shown[i] + " · click to show all"
      })
    }
    if (tags.length > shown.length) {
      out.push({
        key: "tagoverflow",
        tag: "",
        text: "+" + (tags.length - shown.length),
        color: Qt.alpha(row.contentForeground, 0.45),
        bold: false,
        tip: tags.slice(shown.length).map(function(t) { return "#" + t }).join("  ")
          + " · click to edit"
      })
    }
    if (row.dueSet) {
      out.push({
        key: "dueTime",
        // A deadline still to come says how long is left; anything else says
        // what the deadline was, because a countdown of zero is the one state
        // that no longer counts down.
        text: row.dueCountdown !== "" ? row.dueCountdown : String(row.task.dueTime || ""),
        // Outstanding wears the pending colour, not the finished one: a
        // deadline that has gone by — or, in the wider view, one that is still
        // to come — is still work owed, and painting it with the done colour
        // would have made a missed deadline look like a finished one. The
        // tooltip still says "Overdue" only when it really did, because the
        // wording is a statement about the clock rather than about the colour.
        color: row.outstanding ? row.pendingColor : Qt.alpha(row.contentForeground, 0.72),
        bold: row.outstanding,
        tip: row.overdue
          ? "Overdue at " + row.task.dueTime
          : "Due " + row.task.dueTime
            + (row.dueCountdown !== "" ? " · in " + row.dueCountdown : "")
            + " · click to clear"
      })
    }
    if (row.remindSet) {
      out.push({
        key: "remindDaysBefore",
        text: Tasks.remindDaysShort(row.task.remindDaysBefore),
        color: Qt.alpha(row.contentForeground, 0.72),
        bold: false,
        tip: "Reminds every hour " + Tasks.remindDaysLabel(row.task.remindDaysBefore)
          + " · click to clear"
      })
    }
    return out
  }

  // ---- The row's height: the name's own height plus, if there is one, the note.
  //
  // baseHeight is deliberately the formula this row always used, unchanged, so
  // that a task without a note is laid out pixel for pixel as it was before the
  // note existed. Only noteBlockHeight is new, and it is added below rather
  // than distributed around, which keeps every existing row's name at the same
  // distance from the top of its row instead of shifting the whole list to
  // accommodate the rows that happen to have notes.
  readonly property real baseHeight: Math.max(label.implicitHeight, Style.spacing.xxl) + Style.spacing.xs
  readonly property real noteBlockHeight: row.noteShown.length > 0
    ? noteColumn.implicitHeight + Style.spacing.xs
    : 0

  // The name sits where centring it in baseHeight would have put it, which is
  // what the row did before it had anything below it. The checkbox, the badges
  // and the delete button then centre on the name rather than on the row, so a
  // row with a note does not leave them floating beside the note.
  readonly property real nameTopMargin: (row.baseHeight - label.implicitHeight) / 2

  // An open editor is two fields, a deadline with the reminder it implies, a
  // row of reminder chips and a row of buttons, so the row has to be taller
  // than it is at rest — and it takes the whole row's height rather than only
  // the height of what it replaces, because the composer and the deadline row
  // above it do the same when they open.
  //
  // Summed from the parts rather than read off the container: editBody fills the
  // row, and an item positioned by anchors reports an implicitHeight of 0, so
  // asking it how tall the editor is asks a question whose answer is always
  // "none" — and the row collapses to nothing while it is being edited, taking
  // the fields with it. Every block the editor draws has to be named here, in
  // the order it is drawn, or the row clips whatever was left out.
  readonly property real editHeight: editName.height
    + Style.spacing.xs
    + editNote.height
    + Style.spacing.sm
    + editMeta.height
    + Style.spacing.sm
    + editChips.height
    + Style.spacing.sm
    + priorityRow.height
    + Style.spacing.sm
    + editTags.height
    + Style.spacing.sm
    + editButtons.height
    + Style.spacing.sm * 2

  height: row.editing ? row.editHeight : row.baseHeight + row.noteBlockHeight

  // Take the keyboard as soon as the row opens for editing, so the name is
  // already being typed into rather than waiting for a second click. Deferred to
  // the next turn of the loop because `editing` is set from the panel and the
  // field does not exist yet on the way in.
  onEditingChanged: {
    // Seeded here rather than bound to `task.text`, for the reason the composer
    // gives for owning its own text: a `text: task.text` binding is broken by
    // the assignment below, and then the field and the task quietly disagree.
    // Loading on the way in also means a cancelled edit leaves nothing behind.
    if (editing) {
      editBody.seedFromTask()
      Qt.callLater(function() { editName.forceActiveFocus() })
    }
  }

  // The row is a quiet surface of its own so the list reads as a set of rows
  // rather than as loose text on the panel, and so the hover has something to
  // light up. At rest it is transparent — a faint card under every row was a
  // stack of boxes competing with the text; hover is when the surface earns
  // its fill.
  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: rowMouse.containsMouse
      ? Style.hoverFillFor(row.contentForeground, Color.accent)
      : "transparent"
  }

  // A hairline on the leading edge of a task still owed. The badge already says
  // it in words; this says it from across the room, which is the whole reason a
  // deadline is drawn in a colour rather than only in a timestamp.
  Rectangle {
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    width: Style.spacing.xxs
    height: parent.height - Style.spacing.md
    radius: width / 2
    color: row.outstanding ? row.pendingColor : "transparent"
    visible: row.outstanding
  }

  // The checkbox. Filled in the section's own colour when done, hollow in the
  // pending colour when not, and the whole row toggles with it — a small box is
  // a poor thing to have to hit.
  Rectangle {
    id: box
    anchors.left: parent.left
    anchors.leftMargin: Style.spacing.sm
    // On the name's middle rather than the row's: with a note under it, the row
    // is taller than the name and centring the box on the row would leave it
    // sitting between the name and the note rather than beside the name.
    anchors.verticalCenter: label.verticalCenter
    width: Style.spacing.md * 2
    height: width
    radius: Style.cornerRadius
    color: row.task.done ? row.doneColor : "transparent"
    border.width: Style.normalBorderWidth
    border.color: row.task.done
      ? row.doneColor
      : row.pendingColor

    Text {
      anchors.centerIn: parent
      visible: row.task.done
      text: "✓"
      color: Color.popups.background
      font.family: row.contentFontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  // The priority mark, between the checkbox and the name.
  //
  // Its own column of space rather than a glyph prefixed to the name, because
  // a prefix would change the name's text — and the name is what the row
  // elides, searches for and draws at a fixed left edge.
  //
  // The column is reserved on every row now, set or not. It used to collapse
  // to nothing with no priority, which kept rows laid out as they had been
  // before priorities existed and also hid the only control that sets one:
  // a mark that only appears once a value exists is a control nobody can find.
  // The faint circle is the affordance. Every row lines up on its name again,
  // because every row now carries the same mark.
  //
  // The mark is deliberately colourless: red is already spoken for by work
  // still owed, so a high-priority task would have read as an overdue one, and
  // green is finished. The three shapes say which priority it is, and how
  // faint the circle is says whether any of them is set.
  //
  // `z` lifts it over `rowMouse`, which is declared further down and would
  // otherwise swallow the press and tick the task off instead. Changing what a
  // task owes and marking it done are two different acts, and only one of them
  // was asked for.
  Text {
    id: priorityMark
    textFormat: Text.PlainText
    z: 1
    readonly property bool hasPriority: Tasks.priorityGlyph(row.task.priority) !== ""
    visible: !row.editing
    width: visible ? implicitWidth : 0
    anchors.left: box.right
    anchors.leftMargin: visible ? Style.spacing.xs : 0
    anchors.verticalCenter: label.verticalCenter
    text: hasPriority ? Tasks.priorityGlyph(row.task.priority) : "○"
    color: Qt.alpha(row.contentForeground, hasPriority ? 0.72 : 0.3)
    font.family: row.contentFontFamily
    font.pixelSize: Style.font.caption

    // The tooltip names the state you land in, not the one you are leaving.
    // "click to change" makes the reader guess, and guessing wrong is free to
    // test only because Escape does not undo this — the press has already
    // been written by the time the pointer moves away.
    readonly property string nextLabel: {
      var n = Tasks.priorityLabel(Tasks.nextPriority(row.task.priority))
      return n === "" ? "None" : n
    }

    MouseArea {
      id: priorityMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: row.priorityRequested(row.task.id,
        Tasks.nextPriority(row.task.priority))
    }

    PanelToolTip {
      visible: priorityMouse.containsMouse
      text: (Tasks.priorityLabel(row.task.priority) || "No")
        + " priority · click for " + priorityMark.nextLabel
    }
  }

  Text {
    id: label
    textFormat: Text.PlainText
    anchors.left: priorityMark.right
    anchors.leftMargin: Style.spacing.md
    // Against the badges rather than the delete button, so a task with a
    // deadline gives up label width instead of pushing the badges off the row.
    anchors.right: badges.left
    anchors.rightMargin: Style.spacing.sm
    anchors.top: parent.top
    anchors.topMargin: row.nameTopMargin
    text: row.task.text
    // Hidden while editing: the editor holds the same two strings in editable
    // fields, and a read-only copy of the name directly above the field that is
    // being typed into shows the old value while you fix it.
    visible: !row.editing
    // Struck through as well as dimmed: a done task and an unreadable one are
    // different states, and only one of them should look deprioritised.
    color: row.task.done
      ? Qt.alpha(row.contentForeground, 0.45)
      : row.contentForeground
    font.family: row.contentFontFamily
    font.pixelSize: Style.font.body
    font.strikeout: row.task.done
    elide: Text.ElideRight
  }

  // The note, under the name and over the same left edge, in the same column of
  // type rather than in a panel of its own. It is a caption on the name, so it
  // is drawn as one: dimmer, a size down, and never struck through — a done
  // task's name is struck to say the work is finished, and striking its note
  // too would say the words themselves were struck out.
  Column {
    id: noteColumn
    anchors.left: label.left
    anchors.right: parent.right
    // Clear of the action buttons, which the label deliberately reaches under:
    // the note is wrapped prose, and a line running under a delete glyph is a
    // line that looks pressable.
    anchors.rightMargin: actions.width + Style.spacing.sm
    anchors.top: label.bottom
    anchors.topMargin: Style.spacing.xs
    spacing: 0
    // Hidden for the same reason as the name: its editable copy is in editNote.
    visible: !row.editing && row.noteShown.length > 0

    Repeater {
      model: row.noteShown

      delegate: Text {
        required property string modelData
        // Index rather than a flag on the model: which line is last is a
        // question about position, and answering it here means the model stays
        // an array of strings instead of growing a field only the last one sets.
        required property int index

        width: noteColumn.width
        textFormat: Text.PlainText
        // The ellipsis goes on the last line *shown*, not the last line stored:
        // what is cut is always the one at the bottom of the row, so marking
        // some earlier line would point at text that is still there.
        //
        // Compared against the model's length rather than `noteColumn.count`,
        // which counts the Repeater itself and so is always one higher — a
        // comparison that quietly never matches and drops the ellipsis entirely.
        text: modelData + (index === row.noteShown.length - 1 && !row.noteShownAll ? " …" : "")
        elide: Text.ElideRight
        color: Qt.alpha(row.contentForeground, row.task.done ? 0.32 : 0.6)
        font.family: row.contentFontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  MouseArea {
    id: rowMouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    // Dead while the row is open for editing. The editor is drawn above this
    // MouseArea, so clicks in its fields never reach here — but a click on the
    // row's own padding beside them would, and that would tick the task off
    // while its text is being corrected. Toggling is one click away on the
    // checkbox's row once the edit is saved.
    enabled: !row.editing
    onClicked: row.toggled(row.task.id)
  }

  // The deadline and the reminder, in that order: when it is due is the fact
  // the row is really carrying, and when the nagging starts is a detail of it.
  Row {
    id: badges
    anchors.right: actions.left
    anchors.rightMargin: Style.spacing.sm
    anchors.verticalCenter: label.verticalCenter
    spacing: Style.spacing.xs
    // Hidden while editing: a badge is the control that clears its own field,
    // and clicking one next to an editor is a way to change a deadline nobody
    // was trying to change.
    visible: !row.editing && row.badges.length > 0

    Repeater {
      model: row.badges

      delegate: Item {
        required property var modelData
        required property int index

        // Bare text would read as part of the sentence: the badge is also the
        // only way to clear the field it shows, so it has to look like
        // something you can press. It takes the corners of the system's
        // windows, which is what already says "control" on this desktop; a
        // pill would be a shape of its own, and here it would be the only one.
        width: badgeText.implicitWidth + Style.spacing.md
        height: badgeText.implicitHeight + Style.spacing.xs

        Rectangle {
          anchors.fill: parent
          radius: Style.cornerRadius
          color: badgeMouse.containsMouse
            ? Style.hoverFillFor(row.contentForeground, Color.accent)
            : Qt.alpha(row.contentForeground, 0.09)
        }

        Text {
          id: badgeText
          anchors.centerIn: parent
          text: modelData.text
          color: modelData.color
          font.family: row.contentFontFamily
          font.pixelSize: Style.font.caption
          font.bold: modelData.bold
        }

        MouseArea {
          id: badgeMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          // Three things a badge can mean, and the key on the model says which:
          // a real field to clear, a tag to follow, and the overflow count,
          // which is neither and does nothing. Clearing on the last would be
          // destructive on a badge whose own tooltip says "click to edit" —
          // and editing is a button, not a hidden click on a number.
          onClicked: {
            if (modelData.tag) row.tagClicked(String(modelData.tag))
            else if (modelData.key !== "tag" && modelData.key !== "tagoverflow" && modelData.key)
              row.fieldCleared(row.task.id, modelData.key)
          }
        }

        PanelToolTip {
          visible: badgeMouse.containsMouse
          text: modelData.tip
        }
      }
    }
  }

  // Declared after rowMouse, so as the later sibling it is the one on top —
  // otherwise the row's own MouseArea would swallow the click and the button
  // would be dead.
  // The two row actions, edit then delete, in a Row so they take their width
  // from the buttons rather than from two separately anchored edges. Anchored
  // separately they would collide the moment a name ran long, and the delete
  // button is the one that must never be the thing pushed off the row.
  Row {
    id: actions
    anchors.right: parent.right
    anchors.rightMargin: Style.spacing.xs
    // On the name's middle. A hidden item still has geometry in QML, so this
    // stays correct while editing and the label is invisible — no conditional
    // needed, and the buttons do not jump when the editor opens.
    anchors.verticalCenter: label.verticalCenter
    spacing: Style.spacing.xxs
    // Quiet at rest: two glyphs on every row is furniture the list does not
    // need while reading. They light up with the row's own hover, and stay
    // while editing. `enabled` rides along so a faded button cannot be
    // pressed by a click that lands where the glyph used to be.
    enabled: rowMouse.containsMouse || row.editing
    opacity: enabled ? 1 : 0

    Behavior on opacity {
      NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
    }

    // Editing is behind a button rather than behind a click on the name, because
  // clicking the row is already spoken for: it ticks the task off, and a click
  // that meant one thing would silently start meaning another. The button is
  // one press away and says what it does on hover.
  PanelActionButton {
    id: editButton
    iconText: "󰏫"
      // Priority and tags are named here because they are the two a reader
      // would not think to look for: they have no field and no badge until a
      // value is set, so the pencil is the only thing on the row that says they
      // exist. Listing the other three and leaving these out is how a control
      // ends up "not there".
      tooltipText: "Edit name, description, deadline, reminder, priority and tags"
      foreground: row.contentForeground
      fontFamily: row.contentFontFamily
      onClicked: row.editRequested()
    }

    PanelActionButton {
      id: deleteButton
      // The circled X, not a bin: the shape says "remove" without a legend, and
      // it is the one mark on this row that cannot be taken back. Measured at
      // 0.75em it keeps the height of the pencil beside it, where a plain `✕`
      // would be 0.47em and read as a speck next to it.
      //
      // Not `󰅖`, which is the plain X: that one already means "discard" on the
      // save/cancel pair below, and two different buttons wearing the same mark
      // is how a destructive press becomes a misclick.
      iconText: "󰅗"
      tooltipText: "Remove task"
      foreground: row.contentForeground
      fontFamily: row.contentFontFamily
      onClicked: row.removed(row.task.id)
      // Gone while editing. The row is showing its own contents instead, and a
      // delete button beside them invites the one click that cannot be undone —
      // from the same row you were about to fix a typo in.
      visible: !row.editing
    }
  }

  // ---- The editor: the row's own name, note, deadline and reminder, editable
  //      in place.
  //
  // In place rather than in a dialog because the row is already showing the
  // thing being edited. A dialog would restate it behind a border and add a
  // place to get the focus wrong; here the text under the cursor is the text
  // being edited, and a wrong guess about what "save" applies to is answered
  // by looking at it.
  //
  // The deadline and the reminder live here rather than behind the badges, and
  // the badges still only clear. The two are different acts — setting 17:00 on
  // a task and taking its deadline away — and a badge that cleared its field on
  // one click had no way to do the first of them. One editor holds everything a
  // task carries, so there is one Save for it all and one Escape that undoes it.
  //
  // Declared last so it sits above rowMouse. That is the whole reason the row's
  // own click handler is disabled while editing: with the fields on top, a click
  // lands in a field, but a click on the row's padding beside them would still
  // reach rowMouse and tick the task off underneath the editor.
  Item {
    id: editBody
    anchors.fill: parent
    anchors.margins: Style.spacing.xs
    visible: row.editing
    enabled: row.editing

    // The checkbox is the one thing the row keeps while editing: it is how the
    // task was ticked and it stays reachable, because an edit is not the moment
    // to take away the control that has nothing to do with it. It does stop
    // being a shortcut though — a click on the row must not also toggle, or
    // correcting a name would finish the task.
    readonly property real fieldLeft: box.width + Style.spacing.md * 2

    // The deadline and the reminder as this editor has them, seeded from the
    // task on the way in. Held here rather than read back off the field every
    // time, because the reminder has no field to be read from — it is a set of
    // chips — and because a half-typed hour must not be what the summary line
    // beside it reports: that line reads the cleaned value or nothing.
    property string dueDraft: ""
    property var remindDraft: null
    // The priority is held as a draft for the same reason the reminder is: it
    // has no field to be read back from, only a row of chips, and asking the
    // task what it "currently" is would be asking a value the chips have not
    // written yet.
    //
    // The tags are the opposite — they live in a text field, and splitting that
    // field into a list is done at save rather than on every keystroke, so a
    // half-typed comma never becomes a half-tag in the store.
    property var priorityDraft: null
    property var tagsDraft: []
    readonly property bool dueFilled: String(editDue.text || "").replace(/[\s:.]/g, "") !== ""
    readonly property bool dueValid: !dueFilled || Tasks.cleanTime(editDue.text) !== ""
    readonly property string dueSummary: {
      if (dueFilled && !dueValid) return "Unreadable time"
      var clean = Tasks.cleanTime(editDue.text)
      if (clean === "") return "No deadline"
      return "Due at " + clean
    }
    readonly property string remindSummary: {
      if (remindDraft === null) return "No reminder"
      return "Reminds " + Tasks.remindDaysLabel(remindDraft)
    }

    // Every field back to what the store holds. Called on the way in and again
    // on cancel, so that a discarded edit leaves nothing behind and reopening
    // starts from what is actually saved rather than from the last thing typed
    // into an editor that was thrown away.
    function seedFromTask() {
      editName.text = String(row.task.text || "")
      editNote.text = String(row.task.note || "")
      editDue.text = String(row.task.dueTime || "")
      // Through the cleaner rather than straight off the task, so that a value
      // a hand-edited file put above the maximum lands on the chip it will be
      // saved as — otherwise the task would have a reminder no chip on screen
      // claims, and pressing Save would move it without saying so.
      editBody.remindDraft = Tasks.cleanRemindDays(row.task.remindDaysBefore)
      // The field shows what no chip names, so a reminder set to twelve days
      // is visible as twelve rather than as nothing selected. A chip day
      // leaves it empty: the chip already says it, and a number in the field
      // beside a lit chip is two answers to one question.
      editRemindCustom.text = editBody.remindDraft !== null && Tasks.REMIND_CHIP_DAYS.indexOf(editBody.remindDraft) === -1
        ? String(editBody.remindDraft)
        : ""
      editBody.priorityDraft = Tasks.cleanPriority(row.task.priority)
      editBody.tagsDraft = Tasks.cleanTags(row.task.tags)
    }

    // Guarded rather than reading its own text straight into the signal. An
    // emptied name is refused by the store, and telling the user so by refusing
    // to close the editor is better than closing it and appearing to have saved
    // a nameless task. An unreadable hour is refused the same way for the same
    // reason: the alternative is silently clearing a deadline the person thinks
    // they have just set, which is the one edit here that cannot be seen in the
    // row afterwards without looking closely.
    function save() {
      var text = String(editName.text || "")
      if (text.replace(/^\s+|\s+$/g, "") === "") {
        editName.text = row.task.text
        editName.forceActiveFocus()
        return
      }
      var due = String(editDue.text || "").replace(/^\s+|\s+$/g, "")
      if (due !== "" && Tasks.cleanTime(due) === "") {
        editDue.forceActiveFocus()
        editDue.selectAll()
        return
      }
      row.editSaved(row.task.id, text, String(editNote.text || ""), due,
        editBody.remindDraft, editBody.priorityDraft,
        Tasks.cleanTags(String(editTags.text || "").split(",")))
    }

    function cancel() {
      editBody.seedFromTask()
      row.editCancelled()
    }

    // The reminder chips toggle rather than select, because turning one off is
    // as ordinary as setting it: clicking the chip you already have is how you
    // say "no reminder" without hunting for a separate control that means it.
    function toggleRemindDraft(days) {
      editBody.remindDraft = editBody.remindDraft === days ? null : days
      // The chips and the field beside them are one control wearing two
      // faces: a number left in the field after a chip has taken over would
      // be a second answer to what the summary line has already said.
      editRemindCustom.text = ""
    }

    // The field's own way in, for the days no chip names. It only ever sets —
    // turning a reminder off is what the chip you already have is for — and
    // unreadable input is left alone, so a half-typed "1" never becomes
    // "no reminder" on the way to twelve.
    function setRemindDraft(raw) {
      var days = Tasks.cleanRemindDays(String(raw || "").replace(/^\s+|\s+$/g, ""))
      if (days === null) return
      editBody.remindDraft = days
      editRemindCustom.text = String(days)
    }

    TextField {
      id: editName
      anchors.left: parent.left
      anchors.leftMargin: editBody.fieldLeft
      anchors.right: parent.right
      anchors.top: parent.top
      placeholderText: "Task name"
      foreground: row.contentForeground
      accent: Color.accent
      font.family: row.contentFontFamily
      font.pixelSize: Style.font.body
      selectByMouse: true
      onAccepted: editBody.save()
      // Tab walks to the description and on to the buttons rather than leaving
      // the row, which is what a form does and what makes the editor usable
      // without a mouse.
      Keys.onTabPressed: {
        editNote.forceActiveFocus()
        editNote.selectAll()
      }
      Keys.onEscapePressed: editBody.cancel()
      Keys.onEnterPressed: editName.accepted()
    }

    TextField {
      id: editNote
      anchors.left: editName.left
      anchors.right: editName.right
      anchors.top: editName.bottom
      anchors.topMargin: Style.spacing.xs
      placeholderText: "Description (optional)"
      foreground: row.contentForeground
      accent: Color.accent
      font.family: row.contentFontFamily
      font.pixelSize: Style.font.bodySmall
      selectByMouse: true
      onAccepted: editBody.save()
      Keys.onTabPressed: {
        // On to the deadline and from there to the buttons, so the whole editor
        // is walkable without a mouse and Tab never jumps a field.
        editDue.forceActiveFocus()
        editDue.selectAll()
      }
      Keys.onEscapePressed: editBody.cancel()
    }

    // The deadline and what the reminder makes of it, side by side: the hour is
    // typed and the reminder is chosen, and saying them back in words is what
    // keeps a bare "3" from having to be guessed at — the chips below say when
    // the nagging starts, this says what it is for.
    Row {
      id: editMeta
      anchors.left: editName.left
      anchors.right: parent.right
      anchors.top: editNote.bottom
      anchors.topMargin: Style.spacing.sm
      spacing: Style.spacing.sm

      TextField {
        id: editDue
        width: Style.space(68)
        placeholderText: "17:00"
        verticalPadding: Style.spacing.xs
        foreground: row.contentForeground
        accent: Color.accent
        font.family: row.contentFontFamily
        font.pixelSize: Style.font.bodySmall
        selectByMouse: true
        onAccepted: editBody.save()
        Keys.onTabPressed: {
          saveButton.forceActiveFocus()
        }
        Keys.onEscapePressed: editBody.cancel()
      }

      Text {
        id: editDueSummary
        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(0, parent.width - editDue.width - parent.spacing)
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignRight
        textFormat: Text.PlainText
        // The unreadable hour earns the red — the same red as everything else
        // still owed — because an hour that would quietly disappear on save is
        // a mistake, not a preference. The two empty states stay quiet rather
        // than shouting "unset" at a task that has always had neither.
        color: editBody.dueFilled && !editBody.dueValid
          ? row.pendingColor
          : editBody.remindDraft !== null || editBody.dueFilled
            ? Qt.alpha(row.contentForeground, 0.62)
            : Qt.darker(row.contentForeground, 2)
        text: editBody.dueFilled && !editBody.dueValid
          ? editBody.dueSummary
          : editBody.remindDraft !== null
            ? editBody.remindSummary
            : editBody.dueSummary
        font.family: row.contentFontFamily
        font.pixelSize: Style.font.caption
      }
    }

    // The reminder, as the composer words it: chips rather than a dropdown,
    // because there are eight of them and a field for the rest, and they all
    // fit once the run is allowed to wrap. A chip you can see is a chip you
    // can change your mind about without opening anything.
    Flow {
      id: editChips
      anchors.left: editName.left
      anchors.top: editMeta.bottom
      anchors.topMargin: Style.spacing.sm
      spacing: Style.spacing.xs
      // Four to a row, then the field under them. The width is the grid's
      // own — four chips plus the gaps between them — so the second row of
      // four and the field below it all start on the same left edge.
      width: (editChipProbe.implicitWidth + Style.spacing.md * 2) * 4
        + Style.spacing.xs * 3

      // Measured, not guessed: the chips all take this width so they read as a
      // segmented control rather than as a ragged line of pills, and it has to
      // be the widest string any of them can show or the row is sized for a
      // word that is no longer there. `visible: false` and not a zero size on
      // purpose — implicitWidth comes from text metrics, so hiding it keeps the
      // measurement while keeping the probe out of the layout.
      Text {
        id: editChipProbe
        visible: false
        text: "Today"
        font.family: row.contentFontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }

      Repeater {
        model: Tasks.REMIND_CHIP_DAYS

        delegate: Rectangle {
          required property int modelData

          readonly property bool on_: editBody.remindDraft === modelData

          // As wide as the label needs and no wider — the same size the
          // composer draws — so the two faces of this control match, and the
          // Flow above is exactly four of them plus the gaps.
          width: editChipProbe.implicitWidth + Style.spacing.md * 2
          height: editChipText.implicitHeight + Style.spacing.sm * 2
          radius: Style.cornerRadius
          // Inverted rather than coloured, and the reason is the same one the
          // composer gives: the selected chip must not wear the pending red,
          // which is the one colour on this panel that means "still owed".
          color: on_
            ? row.contentForeground
            : editChipMouse.containsMouse
              ? Style.hoverFillFor(row.contentForeground, Color.accent)
              : Qt.alpha(row.contentForeground, 0.07)
          border.width: on_ ? 0 : Style.normalBorderWidth
          border.color: Qt.alpha(row.contentForeground, 0.18)

          Text {
            id: editChipText
            anchors.centerIn: parent
            text: modelData === 0 ? "Today" : String(modelData)
            color: on_
              ? Color.popups.background
              : Qt.alpha(row.contentForeground, 0.78)
            font.family: row.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: on_
          }

          MouseArea {
            id: editChipMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: editBody.toggleRemindDraft(modelData)
          }

          PanelToolTip {
            visible: editChipMouse.containsMouse
            text: "Reminds every hour " + Tasks.remindDaysLabel(modelData)
            fontFamily: row.contentFontFamily
          }
        }
      }

      // Any number the chips do not name — three weeks out, a month, the 45
      // days a form asks for. Same one-control-two-faces rule as the
      // composer: it only ever sets, and the chip you already have is how a
      // reminder is turned off.
      TextField {
        id: editRemindCustom
        width: Style.space(92)
        placeholderText: "Any days"
        verticalPadding: Style.spacing.xs
        foreground: row.contentForeground
        accent: Color.accent
        font.family: row.contentFontFamily
        font.pixelSize: Style.font.bodySmall
        selectByMouse: true
        validator: IntValidator {
          bottom: 0
          top: Tasks.MAX_REMIND_DAYS
        }
        onAccepted: editBody.setRemindDraft(text)
      }
    }

    // The priority, beside a word that says what the row is rather than a bare
    // line of glyphs: ▲ on its own has no reading, and the four chips are a
    // choice rather than a status bar. Chips instead of a dropdown for the same
    // reason the reminder uses them — four options all fit, and seeing them is
    // what makes changing your mind one click.
    //
    // "None" is a chip and not the absence of one. A priority you can only add
    // and never take back is a priority that survives every attempt to undo it,
    // and an empty slot at the head of the row reads as nothing rather than as
    // the option to have nothing.
    Row {
      id: priorityRow
      anchors.left: editName.left
      anchors.top: editChips.bottom
      anchors.topMargin: Style.spacing.sm
      spacing: Style.spacing.xs

      Text {
        anchors.verticalCenter: priorityProbe.verticalCenter
        text: "Priority"
        color: Qt.darker(row.contentForeground, 1.6)
        font.family: row.contentFontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1
        font.bold: true
      }

      // Measured the way the reminder's chips are: from the widest string any
      // of them shows, so the four read as one control rather than as a ragged
      // line, and hidden rather than zero-sized so the measurement survives.
      Text {
        id: priorityProbe
        visible: false
        text: "● Medium"
        font.family: row.contentFontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }

      Repeater {
        model: [
          { value: null, label: "None" },
          { value: "high", label: "▲ High" },
          { value: "medium", label: "● Medium" },
          { value: "low", label: "○ Low" }
        ]

        delegate: Rectangle {
          required property var modelData

          readonly property bool on_: editBody.priorityDraft === modelData.value

          width: priorityProbe.implicitWidth + Style.spacing.md * 1.5
          height: priorityText.implicitHeight + Style.spacing.sm * 2
          radius: Style.cornerRadius
          // Same inversion as every other selected chip on this panel, and for
          // the same reason: the selected one must not wear the pending red,
          // which means work still owed and would say something false about a
          // choice the reader just made.
          color: on_
            ? row.contentForeground
            : priorityChipMouse.containsMouse
              ? Style.hoverFillFor(row.contentForeground, Color.accent)
              : Qt.alpha(row.contentForeground, 0.07)
          border.width: on_ ? 0 : Style.normalBorderWidth
          border.color: Qt.alpha(row.contentForeground, 0.18)

          Text {
            id: priorityText
            anchors.centerIn: parent
            text: modelData.label
            color: on_
              ? Color.popups.background
              : Qt.alpha(row.contentForeground, 0.78)
            font.family: row.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: on_
          }

          MouseArea {
            id: priorityChipMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: editBody.priorityDraft = modelData.value
          }

          PanelToolTip {
            visible: priorityChipMouse.containsMouse
            text: modelData.value === null
              ? "No priority — the task sorts with everything else"
              : Tasks.priorityLabel(modelData.value) + " priority"
            fontFamily: row.contentFontFamily
          }
        }
      }
    }

    // The tags, typed rather than picked. They are open-ended by design — the
    // set of things a person wants to file under is theirs and not this
    // panel's — so a field is the only control that does not decide the answer
    // in advance. Split and cleaned on save, so the commas you are in the
    // middle of typing are not yet a tag.
    TextField {
      id: editTags
      anchors.left: editName.left
      anchors.right: editName.right
      anchors.top: priorityRow.bottom
      anchors.topMargin: Style.spacing.sm
      placeholderText: "Tags, comma separated — work, home"
      foreground: row.contentForeground
      accent: Color.accent
      font.family: row.contentFontFamily
      font.pixelSize: Style.font.bodySmall
      selectByMouse: true
      onAccepted: editBody.save()
      Keys.onTabPressed: {
        saveButton.forceActiveFocus()
      }
      Keys.onEscapePressed: editBody.cancel()
      Keys.onEnterPressed: editTags.accepted()
    }

    // Confirm and cancel, in that order, on the leading side of the buttons so
    // the confirm is the one nearest the fields being confirmed. Both are
    // labelled in words rather than only by glyph: an icon that means "keep" to
    // one person means "discard" to another, and this row holds unsaved text.
    Row {
      id: editButtons
      anchors.left: editName.left
      anchors.top: editTags.bottom
      anchors.topMargin: Style.spacing.sm
      spacing: Style.spacing.xs

      PanelActionButton {
        id: saveButton
        iconText: "󰄬"
        tooltipText: "Save changes"
        foreground: row.contentForeground
        fontFamily: row.contentFontFamily
        focusable: true
        onClicked: editBody.save()
      }

      PanelActionButton {
        iconText: "󰅖"
        tooltipText: "Discard changes"
        foreground: row.contentForeground
        fontFamily: row.contentFontFamily
        focusable: true
        onClicked: editBody.cancel()
      }
    }
  }
}
