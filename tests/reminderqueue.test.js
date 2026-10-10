// Tests for ReminderQueue.js — the rules that decide whether a queued
// reminder interrupts you, runnable under plain node:
//
//   node --test tests/*.test.js
//
// Kept beside Tasks.js and Model.js for the reason they are kept there: this
// is the half of the reminder path that can be checked without a screen. The
// QML that draws the card has to be eyeballed; whether a card appears, and
// why it would not, is arithmetic on the queue file's fields.
//
// The reasons are asserted as much as the outcomes. A reminder that does not
// arrive is a bug that looks exactly like a reminder nobody wrote, so the
// string the shell logs is the only thing that ever tells them apart.

const { test } = require("node:test")
const assert = require("node:assert/strict")
const path = require("node:path")

const Queue = require(path.join(__dirname, "..", "ReminderQueue.js"))

const NOW = 1791600000

// The batch shape ClockReminders.sh writes, with whatever the case wants to
// change about it.
function batch(overrides) {
  const b = {
    version: 1,
    at: NOW,
    run: NOW + "-4242",
    items: [{ text: "Ship it", body: "Due 10/10 at 17:00" }]
  }
  return Object.assign(b, overrides || {})
}

function pick(raw, now, lastRun) {
  return Queue.pick(raw, now === undefined ? NOW : now, lastRun || "")
}

function asJson(overrides) {
  return JSON.stringify(batch(overrides))
}

test("a fresh batch is shown, with its items and its run id", () => {
  const verdict = pick(asJson())
  assert.equal(verdict.show, true)
  assert.equal(verdict.reason, "fresh")
  assert.equal(verdict.run, NOW + "-4242")
  assert.deepEqual(verdict.items, [{ text: "Ship it", body: "Due 10/10 at 17:00" }])
})

test("the title and body are handed through untouched", () => {
  const verdict = pick(asJson({ items: [{ text: '50% "done"', body: "No deadline time" }] }))
  assert.equal(verdict.show, true)
  assert.equal(verdict.items[0].text, '50% "done"')
  assert.equal(verdict.items[0].body, "No deadline time")
})

test("several reminders in one batch all arrive", () => {
  const verdict = pick(asJson({ items: [{ text: "a" }, { text: "b" }, { text: "c" }] }))
  assert.equal(verdict.show, true)
  assert.equal(verdict.items.length, 3)
})

test("an item that is not an object still renders as something", () => {
  // The card reads .text and .body and guards both; the queue's job is to
  // deliver bytes, not to have opinions about them.
  const verdict = pick(asJson({ items: ["just a string"] }))
  assert.equal(verdict.show, true)
  assert.deepEqual(verdict.items, ["just a string"])
})

test("the age limit is fifteen minutes", () => {
  assert.equal(Queue.MAX_AGE_SECONDS, 900)
})

test("a batch at the age limit is still shown", () => {
  const verdict = pick(asJson(), NOW + 900)
  assert.equal(verdict.show, true)
})

test("one second past the limit is stale", () => {
  const verdict = pick(asJson(), NOW + 901)
  assert.equal(verdict.show, false)
  assert.equal(verdict.reason, "stale")
})

test("a batch written seconds ago is fresh", () => {
  assert.equal(pick(asJson(), NOW + 5).show, true)
})

test("a timestamp from slightly in the future is shown, not rejected", () => {
  // A shell whose clock runs behind the script's would otherwise never show
  // anything at all, and a two-minute skew is a normal thing for a laptop.
  const verdict = pick(asJson(), NOW - 120)
  assert.equal(verdict.show, true)
  assert.equal(verdict.reason, "fresh")
})

test("the same batch reported twice shows once", () => {
  const raw = asJson()
  assert.equal(pick(raw).show, true)
  assert.equal(pick(raw, NOW, NOW + "-4242").show, false)
  assert.equal(pick(raw, NOW, NOW + "-4242").reason, "repeat")
})

test("a different batch after the first one shows again", () => {
  const shown = pick(asJson())
  const next = pick(asJson({ run: NOW + "-4243" }), NOW, shown.run)
  assert.equal(next.show, true)
  assert.equal(next.run, NOW + "-4243")
})

test("a batch with no run id is shown rather than suspected of repeating", () => {
  const verdict = pick(asJson({ run: undefined }), NOW, "")
  assert.equal(verdict.show, true)
  assert.equal(verdict.run, "")
})

test("a blank file is 'empty', not an error to report", () => {
  assert.equal(pick("").reason, "empty")
  assert.equal(pick("   \n").reason, "empty")
  assert.equal(pick(null).reason, "empty")
  assert.equal(pick(undefined).reason, "empty")
})

test("a file that is not JSON is 'unparseable'", () => {
  assert.equal(pick("not json at all").reason, "unparseable")
  assert.equal(pick("{\"version\":1,").reason, "unparseable")
})

test("valid JSON that is not a batch object is 'not-a-batch'", () => {
  assert.equal(pick("[1,2,3]").reason, "not-a-batch")
  assert.equal(pick("\"just a string\"").reason, "not-a-batch")
  assert.equal(pick("null").reason, "not-a-batch")
})

test("a batch with no reminders is 'no-items'", () => {
  assert.equal(pick(asJson({ items: [] })).reason, "no-items")
  assert.equal(pick(asJson({ items: undefined })).reason, "no-items")
  assert.equal(pick(asJson({ items: "Ship it" })).reason, "no-items")
})

test("a batch with no usable timestamp is 'no-timestamp'", () => {
  assert.equal(pick(asJson({ at: undefined })).reason, "no-timestamp")
  assert.equal(pick(asJson({ at: "yesterday" })).reason, "no-timestamp")
  assert.equal(pick(asJson({ at: { clock: "broken" } })).reason, "no-timestamp")
})

test("a timestamp written as a numeric string is accepted", () => {
  // jq and a hand-edit both produce a number, but a quoted one still parses
  // to the same instant through Number() and there is no reason to refuse it.
  assert.equal(pick(asJson({ at: String(NOW) })).show, true)
})
