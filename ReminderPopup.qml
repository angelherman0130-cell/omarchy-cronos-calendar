import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// The reminder card: what the widget shows when the timer has queued a batch.
//
// It is drawn here rather than posted to the session's notification host, and
// the reason is a privacy line rather than a look. A notification travels as a
// message to a process that then writes the whole popup — headline included —
// back out as an argument of a shell it runs to persist it, and a command
// line is world-readable under an ordinary /proc. A title the widget renders
// itself never leaves the widget: it comes from a 0600 queue file, through
// this QML, onto the screen. Nothing in between is a process.
//
// It behaves like the toast it replaced: anchored under the clock, up for nine
// seconds, gone at once when clicked, and never a focus grab — a reminder that
// steals the keyboard from a terminal you were typing in is a reminder that
// gets the shell closed instead of read.
PopupWindow {
  id: root

  property var anchorItem: null
  property var bar: null
  property var items: []

  // Raised when the card goes away, for whoever owns `items` to clear them.
  // The dismissal path runs through the owner rather than assigning to
  // `items` from here: an assignment would replace the binding that feeds
  // this window, and the next batch would never arrive.
  signal dismissed()

  readonly property bool hasItems: Array.isArray(items) && items.length > 0
  // Four is past the point where a card is being read rather than glanced at.
  // The rest of the batch is not lost — the tasks are in the panel — but one
  // card never grows into a wall.
  readonly property var shownItems: hasItems ? items.slice(0, 4) : []
  readonly property real cardWidth: Style.space(340)
  readonly property real cardPadding: Style.space(14)

  visible: hasItems && anchorItem !== null && bar !== null
  color: "transparent"
  implicitWidth: cardWidth
  implicitHeight: Math.max(Style.space(44), stack.implicitHeight + cardPadding * 2)

  Timer {
    id: hideTimer
    interval: 9000
    running: root.hasItems
    onTriggered: root.dismissed()
  }

  // A second batch while the first is still on screen restarts the clock
  // rather than being dropped: `running` alone would leave the card vanishing
  // mid-sentence because the hour ticked over.
  onItemsChanged: if (root.hasItems) hideTimer.restart()

  anchor {
    id: popupAnchor
    window: anchorItem ? anchorItem.QsWindow.window : null
    adjustment: PopupAdjustment.Slide
    edges: Edges.Top | Edges.Left
    gravity: Edges.Bottom | Edges.Right
    rect.width: 1
    rect.height: 1

    onAnchoring: {
      if (!root.anchorItem || !root.bar) return

      var target = root.anchorItem
      var window = target.QsWindow.window
      if (!window) return

      var popupWidth = root.implicitWidth
      var popupHeight = root.implicitHeight
      var margin = Style.gapsOut
      var localX = target.width / 2 - popupWidth / 2
      var localY = target.height + margin

      // Same four cases as every other popup this shell draws: the card sits
      // on the inner side of the bar, so a bottom bar gets a card above its
      // widget rather than one hanging off the bottom edge of the screen.
      if (root.bar.position === "bottom") {
        localY = -popupHeight - margin
      } else if (root.bar.position === "left") {
        localX = target.width + margin
        localY = target.height / 2 - popupHeight / 2
      } else if (root.bar.position === "right") {
        localX = -popupWidth - margin
        localY = target.height / 2 - popupHeight / 2
      }

      var point = window.contentItem.mapFromItem(target, localX, localY)
      if (root.bar.position === "top" || root.bar.position === "bottom") {
        point.x = Math.max(margin, Math.min(point.x, window.width - popupWidth - margin))
      } else {
        point.y = Math.max(margin, Math.min(point.y, window.height - popupHeight - margin))
      }

      popupAnchor.rect.x = Math.round(point.x)
      popupAnchor.rect.y = Math.round(point.y)
    }
  }

  Rectangle {
    id: card
    width: root.implicitWidth
    height: root.implicitHeight
    radius: Style.cornerRadius
    color: Color.popups.background
    border.color: Color.popups.border
    border.width: Style.normalBorderWidth

    // The whole card dismisses: a reminder you have seen is finished with,
    // and there is nothing on it to act on that the panel does not do better.
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: root.dismissed()
    }

    Column {
      id: stack
      width: parent.width - root.cardPadding * 2
      x: root.cardPadding
      y: root.cardPadding
      spacing: Style.spacing.md

      Repeater {
        model: root.shownItems

        delegate: Row {
          required property var modelData
          width: stack.width
          spacing: Style.spacing.md

          OpticalGlyph {
            text: "󰢌"
            width: Style.space(20)
            height: Style.space(20)
            anchors.verticalCenter: parent.verticalCenter
            color: Color.accent
            fontSize: Style.font.body
          }

          Column {
            width: parent.width - Style.space(20) - Style.spacing.md
            spacing: Style.space(3)

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: modelData.text !== undefined ? modelData.text : ""
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
              wrapMode: Text.Wrap
              maximumLineCount: 3
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              visible: text !== ""
              textFormat: Text.PlainText
              text: modelData.body !== undefined ? modelData.body : ""
              color: Qt.alpha(Color.popups.text, 0.65)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
              maximumLineCount: 2
              elide: Text.ElideRight
            }
          }
        }
      }
    }
  }
}
