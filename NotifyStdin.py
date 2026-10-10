#!/usr/bin/env python3
"""Post a desktop notification whose text arrives on stdin.

    printf '%s\\0%s\\0' "$headline" "$body" |
        python3 NotifyStdin.py --app-name NAME [--glyph GLYPH]

The headline and the body are read from stdin, split on NUL, so that no
process anywhere carries them in its argv. A command line is the one place
a local account can read our data without our co-operation: /proc/<pid>/cmdline
is world-readable on a default procfs, which would put every task title on
offer to anybody logged into the machine — the same exposure as an unlocked
store, wearing a different hat.

The D-Bus call is the one omarchy-notification-send makes (urgency low, no
actions, no expiry), so the toast that arrives is identical to the one that
tool would have posted; only the road the text took to get there differs.

Exit status is 0 when the bus accepted the notification and non-zero when it
did not, which is what lets the caller play its alert only behind a toast
that really went out.
"""

import os
import sys

import dbus

APP_NAME_FALLBACK = "omarchy"


def parse_args(argv):
    app_name = APP_NAME_FALLBACK
    glyph = ""
    i = 0
    while i < len(argv):
        flag = argv[i]
        if flag in ("--app-name", "--glyph"):
            if i + 1 >= len(argv):
                raise ValueError(f"{flag} needs a value")
            if flag == "--app-name":
                app_name = argv[i + 1]
            else:
                glyph = argv[i + 1]
            i += 2
        else:
            raise ValueError(f"unknown argument: {flag}")
    return app_name, glyph


def session_bus_address():
    address = os.environ.get("DBUS_SESSION_BUS_ADDRESS")
    if address:
        return address
    runtime = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    return f"unix:path={runtime}/bus"


def main():
    app_name, glyph = parse_args(sys.argv[1:])

    # NUL-separated, because a task's title can contain anything — a newline,
    # a run of spaces, the separator itself. Two reads, no shell, no quoting
    # to get wrong on the way in.
    fields = sys.stdin.buffer.read().split(b"\0")
    headline = fields[0].decode("utf-8", "replace") if fields else ""
    body = fields[1].decode("utf-8", "replace") if len(fields) > 1 else ""

    if not headline:
        return 1

    bus = dbus.bus.BusConnection(session_bus_address())
    service = bus.get_object(
        "org.freedesktop.Notifications", "/org/freedesktop/Notifications"
    )
    notifications = dbus.Interface(service, "org.freedesktop.Notifications")

    hints = dbus.Dictionary(signature="sv")
    hints["urgency"] = dbus.Byte(0)
    if glyph:
        hints["omarchy-glyph"] = glyph

    notifications.Notify(
        app_name,
        dbus.UInt32(0),  # replaces_id: a new toast, never an update
        "",  # app_icon: the desktop supplies its own
        headline,
        body,
        dbus.Array([], signature="s"),  # actions
        hints,
        dbus.Int32(-1),  # expire_timeout: let the daemon decide
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:  # a toast that cannot be posted must not kill the timer
        print(f"NotifyStdin.py: {error}", file=sys.stderr)
        sys.exit(1)
