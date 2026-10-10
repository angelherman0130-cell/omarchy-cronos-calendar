// Tests for Tasks.js — the Qt-free half of the plugin, runnable under plain
// node with no framework and no dependencies:
//
//   node --test tests/*.test.js
//
// The glob matters: `node --test tests/` is read as a module to load, not a
// directory to walk.
//
// Kept next to the module rather than in a separate package because Tasks.js
// is deliberately free of Qt so that this is possible at all: everything the
// panel's arithmetic and store mutations do can be checked here, and the QML
// that has to be eyeballed is only the drawing.

const { test } = require("node:test")
const assert = require("node:assert/strict")
const path = require("node:path")

const Tasks = require(path.join(__dirname, "..", "Tasks.js"))

// A store shaped like the real one, with the fields every reader cares about.
function storeWith(tasks) {
  return { version: 2, days: { "2026-10-08": tasks } }
}

function task(over) {
  return Object.assign({
    id: "id1",
    text: "Task",
    note: "",
    done: false,
    dayKey: "2026-10-08",
    dueTime: "",
    remindDaysBefore: null
  }, over)
}

// ---- Store round trip -----------------------------------------------------

test("parse accepts the real file shape and keeps every field", () => {
  const raw = JSON.stringify({
    version: 2,
    days: {
      "2026-10-08": [
        { id: "a", text: "Lab.5 DLA", done: false, dueTime: "17:00", remindDaysBefore: 1, note: "a note" }
      ]
    }
  })
  const store = Tasks.parse(raw)
  const t = store.days["2026-10-08"][0]
  assert.equal(t.text, "Lab.5 DLA")
  assert.equal(t.dueTime, "17:00")
  assert.equal(t.remindDaysBefore, 1)
  assert.equal(t.note, "a note")
  assert.equal(t.done, false)
})

test("serialize → parse is a no-op on a current store", () => {
  const store = storeWith([task({ text: "Taller DLA", note: "bring\nthe form" })])
  const once = Tasks.parse(Tasks.serialize(store))
  const twice = Tasks.parse(Tasks.serialize(once))
  assert.deepEqual(twice, once)
  assert.equal(Tasks.needsRewrite(Tasks.serialize(store)), false)
})

test("parse never throws on rubbish, it returns an empty store", () => {
  assert.deepEqual(Tasks.parse("not json").days, {})
  assert.deepEqual(Tasks.parse("").days, {})
  assert.deepEqual(Tasks.parse(null).days, {})
})

// ---- Cleaning -------------------------------------------------------------

test("cleanText strips control characters and trims", () => {
  assert.equal(Tasks.cleanText("  hello\u0000world  "), "hello world")
  assert.equal(Tasks.cleanText("line\nbreak"), "line break")
  assert.equal(Tasks.cleanText("\ttabbed"), "tabbed")
  assert.equal(Tasks.cleanText(null), "")
})

test("cleanText caps at the text limit", () => {
  assert.equal(Tasks.cleanText("x".repeat(500)).length, Tasks.MAX_TEXT_LENGTH)
})

test("cleanNote keeps newlines where cleanText does not", () => {
  assert.equal(Tasks.cleanNote("a\nb"), "a\nb")
  assert.equal(Tasks.cleanText("a\nb"), "a b")
  assert.equal(Tasks.cleanNote("crlf\r\nend"), "crlf\nend")
  assert.equal(Tasks.cleanNote("blank\n\n\n\nline"), "blank\n\nline")
  assert.equal(Tasks.cleanNote("   \n   \n"), "")
})

test("cleanNote truncates the content at the cap and keeps the marker that says so", () => {
  const truncated = Tasks.cleanNote("x".repeat(900))
  assert.equal(truncated.length, Tasks.MAX_NOTE_LENGTH + 1, "600 of content, then the ellipsis")
  assert.ok(truncated.endsWith("…"))
  assert.ok(truncated.startsWith("x".repeat(100)))

  // The property that actually matters: a note that has already been cleaned
  // must come back identical, or every save would quietly rewrite it.
  for (const raw of ["x".repeat(900), "a".repeat(400) + "\n" + "b".repeat(400), "line\n".repeat(300), "  \n\n\n", "one line"]) {
    assert.equal(Tasks.cleanNote(Tasks.cleanNote(raw)), Tasks.cleanNote(raw))
  }

  // Truncation lands on a line break when the note has one, so the reader
  // gets the last whole line instead of half of it.
  const withBreaks = Tasks.cleanNote("word\n".repeat(300))
  assert.ok(withBreaks.endsWith("…"))
  const kept = withBreaks.slice(0, -1).split("\n").filter(line => line !== "")
  assert.ok(kept.length > 0 && kept.every(line => line === "word"), "every surviving line is complete")
})

test("noteLines caps what the row draws without losing the rest", () => {
  assert.deepEqual(Tasks.noteLines("one\ntwo\nthree", 2), ["one", "two"])
  assert.deepEqual(Tasks.noteLines("only\n\n\nsecond", 2), ["only", "second"])
  assert.deepEqual(Tasks.noteLines("", 2), [])
})

test("hasNote is false for a note that cleans to empty", () => {
  assert.equal(Tasks.hasNote({ note: "  " }), false)
  assert.equal(Tasks.hasNote({ note: "real" }), true)
  assert.equal(Tasks.hasNote({}), false)
})

test("cleanTime accepts the shapes people actually type", () => {
  assert.equal(Tasks.cleanTime("17:00"), "17:00")
  assert.equal(Tasks.cleanTime("9"), "09:00")
  assert.equal(Tasks.cleanTime("9.30"), "09:30")
  assert.equal(Tasks.cleanTime(" 17:00 "), "17:00")
  assert.equal(Tasks.cleanTime("17.00"), "17:00")
})

test("cleanTime refuses rather than clamps, because a deadline silently moved is worse than none", () => {
  assert.equal(Tasks.cleanTime("24:00"), "", "an hour past midnight")
  assert.equal(Tasks.cleanTime("17:60"), "", "an impossible minute")
  assert.equal(Tasks.cleanTime(""), "")
  assert.equal(Tasks.cleanTime(null), "")
  // "930" is either 09:30 or a typo for 13:00, and guessing wrong on a
  // deadline is how you miss it — the colon is what disambiguates, so the
  // bare three-digit shape is dropped instead of padded.
  assert.equal(Tasks.cleanTime("930"), "")
  assert.equal(Tasks.cleanTime("170"), "")
  assert.equal(Tasks.cleanTime("17000"), "")
})

test("cleanRemindDays accepts 0..365 and clamps above", () => {
  assert.equal(Tasks.cleanRemindDays(0), 0)
  assert.equal(Tasks.cleanRemindDays(5), 5)
  assert.equal(Tasks.cleanRemindDays(7), 7)
  // Past the chips is the field's own territory: twelve days is a value a
  // person typed, and the cleaner must not pull it back onto a chip.
  assert.equal(Tasks.cleanRemindDays(12), 12)
  assert.equal(Tasks.cleanRemindDays("3"), 3)
  // Above the year the value is pulled to the year rather than dropped: a
  // hand-edited 400 means "as far ahead as this goes", not "no reminder".
  assert.equal(Tasks.cleanRemindDays(400), Tasks.MAX_REMIND_DAYS)
  assert.equal(Tasks.cleanRemindDays(Tasks.MAX_REMIND_DAYS), Tasks.MAX_REMIND_DAYS)
  // Negative, non-numeric and absent all mean no reminder at all.
  assert.equal(Tasks.cleanRemindDays(-1), null)
  assert.equal(Tasks.cleanRemindDays(null), null)
  assert.equal(Tasks.cleanRemindDays(""), null)
  assert.equal(Tasks.cleanRemindDays("x"), null)
})

test("the chips are the days both halves offer, and each survives the cleaner", () => {
  // One list, two faces: the composer and the row editor draw from it, so
  // "the reminder options" cannot mean two different sets on one panel.
  assert.deepEqual(Tasks.REMIND_CHIP_DAYS, [0, 1, 2, 3, 4, 5, 6, 7])
  for (const days of Tasks.REMIND_CHIP_DAYS) {
    assert.equal(Tasks.cleanRemindDays(days), days, "chip " + days)
  }
})

test("v1 stores fold a remind of 0 to null, v2 keeps it", () => {
  assert.equal(Tasks.migrateRemindDays(1, 0), null)
  assert.equal(Tasks.migrateRemindDays(2, 0), 0)
  assert.equal(Tasks.migrateRemindDays(1, 3), 3)
})

// ---- Mutation: every operation returns a new store ------------------------

test("add appends without touching the input", () => {
  const before = storeWith([task({ id: "id1", text: "First" })])
  const snapshot = JSON.parse(JSON.stringify(before))
  const after = Tasks.add(before, "2026-10-08", "Second", "id2", "17:00", 1, "")
  assert.equal(Tasks.count(after, "2026-10-08"), 2)
  assert.deepEqual(before, snapshot, "input store was mutated")
  assert.equal(before.days["2026-10-08"].length, 1)
})

test("add refuses an empty name", () => {
  const before = storeWith([task({ id: "id1" })])
  const after = Tasks.add(before, "2026-10-08", "   ", "id2", "", null, "")
  assert.equal(after, before, "empty name must be a no-op")
})

test("add normalises what it is given", () => {
  const after = Tasks.add(Tasks.empty(), "2026-10-08", "  real  ", "id1", "1700", 9, "note")
  const t = after.days["2026-10-08"][0]
  assert.equal(t.text, "real")
  assert.equal(t.dueTime, "17:00")
  assert.equal(t.remindDaysBefore, Tasks.cleanRemindDays(9))
  assert.equal(t.note, "note")
})

test("add carries the priority and tags chosen at creation", () => {
  const after = Tasks.add(Tasks.empty(), "2026-10-08", "Task", "id1", "", null, "",
    "high", ["Work", "work", " home "])
  const t = after.days["2026-10-08"][0]
  assert.equal(t.priority, "high")
  assert.deepEqual(t.tags, ["Work", "home"])
})

test("add with no priority or tags still yields none and none", () => {
  // Every caller written before these two existed is a caller that means
  // "none" — the arguments arrive undefined, which is not the same as the
  // caller having answered. They must land on the empty state, not on
  // whatever `undefined` would have been accepted as.
  const after = Tasks.add(Tasks.empty(), "2026-10-08", "Task", "id1", "17:00", 2, "note")
  const t = after.days["2026-10-08"][0]
  assert.equal(t.priority, null)
  assert.deepEqual(t.tags, [])
})

test("priorityColor is one colour per flag, grey for none", () => {
  assert.equal(Tasks.priorityColor("high"), "#e05561")
  assert.equal(Tasks.priorityColor("medium"), "#e5c07b")
  assert.equal(Tasks.priorityColor("low"), "#61afef")
  assert.equal(Tasks.priorityColor(null), "#7d8590")
  assert.equal(Tasks.priorityColor("urgent"), "#7d8590")
  // The legend must be the same four strings on every machine, so nothing
  // here may read a theme, a locale or the clock.
  const seen = new Set(["high", "medium", "low", null].map(Tasks.priorityColor))
  assert.equal(seen.size, 4)
})

test("toggle flips done and only that", () => {
  const before = storeWith([task({ id: "id1", text: "T", dueTime: "17:00" })])
  const after = Tasks.toggle(before, "2026-10-08", "id1")
  assert.equal(after.days["2026-10-08"][0].done, true)
  assert.equal(after.days["2026-10-08"][0].dueTime, "17:00")
  assert.equal(after.days["2026-10-08"][0].text, "T")
  assert.equal(Tasks.toggle(after, "2026-10-08", "id1").days["2026-10-08"][0].done, false)
})

test("toggle on an unknown id is a no-op", () => {
  const before = storeWith([task({ id: "id1" })])
  assert.equal(Tasks.toggle(before, "2026-10-08", "nope"), before)
  assert.equal(Tasks.toggle(before, "2026-10-09", "id1"), before)
})

test("remove drops the task and leaves the others alone", () => {
  const before = storeWith([task({ id: "id1" }), task({ id: "id2", text: "Keep" })])
  const after = Tasks.remove(before, "2026-10-08", "id1")
  assert.equal(after.days["2026-10-08"].length, 1)
  assert.equal(after.days["2026-10-08"][0].text, "Keep")
  assert.equal(before.days["2026-10-08"].length, 2, "input store was mutated")
})

test("restore undoes remove exactly, position and all", () => {
  const before = storeWith([
    task({ id: "id1", text: "First" }),
    task({ id: "id2", text: "Second" }),
    task({ id: "id3", text: "Third" })
  ])
  const index = Tasks.find(before, "2026-10-08", "id2")
  const victim = Tasks.tasksFor(before, "2026-10-08")[index]
  const removed = Tasks.remove(before, "2026-10-08", "id2")
  assert.deepEqual(removed.days["2026-10-08"].map(t => t.id), ["id1", "id3"])

  const restored = Tasks.restore(removed, "2026-10-08", victim, index)
  assert.deepEqual(restored.days["2026-10-08"].map(t => t.id), ["id1", "id2", "id3"])
  assert.deepEqual(restored, before, "a delete and its undo are a no-op")
})

test("restore puts a task back on a day the store no longer has", () => {
  const store = Tasks.empty()
  const restored = Tasks.restore(store, "2026-10-08", task({ id: "id1" }), 0)
  assert.deepEqual(restored.days["2026-10-08"].map(t => t.id), ["id1"])
})

test("restore never loses the task when the arithmetic has moved on", () => {
  const shrunken = storeWith([task({ id: "id1" })])
  const past = Tasks.restore(shrunken, "2026-10-08", task({ id: "ghost" }), 99)
  assert.deepEqual(past.days["2026-10-08"].map(t => t.id), ["id1", "ghost"], "past the end lands on the end")

  const negative = Tasks.restore(shrunken, "2026-10-08", task({ id: "ghost" }), -4)
  assert.deepEqual(negative.days["2026-10-08"].map(t => t.id), ["ghost", "id1"], "before the start lands on the start")

  const nonsense = Tasks.restore(shrunken, "2026-10-08", task({ id: "ghost" }), "x")
  assert.equal(nonsense.days["2026-10-08"].length, 2, "an unreadable index appends")
})

test("restore refuses to invent a task", () => {
  const store = storeWith([task({ id: "id1" })])
  assert.equal(Tasks.restore(store, "2026-10-08", null, 0), store)
  assert.equal(Tasks.restore(store, "2026-10-08", undefined, 0), store)
  assert.equal(Tasks.restore(store, "2026-10-08", "id1", 0), store, "a bare id is not a task")
})

test("remove of an unknown id is a no-op", () => {
  const before = storeWith([task({ id: "id1" })])
  assert.equal(Tasks.remove(before, "2026-10-08", "nope"), before)
})

test("setContent updates name and note together, or neither", () => {
  const base = Tasks.add(Tasks.empty(), "2026-10-08", "Old", "id1", "17:00", 2, "old note")
  const after = Tasks.setContent(base, "2026-10-08", "id1", "  New  ", "  new note  ")
  const t = after.days["2026-10-08"][0]
  assert.equal(t.text, "New")
  assert.equal(t.note, "new note")
  assert.equal(t.dueTime, "17:00", "setContent must keep the deadline")
  assert.equal(t.remindDaysBefore, 2, "setContent must keep the reminder")
  assert.equal(t.id, "id1")
})

test("setContent refuses an empty name and changes nothing", () => {
  const base = Tasks.add(Tasks.empty(), "2026-10-08", "Kept", "id1", "17:00", 1, "note")
  const after = Tasks.setContent(base, "2026-10-08", "id1", "   ", "other")
  assert.equal(after, base)
  assert.equal(after.days["2026-10-08"][0].text, "Kept")
  assert.equal(after.days["2026-10-08"][0].note, "note")
})

test("setContent can clear the note but not the name", () => {
  const base = Tasks.add(Tasks.empty(), "2026-10-08", "Name", "id1", "", null, "note")
  const cleared = Tasks.setContent(base, "2026-10-08", "id1", "Name", "")
  assert.equal(cleared.days["2026-10-08"][0].note, "")
  assert.equal(Tasks.setContent(base, "2026-10-08", "nope", "X", "x"), base)
})

test("setFields changes the deadline and reminder, nothing else", () => {
  const base = Tasks.add(Tasks.empty(), "2026-10-08", "Name", "id1", "", null, "note")
  const after = Tasks.setFields(base, "2026-10-08", "id1", "18:30", 4)
  const t = after.days["2026-10-08"][0]
  assert.equal(t.dueTime, "18:30")
  assert.equal(t.remindDaysBefore, 4)
  assert.equal(t.text, "Name")
  assert.equal(t.note, "note")
  assert.equal(t.done, false)
})

test("setFields can clear either field", () => {
  const base = Tasks.add(Tasks.empty(), "2026-10-08", "Name", "id1", "17:00", 2, "")
  const noDue = Tasks.setFields(base, "2026-10-08", "id1", "", 2)
  assert.equal(noDue.days["2026-10-08"][0].dueTime, "")
  assert.equal(noDue.days["2026-10-08"][0].remindDaysBefore, 2)
  const noRemind = Tasks.setFields(base, "2026-10-08", "id1", "17:00", null)
  assert.equal(noRemind.days["2026-10-08"][0].dueTime, "17:00")
  assert.equal(noRemind.days["2026-10-08"][0].remindDaysBefore, null)
})

test("setFields on an unknown id or day is a no-op", () => {
  const base = Tasks.add(Tasks.empty(), "2026-10-08", "Name", "id1", "", null, "")
  assert.equal(Tasks.setFields(base, "2026-10-08", "nope", "18:00", 1), base)
  assert.equal(Tasks.setFields(base, "2026-10-09", "id1", "18:00", 1), base)
})

test("a task keeps its done flag through an edit", () => {
  const base = Tasks.add(Tasks.empty(), "2026-10-08", "Old", "id1", "17:00", 1, "")
  const done = Tasks.toggle(base, "2026-10-08", "id1")
  const edited = Tasks.setContent(done, "2026-10-08", "id1", "Edited", "")
  assert.equal(edited.days["2026-10-08"][0].done, true)
})

// ---- Listing --------------------------------------------------------------

test("counts split outstanding from finished", () => {
  const store = storeWith([
    task({ id: "a", done: false }),
    task({ id: "b", done: true }),
    task({ id: "c", done: false })
  ])
  assert.equal(Tasks.count(store, "2026-10-08"), 3)
  assert.equal(Tasks.pendingCount(store, "2026-10-08"), 2)
  assert.equal(Tasks.doneCount(store, "2026-10-08"), 1)
  assert.equal(Tasks.allDone(store, "2026-10-08"), false)
  assert.equal(Tasks.pendingCount(Tasks.empty(), "2026-10-08"), 0)
})

test("allDone needs tasks before it can be true", () => {
  assert.equal(Tasks.allDone(Tasks.empty(), "2026-10-08"), false)
  assert.equal(Tasks.allDone(storeWith([task({ id: "a", done: true })]), "2026-10-08"), true)
})

test("pendingGroups tags every task with the day it came from", () => {
  const store = { version: 2, days: {
    "2026-10-08": [task({ id: "a" })],
    "2026-10-13": [task({ id: "b" })]
  } }
  const groups = Tasks.pendingGroups(store)
  assert.equal(groups.length, 2)
  for (const g of groups) for (const t of g.tasks) assert.equal(t.dayKey, g.dayKey)
})

test("pendingGroups orders by day, then hour, and drops finished tasks", () => {
  const store = { version: 2, days: {
    "2026-10-13": [task({ id: "b", dueTime: "" })],
    "2026-10-08": [
      task({ id: "late", dueTime: "17:00" }),
      task({ id: "early", dueTime: "09:00" }),
      task({ id: "done", done: true, dueTime: "08:00" })
    ]
  } }
  const flat = Tasks.pendingGroups(store).flatMap(g => g.tasks.map(t => t.id))
  assert.deepEqual(flat, ["early", "late", "b"], "dated first, by day then hour; finished excluded")
})

test("tasks without a deadline sit last, still in day order", () => {
  const store = { version: 2, days: {
    "2026-10-13": [task({ id: "b", dueTime: "" })],
    "2026-10-08": [task({ id: "dated", dueTime: "17:00" }), task({ id: "b1", dueTime: "" })]
  } }
  const flat = Tasks.pendingGroups(store).flatMap(g => g.tasks.map(t => t.id))
  assert.deepEqual(flat, ["dated", "b1", "b"])
})

test("pendingGroupSummary agrees with pendingGroups", () => {
  const store = { version: 2, days: {
    "2026-10-08": [task({ id: "a" }), task({ id: "b", done: true })],
    "2026-10-13": [task({ id: "c" })]
  } }
  assert.deepEqual(Tasks.pendingGroupSummary(store), { groups: 2, tasks: 2 })
  assert.deepEqual(Tasks.pendingGroupSummary(Tasks.empty()), { groups: 0, tasks: 0 })
})

test("pendingGroups survives a store with nothing sensible in it", () => {
  assert.deepEqual(Tasks.pendingGroups({}), [])
  assert.deepEqual(Tasks.pendingGroups(null), [])
  assert.deepEqual(Tasks.pendingGroups({ days: { "not-a-day": [task()] } }), [])
  assert.deepEqual(Tasks.pendingGroups({ days: { "2026-10-08": "not a list" } }), [])
})

test("doneGroups tags every finished task with the day it came from", () => {
  const store = { version: 2, days: {
    "2026-10-08": [task({ id: "a", done: true })],
    "2026-10-13": [task({ id: "b", done: true })]
  } }
  const groups = Tasks.doneGroups(store)
  assert.equal(groups.length, 2)
  for (const g of groups) for (const t of g.tasks) assert.equal(t.dayKey, g.dayKey)
})

test("doneGroups keeps only finished tasks, newest day first", () => {
  const store = { version: 2, days: {
    "2026-10-08": [
      task({ id: "open", done: false }),
      task({ id: "first", done: true }),
      task({ id: "second", done: true })
    ],
    "2026-10-13": [task({ id: "later", done: true })]
  } }
  const groups = Tasks.doneGroups(store)
  assert.deepEqual(groups.map(g => g.dayKey), ["2026-10-13", "2026-10-08"])
  assert.deepEqual(groups.flatMap(g => g.tasks.map(t => t.id)), ["later", "first", "second"])
})

test("doneGroups survives a store with nothing sensible in it", () => {
  assert.deepEqual(Tasks.doneGroups({}), [])
  assert.deepEqual(Tasks.doneGroups(null), [])
  assert.deepEqual(Tasks.doneGroups({ days: { "not-a-day": [task({ done: true })] } }), [])
  assert.deepEqual(Tasks.doneGroups({ days: { "2026-10-08": [task({ done: false })] } }), [])
})

test("dotFlags reports outstanding-ness and stays capped", () => {
  const store = storeWith([task({ id: "a" }), task({ id: "b", done: true }), task({ id: "c" })])
  assert.deepEqual(Tasks.dotFlags(store, "2026-10-08"), [true, false, true])
  assert.equal(Tasks.dotFlags(store, "2026-10-08", 2).length, 2)
  // A limit of 0 means "use the default", not "draw none": the default is what
  // keeps a busy day from widening its cell into the neighbouring one.
  assert.equal(Tasks.dotFlags(store, "2026-10-08", 0).length, 3)
  const busy = storeWith(Array.from({ length: 9 }, (_, i) => task({ id: "t" + i })))
  assert.equal(Tasks.dotFlags(busy, "2026-10-08", 0).length, 6, "default cap is 6")
})

// ---- Deadlines and reminders ---------------------------------------------

test("hasDue and hasReminder read the cleaned value", () => {
  assert.equal(Tasks.hasDue({ dueTime: "17:00" }), true)
  assert.equal(Tasks.hasDue({ dueTime: "  " }), false)
  assert.equal(Tasks.hasDue({}), false)
  // 0 is the day the task is due, not "off": the store uses null for off.
  assert.equal(Tasks.hasReminder({ remindDaysBefore: 0 }), true)
  // Above the maximum clamps to the maximum, so it still counts as a reminder.
  assert.equal(Tasks.hasReminder({ remindDaysBefore: Tasks.MAX_REMIND_DAYS + 4 }), true)
  assert.equal(Tasks.hasReminder({ remindDaysBefore: null }), false)
  assert.equal(Tasks.hasReminder({ remindDaysBefore: undefined }), false)
  assert.equal(Tasks.hasReminder({ remindDaysBefore: -1 }), false)
  assert.equal(Tasks.hasReminder({}), false)
})

test("reminderDayKey walks backwards by the right number of days", () => {
  assert.equal(Tasks.reminderDayKey("2026-10-08", 0), "2026-10-08")
  assert.equal(Tasks.reminderDayKey("2026-10-08", 1), "2026-10-07")
  assert.equal(Tasks.reminderDayKey("2026-10-08", 5), "2026-10-03")
  assert.equal(Tasks.reminderDayKey("2026-10-08", 7), "2026-10-01")
})

test("reminderDayKey crosses month, year and leap boundaries", () => {
  assert.equal(Tasks.reminderDayKey("2026-10-01", 1), "2026-09-30")
  assert.equal(Tasks.reminderDayKey("2026-01-01", 1), "2025-12-31")
  assert.equal(Tasks.reminderDayKey("2024-03-01", 1), "2024-02-29", "leap year")
  assert.equal(Tasks.reminderDayKey("2026-03-01", 1), "2026-02-28", "non-leap year")
  assert.equal(Tasks.reminderDayKey("2026-01-01", 5), "2025-12-27")
})

test("reminderDayKey refuses what it cannot read", () => {
  assert.equal(Tasks.reminderDayKey("not-a-day", 1), "")
  assert.equal(Tasks.reminderDayKey("2026-10-08", null), "")
  assert.equal(Tasks.reminderDayKey("2026-10-08", "x"), "")
  assert.equal(Tasks.reminderDayKey("2026-10-08", -1), "")
  // Past a year it clamps to the year rather than refusing, so a hand-edited
  // 400 still points at a real day instead of at nothing.
  assert.equal(Tasks.reminderDayKey("2026-10-08", 400), "2025-10-08")
  // Past the chips but under the ceiling is a value the field could have
  // typed, and it walks the same distance as any other.
  assert.equal(Tasks.reminderDayKey("2026-10-08", 9), "2026-09-29")
  assert.equal(Tasks.reminderDayKey("2026-10-08", 7), "2026-10-01")
  assert.equal(Tasks.reminderDayKey("2026-10-08", 365), "2025-10-08")
})

test("remindDaysLabel and remindDaysShort say the same thing in English", () => {
  assert.equal(Tasks.remindDaysLabel(0), "on the due date")
  assert.equal(Tasks.remindDaysLabel(1), "the day before")
  assert.equal(Tasks.remindDaysLabel(3), "3 days before")
  assert.equal(Tasks.remindDaysLabel(7), "7 days before")
  assert.equal(Tasks.remindDaysLabel(12), "12 days before")
  assert.equal(Tasks.remindDaysLabel(null), "")
  assert.equal(Tasks.remindDaysShort(0), "today")
  assert.equal(Tasks.remindDaysShort(1), "1d")
  assert.equal(Tasks.remindDaysShort(12), "12d")
  assert.equal(Tasks.remindDaysShort(null), "")
})

test("isOverdue is about the clock, not about the colour", () => {
  const t = task({ dueTime: "17:00", dayKey: "2026-10-08" })
  assert.equal(Tasks.isOverdue(t, "2026-10-08", 16 * 60 + 59), false, "one minute early")
  assert.equal(Tasks.isOverdue(t, "2026-10-08", 17 * 60 + 1), true, "past it")
  assert.equal(Tasks.isOverdue(t, "2026-10-09", 0), true, "the whole of a later day")
  assert.equal(Tasks.isOverdue(t, "2026-10-07", 23 * 60), false, "an earlier day")
})

test("isOverdue ignores tasks with no deadline or that are finished", () => {
  assert.equal(Tasks.isOverdue(task({ dueTime: "" }), "2026-10-08", 999), false)
  assert.equal(Tasks.isOverdue(task({ dueTime: "17:00", done: true }), "2026-10-09", 0), false)
  assert.equal(Tasks.isOverdue(task({ dueTime: "17:00" }), "not-a-day", 0), false)
  assert.equal(Tasks.isOverdue(task({ dueTime: "17:00" }), "2026-10-08", 0), false, "no dayKey to judge it against")
})

test("minutesNow counts from midnight", () => {
  assert.equal(Tasks.minutesNow(new Date(2026, 0, 1, 17, 5)), 17 * 60 + 5)
  assert.equal(Tasks.minutesNow(new Date(2026, 0, 1, 0, 0)), 0)
  assert.equal(Tasks.minutesNow(new Date(2026, 0, 1, 23, 59)), 23 * 60 + 59)
})

// ---- Reminders the panel should be offering --------------------------------

// activeReminders is the panel's own view of "what should be nagging", and it
// keeps a window rather than a single day: anything whose reminder day has
// already gone is dropped (a store holds years of history, and re-arming
// March's Tuesday is worse than doing nothing), while today and anything
// still to come are kept.
test("activeReminders keeps what has not passed and drops the rest", () => {
  const store = { version: 2, days: {
    "2026-10-08": [
      task({ id: "today", remindDaysBefore: 0 }),
      task({ id: "ago", remindDaysBefore: 1 }),
      task({ id: "done", done: true, remindDaysBefore: 0 }),
      task({ id: "off", remindDaysBefore: null }),
      task({ id: "weekAgo", remindDaysBefore: 5 })
    ],
    "2026-10-10": [
      task({ id: "future", remindDaysBefore: 1 })
    ]
  } }
  const ids = Tasks.activeReminders(store, "2026-10-08").map(t => t.id).sort()
  assert.deepEqual(ids, ["future", "today"])
})

test("activeReminders carries the day each task nags on", () => {
  const store = { version: 2, days: {
    "2026-10-10": [task({ id: "a", remindDaysBefore: 2 })]
  } }
  const [row] = Tasks.activeReminders(store, "2026-10-08")
  assert.equal(row.remindDayKey, "2026-10-08", "the day it nags on")
  assert.equal(row.dayKey, "2026-10-10", "the day the task belongs to")
})

test("activeReminders is indifferent to a broken store", () => {
  assert.deepEqual(Tasks.activeReminders(null, "2026-10-08"), [])
  assert.deepEqual(Tasks.activeReminders({ days: { "nope": [task()] } }, "2026-10-08"), [])
})

// ---- Priority and tags ----------------------------------------------------

test("cleanPriority accepts the three levels and rejects the rest", () => {
  assert.equal(Tasks.cleanPriority("high"), "high")
  assert.equal(Tasks.cleanPriority("HIGH"), "high")
  assert.equal(Tasks.cleanPriority("medium"), "medium")
  assert.equal(Tasks.cleanPriority("low"), "low")
  assert.equal(Tasks.cleanPriority("urgent"), null)
  assert.equal(Tasks.cleanPriority(""), null)
  assert.equal(Tasks.cleanPriority(null), null)
  assert.equal(Tasks.cleanPriority(undefined), null)
})

test("cleanTags strips hashes, trims, deduplicates and drops empties", () => {
  assert.deepEqual(Tasks.cleanTags(["#work", "work", " personal ", "#", ""]), ["work", "personal"])
  assert.deepEqual(Tasks.cleanTags("not an array"), [])
  assert.deepEqual(Tasks.cleanTags(null), [])
  assert.deepEqual(Tasks.cleanTags([]), [])
})

test("normalize includes priority and tags", () => {
  const store = Tasks.parse(JSON.stringify({
    version: 2,
    days: { "2026-10-08": [{ id: "a", text: "Task", priority: "high", tags: ["#work", "urgent"] }] }
  }))
  const t = store.days["2026-10-08"][0]
  assert.equal(t.priority, "high")
  assert.deepEqual(t.tags, ["work", "urgent"])
})

test("copy preserves priority and tags", () => {
  const store = storeWith([task({ priority: "low", tags: ["home"] })])
  const copied = Tasks.copy(store.days["2026-10-08"][0])
  assert.equal(copied.priority, "low")
  assert.deepEqual(copied.tags, ["home"])
})

test("serialize round-trips priority and tags", () => {
  const store = storeWith([task({ priority: "medium", tags: ["a", "b"] })])
  const parsed = Tasks.parse(Tasks.serialize(store))
  const t = parsed.days["2026-10-08"][0]
  assert.equal(t.priority, "medium")
  assert.deepEqual(t.tags, ["a", "b"])
})

test("setPriority updates only the priority", () => {
  const store = storeWith([task({ id: "a", text: "Task", tags: ["work"] })])
  const next = Tasks.setPriority(store, "2026-10-08", "a", "high")
  const t = next.days["2026-10-08"][0]
  assert.equal(t.priority, "high")
  assert.equal(t.text, "Task")
  assert.deepEqual(t.tags, ["work"])
})

test("setPriority rejects invalid values", () => {
  const store = storeWith([task({ id: "a", priority: "high" })])
  const next = Tasks.setPriority(store, "2026-10-08", "a", "urgent")
  assert.equal(next.days["2026-10-08"][0].priority, null)
})

test("setTags updates only the tags", () => {
  const store = storeWith([task({ id: "a", text: "Task", priority: "low" })])
  const next = Tasks.setTags(store, "2026-10-08", "a", ["#work", "personal"])
  const t = next.days["2026-10-08"][0]
  assert.deepEqual(t.tags, ["work", "personal"])
  assert.equal(t.priority, "low")
})

test("setTags rejects non-arrays", () => {
  const store = storeWith([task({ id: "a", tags: ["work"] })])
  const next = Tasks.setTags(store, "2026-10-08", "a", "not an array")
  assert.deepEqual(next.days["2026-10-08"][0].tags, [])
})

// ---- Time until deadline --------------------------------------------------

test("timeUntil returns human-readable remaining time", () => {
  assert.equal(Tasks.timeUntil("2026-10-08", "17:00", "2026-10-08", 540), "8h 0m")
  assert.equal(Tasks.timeUntil("2026-10-08", "17:00", "2026-10-08", 600), "7h 0m")
  assert.equal(Tasks.timeUntil("2026-10-08", "17:00", "2026-10-08", 630), "6h 30m")
  assert.equal(Tasks.timeUntil("2026-10-10", "09:00", "2026-10-08", 540), "2d 0h")
  assert.equal(Tasks.timeUntil("2026-10-12", "17:00", "2026-10-08", 540), "4d 8h")
})

test("timeUntil returns empty for past deadlines", () => {
  assert.equal(Tasks.timeUntil("2026-10-08", "17:00", "2026-10-08", 1100), "")
  assert.equal(Tasks.timeUntil("2026-10-07", "17:00", "2026-10-08", 540), "")
})

test("timeUntil returns empty for missing deadline", () => {
  assert.equal(Tasks.timeUntil("2026-10-08", "", "2026-10-08", 540), "")
  assert.equal(Tasks.timeUntil("2026-10-08", null, "2026-10-08", 540), "")
})

// ---- Statistics -----------------------------------------------------------

test("completedOn checks done and day", () => {
  const t = task({ done: true, dayKey: "2026-10-08" })
  assert.equal(Tasks.completedOn(t, "2026-10-08"), true)
  assert.equal(Tasks.completedOn(t, "2026-10-09"), false)
  assert.equal(Tasks.completedOn(task({ done: false, dayKey: "2026-10-08" }), "2026-10-08"), false)
})

test("streak counts consecutive days with completions", () => {
  const store = { version: 2, days: {
    "2026-10-08": [task({ done: true })],
    "2026-10-07": [task({ done: true })],
    "2026-10-06": [task({ done: true })],
    "2026-10-05": [task({ done: false })]
  } }
  assert.equal(Tasks.streak(store, "2026-10-08"), 3)
})

test("streak returns 0 when today has no completions", () => {
  const store = { version: 2, days: {
    "2026-10-08": [task({ done: false })],
    "2026-10-07": [task({ done: true })]
  } }
  assert.equal(Tasks.streak(store, "2026-10-08"), 0)
})

test("streak handles empty stores", () => {
  assert.equal(Tasks.streak(Tasks.empty(), "2026-10-08"), 0)
  assert.equal(Tasks.streak(null, "2026-10-08"), 0)
})

// ---- Searching ------------------------------------------------------------

test("searchNeedle trims and lowercases", () => {
  assert.equal(Tasks.searchNeedle("  Work  "), "work")
  assert.equal(Tasks.searchNeedle(null), "")
  assert.equal(Tasks.searchNeedle(undefined), "")
  assert.equal(Tasks.searchNeedle("   "), "")
})

test("matchesQuery looks at name, note and tags", () => {
  const t = task({ text: "Buy milk", note: "from the corner shop", tags: ["errands"] })
  assert.equal(Tasks.matchesQuery(t, "milk"), true)
  assert.equal(Tasks.matchesQuery(t, "CORNER"), true)
  assert.equal(Tasks.matchesQuery(t, "errands"), true)
  assert.equal(Tasks.matchesQuery(t, "laundry"), false)
})

test("matchesQuery matches everything on an empty needle", () => {
  const t = task({ text: "Anything" })
  assert.equal(Tasks.matchesQuery(t, ""), true)
  assert.equal(Tasks.matchesQuery(t, "   "), true)
  assert.equal(Tasks.matchesQuery(null, ""), true)
  assert.equal(Tasks.matchesQuery(null, "x"), false)
})

test("matchesQuery handles a task with no tags", () => {
  const bare = { id: "a", text: "Bare", tags: undefined }
  assert.equal(Tasks.matchesQuery(bare, "bare"), true)
  assert.equal(Tasks.matchesQuery(bare, "nothing"), false)
})

test("filterTasks keeps only the matches", () => {
  const list = [
    task({ id: "a", text: "Write report" }),
    task({ id: "b", text: "Call Ana" }),
    task({ id: "c", text: "Review report", note: "second pass" })
  ]
  assert.deepEqual(Tasks.filterTasks(list, "report").map(t => t.id), ["a", "c"])
  assert.equal(Tasks.filterTasks(list, "").length, 3, "empty query is a pass-through")
  assert.deepEqual(Tasks.filterTasks(null, "x"), [])
})

test("filterTasks matches on a tag", () => {
  const list = [task({ id: "a", tags: ["work"] }), task({ id: "b", tags: ["home"] })]
  assert.deepEqual(Tasks.filterTasks(list, "work").map(t => t.id), ["a"])
})

test("filterGroups drops groups left empty", () => {
  const groups = [
    { dayKey: "2026-10-08", tasks: [task({ id: "a", text: "Report" })] },
    { dayKey: "2026-10-09", tasks: [task({ id: "b", text: "Gym" })] }
  ]
  const filtered = Tasks.filterGroups(groups, "report")
  assert.equal(filtered.length, 1)
  assert.equal(filtered[0].dayKey, "2026-10-08")
  assert.equal(filtered[0].tasks.length, 1)
})

test("filterGroups keeps group identity and passes a search through", () => {
  const groups = [{ dayKey: "2026-10-08", tasks: [task({ id: "a" })] }]
  assert.equal(Tasks.filterGroups(groups, "").length, 1, "empty query keeps the store's own array shape")
  assert.deepEqual(Tasks.filterGroups(null, "x"), [])
  assert.deepEqual(Tasks.filterGroups("nope", "x"), [])
})

test("groupSummary counts the groups it is handed", () => {
  const groups = [
    { dayKey: "2026-10-08", tasks: [task(), task()] },
    { dayKey: "2026-10-09", tasks: [task()] }
  ]
  assert.deepEqual(Tasks.groupSummary(groups), { groups: 2, tasks: 3 })
  assert.deepEqual(Tasks.groupSummary([]), { groups: 0, tasks: 0 })
  assert.deepEqual(Tasks.groupSummary(null), { groups: 0, tasks: 0 })
})

// ---- Priority labels ------------------------------------------------------

test("priorityLabel names the three levels and nothing else", () => {
  assert.equal(Tasks.priorityLabel("high"), "High")
  assert.equal(Tasks.priorityLabel("medium"), "Medium")
  assert.equal(Tasks.priorityLabel("low"), "Low")
  assert.equal(Tasks.priorityLabel("HIGH"), "High")
  assert.equal(Tasks.priorityLabel("urgent"), "")
  assert.equal(Tasks.priorityLabel(null), "")
  assert.equal(Tasks.priorityLabel(undefined), "")
})

test("priorityGlyph draws a mark per level, empty when unset", () => {
  assert.equal(Tasks.priorityGlyph("high"), "▲")
  assert.equal(Tasks.priorityGlyph("medium"), "●")
  assert.equal(Tasks.priorityGlyph("low"), "○")
  assert.equal(Tasks.priorityGlyph("nonsense"), "")
  assert.equal(Tasks.priorityGlyph(null), "")
})

test("nextPriority walks none → high → medium → low → none", () => {
  assert.equal(Tasks.nextPriority(null), "high")
  assert.equal(Tasks.nextPriority("high"), "medium")
  assert.equal(Tasks.nextPriority("medium"), "low")
  assert.equal(Tasks.nextPriority("low"), null)

  // Four presses from a standing start are back where they started, so the
  // control cannot strand a value it has no way out of — including "none",
  // which has to be reachable again and not only on the way in.
  let p = null
  for (let i = 0; i < 4; i++) p = Tasks.nextPriority(p)
  assert.equal(p, null)

  // Anything the store would refuse reads as none, and none is where the
  // cycle begins: a value it does not recognise walks out of itself instead
  // of being stuck in it.
  assert.equal(Tasks.nextPriority("urgent"), "high")
  assert.equal(Tasks.nextPriority(undefined), "high")
  assert.equal(Tasks.nextPriority(""), "high")
  assert.equal(Tasks.nextPriority("HIGH"), "medium")
})

// ---- Tag filtering --------------------------------------------------------

test("matchesTag is whole-tag, not a substring", () => {
  const t = { tags: ["work", "homework-debt"] }
  assert.equal(Tasks.matchesTag(t, "work"), true)
  assert.equal(Tasks.matchesTag(t, "#work"), true)
  assert.equal(Tasks.matchesTag(t, "WORK"), true)
  assert.equal(Tasks.matchesTag(t, "wor"), false)
  assert.equal(Tasks.matchesTag(t, "homework"), false)
  assert.equal(Tasks.matchesTag(t, "garden"), false)
})

test("matchesTag cleans the stored tags before comparing", () => {
  const t = { tags: [" #Home ", "home", "", 5] }
  assert.equal(Tasks.matchesTag(t, "home"), true)
  assert.equal(Tasks.matchesTag(t, "5"), true)
  assert.equal(Tasks.matchesTag(t, ""), true)
})

test("matchesTag tolerates a task with no tags and no task at all", () => {
  assert.equal(Tasks.matchesTag({}, "work"), false)
  assert.equal(Tasks.matchesTag(null, "work"), false)
  assert.equal(Tasks.matchesTag(undefined, "work"), false)
})

test("filterByTag keeps order, drops non-matches, and treats empty as all", () => {
  const list = [
    { text: "a", tags: ["work"] },
    { text: "b", tags: ["home"] },
    { text: "c", tags: ["work", "home"] },
    { text: "d" }
  ]
  assert.deepEqual(Tasks.filterByTag(list, "work").map(t => t.text), ["a", "c"])
  assert.deepEqual(Tasks.filterByTag(list, "#home").map(t => t.text), ["b", "c"])
  assert.deepEqual(Tasks.filterByTag(list, "").map(t => t.text), ["a", "b", "c", "d"])
  assert.deepEqual(Tasks.filterByTag(list, null).map(t => t.text), ["a", "b", "c", "d"])
  assert.deepEqual(Tasks.filterByTag(list, "nothing").map(t => t.text), [])
  assert.deepEqual(Tasks.filterByTag("not a list", "work"), [])
})

test("filterByTag returns a fresh array rather than the caller's", () => {
  const list = [{ text: "a", tags: ["work"] }]
  const out = Tasks.filterByTag(list, "")
  assert.notEqual(out, list)
  out.pop()
  assert.equal(list.length, 1)
})

test("tagCounts lists each tag once with its tally, in first-seen order", () => {
  const list = [
    { text: "a", tags: ["work", "urgent"] },
    { text: "b", tags: ["home"] },
    { text: "c", tags: ["work", "work"] },
    { text: "d" }
  ]
  assert.deepEqual(Tasks.tagCounts(list), [
    { tag: "work", count: 2 },
    { tag: "urgent", count: 1 },
    { tag: "home", count: 1 }
  ])
  assert.deepEqual(Tasks.tagCounts("nope"), [])
  assert.deepEqual(Tasks.tagCounts([{ text: "a" }]), [])
})

test("a tag counts once per task even when the store lists it twice", () => {
  assert.deepEqual(Tasks.tagCounts([{ text: "a", tags: ["work", "work"] }]),
    [{ tag: "work", count: 1 }])
})

test("filterGroups honours the tag and drops the days it empties", () => {
  const groups = [
    { dayKey: "2026-10-07", tasks: [{ text: "a", tags: ["work"] }, { text: "b", tags: ["home"] }] },
    { dayKey: "2026-10-08", tasks: [{ text: "c", tags: ["home"] }] }
  ]
  const byTag = Tasks.filterGroups(groups, "", "work")
  assert.deepEqual(byTag.map(g => g.dayKey), ["2026-10-07"])
  assert.deepEqual(byTag[0].tasks.map(t => t.text), ["a"])

  const both = Tasks.filterGroups(groups, "b", "home")
  assert.deepEqual(both.map(g => g.dayKey), ["2026-10-07"])
  assert.deepEqual(both[0].tasks.map(t => t.text), ["b"])

  const none = Tasks.filterGroups(groups, "", "garden")
  assert.deepEqual(none, [])
})

test("filterGroups with no query and no tag returns a fresh copy", () => {
  const groups = [{ dayKey: "2026-10-07", tasks: [{ text: "a" }] }]
  const out = Tasks.filterGroups(groups, "")
  assert.notEqual(out, groups)
  assert.deepEqual(out, groups)
})

test("tagNeedle strips the hash and the edges, and settles on empty", () => {
  assert.equal(Tasks.tagNeedle("#Work "), "Work")
  assert.equal(Tasks.tagNeedle("  home"), "home")
  assert.equal(Tasks.tagNeedle(""), "")
  assert.equal(Tasks.tagNeedle(null), "")
  assert.equal(Tasks.tagNeedle(undefined), "")
})

// ---- Two spellings of one tag ---------------------------------------------

test("cleanTags keeps one spelling of a tag, and keeps the first one", () => {
  assert.deepEqual(Tasks.cleanTags(["Work", "work", "WORK"]), ["Work"])
  assert.deepEqual(Tasks.cleanTags(["#home", "Home"]), ["#home".replace(/^#/, "")])
  assert.deepEqual(Tasks.cleanTags(["urgent", "Urgent", "urgent"]), ["urgent"])
})

test("cleanTags still drops empties and does not lose other tags", () => {
  assert.deepEqual(Tasks.cleanTags(["Work", "", "  ", "home", "work"]), ["Work", "home"])
})

test("tagCounts folds case across tasks so one tag is one chip", () => {
  const list = [
    { text: "a", tags: ["Work"] },
    { text: "b", tags: ["work"] },
    { text: "c", tags: ["WORK", "home"] }
  ]
  assert.deepEqual(Tasks.tagCounts(list), [
    { tag: "Work", count: 3 },
    { tag: "home", count: 1 }
  ])
})

test("tagCounts keeps the first spelling it saw", () => {
  const list = [
    { text: "a", tags: ["home"] },
    { text: "b", tags: ["Home"] }
  ]
  assert.deepEqual(Tasks.tagCounts(list), [{ tag: "home", count: 2 }])
})

test("a task tagged two ways is found under either spelling", () => {
  const list = [{ text: "a", tags: ["Work"] }]
  assert.equal(Tasks.filterByTag(list, "work").length, 1)
  assert.equal(Tasks.filterByTag(list, "WORK").length, 1)
})

// ---- Statistics -----------------------------------------------------------

test("countDone counts only the finished tasks on that day", () => {
  let s = Tasks.empty()
  s = Tasks.add(s, "2026-10-07", "a", "id1", "", null, "")
  s = Tasks.add(s, "2026-10-07", "b", "id2", "", null, "")
  s = Tasks.add(s, "2026-10-08", "c", "id3", "", null, "")
  assert.equal(Tasks.countDone(s, "2026-10-07"), 0)
  s = Tasks.toggle(s, "2026-10-07", "id1")
  s = Tasks.toggle(s, "2026-10-08", "id3")
  assert.equal(Tasks.countDone(s, "2026-10-07"), 1)
  assert.equal(Tasks.countDone(s, "2026-10-08"), 1)
  assert.equal(Tasks.countDone(s, "2026-10-09"), 0)
  assert.equal(Tasks.countDone(s, "not-a-key"), 0)
  assert.equal(Tasks.countDone(null, "2026-10-07"), 0)
})

test("countDoneInRange is inclusive and accepts either order", () => {
  let s = Tasks.empty()
  for (const k of ["2026-10-05", "2026-10-07", "2026-10-09", "2026-10-12"]) {
    s = Tasks.add(s, k, "t-" + k, "id-" + k, "", null, "")
    s = Tasks.toggle(s, k, "id-" + k)
  }
  assert.equal(Tasks.countDoneInRange(s, "2026-10-07", "2026-10-09"), 2)
  assert.equal(Tasks.countDoneInRange(s, "2026-10-09", "2026-10-07"), 2)
  assert.equal(Tasks.countDoneInRange(s, "2026-10-01", "2026-10-31"), 4)
  assert.equal(Tasks.countDoneInRange(s, "2026-10-08", "2026-10-08"), 0)
  assert.equal(Tasks.countDoneInRange(s, "2026-10-10", "2026-10-11"), 0)
  assert.equal(Tasks.countDoneInRange(s, "bogus", "2026-10-09"), 0)
})

test("countDoneInRange ignores unfinished tasks", () => {
  let s = Tasks.add(Tasks.empty(), "2026-10-07", "open", "id1", "", null, "")
  assert.equal(Tasks.countDoneInRange(s, "2026-10-01", "2026-10-31"), 0)
})

test("countByPriority tallies the three levels and the unset", () => {
  const tasks = [
    { priority: "high" },
    { priority: "HIGH" },
    { priority: "medium" },
    { priority: "low" },
    { priority: "nonsense" },
    { priority: null },
    {}
  ]
  assert.deepEqual(Tasks.countByPriority(tasks), {
    high: 2, medium: 1, low: 1, none: 3
  })
  assert.deepEqual(Tasks.countByPriority("nope"), { high: 0, medium: 0, low: 0, none: 0 })
  assert.deepEqual(Tasks.countByPriority([]), { high: 0, medium: 0, low: 0, none: 0 })
})

test("dayKeyShift walks the calendar, and refuses a key that is not one", () => {
  assert.equal(Tasks.dayKeyShift("2026-10-07", -6), "2026-10-01")
  assert.equal(Tasks.dayKeyShift("2026-10-07", 0), "2026-10-07")
  assert.equal(Tasks.dayKeyShift("2026-10-07", 1), "2026-10-08")
  assert.equal(Tasks.dayKeyShift("2026-01-01", -1), "2025-12-31")
  assert.equal(Tasks.dayKeyShift("2026-12-31", 1), "2027-01-01")
  assert.equal(Tasks.dayKeyShift("2026-03-01", -1), "2026-02-28")
  assert.equal(Tasks.dayKeyShift("nonsense", 1), "")
  assert.equal(Tasks.dayKeyShift("", 1), "")
  assert.equal(Tasks.dayKeyShift(null, 1), "")
})
