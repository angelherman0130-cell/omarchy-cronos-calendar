#!/usr/bin/env bash
# Tests for ClockReminders.sh — the systemd half of the plugin.
#
#   bash tests/reminders.test.sh
#
# The script's dependencies are faked rather than stubbed: a `date` that
# reports whatever day and hour the scenario asks for, and a toast sender that
# writes its arguments *and its stdin* to a file instead of posting anything.
# The stdin half is the point: the script hands the task title over a pipe
# precisely so that it never appears in a process's argv, and a fake that only
# looked at argv would pass while the leak was wide open. That is what makes
# the interesting cases testable at all — a reminder's whole behaviour is a
# function of *when* it runs, and today is the wrong day for every interesting
# one of them.
#
# The pair of regressions this exists to hold down:
#   * the window. A reminder used to fire only on its exact remind day, so a
#     machine that was switched off that day lost it, and a task with
#     remindDaysBefore > 0 never nagged on its own due day at all.
#   * the due-time gate. On the task's own day the timer fires hourly, so a
#     17:00 deadline began nagging at midnight.
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
export RECTEST_LOG="$WORK/notified.log"
mkdir -p "$WORK/bin"

REAL_DATE="$(command -v date)"
cat > "$WORK/bin/date" <<EOF
#!/usr/bin/env bash
case "\$1" in
  +%F) printf '%s' "\${FAKE_TODAY:?FAKE_TODAY is unset}"; exit 0 ;;
  +%H:%M) printf '%s' "\${FAKE_NOW:-00:00}"; exit 0 ;;
esac
exec "$REAL_DATE" "\$@"
EOF

cat > "$WORK/bin/python3" <<'EOF'
#!/usr/bin/env bash
# One line per toast: the argv the script built, then the payload it piped in.
# NUL becomes "|" so the two fields stay countable and the line stays one line.
printf '%s | %s\n' "$*" "$(tr '\0' '|')" >> "${RECTEST_LOG:?}"
EOF

chmod +x "$WORK/bin/date" "$WORK/bin/python3"

# The alert's players, all four, all fake. Each writes its own name and its
# arguments to one log so a scenario can say which one was reached and with
# what — the point of the fallbacks is the order they are tried in, and an
# "it played something" assertion would not notice if the order changed.
export RECTEST_SOUND_LOG="$WORK/sound.log"
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

# scenario <label> <fake today> <fake now> <store> <expected notifications>
scenario() {
  local label="$1" day="$2" now="$3" store="$4" want="$5" got
  : > "$RECTEST_LOG"
  : > "$RECTEST_SOUND_LOG"
  FAKE_TODAY="$day" FAKE_NOW="$now" bash "$SCRIPT" run "$store" >/dev/null 2>&1
  got="$(grep -c . "$RECTEST_LOG")"
  if [[ "$got" == "$want" ]]; then
    printf 'ok   %s\n' "$label"
    ((pass++))
  else
    printf 'FAIL %s (expected %s, got %s)\n' "$label" "$want" "$got"
    sed 's/^/       | /' "$RECTEST_LOG"
    ((fail++))
  fi
}

# mkstore <version> <json for days>
#
# Its own file every time. They used to share one name, which was fine while
# each store was written immediately before it was read and never reached for
# again — the moment a later scenario re-created it, every earlier reference
# silently pointed at the newest fixture and read the wrong day. The alert
# tests hit exactly that, and "no notification" was the honest answer they
# got from a store they were never given.
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

# ---- the due-time gate on the task's own day ------------------------------
scenario "own day, 09:00, due 17:00 -> silent"    2026-10-10 09:00 "$window_store" 0
scenario "own day, 16:59, due 17:00 -> silent"    2026-10-10 16:59 "$window_store" 0
scenario "own day, 17:00, due 17:00 -> fires"     2026-10-10 17:00 "$window_store" 1
scenario "own day, 23:30, due 17:00 -> fires"     2026-10-10 23:30 "$window_store" 1
# The gate must not reach back into the days before, or the advance reminder
# would be silent at exactly the hour it exists to give.
scenario "earlier day, 01:00, due 17:00 -> fires" 2026-10-06 01:00 "$window_store" 1

# ---- remind 0, the day of the task itself --------------------------------
day_store="$(mkstore 2 "\"2026-10-10\":[{\"id\":\"t1\",\"text\":\"Ship it\",\"done\":false,\"dueTime\":\"17:00\",\"remindDaysBefore\":0}]")"
scenario "remind 0, own day 08:00 -> silent"      2026-10-10 08:00 "$day_store" 0
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
# The toast still carries the task's title — that is the point of a reminder —
# but it must arrive on the sender's stdin and never in its argv. A command
# line is world-readable under a default procfs, so a title sent that way
# reaches any other local account and undoes the 0600 the store is kept in.
: > "$RECTEST_LOG"
FAKE_TODAY=2026-10-07 FAKE_NOW=12:00 bash "$SCRIPT" run "$window_store" >/dev/null 2>&1
line="$(head -n 1 "$RECTEST_LOG")"
argv_half="${line%% | *}"
payload_half="${line#* | }"
if [[ "$payload_half" == *"Ship it"* && "$argv_half" != *"Ship it"* ]]; then
  printf 'ok   %s\n' "the task title rides on stdin, not in argv"
  ((pass++))
else
  printf 'FAIL %s\n' "the task title rides on stdin, not in argv"
  printf '       argv    | %s\n       payload | %s\n' "$argv_half" "$payload_half"
  ((fail++))
fi

# ---- the alert -------------------------------------------------------------
#
# The sound is optional, so what has to hold is not that it plays but that it
# plays in the right places: after a notification that actually went out,
# never after one that did not, and never with an error when there is nothing
# there to play it.
#
# Players are fired in the background so a slow one cannot hold up the toast,
# which means the script may exit before the fake has written its line. Poll
# rather than sleep: the line is there as soon as it is there, and the test
# does not pay the slow machine's penalty on the fast one.
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
  : > "$RECTEST_LOG"
  : > "$RECTEST_SOUND_LOG"
  FAKE_TODAY="$day" FAKE_NOW="$now" bash "$SCRIPT" run "$store" >/dev/null 2>&1
  wait_for_sound
  got="$(grep -c . "$RECTEST_SOUND_LOG" 2>/dev/null || true)"
  if [[ "$got" == "$want" ]]; then
    printf 'ok   %s\n' "$label"
    ((pass++))
  else
    printf 'FAIL %s (expected %s sounds, got %s)\n' "$label" "$want" "$got"
    sed 's/^/       | /' "$RECTEST_SOUND_LOG"
    ((fail++))
  fi
}

expect_sound() {
  local label="$1" want="$2" got
  got="$(head -n 1 "$RECTEST_SOUND_LOG" 2>/dev/null)"
  if [[ "$got" == "$want" ]]; then
    printf 'ok   %s\n' "$label"
    ((pass++))
  else
    printf 'FAIL %s (expected [%s], got [%s])\n' "$label" "$want" "$got"
    ((fail++))
  fi
}

# A notification that goes out is followed by the first player in line,
# handed the sample that was found under the declared data dir.
sound_scenario "a sent notification is followed by the alert" \
  2026-10-07 12:00 "$window_store" 1
expect_sound "the alert uses paplay first, with the sample" \
  "paplay $SAMPLE_DIR/sounds/freedesktop/stereo/message.oga"

# Nothing sent, nothing heard. A toast that failed to post has not
# interrupted anybody, and a bell on its own is a clock ringing for nothing.
sound_scenario "no notification, no sound" 2026-10-03 12:00 "$window_store" 0

# No sample the players can read: the desktop's own event sound is asked for
# instead, by name, rather than a player being handed a file it cannot play.
XDG_DATA_DIRS="$WORK/nosample" \
  sound_scenario "no sample, fall back to the desktop event" \
  2026-10-07 12:00 "$window_store" 1
expect_sound "the fallback is canberra's own message event" "canberra-gtk-play -i message"

# A machine with none of it: silence, and a run that still reports success.
# The PATH below carries only what `run` needs — the shell, jq, tr for the
# fake sender, the fake clock and the fake sender itself — so no player from
# the host can be found.
NOPATH="$WORK/noplayer"
mkdir -p "$NOPATH"
for bin in bash jq tr; do
  ln -sf "$(command -v "$bin")" "$NOPATH/$bin"
done
ln -sf "$WORK/bin/date" "$NOPATH/date"
ln -sf "$WORK/bin/python3" "$NOPATH/python3"

: > "$RECTEST_LOG"
: > "$RECTEST_SOUND_LOG"
if PATH="$NOPATH" XDG_DATA_DIRS="$WORK/nosample" FAKE_TODAY=2026-10-07 FAKE_NOW=12:00 \
  bash "$SCRIPT" run "$window_store" >/dev/null 2>&1; then
  printf 'ok   %s\n' "no player at all still exits cleanly"
  ((pass++))
else
  printf 'FAIL %s\n' "no player at all still exits cleanly"
  ((fail++))
fi
if [[ ! -s "$RECTEST_SOUND_LOG" ]]; then
  printf 'ok   %s\n' "no player at all is silent"
  ((pass++))
else
  printf 'FAIL %s\n' "no player at all is silent"
  sed 's/^/       | /' "$RECTEST_SOUND_LOG"
  ((fail++))
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
