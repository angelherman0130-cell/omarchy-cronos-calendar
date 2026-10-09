// Task store for the clock's calendar panel.
//
// Tasks live in a single JSON object keyed by the same "yyyy-MM-dd" day
// identity the grid already uses (see Model.dateKey), so a calendar cell only
// has to ask about its own day to know whether it carries anything, and the
// month grid never has to walk a list.
//
// Every function here is pure and Qt-free, like Model.js, so the file stays
// unit-testable outside the shell. Nothing mutates its input: each operation
// returns a fresh store, because QML will not re-evaluate a binding that
// reads a plain JS object it considers unchanged.

var MAX_TEXT_LENGTH = 200
var MAX_NOTE_LENGTH = 600
var DAY_KEY_PATTERN = /^\d{4}-\d{2}-\d{2}$/
var MAX_REMIND_DAYS = 5

// Bumped to 2 when `remindDaysBefore` stopped using 0 for "off" and started
// using it for "the due day itself". See migrateRemindDays for what that
// costs an existing store.
//
// Still 2 after `note` was added, deliberately. The bump exists for changes of
// meaning that a second reader of the file cannot see through — ClockReminders.sh
// reads the raw JSON with jq and never consults this parser, so if a field's
// meaning changed, the two would disagree and needsRewrite would have to fix it.
// A new optional field has no such conflict: an absent `note` already means "no
// note" to both, and neither reader looks at it. The next write serialises the
// field onto every task anyway, which canonicalises an existing file without
// needing a version to say so.
var STORE_VERSION = 2

function pad2(value) {
  return (value < 10 ? "0" : "") + value
}

// A store with no days in it. The empty object is the shape every other
// function here hands back, so callers never have to null-check.
function empty() {
  return { version: STORE_VERSION, days: {} }
}

function isDayKey(value) {
  return DAY_KEY_PATTERN.test(String(value === undefined || value === null ? "" : value))
}

function cleanText(value) {
  var text = String(value === undefined || value === null ? "" : value)
  // Control characters never survive a round trip: they are invisible in the
  // task row, they put a newline in the middle of a toast, and a tab or a
  // newline in a field is exactly what would let a task's text be read as
  // several fields by anything downstream that frames on whitespace. A space
  // keeps the words apart and nothing else.
  text = text.replace(/[\u0000-\u001f\u007f]/g, " ")
  text = text.replace(/^\s+|\s+$/g, "")
  if (text.length > MAX_TEXT_LENGTH) text = text.substr(0, MAX_TEXT_LENGTH)
  return text
}

// A task's note, or "" when it has none. A separate cleaner from cleanText
// rather than a parameter on it, because the two disagree about exactly one
// thing and that one thing is the whole reason a note exists: newlines are
// kept. A task's name is one line and a newline in it is a mistake, but a note
// is prose and "bring coffee / call the front desk" is two things said on purpose.
//
// Everything else is treated as cleanText treats it — other control characters
// are still invisible garbage — plus a few rules that only matter once line
// breaks are allowed: CRLF and a bare CR both become LF, so a note written on
// one platform and read on another does not depend on which key was pressed;
// runs of blank lines collapse to one blank line, because nobody means four and
// they cost the reader four lines of nothing. Trailing and leading whitespace
// goes, which also strips a note that is nothing but newlines down to the empty
// string that means "no note".
function cleanNote(value) {
  var note = String(value === undefined || value === null ? "" : value)

  // \r first, then whatever control characters are left, which is why the
  // \u000d in the second range is harmless here: CRLF is already gone by the
  // time it runs.
  note = note.replace(/\r\n?/g, "\n")
  note = note.replace(/[\u0000-\u0009\u000b\u000c\u000e-\u001f\u007f]/g, " ")
  note = note.replace(/\n{3,}/g, "\n\n")
  note = note.replace(/^\s+|\s+$/g, "")

  // Truncated by lines rather than by characters. Cutting a note mid-word at
  // the cap is at least honest, but cutting it so the last line is a fragment
  // reads as the file having been damaged, and the ellipsis is what says
  // otherwise.
  if (note.length > MAX_NOTE_LENGTH) {
    note = note.substr(0, MAX_NOTE_LENGTH)
    var lastBreak = note.lastIndexOf("\n")
    if (lastBreak > 0) note = note.substr(0, lastBreak)
    note = note.replace(/\s+$/g, "") + "…"
  }

  return note
}

// A note the row can actually draw: at most `limit` non-empty lines, each
// trimmed. The stored note is not shortened to fit, because what is written down
// and what is legible in a 424px row are different questions and the second one
// must not decide the first.
//
// Blank lines are dropped rather than drawn, including ones inside the note. A
// blank line inside prose is a paragraph break, and a row with two lines to spend
// cannot both mark the break and carry the text it separates: one of the two
// paragraphs would be missing. Drawing "a", blank, "b" is worse than drawing
// "a", "b", which at least says both of them. A note that needs its breaks
// honoured needs a taller row, not a denser one.
function noteLines(value, limit) {
  var max = typeof limit === "number" && limit > 0 ? Math.floor(limit) : 2
  var note = cleanNote(value)
  if (note === "") return []

  var lines = note.split("\n")
  var out = []
  for (var i = 0; i < lines.length && out.length < max; i++) {
    var line = lines[i].replace(/^\s+|\s+$/g, "")
    if (line !== "") out.push(line)
  }
  return out
}

// True when the note holds something a row would not already be showing.
function hasNote(task) {
  return cleanNote(task && task.note) !== ""
}

// A deadline hour, reduced to "HH:MM", or "" when the task has none. The
// shapes people actually type are all accepted — a bare hour, an explicit
// hour and minute, and the zero-padded four-digit form — because a field that
// rejects "0930" while you are typing it is a field people give up on.
// Anything out of range is dropped rather than clamped, since a deadline
// silently moved to midnight is worse than no deadline at all, and so is the
// bare three-digit form: "930" could be 9:30 or a typo for 13:00, and
// guessing wrong on a deadline is how you miss it. The colon disambiguates.
function cleanTime(value) {
  var raw = String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "")
  if (raw === "") return ""

  var hour = -1
  var minute = 0

  if (/^\d{4}$/.test(raw)) {
    hour = parseInt(raw.substr(0, 2), 10)
    minute = parseInt(raw.substr(2, 2), 10)
  } else {
    var pair = /^(\d{1,2})(?:[:.h](\d{1,2}))?$/.exec(raw)
    if (!pair) return ""
    hour = parseInt(pair[1], 10)
    minute = pair[2] === undefined ? 0 : parseInt(pair[2], 10)
  }

  if (!(hour >= 0 && hour <= 23)) return ""
  if (!(minute >= 0 && minute <= 59)) return ""
  return pad2(hour) + ":" + pad2(minute)
}

// `value` moved by `deltaMinutes`, back to "HH:MM". Wraps around midnight in
// both directions rather than clamping, because the deadline a person wants
// after pressing "an hour later" at 23:30 is 00:30 and the one they want after
// "an hour earlier" at 00:15 is 23:15; clamping would quietly pin one of them
// to the wrong hour. An unreadable `value` starts from `fallbackMinutes` so a
// mistyped field still responds to the stepper instead of doing nothing.
//
// Kept here rather than in the panel because it is the same decision cleanTime
// makes — what counts as an hour — and a second copy of that in QML is a second
// answer to it.
function shiftTime(value, deltaMinutes, fallbackMinutes) {
  var clean = cleanTime(value)
  var minutes
  if (clean === "") {
    minutes = Number(fallbackMinutes)
    if (!isFinite(minutes)) minutes = 0
  } else {
    minutes = parseInt(clean.substr(0, 2), 10) * 60 + parseInt(clean.substr(3, 2), 10)
  }

  var delta = Number(deltaMinutes)
  if (!isFinite(delta)) delta = 0

  var total = (minutes + Math.round(delta)) % 1440
  if (total < 0) total += 1440

  return pad2(Math.floor(total / 60)) + ":" + pad2(total % 60)
}

// Minutes since midnight to "HH:MM", the other direction: what the stepper
// starts from when the field is still empty. Same rounding and the same
// wrap-around contract as shiftTime, so a panel can hand the result straight
// back into it.
function clockOffset(minutes) {
  var value = Number(minutes)
  if (!isFinite(value)) return ""

  var total = Math.round(value) % 1440
  if (total < 0) total += 1440

  return pad2(Math.floor(total / 60)) + ":" + pad2(total % 60)
}

// How many days before the task to nag, null for no reminder at all. Capped at
// five because that is the range the panel offers, and a hand-edited file
// asking for a hundred days of nagging is a reminder nobody will ever mute.
//
// Zero is a real answer and not an absent one: it means "remind me on the day
// it is due", which is what most tasks actually want. That is why "off" is null
// rather than 0 — with 0 meaning off, the day-of reminder has nowhere to go,
// and every place that asked "is this reminder on?" had to answer it with
// "> 0", which silently dropped the one value that is most often wanted.
function cleanRemindDays(value) {
  if (value === undefined || value === null || value === "") return null

  var days = Number(value)
  if (!isFinite(days)) return null
  days = Math.floor(days)
  if (days < 0) return null
  if (days > MAX_REMIND_DAYS) return MAX_REMIND_DAYS
  return days
}

var PRIORITIES = ["high", "medium", "low"]

function cleanPriority(value) {
  if (value === undefined || value === null || value === "") return null
  var p = String(value).toLowerCase()
  return PRIORITIES.indexOf(p) !== -1 ? p : null
}

function cleanTags(value) {
  if (!Array.isArray(value)) return []
  var out = []
  // Compared lower-cased, kept as typed. Two spellings of one tag are one tag
  // — filtering is case-insensitive, so "#Work" and "#work" would be two chips
  // doing exactly the same job, and a reader cannot tell from looking at them
  // that they are the same. The first spelling wins so a tag stays the way it
  // was written rather than being silently re-cased by a later edit.
  var seen = []
  for (var i = 0; i < value.length; i++) {
    var tag = cleanText(value[i]).replace(/^#/, "")
    if (tag === "") continue
    var folded = tag.toLowerCase()
    if (seen.indexOf(folded) !== -1) continue
    seen.push(folded)
    out.push(tag)
  }
  return out
}

// The three words, and the three marks beside them, both kept here so the row,
// the editor's chips and the tooltip cannot drift apart on how a priority is
// spelled or drawn. The marks are plain geometric shapes rather than a font's
// own glyphs on purpose: they render the same on a machine without the icon
// font, and a priority that turns into tofu on someone else's screen is a
// priority that says nothing.
function priorityLabel(value) {
  var p = cleanPriority(value)
  if (p === null) return ""
  if (p === "high") return "High"
  if (p === "medium") return "Medium"
  return "Low"
}

function priorityGlyph(value) {
  var p = cleanPriority(value)
  if (p === null) return ""
  if (p === "high") return "▲"
  if (p === "medium") return "●"
  return "○"
}

// What one press on the mark walks to. Loudest first from a standing start,
// because nobody who wants `low` is starting at `none` and climbing past two
// stronger marks to reach it, while everybody else is moving the way the
// shapes themselves suggest — and it closes the circle back to `none`, so the
// option to have nothing is never more than one press further than the value
// you already have. Kept here rather than in the row because the cycle is the
// rule, and the rule is the part that gets tested.
function nextPriority(value) {
  var p = cleanPriority(value)
  if (p === "high") return "medium"
  if (p === "medium") return "low"
  if (p === "low") return null
  return "high"
}

// The colour of each flag, and the one place that decides it.
//
// Fixed rather than taken from the theme, which is the opposite of what the
// rest of this panel does: these four are a legend, not chrome. The flag says
// which priority *by its colour*, so a colour that followed the theme would
// mean the same flag stood for a different thing on another machine — and a
// legend that changes with the wallpaper is not a legend.
//
// Red for high sits against the panel's own rule that red means work still
// owed, and it is deliberate: the flag is a badge on a shape, not the task's
// own text, and the two are read as different objects. What still holds is
// that the *task* is never painted with these.
function priorityColor(value) {
  var p = cleanPriority(value)
  if (p === "high") return "#e05561"
  if (p === "medium") return "#e5c07b"
  if (p === "low") return "#61afef"
  return "#7d8590"
}

// Migrate v1 stores to v2 semantics for `remindDaysBefore`. v1 treated 0 as
// "off" (returned null), v2 treats 0 as "the day of the due date". An
// existing task saved with 0 meant "no reminders" and must remain "no
// reminders" after the upgrade, so 0 becomes null when loading from a v1
// store. This migration is lossy only for that intentional change of meaning,
// which is the reason for the major version bump of the store.
function migrateRemindDays(storeVersion, value) {
  if (value === undefined || value === null || value === "") return null
  var days = Number(value)
  if (!isFinite(days)) return null
  days = Math.floor(days)

  // If coming from v1, preserve the old "0 = off" meaning rather than
  // silently turning it into a same-day reminder.
  if (storeVersion === 1 && days === 0) return null

  if (days < 0) return null
  if (days > MAX_REMIND_DAYS) return MAX_REMIND_DAYS
  return days
}

// One task, or null when the entry carries no usable text. A missing id falls
// back to the caller-supplied one so a hand-edited file still ends up with keys
// that address exactly one task.
//
// `storeVersion` is the version of the file this task was read from, not the
// version being written. It is what lets a v1 file's `remindDaysBefore: 0`
// keep meaning "off" while every other version means the due day.
function normalize(value, fallbackId, storeVersion) {
  if (!value || typeof value !== "object") return null

  var text = cleanText(value.text)
  if (text === "") return null

  var id = String(value.id === undefined || value.id === null ? "" : value.id)
  if (id === "") id = String(fallbackId === undefined || fallbackId === null ? "" : fallbackId)
  if (id === "") return null

  return {
    id: id,
    text: text,
    note: cleanNote(value.note),
    done: value.done === true,
    dueTime: cleanTime(value.dueTime),
    remindDaysBefore: migrateRemindDays(storeVersion, value.remindDaysBefore),
    priority: cleanPriority(value.priority),
    tags: cleanTags(value.tags)
  }
}

// A fresh, canonically-shaped copy. Every mutation goes through this rather
// than rebuilding the object field by field: that is exactly how the deadline
// and the reminder would go missing the first time somebody ticked a task
// off, which is the one moment the fields are still worth having.
function copy(task) {
  return {
    id: String(task.id),
    text: String(task.text),
    note: cleanNote(task.note),
    done: task.done === true,
    dueTime: cleanTime(task.dueTime),
    remindDaysBefore: cleanRemindDays(task.remindDaysBefore),
    priority: cleanPriority(task.priority),
    tags: cleanTags(task.tags)
  }
}

function parse(raw) {
  var store = empty()

  var parsed
  try {
    parsed = JSON.parse(String(raw === undefined || raw === null ? "" : raw))
  } catch (e) {
    return store
  }
  if (!parsed || typeof parsed !== "object") return store

  // A missing or unparseable version is treated as 1. That is the conservative
  // reading: a hand-edited file with no version was written by hand, most
  // likely before 2.0.0, so its 0 means "off" and must not be promoted to a
  // live reminder behind the user's back.
  var sourceVersion = Number(parsed.version)
  if (!isFinite(sourceVersion) || sourceVersion < 1) sourceVersion = 1
  if (sourceVersion > STORE_VERSION) sourceVersion = STORE_VERSION

  var days = parsed.days && typeof parsed.days === "object" ? parsed.days : {}
  for (var key in days) {
    if (!Object.prototype.hasOwnProperty.call(days, key)) continue
    if (!isDayKey(key)) continue

    var list = days[key]
    if (!Array.isArray(list)) continue

    var tasks = []
    for (var i = 0; i < list.length; i++) {
      var task = normalize(list[i], key + "#" + i, sourceVersion)
      if (task) tasks.push(task)
    }
    if (tasks.length > 0) store.days[key] = tasks
  }

  return store
}

// True when `raw` is a readable store whose file format predates
// STORE_VERSION, and so should be written back in the current shape once the
// panel has loaded it. This is what keeps the two readers of the file agreeing:
// parse() migrates in memory, but ClockReminders.sh is driven by systemd and
// reads the raw JSON with jq, without ever consulting this file. Leaving a v1
// file on disk means the panel shows a v1 0 as "off" while the script reads the
// same 0 as "the due day" — two consumers, two meanings, one file.
//
// Deliberately conservative about what it will rewrite. Only a file that
// parsed into a well-formed store with a numeric version below the current one
// qualifies: an empty, truncated, hand-mangled or unparseable file is left
// exactly as it is, because rewriting one of those to an empty store would
// destroy data instead of migrating it.
function needsRewrite(raw) {
  var text = String(raw === undefined || raw === null ? "" : raw).trim()
  if (text === "") return false

  var parsed
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    return false
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return false
  if (!parsed.days || typeof parsed.days !== "object") return false

  // A missing version means the same thing parse() means by it: version 1. That
  // is the likeliest shape to meet here, since a store migrated by hand often
  // loses the marker. A version that is present but not a usable number is
  // ambiguous rather than old, so it is left alone — an unreadable marker is not
  // evidence of an outdated file, and the in-memory migration plus the script's
  // own version check already read it correctly either way.
  var version = parsed.version
  if (version === undefined || version === null) version = 1
  version = Number(version)
  if (!isFinite(version) || version < 1) return false
  return version < STORE_VERSION
}

function serialize(store) {
  var source = store && store.days ? store.days : {}
  var out = empty()

  for (var key in source) {
    if (!Object.prototype.hasOwnProperty.call(source, key)) continue
    if (!isDayKey(key)) continue

    var list = source[key]
    if (!Array.isArray(list) || list.length === 0) continue
    out.days[key] = list.map(function(task) {
      return {
        id: task.id,
        text: task.text,
        note: cleanNote(task.note),
        done: task.done === true,
        dueTime: cleanTime(task.dueTime),
        remindDaysBefore: cleanRemindDays(task.remindDaysBefore),
        priority: cleanPriority(task.priority),
        tags: cleanTags(task.tags)
      }
    })
  }

  return JSON.stringify(out, null, 2) + "\n"
}

// Copy of `store` with `key` set to `tasks`; a now-empty day is dropped rather
// than left behind as an empty array, so the file does not accumulate
// "2026-01-01": [] entries for every day ever cleared.
function withDay(store, key, tasks) {
  var next = empty()
  var days = store && store.days ? store.days : {}

  for (var existing in days) {
    if (!Object.prototype.hasOwnProperty.call(days, existing)) continue
    if (existing === key) continue
    next.days[existing] = days[existing]
  }

  if (tasks && tasks.length > 0) next.days[key] = tasks
  return next
}

function tasksFor(store, key) {
  var days = store && store.days ? store.days : {}
  var list = isDayKey(key) ? days[String(key)] : null
  return Array.isArray(list) ? list.slice() : []
}

function count(store, key) {
  return tasksFor(store, key).length
}

// The two halves the task list is drawn from. Splitting here rather than in
// the panel keeps "outstanding" and "finished" a single definition that the
// count, the list and the calendar dot can never disagree about.
function pendingFor(store, key) {
  return tasksFor(store, key).filter(function(task) { return task.done !== true })
}

function doneFor(store, key) {
  return tasksFor(store, key).filter(function(task) { return task.done === true })
}

function pendingCount(store, key) {
  return pendingFor(store, key).length
}

function doneCount(store, key) {
  return doneFor(store, key).length
}

// Every outstanding task in the store, across every day, grouped by the day it
// belongs to and ordered by how soon it is due. Each task is tagged with its
// `dayKey`, because a task read out of the day map does not otherwise know
// which day it came from — and without that a row cannot name its date or be
// ticked off, since both of those act on one day at a time.
//
// "How soon" is the day first and the hour second, which is the same order the
// overdue check uses, so a task from a past day lands above one from today no
// matter what hour each carries. Fixed-width day keys mean comparing them as
// strings is comparing them as dates.
//
// Tasks with no deadline are not folded in at their day's position. A day key
// says when a task is due, and one without an hour has not said that yet, so
// putting it beside 09:00 would be claiming a precision nobody gave. They go
// last, still ordered by day, still in the order they were written.
//
// Ties keep stored order, which Array.prototype.sort has done since ES2019 and
// which is why two tasks sharing an hour stay in the sequence they were typed
// rather than swapping about between redraws.
function pendingGroups(store) {
  var days = store && store.days ? store.days : {}
  var dated = []
  var undated = []

  for (var key in days) {
    if (!Object.prototype.hasOwnProperty.call(days, key)) continue
    if (!isDayKey(key)) continue

    var list = days[key]
    if (!Array.isArray(list)) continue

    for (var i = 0; i < list.length; i++) {
      var task = list[i]
      if (!task || task.done === true) continue

      var tagged = copy(task)
      tagged.dayKey = String(key)

      if (hasDue(task)) dated.push(tagged)
      else undated.push(tagged)
    }
  }

  dated.sort(function(a, b) {
    if (a.dayKey !== b.dayKey) return a.dayKey < b.dayKey ? -1 : 1
    if (a.dueTime !== b.dueTime) return a.dueTime < b.dueTime ? -1 : 1
    return 0
  })

  undated.sort(function(a, b) {
    if (a.dayKey !== b.dayKey) return a.dayKey < b.dayKey ? -1 : 1
    return 0
  })

  // Grouped on the way out rather than by a pass over the sorted list, because
  // the list is already in day order and doing it here keeps the grouping and
  // the ordering from being two decisions that can disagree.
  var groups = []
  var index = {}
  var all = dated.concat(undated)

  for (var j = 0; j < all.length; j++) {
    var day = all[j].dayKey
    var group = index[day]
    if (!group) {
      group = { dayKey: day, tasks: [] }
      index[day] = group
      groups.push(group)
    }
    group.tasks.push(all[j])
  }

  return groups
}

// How many groups, and how many tasks, pendingGroups would return. The list
// draws them and the header counts them, and a second walk of the store to get
// the number would be a second answer to the same question.
function pendingGroupSummary(store) {
  var groups = pendingGroups(store)
  var tasks = 0
  for (var i = 0; i < groups.length; i++) tasks += groups[i].tasks.length
  return { groups: groups.length, tasks: tasks }
}

// One flag per task for the dots under a day number: true for still
// outstanding, false for finished, in stored order. Capped, because a row of
// dots has to stay inside its own cell and a busy day would otherwise widen
// the row until it collided with the neighbouring day.
function dotFlags(store, key, limit) {
  var max = typeof limit === "number" && limit > 0 ? Math.floor(limit) : 6
  return tasksFor(store, key).slice(0, max).map(function(task) {
    return task.done !== true
  })
}

// A day with nothing left to do still gets a dot, just the other colour: the
// day was used, and that is not the same signal as work still outstanding.
function allDone(store, key) {
  var total = count(store, key)
  return total > 0 && pendingCount(store, key) === 0
}

function find(store, key, id) {
  var list = tasksFor(store, key)
  for (var i = 0; i < list.length; i++) if (list[i].id === String(id)) return i
  return -1
}

// `note` is optional and independent of `text`: a task with no name is not a
// task, but a task with a name and no note is the common case, so the note is
// never what makes an add succeed or fail.
// priority and tags are trailing and optional on purpose: every caller that
// was written before they existed is a caller that means "none" and "no tags",
// which is exactly what `cleanPriority` and `cleanTags` answer for arguments
// they are given as undefined. Adding them in the middle would have turned
// every one of those calls into a silent wrong answer.
function add(store, key, text, id, dueTime, remindDaysBefore, note, priority, tags) {
  if (!isDayKey(key)) return store

  var clean = cleanText(text)
  if (clean === "") return store

  var taskId = String(id === undefined || id === null ? "" : id)
  if (taskId === "") return store

  var task = {
    id: taskId,
    text: clean,
    note: cleanNote(note),
    done: false,
    dueTime: cleanTime(dueTime),
    remindDaysBefore: cleanRemindDays(remindDaysBefore),
    priority: cleanPriority(priority),
    tags: cleanTags(tags)
  }
  return withDay(store, String(key), tasksFor(store, key).concat([task]))
}

function toggle(store, key, id) {
  var index = find(store, key, id)
  if (index === -1) return store

  var list = tasksFor(store, key)
  var task = copy(list[index])
  task.done = !task.done
  list[index] = task
  return withDay(store, String(key), list)
}

function remove(store, key, id) {
  var index = find(store, key, id)
  if (index === -1) return store

  var list = tasksFor(store, key)
  list.splice(index, 1)
  return withDay(store, String(key), list)
}

// Put a task back where remove took it from. The other half of a delete, and
// the reason an undo button can be offered at all.
//
// The index is a real argument rather than a detail the function works out,
// because by the time this runs the task is no longer in the store and there
// is nothing left to look its position up from. Re-adding at the end would
// work and would also mean a delete-and-undo quietly moves the task from under
// wherever the reader last saw it, which is a small lie about a list they have
// been reading by position.
//
// An index past the end lands on the end rather than being rejected: the list
// can have been shortened by something else between the delete and the undo,
// and dropping the task on the floor because the arithmetic changed would turn
// an accident into a loss.
function restore(store, key, task, index) {
  if (!task || typeof task !== "object") return store

  var list = tasksFor(store, key)
  var at = typeof index === "number" && isFinite(index) ? Math.round(index) : list.length
  if (at < 0) at = 0
  if (at > list.length) at = list.length

  list.splice(at, 0, task)
  return withDay(store, String(key), list)
}

// Replace the two pieces of writing on a task that already exists: its name and
// its description.
//
// Both in one function rather than two because the row's editor is one gesture
// — a single confirm that saves both fields or neither. Two functions would let
// a caller save a name and lose the description, and the description is the part
// nobody would notice missing.
//
// The same refusal as `add`: a task with no name is not a task, so an emptied
// name returns the store untouched. The caller keeps its editor open rather than
// saving a blank row, which is why nothing here has to report the refusal — the
// store coming back unchanged is the whole report.
function setContent(store, key, id, text, note) {
  var index = find(store, key, id)
  if (index === -1) return store

  var clean = cleanText(text)
  if (clean === "") return store

  var list = tasksFor(store, key)
  var task = copy(list[index])
  task.text = clean
  task.note = cleanNote(note)
  list[index] = task
  return withDay(store, String(key), list)
}

// Set or clear one of the two optional fields on a task that already exists.
// Passing "" for the hour and null for the days is how the row's badges turn
// themselves off again, so a mistyped deadline is not a permanent mistake.
function setFields(store, key, id, dueTime, remindDaysBefore) {
  var index = find(store, key, id)
  if (index === -1) return store

  var list = tasksFor(store, key)
  var task = copy(list[index])
  task.dueTime = cleanTime(dueTime)
  task.remindDaysBefore = cleanRemindDays(remindDaysBefore)
  list[index] = task
  return withDay(store, String(key), list)
}

function setPriority(store, key, id, priority) {
  var index = find(store, key, id)
  if (index === -1) return store

  var list = tasksFor(store, key)
  var task = copy(list[index])
  task.priority = cleanPriority(priority)
  list[index] = task
  return withDay(store, String(key), list)
}

function setTags(store, key, id, tags) {
  var index = find(store, key, id)
  if (index === -1) return store

  var list = tasksFor(store, key)
  var task = copy(list[index])
  task.tags = cleanTags(tags)
  list[index] = task
  return withDay(store, String(key), list)
}

// ---- Deadlines and reminders

function hasDue(task) {
  return cleanTime(task && task.dueTime) !== ""
}

function hasReminder(task) {
  return cleanRemindDays(task && task.remindDaysBefore) !== null
}

// The day a reminder runs on: `daysBefore` days before the task's own day.
// Zero means the task's own day, which is the day-of reminder. Done through
// Date.UTC rather than a local Date so that a task due on the 30th cannot land
// on the 29th because the intervening night was an hour long. Returns "" for
// anything that is not a usable day key, which keeps the callers from having to
// re-check the shape.
function reminderDayKey(key, daysBefore) {
  if (!isDayKey(key)) return ""

  var days = cleanRemindDays(daysBefore)
  if (days === null) return ""

  var parts = String(key).split("-")
  var when = Date.UTC(
    parseInt(parts[0], 10),
    parseInt(parts[1], 10) - 1,
    parseInt(parts[2], 10) - days
  )
  var date = new Date(when)
  return date.getUTCFullYear() + "-" + pad2(date.getUTCMonth() + 1) + "-" + pad2(date.getUTCDate())
}

// The one line of wording the row badge and the panel tooltip both need, so
// "1 day before" and "on the day" are never described two different ways in two
// places. Kept next to reminderDayKey because it is the same decision stated
// for a human.
function remindDaysLabel(daysBefore) {
  var days = cleanRemindDays(daysBefore)
  if (days === null) return ""
  if (days === 0) return "on the due date"
  if (days === 1) return "the day before"
  return days + " days before"
}

// A short form for the row's badge, where "0d" is as unclear as a symbol gets
// and the badge has room for a word but not for a sentence.
function remindDaysShort(daysBefore) {
  var days = cleanRemindDays(daysBefore)
  if (days === null) return ""
  if (days === 0) return "today"
  return days + "d"
}

// Past its deadline and not finished. `nowKey` is "yyyy-MM-dd" and
// `nowMinutes` is minutes since midnight, so the caller decides what "now"
// means and the comparison stays free of clocks. Day keys are fixed-width, so
// comparing them as strings is comparing them as dates.
function isOverdue(task, nowKey, nowMinutes) {
  if (!hasDue(task) || (task && task.done === true)) return false
  if (!isDayKey(nowKey)) return false

  var due = cleanTime(task.dueTime)
  var minutes = parseInt(due.substr(0, 2), 10) * 60 + parseInt(due.substr(3, 2), 10)

  // The due hour belongs to the task's own day, so the task's day has to be
  // known here; the caller supplies it alongside the clock reading.
  var dayKey = String(task.dayKey === undefined || task.dayKey === null ? "" : task.dayKey)
  if (!isDayKey(dayKey)) return false

  if (dayKey < nowKey) return true
  if (dayKey > nowKey) return false

  var elapsed = typeof nowMinutes === "number" && isFinite(nowMinutes) ? Math.floor(nowMinutes) : 0
  return elapsed > minutes
}

// Minutes since midnight, for isOverdue's clock argument. Kept next to it so
// the panel cannot pass an hour-of-day where a minute count belongs.
function minutesNow(date) {
  var when = date instanceof Date ? date : new Date()
  return when.getHours() * 60 + when.getMinutes()
}

// Every task in the store that should currently be nagging, paired with the
// day it nags on. Finished tasks are excluded and so are reminders whose day
// has already gone: a store can hold years of history, and re-arming a
// reminder for a Tuesday that passed in March is worse than doing nothing.
// `onDay` is the task's own day, carried through so callers do not have to
// re-attach it.
function activeReminders(store, nowKey) {
  var days = store && store.days ? store.days : {}
  var out = []

  for (var key in days) {
    if (!Object.prototype.hasOwnProperty.call(days, key)) continue
    if (!isDayKey(key)) continue

    var list = days[key]
    if (!Array.isArray(list)) continue

    for (var i = 0; i < list.length; i++) {
      var task = list[i]
      if (!hasReminder(task) || task.done === true) continue

      var remindOn = reminderDayKey(key, task.remindDaysBefore)
      if (remindOn === "") continue
      if (isDayKey(nowKey) && remindOn < nowKey) continue

      var tagged = copy(task)
      tagged.dayKey = key
      tagged.remindDayKey = remindOn
      out.push(tagged)
    }
  }

  return out
}

// Human-readable time until a deadline: "2d 3h", "45m", "1h 5m". Returns "" when
// there is no deadline or the deadline has passed. `nowKey` is "yyyy-MM-dd" and
// `nowMinutes` is minutes since midnight, so the caller decides what "now" means.
function timeUntil(dayKey, dueTime, nowKey, nowMinutes) {
  if (!hasDue({ dueTime: dueTime })) return ""
  if (!isDayKey(dayKey) || !isDayKey(nowKey)) return ""

  var due = cleanTime(dueTime)
  var dueMinutes = parseInt(due.substr(0, 2), 10) * 60 + parseInt(due.substr(3, 2), 10)
  var elapsed = typeof nowMinutes === "number" && isFinite(nowMinutes) ? Math.floor(nowMinutes) : 0

  var totalMinutes
  if (dayKey === nowKey) {
    totalMinutes = dueMinutes - elapsed
  } else {
    var dayDiff = Math.round((Date.parse(dayKey) - Date.parse(nowKey)) / 86400000)
    totalMinutes = dayDiff * 1440 + dueMinutes - elapsed
  }

  if (totalMinutes <= 0) return ""

  var days = Math.floor(totalMinutes / 1440)
  var hours = Math.floor((totalMinutes % 1440) / 60)
  var mins = totalMinutes % 60

  if (days > 0) return days + "d " + hours + "h"
  if (hours > 0) return hours + "h " + mins + "m"
  return mins + "m"
}

// True when a task was completed on a given day. Used by the statistics section.
function completedOn(task, dayKey) {
  return task && task.done === true && String(task.dayKey || "") === String(dayKey)
}

function countDoneOn(list) {
  if (!Array.isArray(list)) return 0
  var n = 0
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].done === true) n++
  }
  return n
}

// Finished work on one day, as a number rather than as something the panel has
// to count by walking the list itself — every figure the stats block reports
// comes from here so they cannot disagree with each other.
function countDone(store, dayKey) {
  if (!isDayKey(dayKey)) return 0
  var days = store && store.days ? store.days : {}
  return countDoneOn(days[String(dayKey)])
}

// Finished work between two day keys, inclusive, in either order. Keys are
// compared as strings because "yyyy-MM-dd" sorts the way dates do, which is
// cheaper and less fragile than parsing every key in the store into a Date and
// hoping two of them agree on a timezone.
function countDoneInRange(store, fromKey, toKey) {
  if (!isDayKey(fromKey) || !isDayKey(toKey)) return 0
  var lo = fromKey < toKey ? fromKey : toKey
  var hi = fromKey < toKey ? toKey : fromKey
  var days = store && store.days ? store.days : {}
  var total = 0
  for (var key in days) {
    if (!isDayKey(key) || key < lo || key > hi) continue
    total += countDoneOn(days[key])
  }
  return total
}

// How a set of tasks falls across the three priorities. Returned as a plain
// tally rather than as a sorted list, because the stats block reads it as four
// figures and a sort would put them in an order nobody asked for.
function countByPriority(tasks) {
  var out = { high: 0, medium: 0, low: 0, none: 0 }
  if (!Array.isArray(tasks)) return out
  for (var i = 0; i < tasks.length; i++) {
    var p = cleanPriority(tasks[i] && tasks[i].priority)
    if (p === null) out.none++
    else out[p]++
  }
  return out
}

// A day key moved by a number of days. UTC throughout, and the same key
// format every other function speaks, because the calendar has no timezone —
// a "seven days ago" that could land on a different date depending on where
// the machine is would make the streak and the weekly tally disagree.
function dayKeyShift(dayKey, deltaDays) {
  if (!isDayKey(dayKey)) return ""
  var date = new Date(String(dayKey) + "T00:00:00")
  var delta = Number(deltaDays)
  if (!isFinite(delta)) delta = 0
  date.setUTCDate(date.getUTCDate() + delta)
  return date.getUTCFullYear() + "-" + pad2(date.getUTCMonth() + 1) + "-" + pad2(date.getUTCDate())
}

// Consecutive days with at least one completed task, counting back from today.
// Returns 0 when today has no completions. `todayKey` is "yyyy-MM-dd".
function streak(store, todayKey) {
  if (!isDayKey(todayKey)) return 0

  var days = store && store.days ? store.days : {}
  var count = 0
  var current = new Date(todayKey + "T00:00:00")

  for (var i = 0; i < 365; i++) {
    var key = current.getUTCFullYear() + "-" + pad2(current.getUTCMonth() + 1) + "-" + pad2(current.getUTCDate())
    var list = days[key]
    var hasCompletion = false
    if (Array.isArray(list)) {
      for (var j = 0; j < list.length; j++) {
        if (list[j] && list[j].done === true) { hasCompletion = true; break }
      }
    }
    if (hasCompletion) {
      count++
    } else {
      break
    }
    current.setUTCDate(current.getUTCDate() - 1)
  }

  return count
}

// ---- Searching the list

// A trimmed, lower-cased query, or "" for "no search". Kept as its own
// function so every matcher below agrees on what a query is — one that trims
// and one that does not would make the same string match in the header and
// fail in the list.
function searchNeedle(query) {
  return String(query === undefined || query === null ? "" : query).replace(/^\s+|\s+$/g, "").toLowerCase()
}

// Whether one task is what somebody is looking for. A name, a note or a tag
// will do, because nobody remembers which of the three they put the word in.
// An empty needle matches everything, which is what lets the caller filter
// unconditionally instead of branching on "is there a search at all".
function matchesQuery(task, query) {
  var needle = searchNeedle(query)
  if (needle === "") return true
  if (!task) return false

  if (String(task.text || "").toLowerCase().indexOf(needle) !== -1) return true
  if (String(task.note || "").toLowerCase().indexOf(needle) !== -1) return true

  var tags = Array.isArray(task.tags) ? task.tags : []
  for (var i = 0; i < tags.length; i++) {
    if (String(tags[i]).toLowerCase().indexOf(needle) !== -1) return true
  }
  return false
}

function filterTasks(tasks, query) {
  if (!Array.isArray(tasks)) return []
  if (searchNeedle(query) === "") return tasks.slice()
  return tasks.filter(function(task) { return matchesQuery(task, query) })
}

// A tag filter is not a substring search, and treating it as one would break a
// promise the chip above the list makes. Searching "work" is meant to find
// "homework", because a search is a guess; clicking #work is a request for
// exactly that tag, and handing back "workspace" for it would be the filter
// answering a question nobody asked. Matched whole, against the cleaned tags,
// case-insensitively — so "#Work" and "work" are the same chip, and neither is
// a partial match on anything else.
function tagNeedle(rawTag) {
  return String(rawTag === undefined || rawTag === null ? "" : rawTag)
    .replace(/^#/, "")
    .replace(/^\s+|\s+$/g, "")
}

function matchesTag(task, rawTag) {
  var needle = tagNeedle(rawTag).toLowerCase()
  if (needle === "") return true
  if (!task) return false
  var tags = cleanTags(task.tags)
  for (var i = 0; i < tags.length; i++) {
    if (tags[i].toLowerCase() === needle) return true
  }
  return false
}

function filterByTag(tasks, rawTag) {
  if (!Array.isArray(tasks)) return []
  if (tagNeedle(rawTag) === "") return tasks.slice()
  return tasks.filter(function(task) { return matchesTag(task, rawTag) })
}

// Every tag in the store that is still in play, each with how many tasks carry
// it. Built from the list it will narrow rather than from the whole store, so
// a tag whose last task is finished disappears from the row instead of sitting
// there filtering a view down to nothing.
function tagCounts(tasks) {
  if (!Array.isArray(tasks)) return []
  var counts = {}
  var order = []
  var folded = {}
  for (var i = 0; i < tasks.length; i++) {
    var tags = cleanTags(tasks[i] && tasks[i].tags)
    for (var j = 0; j < tags.length; j++) {
      var tag = tags[j]
      // Keyed lower-cased for the same reason cleanTags compares that way: a
      // file edited by hand can carry "Work" on one task and "work" on
      // another, and two chips that narrow the list identically are one chip
      // shown twice. The first spelling is the one kept.
      var key = tag.toLowerCase()
      if (counts[key] === undefined) {
        counts[key] = 0
        folded[key] = tag
        order.push(key)
      }
      counts[key]++
    }
  }
  var out = []
  for (var k = 0; k < order.length; k++) {
    out.push({ tag: folded[order[k]], count: counts[order[k]] })
  }
  return out
}

// pendingGroups narrowed to the search and to a followed tag. Groups that lose
// every task are dropped rather than left as an empty heading, because a
// heading over nothing is a promise that there is something under it. Both
// filters are applied before that decision, so a day emptied by the tag alone
// disappears too — leaving it would promise a heading and deliver a blank.
//
// The tag argument is optional so the plain search keeps working as it did.
function filterGroups(groups, query, tag) {
  if (!Array.isArray(groups)) return []
  var hasTag = tagNeedle(tag) !== ""
  if (searchNeedle(query) === "" && !hasTag) return groups.slice()

  var out = []
  for (var i = 0; i < groups.length; i++) {
    var group = groups[i]
    if (!group) continue
    var kept = filterTasks(group.tasks, query)
    if (hasTag) kept = filterByTag(kept, tag)
    if (kept.length === 0) continue

    var copy = { dayKey: String(group.dayKey), tasks: kept }
    out.push(copy)
  }
  return out
}

// The header's counts for a set of groups. Separate from pendingGroupSummary
// so that a filtered list reports the filtered number instead of the store's.
function groupSummary(groups) {
  var list = Array.isArray(groups) ? groups : []
  var tasks = 0
  for (var i = 0; i < list.length; i++) {
    if (list[i] && Array.isArray(list[i].tasks)) tasks += list[i].tasks.length
  }
  return { groups: list.length, tasks: tasks }
}

if (typeof module !== "undefined") {
  module.exports = {
    MAX_TEXT_LENGTH: MAX_TEXT_LENGTH,
    MAX_NOTE_LENGTH: MAX_NOTE_LENGTH,
    MAX_REMIND_DAYS: MAX_REMIND_DAYS,
    empty: empty,
    isDayKey: isDayKey,
    cleanText: cleanText,
    cleanNote: cleanNote,
    noteLines: noteLines,
    hasNote: hasNote,
    cleanTime: cleanTime,
    shiftTime: shiftTime,
    clockOffset: clockOffset,
    cleanRemindDays: cleanRemindDays,
    migrateRemindDays: migrateRemindDays,
    cleanPriority: cleanPriority,
    cleanTags: cleanTags,
    priorityLabel: priorityLabel,
    priorityGlyph: priorityGlyph,
    nextPriority: nextPriority,
    priorityColor: priorityColor,
    parse: parse,
    needsRewrite: needsRewrite,
    serialize: serialize,
    tasksFor: tasksFor,
    count: count,
    pendingFor: pendingFor,
    doneFor: doneFor,
    pendingGroups: pendingGroups,
    pendingGroupSummary: pendingGroupSummary,
    dotFlags: dotFlags,
    pendingCount: pendingCount,
    doneCount: doneCount,
    allDone: allDone,
    find: find,
    copy: copy,
    add: add,
    toggle: toggle,
    remove: remove,
    restore: restore,
    setFields: setFields,
    setContent: setContent,
    setPriority: setPriority,
    setTags: setTags,
    hasDue: hasDue,
    hasReminder: hasReminder,
    reminderDayKey: reminderDayKey,
    remindDaysLabel: remindDaysLabel,
    remindDaysShort: remindDaysShort,
    isOverdue: isOverdue,
    minutesNow: minutesNow,
    activeReminders: activeReminders,
    timeUntil: timeUntil,
    completedOn: completedOn,
    dayKeyShift: dayKeyShift,
    streak: streak,
    countDone: countDone,
    countDoneInRange: countDoneInRange,
    countByPriority: countByPriority,
    searchNeedle: searchNeedle,
    matchesQuery: matchesQuery,
    filterTasks: filterTasks,
    tagNeedle: tagNeedle,
    matchesTag: matchesTag,
    filterByTag: filterByTag,
    tagCounts: tagCounts,
    filterGroups: filterGroups,
    groupSummary: groupSummary
  }
}
