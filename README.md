# Cronos-Calendar

A bar clock with a calendar popup, per-day tasks, and reminders that survive
a reboot. Fork of Omarchy's built-in `omarchy.clock` widget.

## Install

```bash
omarchy plugin add https://github.com/angelherman0130-cell/omarchy-cronos-calendar --enable
```

Or copy the directory into `~/.config/omarchy/plugins/angelherman.cronos-calendar`
and add it to a bar section:

```bash
omarchy bar put angelherman.cronos-calendar center
```

## Uninstall

```bash
omarchy plugin remove angelherman.cronos-calendar --yes
```

That unloads the widget and, since it was cloned from `omarchy.clock`, puts
the stock clock back where it was. It does not touch the reminder timer, which
lives outside the plugin directory:

```bash
systemctl --user disable --now omarchy-clock-reminders.timer
rm -f ~/.config/systemd/user/omarchy-clock-reminders.service \
      ~/.config/systemd/user/omarchy-clock-reminders.timer
systemctl --user daemon-reload
```

Your tasks stay in `~/.local/state/omarchy/clock-tasks.json`. Delete that file
as well when you want the data itself gone:

```bash
rm -f ~/.local/state/omarchy/clock-tasks.json
```

## What it does

- **Clock and calendar.** Click the bar label for a month grid with ISO week
  numbers and month stepping. Arrow keys move by month and year.
- **Tasks per day.** Tasks belong to a day, not to a date. Add one with the
  field at the top of the panel, tick it off with the checkbox, click a
  badge to clear its deadline or reminder.
- **Everything outstanding, soonest first.** The list opens on every pending task
  in the store rather than on one day, grouped under the day it belongs to and
  ordered by how soon it falls due. Tasks with no deadline go last, since a day
  key says when a task is due and a task without an hour has not said that yet.
  Click a group heading to narrow the list to that day, and click the day in the
  grid to widen it back out — or click the day already showing. Deadlines that
  have not passed yet wear the pending red here, because in a list spanning
  several days "still owed" is what the red has to mean.
- **The finished block belongs to a single day.** It is not drawn in the wider
  view: a list of receipts under other days' tasks describes a day nobody is
  looking at.
- **A description per task.** Optional, typed in the field under the name and
  drawn under the name in the row, a size down and dimmer. A name says what the
  task is; this says what is still open about it — the room, the person, what to
  bring — and it grows the row rather than pushing the name out of the list. Up
  to two lines are shown, with an ellipsis if there is more; the rest is kept in
  the file.
- **Edit and delete from the row.** Every row has an edit button and a delete
  button at its right edge. Editing opens that row's name, description, deadline
  and reminder as fields in place — `Enter` or `󰄬` saves, `Esc` or `󰅖`
  discards, and `Tab` walks from the name to the description to the deadline to
  the buttons. Only one row is open at a time. A row being edited hides its
  deadline and reminder badges and its delete button, so neither can be changed
  by accident next to unsaved text; the badges keep their one-click clear for
  when you are not editing, which is a different act from setting one.
  A deadline that will not parse is refused rather than saved as nothing —
  clearing a time you think you have just set is the one mistake here you would
  not notice.
- **Deleting is undoable.** The delete reports itself with a toast at the bottom
  of the panel — *Task deleted · Undo* — which holds for six seconds and then
  expires. Undo puts the task back exactly where it was, at the index it came
  from, so a delete and its undo together change nothing. Only the newest delete
  is offered: a second one replaces the first rather than queueing a second
  promise nothing would honour.
- **The composer, in five rows.** The name, the description, a row of two
  buttons for priority and tags, the deadline and the reminder side by side,
  then the list with the search at its foot. Each row is only what you need at
  that point, and the two halves of the card share one row because they are one
  question in two parts — *when is it due, and when will I hear about it* —
  which is more use answered in a single look than in two.
- **A deadline per task.** A due time, typed as `17:00` or nudged an hour at a
  time with the `−` and `+` beside the field. The panel says which day it lands
  on — *Due Fri 12 Sep at 17:00* — because `17:00` on its own does not
  say whose day it is. Once it has passed the row is marked overdue.
- **Reminders.** Per task: the day of the due date itself, or 1 to 5 days
  before, or off. They keep firing across reboots. The chip you pick is
  resolved back into the day it starts nagging — *Starts Fri 11 Sep* —
  which is the half a bare `1` never said. They arrive **on the hour**, so a
  task due at 14:20 is announced at 15:00 and not before.
  A reminder is a **window** rather than one date: it opens `remindDaysBefore`
  days ahead and closes on the task's own day, so a machine that was switched
  off on the day it should have fired still delivers it when it comes back —
  which `Persistent=true` alone could not do, because that replays the missed
  timer run, not the day it belonged to. Nothing is re-armed after the task's
  own day has passed.
  On the task's own day the timer fires every hour, so the nagging **waits for
  the deadline hour**: a task due at 17:00 stays silent until 17:00 instead of
  starting at midnight. Days earlier in the window keep the whole day, since
  being told in advance is the entire point of asking for a two-day reminder.
- **How long is left.** A pending task with a deadline shows a countdown on its
  badge — `2d 3h`, `45m` — instead of a bare hour, so "soon" is a number and not
  a judgement. Once the hour is past the badge goes back to the time itself:
  a countdown of zero is the one state that has stopped counting down.
- **Search.** A field at the foot of the list narrows it by name, description
  or tag as you type, with nothing to press and nothing to confirm. Press `s` to
  reach it, `Esc` to leave it. A list the search emptied says so by name rather
  than claiming there is nothing pending.
- **Priority.** High, medium, low, or none. The mark sits beside the name —
  `▲`, `●`, `○`, and a faint `○` when nothing is set — and pressing it walks to
  the next one, so what draws the priority is also what sets it. Every row
  keeps the column whether it has a value or not: a mark that only appears
  once it exists is a control nobody can find. The editor carries the same
  four as chips. The composer carries a flag that opens the choice as four
  flags — red, amber, blue, grey — and colour is allowed there because a menu
  is read one option at a time while a list is read as a whole; the mark on
  the row stays colourless for exactly that reason, since red beside a name
  already means work still owed. The three shapes are plain characters rather
  than an icon font's glyphs so that a priority reads the same on a machine
  without that font.
- **Tags.** Open-ended, comma separated, and typed rather than picked — the
  things worth filing under a subject are yours, and a fixed list would decide
  them for you. The composer takes one through a button that opens a field and
  the tags already on the task; the row shows them as chips, capped at three
  with the overflow counted rather than hidden. Clicking a chip narrows the
  list to it and clicking it again puts the list back, and the two ways of
  narrowing now sandwich the list — tag chips above it, the field that narrows
  by name below it — so both are filters, and neither is where a tag is written.
  Matching is whole-tag, never a substring: clicking `#work` asks for that tag
  and does not hand back `workspace`.
- **Statistics.** A collapsed `STATS` block under the list holds the day's
  streak, today's total, the last seven days, and how the pending work falls
  across the three priorities. It is closed by default — these are the numbers
  you go looking for, not the ones you need while writing a task down — and
  opening it stays open.
- **Week view.** The panel opens on the week rather than the month: seven cells
  big enough to read and to hit, which is the question people open this for.
  `Month` is one click away in the header and stays where it always was. The
  chevrons and `[` `]` step whatever is on screen — a week in one view, a month
  in the other — and the header follows, showing `5–11 OCT` over a week and
  `OCTOBER 2026` over a month. Switching back to the month lands on the month
  the week belongs to.
- **A sound with the toast.** Optional in the only way that matters here: no
  setting to switch on, no package to install, and a machine with none of it
  gets silence rather than an error from a timer that runs while nobody is
  watching. When there is something to play with, the alert goes out *after* a
  notification that actually posted — never on its own. See Requirements for
  what it looks for.
- **Colour.** Red means still owed, including overdue work, an unreadable due
  time, and — in the wider view — any deadline at all. Green means finished.
  Nothing else uses those two colours, so a glance at a day tells you what is
  outstanding.

### Keyboard

| Key       | Action                              |
|-----------|-------------------------------------|
| `[` `]`   | Previous / next week or month, whichever view is on |
| `{` `}`   | Previous / next year (52 weeks in the week view) |
| `t`       | Jump to today (does not change the list's view) |
| `n`       | Focus the task field                |
| `s`       | Focus the search field              |
| `v`       | Toggle week / month                 |
| `w`       | Toggle week start (Monday / Sunday) |
| arrows    | Move month / year                   |
| `Enter`   | Commit the field being edited       |
| `Esc`     | Clear the field, or discard the row edit |

## How reminders survive a reboot

A single persistent `systemd --user` timer and service, not one timer per
task:

- `omarchy-clock-reminders.timer` — `Persistent=yes`, so a reminder due while
  the machine was off fires at the next boot.
- `omarchy-clock-reminders.service` — reads the store and sends one toast per
  reminder that is due.

Both are generated by `ClockReminders.sh install` and rewritten on every
install, so do not hand-edit them; the header says so.

`Persistent=yes` replays the *timer run* that was missed, and the script then
reads today's date — so on its own it cannot rescue a reminder whose whole day
passed while the machine was off. That is what the window in the script below
is for; between them the two cover a machine that was off overnight and one
that was off for a week.

## Tests

No framework and no dependencies. `Tasks.js` and `Model.js` are deliberately
free of Qt so that the arithmetic, the store mutations and the calendar's own
date maths are testable under plain node:

    node --test tests/*.test.js

The glob matters: `node --test tests/` is read as a module to load rather than
a directory to walk.

`Model.js` has its own file because the grids are the part a change is most
likely to bend without anything looking broken: six rows of cells the whole
panel is drawn from, and now a seventh view that has to be made of the very
same cells or the two grids would drift apart in what a day is.

`ClockReminders.sh` is covered too, because the two bugs most worth keeping
locked down are both invisible to a unit test of `Tasks.js` — the script is a
second, independent reader of the store that runs whether or not the panel has
ever been opened:

    bash tests/reminders.test.sh

It fakes `date`, the notifier and all four sound players on `PATH`, so every
case can be run at the day and the hour it is actually about instead of only
at the one today happens to be — and so the alert can be asserted on which
player it reached and with which sample, rather than only that something
played.

Each fixture gets its own file. They used to share one, which was fine while
each was written immediately before it was read; a later fixture would quietly
become what every earlier reference pointed at, and a test would then report
"no notification" as the honest answer to a store it was never given.

## Requirements

- Omarchy with the Quickshell shell (v4 / "Quattro" or later).
- `jq`.
- A systemd user session, for the reminder timer.
- `omarchy-notification-send`. Without it the script sends nothing and exits
  quietly rather than failing loudly.

For the optional alert, in this order and each entirely optional: `paplay`,
`pw-play`, `aplay`, then `canberra-gtk-play`. The sample is looked for under
`$XDG_DATA_DIRS` (`sounds/freedesktop/stereo/message.oga` and its kin) or,
when that is unset, under `/usr/local/share` and `/usr/share`. Nothing found
means silence — the notification still arrives, and the timer still exits 0.

Tasks live in `~/.local/state/omarchy/clock-tasks.json`. That path predates
the rename and was left alone so existing tasks keep working.

## Upgrading

Version 2.0.0 changed the plugin id. Your `shell.json` still names the old
one, so after updating the widget will be missing from the bar:

```bash
omarchy bar put angelherman.cronos-calendar center
```

Reminders stored by 1.x keep their meaning. In 1.x a `remindDaysBefore` of
`0` meant "off" and the loader folded it to `null`; in 2.x `0` means "the day
of the due date itself". The loader migrates old files, so a `0` in a
version 1 file still loads as "off" instead of silently becoming an alarm.
See `CHANGELOG.md` for the full list of breaking changes.

## Notes

`moduleName` and the IPC target are still `omarchy.clock`. This is
intentional: the `pretty.omagen` bar plugin recognises a clock by that name,
and `shell.json`'s `centerAnchor` points at it. Renaming them would cost the
widget its styling and its centred position in the bar.

The plugin id is lowercase `angelherman.cronos-calendar` to follow Omarchy's
naming convention. The name you see in the menus is *Cronos-Calendar*.

## License

MIT. See `LICENSE`.

Forked from Omarchy's `omarchy.clock`, copyright (c) David Heinemeier
Hansson, which is MIT licensed. This fork is not endorsed by Omarchy.
