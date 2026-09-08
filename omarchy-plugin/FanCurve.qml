import QtQuick
import qs.Commons

// Draggable eight-point fan curve. The firmware exposes fixed points, so this
// edits them in place rather than fitting anything: drag a knob, then Apply.
//
// Drawn on a Canvas because the shell ships no charting component; everything
// else here (colours, spacing, fonts) still comes from the shared tokens.
Item {
  id: root

  // [{ temp, percent }], edited in place
  property var points: []
  property real nowTemp: -1
  property color foreground: Color.menu.text
  property int tMin: 20
  property int tMax: 100
  property int padLeft: Style.space(30)
  property int padRight: Style.space(8)
  property int padTop: Style.space(8)
  property int padBottom: Style.space(18)
  property int knobRadius: Math.max(5, Style.space(6))
  property int dragIndex: -1

  signal edited()

  implicitHeight: Style.space(170)

  function plotX(temp) {
    return padLeft + ((temp - tMin) / (tMax - tMin)) * (width - padLeft - padRight)
  }
  function plotY(percent) {
    return padTop + (1 - percent / 100) * (height - padTop - padBottom)
  }
  function tempAt(x) {
    return tMin + ((x - padLeft) / Math.max(1, width - padLeft - padRight)) * (tMax - tMin)
  }
  function percentAt(y) {
    return (1 - (y - padTop) / Math.max(1, height - padTop - padBottom)) * 100
  }

  function nearest(x, y) {
    var best = -1, bestDist = Infinity
    for (var i = 0; i < points.length; i++) {
      var dx = x - plotX(points[i].temp)
      var dy = y - plotY(points[i].percent)
      var d = dx * dx + dy * dy
      if (d < bestDist) { bestDist = d; best = i }
    }
    return bestDist <= Math.pow(knobRadius * 3, 2) ? best : -1
  }

  Canvas {
    id: canvas
    anchors.fill: parent
    renderStrategy: Canvas.Cooperative

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      ctx.clearRect(0, 0, width, height)

      var grid = Qt.alpha(root.foreground, 0.16)
      var dim = Qt.alpha(root.foreground, 0.55)
      ctx.strokeStyle = grid
      ctx.lineWidth = 1
      ctx.font = Math.round(Style.font.caption * 0.85) + "px " + Style.font.family
      ctx.fillStyle = dim

      for (var p = 0; p <= 100; p += 25) {
        var gy = root.plotY(p)
        ctx.beginPath(); ctx.moveTo(root.padLeft, gy); ctx.lineTo(width - root.padRight, gy); ctx.stroke()
        ctx.textAlign = "right"
        ctx.fillText(p + "%", root.padLeft - Style.space(4), gy + 3)
      }
      for (var t = root.tMin; t <= root.tMax; t += 20) {
        var gx = root.plotX(t)
        ctx.beginPath(); ctx.moveTo(gx, root.padTop); ctx.lineTo(gx, height - root.padBottom); ctx.stroke()
        ctx.textAlign = "center"
        ctx.fillText(t + "°", gx, height - root.padBottom + Style.space(12))
      }

      if (!root.points || root.points.length === 0) return

      // Filled area under the curve, then the line, then the knobs.
      ctx.beginPath()
      ctx.moveTo(root.plotX(root.points[0].temp), root.plotY(0))
      for (var i = 0; i < root.points.length; i++)
        ctx.lineTo(root.plotX(root.points[i].temp), root.plotY(root.points[i].percent))
      ctx.lineTo(root.plotX(root.points[root.points.length - 1].temp), root.plotY(0))
      ctx.closePath()
      ctx.fillStyle = Qt.alpha(Color.accent, 0.18)
      ctx.fill()

      ctx.beginPath()
      for (var j = 0; j < root.points.length; j++) {
        var x = root.plotX(root.points[j].temp)
        var y = root.plotY(root.points[j].percent)
        if (j === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
      }
      ctx.strokeStyle = Color.accent
      ctx.lineWidth = 2
      ctx.stroke()

      // Where the chip actually is right now.
      if (root.nowTemp >= root.tMin && root.nowTemp <= root.tMax) {
        var nx = root.plotX(root.nowTemp)
        ctx.setLineDash([4, 3])
        ctx.strokeStyle = Qt.rgba(0.42, 0.78, 0.42, 1)
        ctx.lineWidth = 1.5
        ctx.beginPath(); ctx.moveTo(nx, root.padTop); ctx.lineTo(nx, height - root.padBottom); ctx.stroke()
        ctx.setLineDash([])
        ctx.fillStyle = Qt.rgba(0.42, 0.78, 0.42, 1)
        ctx.textAlign = "left"
        ctx.fillText("now " + Math.round(root.nowTemp) + "°", nx + Style.space(4), root.padTop + Style.space(10))
      }

      for (var k = 0; k < root.points.length; k++) {
        ctx.beginPath()
        ctx.arc(root.plotX(root.points[k].temp), root.plotY(root.points[k].percent),
                root.knobRadius, 0, Math.PI * 2)
        ctx.fillStyle = k === root.dragIndex ? Color.accent : Color.menu.background
        ctx.fill()
        ctx.strokeStyle = Color.accent
        ctx.lineWidth = 2
        ctx.stroke()
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: false

    onPressed: function (mouse) {
      root.dragIndex = root.nearest(mouse.x, mouse.y)
      canvas.requestPaint()
    }
    onReleased: {
      if (root.dragIndex !== -1) root.edited()
      root.dragIndex = -1
      canvas.requestPaint()
    }
    onPositionChanged: function (mouse) {
      if (root.dragIndex === -1) return
      var i = root.dragIndex
      // Keep the points ordered in temperature; the firmware rejects a
      // curve whose points cross over.
      var lowT = i === 0 ? root.tMin : root.points[i - 1].temp + 1
      var highT = i === root.points.length - 1 ? root.tMax : root.points[i + 1].temp - 1
      var t = Math.round(Math.max(lowT, Math.min(highT, root.tempAt(mouse.x))))
      var pc = Math.round(Math.max(0, Math.min(100, root.percentAt(mouse.y))))
      root.points[i].temp = t
      root.points[i].percent = pc
      canvas.requestPaint()
    }
  }

  onPointsChanged: canvas.requestPaint()
  onNowTempChanged: canvas.requestPaint()
  onWidthChanged: canvas.requestPaint()
  onHeightChanged: canvas.requestPaint()
}
