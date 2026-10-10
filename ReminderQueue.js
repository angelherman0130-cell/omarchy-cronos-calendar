// Whether a queued reminder batch should interrupt this session.
//
// The file is written by ClockReminders.sh and read by BarWidget.qml; this is
// the decision between the two, kept out of QML for the same reason Tasks.js
// and Model.js are: it is pure arithmetic and shape-checking, and it is the
// part a change is most likely to bend without anything looking broken on
// screen. A popup that appears when it should not is as much a bug as one
// that does not, and both are decided here.
//
// Every failure returns a reason rather than null, so the shell log can say
// why nothing appeared instead of leaving a missing reminder to be guessed
// at. The reasons are the API's vocabulary and are what the tests assert on.
//
// Like Tasks.js and Model.js, everything is declared at the top level so the
// shell can import it, and the CommonJS export at the foot is guarded so the
// same file also loads under plain node.

// How long a batch stays showable.
//
// Written hourly and shown for seconds, so anything older than this is one an
// earlier session already displayed: the file is replaced, never cleared, and
// re-showing it at the next login would be yesterday's reminder interrupting
// today. It is wide enough to cover a shell restart in the middle of an hour
// and a clock that runs a little behind, and narrow enough that a batch
// nobody saw for a working afternoon is not worth an ambush.
var MAX_AGE_SECONDS = 900

// pick(raw, nowSeconds, lastRun) -> { show, reason, items, run }
//
//   raw        the queue file's contents, whatever they are
//   nowSeconds epoch seconds, passed in so the clock is the caller's problem
//   lastRun    the id of the batch last shown, or "" for none yet
function pick(raw, nowSeconds, lastRun) {
  var no = function(reason) { return { show: false, reason: reason, items: [], run: "" } }

  var text = String(raw === undefined || raw === null ? "" : raw).trim()
  if (text === "") return no("empty")

  var data = null
  try { data = JSON.parse(text) } catch (e) { return no("unparseable") }
  if (!data || typeof data !== "object" || Array.isArray(data)) return no("not-a-batch")

  if (!Array.isArray(data.items) || data.items.length === 0) return no("no-items")

  var at = Number(data.at)
  if (!isFinite(at)) return no("no-timestamp")

  var age = Number(nowSeconds) - at
  if (!isFinite(age) || age > MAX_AGE_SECONDS) return no("stale")

  // Two runs inside the same second are two batches; the same id coming back
  // is the same batch being reported twice, which the watcher does on a file
  // event that changes nothing. An idless batch cannot be told apart from a
  // repeat, so it is shown — better a rare double popup than a reminder that
  // stops arriving because a field went missing.
  var run = data.run === undefined || data.run === null ? "" : String(data.run)
  if (run !== "" && run === lastRun) return no("repeat")

  return { show: true, reason: "fresh", items: data.items, run: run }
}

if (typeof module !== "undefined") {
  module.exports = { pick: pick, MAX_AGE_SECONDS: MAX_AGE_SECONDS }
}
