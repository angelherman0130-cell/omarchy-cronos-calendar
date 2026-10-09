const test = require("node:test")
const assert = require("node:assert")
const Model = require("../Model.js")

// ---- monthGrid ------------------------------------------------------------

test("monthGrid returns six rows of seven days", () => {
  const weeks = Model.monthGrid(2026, 9, 1, "2026-10-07")
  assert.equal(weeks.length, 6)
  for (const w of weeks) assert.equal(w.days.length, 7)
})

test("monthGrid cells carry the shape the grid delegate reads", () => {
  const row = Model.monthGrid(2026, 9, 1, "2026-10-07")[1]
  const cell = row.days[0]
  assert.deepEqual(Object.keys(cell).sort(),
    ["day", "inMonth", "key", "month", "today", "weekday", "weekend", "year"].sort())
  assert.equal(cell.key, "2026-10-05")
  assert.equal(cell.weekday, 1)
  assert.equal(cell.inMonth, true)
  assert.equal(cell.weekend, false)
  assert.equal(cell.today, false)
  // The one cell carrying today, on the same row and the same week.
  const today = row.days.filter(d => d.today)
  assert.equal(today.length, 1)
  assert.equal(today[0].key, "2026-10-07")
})

test("monthGrid lays out from the week start, not from Sunday", () => {
  // October 2026 starts on a Thursday.
  const mondayFirst = Model.monthGrid(2026, 9, 1, "")
  const sundayFirst = Model.monthGrid(2026, 9, 0, "")
  assert.equal(mondayFirst[0].days[0].key, "2026-09-28")
  assert.equal(sundayFirst[0].days[0].key, "2026-09-27")
  assert.equal(mondayFirst[0].days[3].key, "2026-10-01")
})

test("monthGrid marks days outside the viewed month", () => {
  const weeks = Model.monthGrid(2026, 9, 1, "")
  assert.equal(weeks[0].days[0].inMonth, false)
  assert.equal(weeks[0].days[3].inMonth, true)
})

test("monthGrid numbers each row by the ISO week of its Thursday", () => {
  const weeks = Model.monthGrid(2026, 9, 1, "")
  assert.equal(weeks[0].week, 40)
  assert.equal(weeks[1].week, 41)
  assert.equal(weeks[5].week, 45)
})

test("monthGrid flags weekends regardless of the week start", () => {
  const weeks = Model.monthGrid(2026, 9, 1, "")
  const row = weeks[1].days
  assert.equal(row.find(d => d.weekday === 0).weekend, true)
  assert.equal(row.find(d => d.weekday === 6).weekend, true)
  assert.equal(row.find(d => d.weekday === 3).weekend, false)
})

// ---- weekGrid -------------------------------------------------------------

test("weekGrid returns the one week holding the anchor", () => {
  const week = Model.weekGrid("2026-10-07", 1, "2026-10-07")
  assert.equal(week.days.length, 7)
  assert.equal(week.days[0].key, "2026-10-05")
  assert.equal(week.days[6].key, "2026-10-11")
  assert.equal(week.week, 41)
})

test("weekGrid cells are the same shape monthGrid's are", () => {
  const cell = Model.weekGrid("2026-10-07", 1, "2026-10-07").days[2]
  assert.deepEqual(Object.keys(cell).sort(),
    ["day", "inMonth", "key", "month", "today", "weekday", "weekend", "year"].sort())
  assert.equal(cell.today, true)
  assert.equal(cell.key, "2026-10-07")
})

test("weekGrid starts on the configured week start", () => {
  assert.equal(Model.weekGrid("2026-10-07", 1, "").days[0].key, "2026-10-05")
  assert.equal(Model.weekGrid("2026-10-07", 0, "").days[0].key, "2026-10-04")
  assert.equal(Model.weekGrid("2026-10-07", 6, "").days[0].key, "2026-10-03")
})

test("weekGrid dims the days outside the anchor's month", () => {
  // 5 October is a Monday, so a week starting Sunday 4 Oct belongs to two
  // months once October ends — check a straddle at the month's close instead.
  const week = Model.weekGrid("2026-10-01", 1, "") // Thu 1 Oct, row = 28 Sep – 4 Oct
  assert.equal(week.days[0].key, "2026-09-28")
  assert.equal(week.days[0].inMonth, false)
  assert.equal(week.days[3].inMonth, true)
  assert.equal(week.week, 40)
})

test("weekGrid walks back to the previous week, keeping the same shape", () => {
  const week = Model.weekGrid("2026-09-30", 1, "")
  assert.equal(week.days[0].key, "2026-09-28")
  assert.equal(week.days[6].key, "2026-10-04")
  assert.equal(week.week, 40)
})

test("weekGrid numbers by the ISO week of its Thursday", () => {
  // 1 January 2026 is a Thursday, and it belongs to ISO week 1 of 2026.
  const week = Model.weekGrid("2026-01-01", 1, "")
  assert.equal(week.week, 1)
  assert.equal(week.days[0].key, "2025-12-29")
})

test("weekGrid refuses a key that is not a real day", () => {
  assert.equal(Model.weekGrid("nonsense", 1, ""), null)
  assert.equal(Model.weekGrid("", 1, ""), null)
  assert.equal(Model.weekGrid(null, 1, ""), null)
  assert.equal(Model.weekGrid("2026-02-30", 1, ""), null)
  assert.equal(Model.weekGrid("2026-13-01", 1, ""), null)
})

test("weekGrid flags the weekend the same way monthGrid does", () => {
  const days = Model.weekGrid("2026-10-07", 1, "").days
  assert.equal(days.filter(d => d.weekend).length, 2)
  assert.equal(days.filter(d => d.weekday === 0)[0].weekend, true)
  assert.equal(days.filter(d => d.weekday === 6)[0].weekend, true)
})

// ---- parseDayKey ----------------------------------------------------------

test("parseDayKey reads a key and refuses everything else", () => {
  assert.equal(Model.parseDayKey("2026-10-07").getDate(), 7)
  assert.equal(Model.parseDayKey("2026-01-01").getMonth(), 0)
  assert.equal(Model.parseDayKey("2026-10-07").getHours(), 0)
  assert.equal(Model.parseDayKey("2026-10-7"), null)
  assert.equal(Model.parseDayKey("07-10-2026"), null)
  assert.equal(Model.parseDayKey("2026-10-07x"), null)
  assert.equal(Model.parseDayKey("2026-02-29"), null)
  assert.equal(Model.parseDayKey("2028-02-29") !== null, true)
  assert.equal(Model.parseDayKey(""), null)
  assert.equal(Model.parseDayKey(null), null)
})
