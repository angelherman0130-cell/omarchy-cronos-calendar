// The priority flag, drawn rather than typed.
//
// The colour is the whole message here: four flags, four answers to one
// question, and the difference between them is the difference between a task
// you drop and a task you get to. A glyph would make all of that depend on one
// font file — the same shape in a font without it is a grey box that has
// stopped saying anything — and two rectangles and a pole come from no font at
// all, so the flag reads the same on a machine that has never heard of the
// one this was drawn against.
//
// The pole takes its darkening from the cloth rather than being fixed, so the
// four read as one shape in four colours rather than as four shapes.

import QtQuick
import qs.Commons

Item {
  id: root

  property color flagColor: Color.foreground
  property real size: Style.space(16)

  width: size
  height: size

  readonly property real poleWidth: Math.max(1, Math.round(size * 0.11))
  readonly property real clothHeight: Math.max(2, Math.round(size * 0.6))

  Rectangle {
    id: pole
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    width: root.poleWidth
    height: root.size
    radius: width / 2
    color: Qt.darker(root.flagColor, 1.5)
  }

  Rectangle {
    id: cloth
    anchors.left: pole.right
    anchors.top: parent.top
    width: root.size - root.poleWidth
    height: root.clothHeight
    radius: Math.max(1, Math.round(root.size * 0.18))
    color: root.flagColor
  }
}
