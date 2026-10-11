#!/usr/bin/env bash
# Tests for ClockReminders.sh — the systemd half of the plugin.
#
#   bash tests/reminders.test.sh
#
# The script's dependencies are faked rather than stubbed: a `date` that
# reports whatever day and hour the scenario asks for, and wrappers around
# every other command the script is allowed to run — each wrapper records the
# argv it was handed and then execs the real one. The recording half is the
# point: a reminder's whole behaviour is a function of *when* it runs, and
# today is the wrong day for every interesting one of them, while the thing
# worth protecting here is that the task title never appears on a command
# line at all. A wrapper that only looked at behaviour would pass while that
# guarantee was gone, because nothing in the script's output mentions argv.
#
# The pair of regressions this exists to hold down:
#   * the window. A reminder used to fire only on its exact remind day, so a
#     machine that was switched off that day lost it, and a task with
#     remindDaysBefore > 0 never nagged on its own due day at all.
#   * the whole-day rule. Every hour of every day in the window counts,
#     deadline hour or not: a reminder set "3 days before" speaks for the 3
#     days before and the due day alike, 24 hours each.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(dirname "$HERE")"
SCRIPT="$PLUGIN/ClockReminders.sh"

if [[ ! -r "$SCRIPT" ]]; then
  printf 'cannot find %s\n' "$SCRIPT" >&2
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export PATH="$WORK/bin:$PATH"
mkdir -p "$WORK/bin" "$WORK/log"

# The widget reads the queue from a literal ~/.local/state, and so does the
# script: HOME is pointed into the sandbox so a test run cannot be satisfied
# by a queue that happens to exist on the machine it is running on.
export HOME="$WORK/home"
mkdir -p "$HOME"
QUEUE="$HOME/.local/state/omarchy/clock-reminders.json"

# One line per child process the script runs: its name, then its arguments.
# Titles are the only thing this log is ever searched for.
export RECTEST_ARGV_LOG="$WORK/log/argv.log"
export RECTEST_SOUND_LOG="$WORK/log/sound.log"
: > "$RECTEST_ARGV_LOG"
: > "$RECTEST_SOUND_LOG"

REAL_DATE="$(command -v date)"
REAL_JQ="$(command -v jq)"
REAL_MKDIR="$(command -v mkdir)"
REAL_MV="$(command -v mv)"
REAL_RM="$(command -v rm)"
REAL_CHMOD="$(command -v chmod)"

cat > "$WORK/bin/date" <<EOF
#!/usr/bin/env bash
printf 'date %s\n' "\$*" >> "\${RECTEST_ARGV_LOG:?}"
case "\$1" in
  +%F) printf '%s' "\${FAKE_TODAY:?FAKE_TODAY is unset}"; exit 0 ;;
  +%H:%M) printf '%s' "\${FAKE_NOW:-00:00}"; exit 0 ;;
esac
exec "$REAL_DATE" "\$@"
EOF

# Every remaining command the script may reach for, wrapped the same way:
# argv into the log, then the real thing. jq is in that list even though it
# only ever reads the store and answers on a pipe, because "it probably does
# not see the title" is exactly the assumption this log exists to replace.
# chmod is wrapped too — secure-store leans on it, and the +x calls below go
# through $REAL_CHMOD so wrapping it cannot unmake its own wrapper.
for pair in "jq:$REAL_JQ" "mkdir:$REAL_MKDIR" "mv:$REAL_MV" "rm:$REAL_RM" \
  "chmod:$REAL_CHMOD"; do
  name="${pair%%:*}"
  real="${pair#*:}"
  cat > "$WORK/bin/$name" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "$name" "\$*" >> "\${RECTEST_ARGV_LOG:?}"
exec "$real" "\$@"
EOF
  "$REAL_CHMOD" +x "$WORK/bin/$name"
done
"$REAL_CHMOD" +x "$WORK/bin/date"

# The alert's players, all four, all fake. Each writes its own name and its
# arguments to one log so a scenario can say which one was reached and with
# what — the point of the fallbacks is the order they are tried in, and an
# "it played something" assertion would not notice if the order changed.
for player in paplay pw-play aplay canberra-gtk-play; do
  cat > "$WORK/bin/$player" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >> "${RECTEST_SOUND_LOG:?}"
EOF
  chmod +x "$WORK/bin/$player"
done

# One declared data dir, and a sample inside it, so the search never falls
# through to whatever this host happens to have under /usr/share. An empty
# counterpart sits beside it for the scenarios that want no sample at all.
SAMPLE_DIR="$WORK/share"
mkdir -p "$SAMPLE_DIR/sounds/freedesktop/stereo"
printf 'oga' > "$SAMPLE_DIR/sounds/freedesktop/stereo/message.oga"
mkdir -p "$WORK/nosample"
export XDG_DATA_DIRS="$SAMPLE_DIR"

pass=0
fail=0

ok() { printf 'ok   %s\n' "$1"; ((pass++)); }
bad() {
  printf 'FAIL %s\n' "$1"
  shift
  local line
  for line in "$@"; do printf '       %s\n' "$line"; done
  ((fail++))
}

# How many reminders the last run put in the queue. A run with nothing due
# writes no file at all — the queue is only ever replaced when there is
# something to say — so an absent file counts as zero rather than as an error.
queue_count() {
  [[ -s "$QUEUE" ]] || { printf '0'; return 0; }
  "$REAL_JQ" -r '.items | length' "$QUEUE" 2>/dev/null || printf '0'
}

# scenario <label> <fake today> <fake now> <store> <expected reminders>
#
# Two things are asserted for every row, and the second is the one the first
# used to hide: the count, and that the run itself succeeded. The timer fires
# hourly on a due day, so most runs have nothing to do, and a `run` that
# exits non-zero for having nothing to do is a unit that is red all day for
# reasons nobody will ever look into.
scenario() {
  local label="$1" day="$2" now="$3" store="$4" want="$5" got status
  rm -f "$QUEUE"
  FAKE_TODAY="$day" FAKE_NOW="$now" bash "$SCRIPT" run "$store" >/dev/null 2>&1
  status=$?
  got="$(queue_count)"
  if [[ "$status" -ne 0 ]]; then
    bad "$label" "| run exited $status" "| queue: $(cat "$QUEUE" 2>/dev/null)"
  elif [[ "$want" == "0" && -e "$QUEUE" ]]; then
    # A batch nobody asked for is not the same as no batch: writing an empty
    # one over the file would replace a batch the widget has not shown yet
    # with a file that says "nothing", and the reminder would be gone.
    bad "$label" "| wrote a queue for a run with nothing due" "| $(cat "$QUEUE")"
  elif [[ "$got" == "$want" ]]; then
    ok "$label"
  else
    bad "$label" "| expected $want, got $got" "| queue: $(cat "$QUEUE" 2>/dev/null)"
  fi
}

# mkstore <version> <json for days>
#
# Its own file every time. They used to share one name, which was fine while
# each store was written immediately before it was read and never reached for
# again — the moment a later scenario re-created it, every earlier reference
# silently pointed at the newest fixture and read the wrong day. The alert
# tests hit exactly that, and "no reminder" was the honest answer they got
# from a store they were never given.
mkstore() {
  local path
  path="$(mktemp "$WORK/store.XXXXXX.json")"
  printf '{"version":%s,"days":{%s}}' "$1" "$2" > "$path"
  printf '%s' "$path"
}

# A task due 2026-10-10 at 17:00, remind days given by the caller.
window_store="$(mkstore 2 "\"2026-10-10\":[{\"id\":\"t1\",\"text\":\"Ship it\",\"done\":false,\"dueTime\":\"17:00\",\"remindDaysBefore\":5}]")"

# ---- the window -----------------------------------------------------------
scenario "opens five days out"                    2026-10-05 12:00 "$window_store" 1
scenario "catch-up after the machine was off"     2026-10-07 12:00 "$window_store" 1
scenario "silent before the window opens"         2026-10-03 12:00 "$window_store" 0
scenario "silent after the task's day has passed" 2026-10-11 12:00 "$window_store" 0
scenario "the task's own due day is in the window" 2026-10-10 18:00 "$window_store" 1
scenario "days in between still nag"              2026-10-06 01:00 "$window_store" 1

# ---- every hour of every day in the window --------------------------------
# The whole point of asking for "3 days before": no hour of those four days
# is quieter than the others, whether or not the deadline hour has come.
scenario "own day, 00:00, due 17:00 -> fires"     2026-10-10 00:00 "$window_store" 1
scenario "own day, 09:00, due 17:00 -> fires"     2026-10-10 09:00 "$window_store" 1
scenario "own day, 16:59, due 17:00 -> fires"     2026-10-10 16:59 "$window_store" 1
scenario "own day, 17:00, due 17:00 -> fires"     2026-10-10 17:00 "$window_store" 1
scenario "own day, 23:30, due 17:00 -> fires"     2026-10-10 23:30 "$window_store" 1
# And the days before are no different: the advance hour is not a special one.
scenario "earlier day, 00:00, due 17:00 -> fires" 2026-10-05 00:00 "$window_store" 1
scenario "earlier day, 01:00, due 17:00 -> fires" 2026-10-06 01:00 "$window_store" 1

# ---- remind 0, the day of the task itself --------------------------------
day_store="$(mkstore 2 "\"2026-10-10\":[{\"id\":\"t1\",\"text\":\"Ship it\",\"done\":false,\"dueTime\":\"17:00\",\"remindDaysBefore\":0}]")"
scenario "remind 0, own day 08:00 -> fires"       2026-10-10 08:00 "$day_store" 1
scenario "remind 0, own day 17:00 -> fires"       2026-10-10 17:00 "$day_store" 1
scenario "remind 0, day before -> silent"         2026-10-09 12:00 "$day_store" 0

# ---- cases where the gate has nothing to gate on -------------------------
untimed="$(mkstore 2 "\"2026-10-10\":[{\"id\":\"t2\",\"text\":\"Whenever\",\"done\":false,\"dueTime\":\"\",\"remindDaysBefore\":0}]")"
scenario "no deadline hour, own day 03:00 -> fires" 2026-10-10 03:00 "$untimed" 1

# ---- a task that is already ticked off -----------------------------------
done_store="$(mkstore 2 "\"2026-10-10\":[{\"id\":\"t3\",\"text\":\"Done\",\"done\":true,\"dueTime\":\"17:00\",\"remindDaysBefore\":0}]")"
scenario "a finished task never nags"             2026-10-10 18:00 "$done_store" 0

# ---- v1 stores still read remind 0 as "off" ------------------------------
# This script never sees the in-memory migration Tasks.js performs, so it has
# to fold a pre-2 zero itself or a reminder someone switched off comes back.
v1="$(mkstore 1 "\"2026-10-10\":[{\"id\":\"t4\",\"text\":\"Old\",\"done\":false,\"dueTime\":\"17:00\",\"remindDaysBefore\":0}]")"
scenario "v1 remind 0 still means off"            2026-10-10 18:00 "$v1" 0

# ---- where the task title travels -----------------------------------------
# The reminder still carries the task's title — that is the point of a
# reminder — but it must reach the queue file and nothing else. Anything it
# does on a command line is world-readable under an ordinary /proc and undoes
# the 0600 the store is kept in, so the assertions are three: it is in the
# file, the file is owner-only, and no child process this run started was
# handed it as an argument.
: > "$RECTEST_ARGV_LOG"
rm -f "$QUEUE"
FAKE_TODAY=2026-10-07 FAKE_NOW=12:00 bash "$SCRIPT" run "$window_store" >/dev/null 2>&1

if [[ -s "$QUEUE" ]] && [[ "$("$REAL_JQ" -r '.items[0].text' "$QUEUE" 2>/dev/null)" == "Ship it" ]]; then
  ok "the title is queued for the widget"
else
  bad "the title is queued for the widget" "| queue: $(cat "$QUEUE" 2>/dev/null)"
fi

mode="$(stat -c %a "$QUEUE" 2>/dev/null || printf missing)"
if [[ "$mode" == "600" ]]; then
  ok "the queue file is owner-only"
else
  bad "the queue file is owner-only" "| mode: $mode"
fi

# The shape the widget reads. Nothing here is cosmetic: `at` is how a card
# from an ended session is told apart from one written this minute, and `run`
# is how two batches in the same second are told apart from a repeat.
if "$REAL_JQ" -e '.version == 1 and (.at | type == "number") and (.run | type == "string")
    and (.items | length > 0) and (.items[0].body | type == "string")' \
    "$QUEUE" >/dev/null 2>&1; then
  ok "the queue carries the fields the widget reads"
else
  bad "the queue carries the fields the widget reads" "| queue: $(cat "$QUEUE")"
fi

# The wrappers have to have run, or the assertion after this one is vacuous:
# an empty log proves nothing except that no command was recorded.
if [[ -s "$RECTEST_ARGV_LOG" ]]; then
  ok "the run's child processes were recorded at all"
else
  bad "the run's child processes were recorded at all" "| the argv wrappers did not run"
fi

if grep -q "Ship it" "$RECTEST_ARGV_LOG"; then
  bad "the title never appears in a child process's argv" "| $(grep "Ship it" "$RECTEST_ARGV_LOG" | head -n 1)"
else
  ok "the title never appears in a child process's argv"
fi

# Titles that would break the JSON are escaped rather than passed along: a
# task called 50% "done" is a task whose title holds a quote, and a queue
# written with it unescaped would be a file that is not an object at all —
# the widget would read a parse error where a reminder should be. Both the
# escape and the round trip are worth pinning: jq parsing it back to the
# original is what proves the escape was the right one.
quote_store="$(mkstore 2 "\"2026-10-07\":[{\"id\":\"t5\",\"text\":\"50% \\\"done\\\"\",\"done\":false,\"dueTime\":\"17:00\",\"remindDaysBefore\":5}]")"
rm -f "$QUEUE"
FAKE_TODAY=2026-10-07 FAKE_NOW=18:00 bash "$SCRIPT" run "$quote_store" >/dev/null 2>&1
if "$REAL_JQ" -e '.items[0].text == "50% \"done\""' "$QUEUE" >/dev/null 2>&1; then
  ok "quotes and backslashes in a title survive the queue"
else
  bad "quotes and backslashes in a title survive the queue" "| queue: $(cat "$QUEUE" 2>/dev/null)"
fi

# ---- the alert -------------------------------------------------------------
#
# The sound is optional, so what has to hold is not that it plays but that it
# plays in the right places: after a batch that actually landed, never after
# one that did not, and never with an error when there is nothing there to
# play it.
#
# Players are fired in the background so a slow one cannot hold up the queue
# write, which means the script may exit before the fake has written its line.
# Poll rather than sleep: the line is there as soon as it is there, and the
# test does not pay the slow machine's penalty on the fast one.
wait_for_sound() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [[ -s "$RECTEST_SOUND_LOG" ]] && return 0
    sleep 0.05
  done
  return 0
}

sound_scenario() {
  local label="$1" day="$2" now="$3" store="$4" want="$5" got
  rm -f "$QUEUE"
  : > "$RECTEST_SOUND_LOG"
  FAKE_TODAY="$day" FAKE_NOW="$now" bash "$SCRIPT" run "$store" >/dev/null 2>&1
  wait_for_sound
  got="$(grep -c . "$RECTEST_SOUND_LOG" 2>/dev/null || true)"
  if [[ "$got" == "$want" ]]; then
    ok "$label"
  else
    bad "$label" "| expected $want sounds, got $got" "| $(cat "$RECTEST_SOUND_LOG")"
  fi
}

expect_sound() {
  local label="$1" want="$2" got
  got="$(head -n 1 "$RECTEST_SOUND_LOG" 2>/dev/null)"
  if [[ "$got" == "$want" ]]; then
    ok "$label"
  else
    bad "$label" "| expected [$want], got [$got]"
  fi
}

# A batch that lands is followed by the first player in line, handed the
# sample that was found under the declared data dir.
sound_scenario "a queued batch is followed by the alert" \
  2026-10-07 12:00 "$window_store" 1
expect_sound "the alert uses paplay first, with the sample" \
  "paplay $SAMPLE_DIR/sounds/freedesktop/stereo/message.oga"

# Nothing queued, nothing heard. A reminder the widget was never given has
# not interrupted anybody, and a bell on its own is a clock ringing for
# nothing.
sound_scenario "no reminder, no sound" 2026-10-03 12:00 "$window_store" 0

# No sample the players can read: the desktop's own event sound is asked for
# instead, by name, rather than a player being handed a file it cannot play.
XDG_DATA_DIRS="$WORK/nosample" \
  sound_scenario "no sample, fall back to the desktop event" \
  2026-10-07 12:00 "$window_store" 1
expect_sound "the fallback is canberra's own message event" "canberra-gtk-play -i message"

# A machine with none of it: silence, and a run that still reports success.
# The PATH below carries only what `run` needs — the shell, jq, the three
# file commands the queue write uses and the fake clock — so no player from
# the host can be found.
NOPATH="$WORK/noplayer"
mkdir -p "$NOPATH"
for bin in bash jq mkdir mv rm; do
  ln -sf "$(command -v "$bin")" "$NOPATH/$bin"
done
ln -sf "$WORK/bin/date" "$NOPATH/date"

rm -f "$QUEUE"
: > "$RECTEST_SOUND_LOG"
if PATH="$NOPATH" XDG_DATA_DIRS="$WORK/nosample" FAKE_TODAY=2026-10-07 FAKE_NOW=12:00 \
  bash "$SCRIPT" run "$window_store" >/dev/null 2>&1; then
  ok "no player at all still exits cleanly"
else
  bad "no player at all still exits cleanly"
fi
if [[ ! -s "$RECTEST_SOUND_LOG" ]]; then
  ok "no player at all is silent"
else
  bad "no player at all is silent" "| $(cat "$RECTEST_SOUND_LOG")"
fi

# ---- the store is born locked down -----------------------------------------
#
# The widget's FileView must never be the process that creates the store:
# QML's atomic write makes the file at the umask's mode — 0644 under an
# ordinary login — and the chmod that would fix it lands after, which is an
# interval in which every task name is readable by any other local account.
# What has to hold: secure-store makes the file 0600 and its directory 0700
# from nothing, corrects a store someone left 0644 without reading it, and
# is idempotent enough to run at every panel load.
new_store="$WORK/newhome/.local/state/omarchy/clock-tasks.json"

if bash "$SCRIPT" secure-store "$new_store" >/dev/null 2>&1; then
  ok "secure-store exits cleanly on a fresh path"
else
  bad "secure-store exits cleanly on a fresh path"
fi

mode="$(stat -c %a "$new_store" 2>/dev/null || printf missing)"
if [[ "$mode" == "600" ]]; then
  ok "a store created by secure-store is owner-only"
else
  bad "a store created by secure-store is owner-only" "| mode: $mode"
fi

dirmode="$(stat -c %a "$(dirname "$new_store")" 2>/dev/null || printf missing)"
if [[ "$dirmode" == "700" ]]; then
  ok "the state directory secure-store creates is owner-only"
else
  bad "the state directory secure-store creates is owner-only" "| mode: $dirmode"
fi

# An existing store keeps its bytes and gets its mode corrected — the write
# path the panel uses (QSaveFile) preserves the permissions of the file it
# replaces, so fixing the mode once here is what keeps every later save 0600.
printf '{"version":2,"days":{}}\n' > "$new_store"
"$REAL_CHMOD" 644 "$new_store"
bash "$SCRIPT" secure-store "$new_store" >/dev/null 2>&1
mode="$(stat -c %a "$new_store" 2>/dev/null || printf missing)"
content="$(cat "$new_store")"
if [[ "$mode" == "600" ]]; then
  ok "secure-store corrects an existing store back to owner-only"
else
  bad "secure-store corrects an existing store back to owner-only" "| mode: $mode"
fi
if [[ "$content" == '{"version":2,"days":{}}' ]]; then
  ok "secure-store never rewrites the store's contents"
else
  bad "secure-store never rewrites the store's contents" "| content: $content"
fi

# Idempotent: the panel calls it on every load, so a second run over the same
# store must be a no-op in every way a caller could observe.
bash "$SCRIPT" secure-store "$new_store" >/dev/null 2>&1
mode="$(stat -c %a "$new_store" 2>/dev/null || printf missing)"
content="$(cat "$new_store")"
if [[ "$mode" == "600" && "$content" == '{"version":2,"days":{}}' ]]; then
  ok "secure-store is idempotent"
else
  bad "secure-store is idempotent" "| mode: $mode | content: $content"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
