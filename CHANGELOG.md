# Changelog

All notable changes to this plugin are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this plugin adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

Six things the list could not say about itself, and one it could not do.

- **A countdown where the deadline is.** A pending task's badge shows how long
  is left — `2d 3h`, `45m`, `1h 5m` — instead of only the hour it is due. The
  hour is kept for the state where it is the useful half: once the time has
  passed the badge reverts to `17:00`, because a countdown of zero is the one
  countdown that has stopped. It is computed from the same clock the overdue
  colour uses, so the two can never disagree about whether the hour has come.
- **Search.** A field at the foot of the list, narrowing it by name, description
  or tag as you type. No mode, no confirm: looking for one task is not a
  different place to be, and a search box behind a button is a search nobody
  uses. It reads the whole list the header counts, so a list emptied by a
  search says "No task matches" and names the needle rather than claiming the
  store is empty — two different absences, and only one of them is a problem.
  It sits under the list rather than over it: the tasks are what the panel is
  for, and a field above them spent the first row on a box you only reach for
  once you already know what you are looking for.
- **Priority.** High, medium, low, or none. The mark is `▲`, `●`, `○` beside the
  name: plain characters rather than an icon font's glyphs, so a priority reads
  the same on a machine that never installed that font. Pressing it walks to the
  next state, so the read-out and the control are one object and the tooltip
  names the state you land in rather than the one you are leaving. It used to be
  set only from the row's editor, which meant a priority did not exist on screen
  until it had been set — a mark that appears after the fact is a control nobody
  can find. Every row now reserves the column and shows a faint `○` when nothing
  is set. The editor keeps the four as chips for anyone who wants to see the
  choice rather than walk it, and the composer carries a flag button that opens
  the same choice as four flags — red, amber, blue, grey. Colour is allowed in
  the menu and nowhere else: a menu is read one option at a time while a list
  is read as a whole, and on the list red is already the colour of work still
  owed, so a high-priority task painted red would read as an overdue one and
  green is finished. What a priority is called, which one is next, how it is
  drawn and what colour it is all live in `Tasks.js`, so the row, the editor's
  chips, the composer's flags and the tooltip cannot drift apart on the
  spelling.
- **Tags, and a filter that follows them.** Typed as a comma separated line in
  the editor rather than picked from a menu: the set of things worth filing
  under a subject belongs to the reader, and a fixed list would decide it for
  them. They show as chips on the row — capped at three, with the overflow
  counted rather than hidden — and clicking one narrows the list, clicking it
  again puts the list back. The composer takes a new one through a button that
  opens a field over the card, which is also where the tags already on the task
  are shown and removed, so setting a tag and filtering by one are two different
  objects now rather than one row doing both jobs. Matching is whole-tag and
  case-insensitive,
  deliberately not substring: `#work` asks for that tag and does not hand back
  `workspace`, because a search may guess and a chip the reader pressed may
  not. Two spellings of one tag are one tag throughout — `Work` and `work`
  would otherwise be two chips doing exactly the same job, which is also why
  `cleanTags` now folds case when it de-duplicates while keeping the first
  spelling, so a tag stays as it was written instead of being re-cased by a
  later edit.
- **Statistics.** A collapsed `STATS` block under the list: the streak, today's
  total, the last seven days, and how the pending work falls across the three
  priorities. Closed by default, because these are the numbers you go looking
  for and not the ones you need while writing a task down. The first three
  count from today and not from the day on screen — a streak that changed when
  you clicked next Thursday would be a streak about nothing — while the last
  is about what is on the list now, so it moves with the filters.
- **A week view, as the view.** The panel opens on the week rather than the
  month: seven cells big enough to read and to hit, which is the question
  people open this for, where a month answers one they ask less often.
  `Month` is one click away in the header and nothing about it moved. The
  week is built from the very cells the month grid draws — one shared
  `buildDayCells`, one cell shape — so the two cannot drift apart in what a
  day is, and the grid's delegate does not know which of the two it is
  drawing. The chevrons and `[` `]` step whatever is on screen, a week in one
  and a month in the other, with one entry point so the key never has to know
  the answer; the header follows, saying `5–11 OCT` over a week and
  `OCTOBER 2026` over a month. Coming back to the month lands on the month
  the week belongs to, and `t` resets both.
- **An optional sound with the toast.** No setting to switch on, no package to
  install, and a machine with none of it gets silence rather than an error
  from a timer that runs while nobody is watching. When there is something to
  play with, `paplay`, `pw-play`, `aplay` then `canberra-gtk-play`, in that
  order, over a sample found under `$XDG_DATA_DIRS` — and the alert is fired
  only after a notification that actually posted, never on its own, since a
  toast that failed to post has not interrupted anybody. It is left to finish
  in the background so a slow or hung player cannot delay or drop the
  notification it was meant to accompany.

### Changed

- **The composer was re-laid-out into five rows.** Name, description, a row of
  two buttons for priority and tags, the deadline and the reminder side by side,
  then the list with the search at its foot. Everything that was previously
  reachable only after the task existed — priority and tags — is now set while
  you are writing it, which is when you know it. The deadline and the reminder
  stopped being stacked and now share one row under one hairline, turned from
  lying down to standing up, because they are one question in two parts: *when
  is it due, and when will I hear about it*. Inside each half the summary moved
  onto its own line beneath the label — at half a card's width *Due Fri 11 Sep
  at 17:00* would have elided the hour away, and the hour is the half worth
  reading — and the six reminder chips became a `Flow`, since half a card is
  two rows of three rather than one run of six.
- **The task block now reads as three zones.** Name, description and the two
  buttons sit together as the act of writing a task; the deadline-and-reminder
  card gets sixteen pixels of air of its own; and the list begins under a rule,
  so each zone is separated from the next by more than any two lines inside one
  of them. A `Column` carries one spacing for all of its children, so the extra
  gaps are bought with a zero-height child rather than by loosening the rhythm
  inside a zone — the fields stay at eight, the list stays at eight, and only
  the joins open up. The rule takes the rail's own treatment and spans the
  block's width with no anchor, because a `Column` assigns `x` to its children
  and an anchor would fight it for the same property.
- **The statistics block moved to the foot of the list**, where its own comment
  always said it lived. It was a sibling of the task block inside a plain
  `Item`, which lays nothing out, so it sat at `y = 0` while the block below it
  starts at fourteen: its header was drawn on the section rule, and opening it
  grew the figures down over the *Add task* field. As a child of the task
  block's own `Column` it is positioned by the layout, counted by
  `implicitHeight` — so an expanded block is inside the panel's content height
  and can be scrolled to — and it takes the list's width, centred, instead of
  the wider and uncentered one it had.
- **The interface is English throughout**, task block included. It had been half
  translated: the calendar grid, the composer shell and the row editor spoke
  English while every string a task actually touched — placeholders, deadline
  and reminder summaries, group headings, list headers, empty states, badge
  tooltips, toast notifications — was still Spanish. Two languages in one card
  is one more thing to translate by eye.
- `Qt.locale("es")` is gone, and `dayPhrase` reads its day and month names from
  the same `labelLocale` the grid's weekday headings already used. Leaving it
  would have been the one failure no reviewer would catch by reading the diff:
  every literal would read English while the date inside it went on saying
  "Fri 12 Sep" as "vie 12 sept", inside an English sentence.
- The three `Qt.formatDate` calls in the panel and the `Qt.formatDateTime` in
  the bar were pinned to `labelLocale` too. These take no locale argument, so
  they follow the system — on this machine `es_MX`, where a `dddd d MMM` preset
  would have written "lunes 12 oct" in the one label that is always on screen.
  `QLocale.toString` produces byte-identical output to the Qt call for all ten
  clock presets, verified against each.
- `dayPhrase` lost its `article` argument, which existed to prefix "el" on the
  dated form. English does not carry a definite article there, so the rule and
  the comment explaining it both went with it.
- "PENDING" and "DONE" are invariant in English where "PENDIENTE"/"HECHA" were
  not, so the count in the list header dropped its singular/plural branch — one
  task reads "1 PENDING" and so do three. Only "DAY"/"DAYS" still inflects.
- The reminder chip row's hidden width probe moved from "Hoy" to "Today" in
  lockstep with the chip label it stands in for. Translated one without the
  other it would have kept sizing the row for a word no longer on screen.
- **Reminders now arrive on the hour instead of twice an hour.** The timer went
  from `OnCalendar=*:00,30:00` to `*:00:00`, so a reminder is one toast at the
  top of the hour rather than one at the half and one at the hour. A task due at
  14:20 is now announced at 15:00 and nothing between — which is the point of
  asking for it, and why the row badge and chip tooltip changed from "Reminds
  every 30 min" to "Reminds every hour" rather than being left describing a
  schedule that no longer exists.
- `AccuracySec=1min` stayed as it was. It bounds how far past the top of the
  hour systemd may drift, which is worth keeping at any frequency.

A task can now say more than what it is, and can be corrected without being
deleted and written again. The description sits under the name in the composer
and under the name in the row, which is where the detail nobody can infer — the
room, the person, the file — was missing until now. Every row also has an edit
button that opens its own name, description, deadline and reminder in place.

The composer. Both optional extras now live in one card with a label each, and
each says its choice back in words instead of only encoding it in a control.

And the list opens on everything outstanding rather than on one day. A list that
spans several days can answer a question a single day's cannot — what is about
to be due — and that is the question a task list exists for.

### Fixed

- **A reminder no longer dies with the day it was scheduled for.** The script
  matched the reminder day exactly, so a task set to nag five days out was
  announced on that one date and on no other — and if the machine was switched
  off that day, never at all. `Persistent=yes` does not cover this: it replays
  the missed *timer run*, and the run that comes back reads the later date,
  which the exact match then rejected. The test is now a window from
  `remindDaysBefore` days ahead to the task's own day, so a machine back after
  a week still gets the reminder, and a task whose day has passed is left alone
  rather than re-armed.
- **A reminder now fires on the task's own due day at all.** The same exact
  match meant a task with a reminder set was silent on the day it was due —
  the one day it matters most — unless the reminder happened to be the day
  itself. The window above closes on that day instead of skipping over it.
- **No nagging before the deadline hour.** The timer fires hourly, so on the
  task's own day a 17:00 deadline used to start announcing itself at 00:00 and
  keep going every hour until someone ticked it off — seventeen toasts of
  "due at 17:00" before a single one of them could be acted on. The day-of
  nagging now waits for the hour to arrive. Days earlier in the window are
  untouched, because being told in advance is the point of asking for a
  two-day reminder.

### Added

- **Undo for a delete.** Deleting a row reports itself with a toast at the
  bottom of the panel — *Task deleted · Undo* — which holds for six seconds and
  expires on its own. `Tasks.restore` puts the task back at the index
  `Tasks.remove` took it from, so a delete and its undo together change
  nothing; appending instead would have moved the task out from under wherever
  the reader last saw it. The toast carries the task and its position rather
  than its id, because immediately after the delete there is nothing left in
  the store to look either of them up from. Only the newest delete is offered,
  and a delete that matched nothing offers nothing, so the button never
  promises a return it cannot make.
- **The deadline and the reminder are editable from the row.** The editor now
  carries a time field and the six reminder chips alongside the name and
  description, written back with the text in one Save. They had been clearable
  from their badges and nothing else — setting 17:00 on an existing task and
  taking its deadline away are different acts, and only one of them had a
  control. A time that will not parse is refused with the field left focused
  and its text selected, the same way an emptied name already was, rather than
  being saved as "no deadline".
- **The first test suite.** `tests/tasks.test.js` runs `Tasks.js` under plain
  node with no framework and no dependencies — 50 cases over the store's
  round trip, its cleaners, every mutation, the grouping and the reminder
  arithmetic. `tests/reminders.test.sh` covers `ClockReminders.sh` with a fake
  `date` and a fake notifier on `PATH`, so each of its 17 cases runs at the day
  and the hour it is actually about rather than at whichever one today happens
  to be. Both existed as bugs first: the window and the due-hour gate above
  fail 6 and 1 cases respectively of the shell suite as it was before the fix.
  `cleanText` and `migrateRemindDays` were exported so they could be tested at
  all; nothing in the panel had ever needed them.

- A wider view of the task list, and it is now the default: every outstanding
  task in the store, grouped under the day it belongs to and ordered by how soon
  it falls due, so the nearest deadlines are at the top. `Tasks.pendingGroups`
  owns the walk, the tagging and the ordering; `Tasks.pendingGroupSummary`
  counts it, so the header and the list cannot disagree.
- A heading per group — "TODAY", "TOMORROW", "FRI 12 SEP" — carrying that group's
  pending count. Clicking it narrows the list to that day. The heading is a
  button because a date you can read but not press is a caption.
- `ALL PENDING` as the list header in the wider view, with the total
  alongside it: "8 PENDING · 4 DAYS". When a day is showing instead, the
  header names the day and is itself the way back out of it.

- A deadline summary under the field, phrased against the day the calendar is
  showing: "Due Fri 12 Sep at 17:00", or "Due today at 17:00",
  or "Due tomorrow at 09:00". "No deadline" when there is none, and "Unreadable
  time" — in the pending red — for one that will not parse.
- **An edit button on every row.** It opens that row's name and description as
  editable fields in place, with `󰄬` to save and `󰅖` to discard, `Enter` to
  save and `Esc` to discard. The row grows to hold the editor, and only one row
  is ever open: two editors would be two sets of fields sharing one keyboard
  with nothing on screen saying which one `Esc` belongs to.
- While a row is being edited its deadline and reminder badges are hidden and its
  delete button is gone. A badge is the control that clears its own field, and a
  delete button beside unsaved text is the one click that cannot be undone.
- An emptied name is refused and the editor stays open with the name put back,
  rather than closing on a nameless task. The same rule `add` follows.
- **A description per task.** Optional, typed in the field under the name and
  drawn under the name in the row, a size down and dimmer. A name says what the
  task is; a note says what is still open about it — where the key is, who to
  ask, what to bring. It was previously not expressible at all, so those details
  either went unrecorded or were typed into the name, where they push out the one
  line that gets read every time.
- The description is drawn under the name in the row, a size down and dimmer,
  and the row grows to hold it. The checkbox, the deadline and the reminder now
  line up with the name rather than with the whole row, so they stay beside the
  task instead of floating beside its note.
- A reminder summary that resolves the chosen offset into an actual day:
  "Starts Fri 11 Sep" for one day before, rather than a chip reading "1".
- `−` / `+` steppers beside the deadline field, an hour at a time, wrapping
  around midnight in both directions. Pressed on an empty field they start from
  the next half hour for a task due today, and from 09:00 for any other day,
  so a task due this evening never starts out already overdue. `Tasks.shiftTime`
  and `Tasks.clockOffset` own that arithmetic, so there is one answer to "what is
  an hour" instead of two.

### Changed

- **Picking a day in the grid narrows the list to it; picking the day already
  showing widens it back out.** The wider view is not a mode you can only leave
  by reloading, because the grid is the one control that is always on screen and
  always aimed at a day. `t` and the TODAY button only move the cursor now
  rather than also choosing a view, so the same key does not quietly close the
  list down one way and open it the other depending on what it found.
- The completed section belongs to a single day and is not drawn in the wider
  view. A per-day list of receipts under other days' tasks describes a day
  nobody is looking at; click a day to read a day.
- The list header speaks the same language as everything else in the task block
  instead of borrowing from the calendar grid, and is phrased by the same
  `dayPhrase` the composer's own sentences use, so a day reads identically
  wherever it appears.
- Ticking or deleting a row in the wider view acts on that row's own day rather
  than on the selected one, so a task can be finished from the list without
  moving the cursor first.
- In the wider view a deadline that has not yet passed wears the pending red.
  The list is sorted by how soon things are due, and the near ones are what is
  being looked for; in a single day's list only a deadline that has actually
  gone by is red, where red would otherwise mean nothing at all.
- A selected reminder chip is drawn inverted — foreground fill, panel-coloured
  text — rather than in the pending red. The red is the one colour on this
  panel that means "still owed", and a selection is not that; on a theme whose
  accent is plain grey, as Omarchy's own grayscale themes are, an accent tint
  would not have been a selection you could see either.
- The chips are one uniform width, measured from the widest label, so the row
  reads as a segmented control instead of a ragged line of pills. The first is
  labelled "Today" rather than numbered, because it is the one that is not a
  number of days before anything.
- The deadline field has a fixed width rather than a floor on its
  `implicitWidth`. Same geometry, minus the clamp that had to be written against
  `width` instead of `implicitWidth` to avoid a binding loop.

### Fixed

- The group delegates own a `Column` of rows, so switching out of the wider view
  tore down that whole tree at once and each row's `parent.width` binding was
  re-evaluated with its parent already gone. One "Cannot read property 'width' of
  null" per destroyed row, flooding the log on every toggle. The three width
  bindings read through a null check.
- While the deadline field had focus, the panel's key dispatcher was still
  live, so a `t` jumped the calendar to today and a `w` moved the week start
  while the same keystroke went into the field. Both fields now stand the
  dispatcher down. It only became reachable because the steppers hand the
  focus to the deadline field — the point of a stepper is that the next digit
  has somewhere to land.

## [2.0.0]

First tagged release of this fork. The two breaking changes are listed first
because they need an action from anyone upgrading.

### Breaking

- **The plugin id changed**, from `angelherman.clock` to
  `angelherman.cronos-calendar`. The id is what `shell.json` records for the
  bar slot, so after upgrading, the old entry no longer resolves and the
  widget disappears from the bar. Re-add it:
  `omarchy bar put angelherman.cronos-calendar center`. The display name is
  unchanged and still shows as *Cronos-Calendar*.
- **`remindDaysBefore: 0` now means "the day of the due date itself".**
  Previously `0` meant "no reminder", and the way to turn a reminder off was
  `null`. Storing `0` in a version 1 file was preserved as `null` by the
  loader, so existing tasks keep their meaning and no alarm appears that the
  user had switched off. Any tool that wrote a literal `0` into a store by
  hand is still migrated the same way.

### Added

- Reminders that survive a reboot, implemented with a persistent
  `systemd --user` timer rather than one transient timer per task.
- Day tasks, attached to a calendar day rather than to a single date.
- A due-time field on each task, which also drives the overdue state.
- A reminder option for the day of the due date itself, alongside 1 to 5
  days before.
- A red / green colour scheme: red for everything still owed, including
  overdue tasks and an unreadable due time, and green for finished tasks.
- English interface text.
- Task text is stripped of control characters, so a task can no longer carry
  a newline or a tab into the store or into a notification.

### Fixed

- The due-time field could not be focused or clicked. A `MouseArea` was
  declared after the `TextField` inside the row and sat on top of it, so
  every click landed on the mouse area instead of the field. The redundant
  wrapper that held it has been removed.
- The finished block measured its own height by hand and forgot the divider
  and the gap above its heading, so it reserved less height than it drew.
  The column clipped the last finished task through the middle of its name
  and the scrollable area was short by the same amount, leaving nothing to
  scroll to. It is now measured from the bottom of its last child.
- The reminder script rejected `0` because of a `> 0` comparison, which is
  why the same-day reminder could never fire.
- The reminder script read the store with `jq` and never saw the version
  migration that `Tasks.js` applies on load, so on a store left at version 1 a
  `remindDaysBefore` of `0` — which in 1.x meant "no reminder" — was read as
  "the due day itself" and fired a notification for something that had been
  switched off. The script now reads the store's version and applies the same
  rule as the panel. This mattered even when the panel was never opened, since
  systemd runs the script whether or not the shell is running.
- A store written by an older version was only rewritten the next time a task
  was edited, which left the file and the panel disagreeing in the meantime.
  It is now rewritten as soon as it is read. A file that is empty, truncated
  or otherwise unreadable is left untouched rather than being replaced, so the
  rewrite can never destroy data.

### Notes

- `moduleName` and the IPC target remain `omarchy.clock` on purpose. The
  `pretty.omagen` bar plugin identifies a clock by that name in several
  places, and `shell.json`'s `centerAnchor` points at it, so renaming it
  would cost the clock its styling and its centred position.

## [1.1.0]

Untagged development state. Not published.
