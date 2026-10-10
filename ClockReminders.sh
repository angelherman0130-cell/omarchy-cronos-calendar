#!/usr/bin/env bash
# Reminders for the "Cronos-Calendar" bar widget (angelherman.cronos-calendar).
#
# Two jobs in one file, because they are the two halves of a single promise: a
# task marked "remind me" keeps notifying you until you tick it off — on this
# machine, across reboots, and with the bar widget closed.
#
#   install <store.json> [script-path]
#                          Make sure a persistent systemd user timer exists that
#                          runs this script every hour, and that it is
#                          enabled to start at boot. Idempotent: systemd is only
#                          touched when something actually differs. The widget
#                          passes the path it resolved for this file, which keeps
#                          the generated unit pointing at the copy that is
#                          actually installed rather than at a guess.
#   run <store.json>       Send the notifications that are due right now. This
#                          is what the timer calls, and what a human can call by
#                          hand to check it works.
#
# Why the timer lives here instead of in the bar widget: the widget would have
# to arm a timer with systemd-run every time it opened, and a timer armed that
# way is *transient* — it lives in /run, which is a tmpfs, so a reboot deletes
# it and the reminder is silently gone. A real unit file in
# ~/.config/systemd/user survives that, is started by systemd at login whether
# or not any GUI is running, and with Persistent=true it even delivers a
# reminder whose moment passed while the machine was switched off. The widget
# keeps owning the task list; this file only owes it a reliable alarm.

set -uo pipefail

SERVICE_NAME="omarchy-clock-reminders.service"
TIMER_NAME="omarchy-clock-reminders.timer"

# The glyph on the toast. A reminder is a clock ringing, not a task, so the
# toast is identifiable as "the calendar talking to me" rather than as whatever
# else happened to post a notification.
GLYPH="󰢌"
APP_NAME="Cronos-Calendar"

# The store is the widget's file, not ours. The panel passes it in so the two
# can never disagree about which file is authoritative.
DEFAULT_STORE="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/clock-tasks.json"

unit_dir() {
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
}

# The script's own absolute path, so the generated unit keeps working no matter
# what the caller's working directory or PATH looks like. readlink -f so a
# symlinked plugin directory still yields a path systemd can execute.
self_path() {
  local path
  path="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)" && printf '%s\n' "$path" && return 0
  printf '%s\n' "${BASH_SOURCE[0]}"
}

# Path of the shell used to run this file. Resolved rather than hardcoded so the
# unit does not depend on a particular distribution layout.
bash_path() {
  local path
  path="$(command -v bash 2>/dev/null)" && printf '%s\n' "$path" && return 0
  printf '%s\n' "/usr/bin/bash"
}

# Quotes one argument for a systemd command line.
#
# systemd parses ExecStart itself rather than handing the line to a shell, and
# its rules are not the shell's: it splits on whitespace, but it also expands
# $VAR and % specifiers. A path is not allowed to bring either of those into a
# unit, so they are escaped, and a path with a space in it has to survive the
# split — a plugin installed under a home directory with a space would
# otherwise produce a unit that fails with exit code 127 and no explanation.
systemd_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//%/%%}"
  value="${value//\$/\$\$}"
  printf '"%s"' "$value"
}

# ---- Unit files
#
# Written with a heredoc rather than assembled with echo, so the content is
# readable in the file itself. Everything interpolated is a path this script
# computed; the only value that could contain a newline is the plugin path, and
# a plugin directory with a newline in its name is not a case worth supporting.

timer_unit_text() {
  cat <<EOF
# Written by the Cronos-Calendar widget (angelherman.cronos-calendar) — edits are overwritten.
#
# On the hour, every day. The widget asks this script what
# is actually due; the schedule itself is the same all day, so there is nothing
# to rewrite when a task changes.
[Unit]
Description=Cronos-Calendar task reminders

[Timer]
OnCalendar=*:00:00
# Without this, systemd is free to merge two firings a minute apart into one.
AccuracySec=1min
RandomizedDelaySec=0
# Fire once, on the next start, for a reminder whose moment passed while the
# machine was off. This is the half that makes a reminder survive a reboot
# instead of being quietly skipped by one.
Persistent=true
Unit=$SERVICE_NAME

[Install]
WantedBy=timers.target
EOF
}

service_unit_text() {
  local script="$1" store="$2" shell
  shell="$(bash_path)"
  cat <<EOF
# Written by the Cronos-Calendar widget (angelherman.cronos-calendar) — edits are overwritten.
[Unit]
Description=Cronos-Calendar task reminder check
# Both conditions are checked before the service is considered for start, so a
# removed plugin or a never-used store leaves a skipped unit rather than a
# failed one in the user's journal.
ConditionPathExists=$script
ConditionPathExists=$store

[Service]
Type=oneshot
ExecStart=$(systemd_quote "$shell") $(systemd_quote "$script") run $(systemd_quote "$store")
EOF
}

# Write $2 into $1 only when the contents differ. systemctl daemon-reload and
# enable are expensive enough, and noisy enough in the journal, to be worth not
# doing on every single panel open. Echoes "changed" or "same" for the caller.
write_if_changed() {
  local target="$1" wanted="$2" current
  if [[ -f "$target" ]]; then
    current="$(cat "$target" 2>/dev/null)"
    if [[ "$current" == "$wanted" ]]; then
      printf 'same\n'
      return 0
    fi
  fi
  if printf '%s\n' "$wanted" >"$target" 2>/dev/null; then
    printf 'changed\n'
    return 0
  fi
  printf 'failed\n'
  return 1
}

install_units() {
  local store="${1:-$DEFAULT_STORE}"
  local given="${2:-}"
  local dir script service_file timer_file service_text timer_text
  local service_state timer_state

  dir="$(unit_dir)"
  mkdir -p "$dir" || return 1

  # The caller may pass the plugin's own file:// URL rather than a path, which
  # is the only way the widget can name a file sitting next to itself. When it
  # does not, this script's own location is used, which is what a human typing
  # `install` in a terminal gets.
  if [[ -n "$given" ]]; then
    script="$given"
  else
    script="$(self_path)"
  fi
  [[ -n "$script" && -f "$script" ]] || return 1

  service_file="$dir/$SERVICE_NAME"
  timer_file="$dir/$TIMER_NAME"

  service_text="$(service_unit_text "$script" "$store")"
  timer_text="$(timer_unit_text)"

  service_state="$(write_if_changed "$service_file" "$service_text")" || return 1
  timer_state="$(write_if_changed "$timer_file" "$timer_text")" || return 1

  # A timer that is present but disabled still never fires, and a timer that is
  # enabled but not started misses today. --now covers both, and is a no-op
  # once the timer is already active.
  if [[ "$service_state" != "same" || "$timer_state" != "same" ]]; then
    systemctl --user daemon-reload >/dev/null 2>&1
  fi
  systemctl --user enable --now "$TIMER_NAME" >/dev/null 2>&1
}

# ---- Sending
#
# Task text is the notification's headline, which is the whole point: a toast
# that says "Reminder" tells you nothing, and a toast that says "Buy milk"
# tells you what to go and do. The details sit underneath it.

# The panel names a day the way a person would ("Fri 12 Sep") rather than as a
# number, so DD/MM here is this script's own shape rather than a shared one —
# which is why it is spelled out instead of borrowed. A key that is not a key
# prints nothing, and the caller falls back to the raw string rather than
# showing an empty date.
day_label() {
  local key="$1"
  [[ "$key" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]] || return 0
  printf '%s/%s' "${BASH_REMATCH[3]}" "${BASH_REMATCH[2]}"
}

# ---- Sound
#
# Optional by construction: no setting to switch on, no package this file asks
# anybody to install, and a machine with neither a player nor a sample gets
# silence rather than an error from a timer that runs while nobody is watching.
# The toast is never held up by any of this — the sound is fired and left to
# finish on its own, so a slow or hung player cannot delay or drop the
# notification it was supposed to accompany.
#
# The sample is looked for under XDG_DATA_DIRS when that is set, and under the
# two system directories only when it is not. That is what makes the search
# answerable to a test: an environment that declares its own data dirs gets
# exactly those, instead of quietly also finding whatever the host happens to
# have installed under /usr/share.
sound_sample() {
  local dirs dir rel
  if [[ -n "${XDG_DATA_DIRS:-}" ]]; then
    dirs="$XDG_DATA_DIRS"
  else
    dirs="/usr/local/share:/usr/share"
  fi

  local IFS=':'
  for dir in $dirs; do
    [[ -n "$dir" ]] || continue
    for rel in \
      "sounds/freedesktop/stereo/message.oga" \
      "sounds/freedesktop/stereo/bell.oga" \
      "sounds/gnome/default/alerts/bark.ogg" \
      "sounds/gnome/default/alerts/drip.ogg"; do
      if [[ -r "$dir/$rel" ]]; then
        printf '%s\n' "$dir/$rel"
        return 0
      fi
    done
  done
  return 1
}

# Fire the alert, and never say anything about it. Every branch ends in 0:
# a machine that cannot make a sound has lost nothing, and reporting failure
# to a systemd unit that ignores output would be noise about noise.
play_alert() {
  local sample="" player="" candidate

  # In the order they are likeliest to already be there on a desktop playing
  # through PipeWire, with the ALSA fallback last because it is the one that
  # may have the player and still not be able to read the sample.
  for candidate in paplay pw-play aplay; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    player="$candidate"
    break
  done

  if [[ -n "$player" ]]; then
    sample="$(sound_sample || true)"
    # aplay speaks WAV and nothing else. A sample it cannot read is not a
    # sample, and handing it an .oga anyway would play noise — better to fall
    # through and let the event below make the sound instead.
    if [[ "$player" == "aplay" && "$sample" != *.wav ]]; then
      sample=""
    fi
    if [[ -n "$sample" ]]; then
      "$player" "$sample" >/dev/null 2>&1 &
      return 0
    fi
  fi

  # No sample usable by the player found: libcanberra picks a sound the
  # desktop itself chose, under a freedesktop event name. This is also the
  # whole answer on a machine that has the library but never installed a
  # sample of its own.
  if command -v canberra-gtk-play >/dev/null 2>&1; then
    canberra-gtk-play -i message >/dev/null 2>&1 &
    return 0
  fi

  return 0
}

# Post one toast: $1 is the headline, $2 the body.
#
# Both are written to the sender's stdin instead of handed over as arguments.
# omarchy-notification-send takes its headline on the command line, and a
# command line is world-readable under a default procfs — a task title posted
# that way reaches any other local account without that account ever touching
# the 0600 store. NotifyStdin.py, sitting next to this file, makes the same
# org.freedesktop.Notifications call with the text it is handed over a pipe,
# and pipes live in the kernel, not in /proc.
send_toast() {
  local self dir script
  self="$(self_path)"
  dir="${self%/*}"
  [[ "$dir" == "$self" ]] && dir="."
  script="$dir/NotifyStdin.py"
  [[ -r "$script" ]] || return 1
  printf '%s\0%s\0' "$1" "$2" |
    python3 "$script" --app-name "$APP_NAME" --glyph "$GLYPH" >/dev/null 2>&1
}

notify_due() {
  local store="${1:-$DEFAULT_STORE}"
  local today rows day id text due remind remind_day now_hm body label

  [[ -r "$store" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  today="$(date +%F)"

  # One line per outstanding task that asks to be reminded, fields joined with
  # U+001F.
  #
  # Not a tab: bash treats tab as IFS whitespace and collapses runs of it, so a
  # task with no deadline — a genuinely empty field — would shift every later
  # field along and be read with no reminder count at all, and would then be
  # skipped as unreadable. U+001F is not whitespace, so an empty field stays an
  # empty field. The control characters in the text are flattened to spaces
  # here, which is also what guarantees no field can contain the separator.
  #
  # The reminder field is emitted raw, with no filtering here. Deciding what
  # counts as a reminder in jq would mean re-spelling it in bash as well; the
  # one regex below already settles every case — a null reads as "null" and
  # fails, a decimal or a negative fails, "0" passes, and a number typed as a
  # bare string in a hand-edited file passes too, which is what that reader
  # meant.
  #
  # Except that "0 passes" is only true from store version 2 on. This script is
  # a second, independent reader of the store: it is driven by systemd, so it
  # runs whether or not the panel has ever been opened, and it never sees the
  # in-memory migration that Tasks.js performs on load. In version 1 a 0 meant
  # "no reminder", so reading one here as "the due day itself" would fire a
  # notification for something the owner had switched off. Hence the version is
  # read first and a pre-2 0 is folded to null here too, mirroring
  # Tasks.migrateRemindDays.
  local ver
  ver="$(jq -r '(.version // 1)' "$store" 2>/dev/null)" || return 0
  case "$ver" in '' | *[!0-9]*) ver=1 ;; esac

  rows="$(jq -r --argjson ver "$ver" '
    def eff_remind:
      (.remindDaysBefore // null) as $r
      | if ($ver < 2) and (($r | tostring) == "0") then null else $r end;
    [ (.days // {} | to_entries[]) as $entry
      | ($entry.value // [])[]?
      | select((.done // false) != true)
      | [ $entry.key,
          (.id | tostring),
          (.text | tostring),
          ((.dueTime // "") | tostring),
          (eff_remind | tostring)
        ]
    ]
    | .[]
    | map(gsub("[[:cntrl:]]"; " ") | gsub("^[[:space:]]+|[[:space:]]+$"; ""))
    | join("\u001f")
  ' "$store" 2>/dev/null)" || return 0

  [[ -n "$rows" ]] || return 0

  local IFS=$'\x1f'
  while read -r day id text due remind; do
    [[ -n "$id" ]] || continue
    # Zero means the reminder is set for the task's own day, not "off": the
    # widget stores null for off and 0 for the day itself, so rejecting 0 here
    # is what used to make the day-of reminder impossible. A value that is not a
    # non-negative integer — null, a decimal, a negative — is not a reminder and
    # is passed over.
    [[ "$remind" =~ ^[0-9]+$ ]] || continue

    # The day this particular task starts nagging: remindDaysBefore days before
    # the task itself. Recomputed here rather than stored, so changing the chip
    # on an existing task takes effect without rewriting the file.
    remind_day="$(date -d "$day -$remind days" +%F 2>/dev/null)" || continue

    # A window, not an exact match. remind_day is when the nag opens and the
    # task's own day is when it closes; only the exact day used to be accepted,
    # which threw away every reminder whose day fell while the machine was
    # switched off. Persistent=true does not save it: that replays the missed
    # timer firing on the next boot, and the date read here on that boot is
    # already the later one, so the == test failed and the toast never came.
    # Anything before remind_day has not opened yet, anything after the task's
    # own day is a task long past that is not worth re-arming.
    if [[ "$today" < "$remind_day" || "$day" < "$today" ]]; then
      continue
    fi

    # Not before the hour it is due. On the task's own day the timer fires
    # every hour, so without this a deadline at 17:00 would start nagging at
    # 00:00 — seventeen toasts of "due at 17:00" before a single one of them
    # could be acted on, which is noise wearing the costume of a reminder. The
    # day-of nag waits for the hour to come. Days earlier in the window keep
    # the whole day, because being told in advance is the entire point of
    # asking for a two-day reminder.
    if [[ "$today" == "$day" && "$due" =~ ^[0-9]{2}:[0-9]{2}$ ]]; then
      now_hm="$(date +%H:%M)"
      if [[ "$now_hm" < "$due" ]]; then
        continue
      fi
    fi

    body=""
    if [[ -n "$due" ]]; then
      label="$(day_label "$day")"
      body="Due ${label:-$day} at $due"
    else
      body="No deadline time"
    fi
    body="$body · reminder $(date +%d/%m)"

    [[ -n "$text" ]] || text="Task"

    # A headline that begins with a dash would be read as an option by
    # omarchy-notification-send's own parser. A leading space is invisible in
    # the toast and keeps a task called "-p" from swallowing the notification.
    case "$text" in -*) text=" $text" ;; esac

    # The sound follows a notification that actually went out, and only that
    # one: a toast that failed to post has not interrupted anybody, and an
    # alert on its own would be a clock ringing for nothing.
    if send_toast "$text" "$body"; then
      play_alert
    fi
  done <<<"$rows"
}

main() {
  local mode="${1:-run}"
  case "$mode" in
    install) install_units "${2:-$DEFAULT_STORE}" "${3:-}" ;;
    run | "") notify_due "${2:-$DEFAULT_STORE}" ;;
    *)
      printf 'usage: %s [install [store.json] [script-path]] | [run [store.json]]\n' "${0##*/}" >&2
      return 2
      ;;
  esac
}

main "$@"
