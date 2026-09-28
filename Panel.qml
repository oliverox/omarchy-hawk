import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import qs.Ui

// Hawk: the vault in the bar, the console in the panel.
//
// The bar shows account value and today's realized P&L. The panel opens on a
// click (or `omarchy-shell shell toggle oliverox.hawk`) with the header
// figures, the daily realized P&L calendar and the position-value chart —
// the same two views the Hawk console renders, fed by the same queries.
//
// All fetching and all arithmetic happens in `bin/hawk-status`; this file
// only lays out what the script hands over. External strings (coin names)
// render as PlainText only.
Panel {
  id: root

  moduleName: "oliverox.hawk"
  ipcTarget: "oliverox.hawk"

  readonly property string script:
    Qt.resolvedUrl("bin/hawk-status").toString().replace(/^file:\/\//, "")
  readonly property string toastIcon:
    Qt.resolvedUrl("hawk.png").toString().replace(/^file:\/\//, "")

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Gains and losses keep the console's emerald/red so the calendar reads the
  // same way it does on hawkish.app; everything else is the theme's.
  readonly property color gain: "#34d399"
  readonly property color loss: "#f87171"

  readonly property string slug: String(setting("slug", "hawk-2") || "hawk-2")
  readonly property bool notifyEnabled: setting("notify", true) === true

  // What the script's summary hands over, kept as plain properties so the
  // panel redraws by itself when a refresh lands.
  property bool loaded: false
  property bool refreshing: false
  property bool demo: false
  property string errorText: ""
  property var errors: []
  property string label: "Hawk"
  property var vault: ({})
  property var account: ({})
  property var positions: []
  property var today: ({})
  property var daily: ({})
  property var dailyRows: []
  property var windows: ({})
  property var record: ({})
  property string barText: ""
  property string hoverDayText: ""

  // The chart.
  property string navRange: "7d"
  property var navPoints: []
  property real navMin: 0
  property real navMax: 0
  property real navHwm: 0
  property string navCurrentText: ""
  property string navHwmText: ""
  property int navCount: 0
  property bool navLoading: false
  readonly property var navRanges: ["1d", "7d", "15d", "30d", "60d", "90d", "all"]

  // Transitions that deserve a toast, remembered so they fire once.
  property bool wasStale: false
  property bool wasPaused: false

  // For sinks the shell renders as rich text (tooltips, notification
  // summary and body): no markup, no control or bidi characters, capped.
  function plain(value, max) {
    return String(value || "")
      .replace(/[<>&\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, "")
      .slice(0, max || 120)
  }

  readonly property bool paused: vault && vault.paused === true
  readonly property bool stale: vault && vault.stale === true
  readonly property bool attention: paused || stale || errorText !== ""

  readonly property string barLabel:
    !loaded ? "…"
    : errorText !== "" && barText === "" ? "HAWK"
    : (paused ? "⏸ " : (stale ? "⚠ " : "")) + barText

  TextMetrics {
    id: barMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    text: root.barLabel
  }
  readonly property real barContentWidth:
    Math.ceil(barMetrics.advanceWidth) + barIconSize + barGap + Style.space(17)
  implicitWidth: bar && bar.vertical
    ? (bar ? bar.barSize : Style.bar.sizeHorizontal)
    : Math.max(Style.space(26), barContentWidth)
  implicitHeight: bar && bar.vertical
    ? Math.max(Style.space(26), barContentWidth)
    : (bar ? bar.barSize : Style.bar.sizeHorizontal)

  function refresh() {
    if (!summaryProc.running) summaryProc.running = true
  }

  function refreshNav() {
    if (navProc.running) return
    navLoading = true
    navProc.command = ["/usr/bin/bash", root.script, "nav", root.navRange]
    navProc.running = true
  }

  function setRange(range) {
    if (navRanges.indexOf(range) < 0) return
    navRange = range
    refreshNav()
  }

  function applySummary(payload) {
    loaded = true
    refreshing = false
    if (!payload || payload.ok !== true) {
      errorText = String((payload && payload.error) || "Something went wrong")
      return
    }
    errorText = ""
    errors = payload.errors || []
    demo = payload.demo === true
    label = String(payload.label || "Hawk")
    vault = payload.vault || {}
    account = payload.account || {}
    positions = (payload.account && payload.account.positions) || []
    today = payload.today || {}
    daily = payload.daily || {}
    dailyRows = (payload.daily && payload.daily.rows) || []
    windows = (payload.daily && payload.daily.windows) || {}
    record = (payload.daily && payload.daily.record) || {}
    barText = String(payload.barText || "")

    var exits = payload.newExits || []
    if (root.notifyEnabled && exits.length > 0) {
      for (var i = 0; i < exits.length && i < 5; i++) toastExit(exits[i])
    }
    var nowStale = vault.stale === true
    var nowPaused = vault.paused === true
    if (root.notifyEnabled) {
      if (nowStale && !wasStale && loadedOnce) toast("Hawk sync stale", "No bot sync for over 15 minutes.", "critical")
      if (nowPaused && !wasPaused && loadedOnce) toast("Hawk paused", "The bot is not opening new grids.", "normal")
      if (!nowPaused && wasPaused) toast("Hawk resumed", "The bot is live again.", "normal")
    }
    wasStale = nowStale
    wasPaused = nowPaused
    loadedOnce = true
  }
  property bool loadedOnce: false

  function applyNav(payload) {
    navLoading = false
    if (!payload || payload.ok !== true) return
    navPoints = payload.points || []
    navCount = Number(payload.count) || 0
    navMin = Number(payload.min) || 0
    navMax = Number(payload.max) || 0
    navHwm = Number(payload.hwm) || 0
    navCurrentText = String(payload.currentText || "")
    navHwmText = String(payload.hwmText || "")
    chart.requestPaint()
  }

  // Toasts go through notify-send so Omarchy's own notification surface
  // shows them, with the plugin named so silencing applies.
  function toast(title, body, urgency) {
    var proc = notifyComponent.createObject(root, {
      command: ["/usr/bin/notify-send", "-a", "Hawk", "-u", urgency || "normal",
                "-i", root.toastIcon, "--", plain(title), plain(body)]
    })
    proc.running = true
  }
  function toastExit(exit) {
    var coin = plain(exit.coin)
    var pnl = plain(exit.pnlText)
    var px = plain(exit.pxText)
    toast(coin + " " + pnl, "Closed at " + px, "low")
  }

  function openDashboard() {
    openProc.command = ["/usr/bin/xdg-open", "https://hawkish.app/grid/dashboard"]
    openProc.running = true
  }

  function close() { controller.hide() }

  Component {
    id: notifyComponent
    Process {
      onExited: destroy()
    }
  }

  BoundedProcess {
    id: summaryProc
    command: ["/usr/bin/bash", root.script, "summary"]
    environment: ({ HAWK_SLUG: root.slug })
    onDone: function(payload) { root.applySummary(payload) }
  }

  BoundedProcess {
    id: navProc
    timeoutMs: 60000
    environment: ({ HAWK_SLUG: root.slug })
    onDone: function(payload) { root.applyNav(payload) }
  }

  Component.onDestruction: {
    summaryProc.stop()
    navProc.stop()
  }

  Process { id: openProc }

  // The account line does not wait for the panel to be open.
  Timer {
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // The chart only refreshes while someone is looking.
  Timer {
    interval: 300000
    running: root.opened
    repeat: true
    onTriggered: root.refreshNav()
  }

  onOpenedChanged: {
    if (opened) {
      refreshing = true
      refresh()
      refreshNav()
    }
  }

  // The bar entry: the Hawk mark, then the figures. The button's own label
  // is hidden and a row is drawn in its place, the way BarIconButton does it.
  readonly property real barIconSize: Style.space(13)
  readonly property real barGap: Style.space(5)

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.plain(root.barLabel, 60)
    labelVisible: false
    hasVisualContent: true
    foreground: root.attention ? root.urgent : (bar ? bar.barForeground : Color.foreground)
    dimmed: !root.loaded
    tooltipText: root.errorText !== ""
      ? root.plain(root.errorText)
      : (root.loaded ? root.plain(root.label, 60) + " · today " + root.plain(root.today.liveText || "", 30) : "Hawk")
    onPressed: function(b) { root.toggle() }

    Row {
      anchors.centerIn: parent
      spacing: root.barGap
      rotation: button.vertical ? 90 : 0
      HawkIcon {
        anchors.verticalCenter: parent.verticalCenter
        iconSize: root.barIconSize
        color: button.foreground
        opacity: root.loaded ? 1 : 0.6
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.barLabel
        textFormat: Text.PlainText
        color: button.foreground
        opacity: root.loaded ? 1 : 0.6
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys

    readonly property int desiredWidth: Style.space(560)
    contentWidth: Math.min(desiredWidth,
                           panel.availableCardWidth > 0 ? panel.availableCardWidth : desiredWidth)
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    Item {
      id: keys
      anchors.fill: parent
      focus: true

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          root.close()
          event.accepted = true
        } else if (event.key === Qt.Key_R) {
          root.refreshing = true
          root.refresh()
          root.refreshNav()
          event.accepted = true
        } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right) {
          var idx = root.navRanges.indexOf(root.navRange)
          var next = idx + (event.key === Qt.Key_Left ? -1 : 1)
          if (next >= 0 && next < root.navRanges.length) root.setRange(root.navRanges[next])
          event.accepted = true
        }
      }

      ColumnLayout {
        id: content
        width: parent.width
        spacing: Style.space(10)

        // ------------------------------------------------------------ header
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          Text {
            text: root.plain(root.label).toUpperCase()
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            font.letterSpacing: 1
          }
          Badge { visible: root.vault.leverage !== undefined && root.vault.leverage !== null
                  text: (root.vault.leverage || "") + "×"; tint: root.foreground }
          Badge { visible: root.demo; text: "DEMO"; tint: root.accent }
          Badge { visible: root.paused; text: "PAUSED"; tint: root.urgent }
          Badge { visible: root.stale && !root.paused; text: "STALE"; tint: root.urgent }
          Badge { visible: !root.stale && !root.paused && root.loaded && root.errorText === ""
                  text: "LIVE"; tint: root.gain }

          Item { Layout.fillWidth: true }

          FocusableGlyph { glyph: ""; tip: "Open the dashboard"; onActivated: root.openDashboard() }
        }

        // ------------------------------------------------------- error strip
        Text {
          visible: root.errorText !== "" || (root.errors && root.errors.length > 0)
          Layout.fillWidth: true
          text: root.errorText !== "" ? root.plain(root.errorText) : root.plain((root.errors || []).join(" · "))
          textFormat: Text.PlainText
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // ------------------------------------------------------ header strip
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(18)

          Stat { label: "YOUR ACCOUNT"; value: root.plain(root.account.valueText || "—"); big: true }
          Stat { label: "TODAY"; value: root.plain(root.today.liveText || "—")
                 tint: root.signColor(root.today.live); big: true }
          Stat { label: "MARGIN"; value: (root.account.marginPct !== undefined ? root.account.marginPct + "%" : "—") }
          Stat { label: "FREE"; value: root.plain(root.account.freeText || "—") }
          Item { Layout.fillWidth: true }
        }

        // --------------------------------------------------------- positions
        Flow {
          visible: root.positions.length > 0
          Layout.fillWidth: true
          spacing: Style.space(4)
          Repeater {
            model: root.positions
            delegate: Rectangle {
              required property var modelData
              radius: Style.space(3)
              color: Qt.alpha(root.foreground, 0.06)
              border.color: Qt.alpha(root.signColor(modelData.unrealized), 0.35)
              border.width: 1
              implicitWidth: posRow.implicitWidth + Style.space(10)
              implicitHeight: posRow.implicitHeight + Style.space(5)
              Row {
                id: posRow
                anchors.centerIn: parent
                spacing: Style.space(5)
                Text { text: root.plain(modelData.coin); textFormat: Text.PlainText; color: root.foreground
                       font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                Text { text: root.plain(modelData.unrealizedText); textFormat: Text.PlainText
                       color: root.signColor(modelData.unrealized)
                       font.family: root.fontFamily; font.pixelSize: Style.font.caption }
              }
            }
          }
        }

        PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

        // ---------------------------------------------------- daily calendar
        SectionTitle { text: "DAILY REALIZED P&L" }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(14)

          // Roll-ups down the left, the console's column.
          ColumnLayout {
            Layout.alignment: Qt.AlignTop
            Layout.preferredWidth: Style.space(96)
            spacing: Style.space(6)
            Stat { label: "TODAY"; value: root.plain(root.windows.todayText || "—"); tint: root.signColor(root.windows.today); big: true }
            Stat { label: "YESTERDAY"; value: root.plain(root.windows.yesterdayText || "—"); tint: root.signColor(root.windows.yesterday) }
            Stat { label: "2 DAYS AGO"; value: root.plain(root.windows.dayBeforeText || "—"); tint: root.signColor(root.windows.dayBefore) }
            Stat { label: "LAST 7D"; value: root.plain(root.windows.last7Text || "—"); tint: root.signColor(root.windows.last7) }
            Stat { label: "LAST 15D"; value: root.plain(root.windows.last15Text || "—"); tint: root.signColor(root.windows.last15) }
            Stat { label: "LAST 30D"; value: root.plain(root.windows.last30Text || "—"); tint: root.signColor(root.windows.last30) }
          }

          // The heatmap: one column per week, Monday at the top, oldest on
          // the left, exactly the console's grid.
          ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignTop
            spacing: Style.space(4)

            readonly property var grid: root.buildGrid(root.dailyRows, root.daily.days || 70, root.daily.todayKey || "")
            readonly property int cell: Style.space(30)
            readonly property int gap: Style.space(3)

            // Month labels over the first column of each month.
            Item {
              Layout.fillWidth: true
              implicitHeight: Style.font.caption + Style.space(2)
              Repeater {
                model: parent.parent.grid.months
                delegate: Text {
                  required property var modelData
                  x: Style.space(30) + modelData.col * (parent.parent.cell + parent.parent.gap)
                  text: modelData.label
                  textFormat: Text.PlainText
                  color: root.foreground
                  opacity: 0.55
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }
              }
            }

            Row {
              id: gridRow
              spacing: parent.gap
              readonly property var dows: ["MON", "", "WED", "", "FRI", "", "SUN"]

              Column {
                spacing: gridRow.parent.gap
                width: Style.space(30) - gridRow.parent.gap
                Repeater {
                  model: 7
                  delegate: Item {
                    required property int index
                    width: Style.space(26)
                    height: gridRow.parent.cell
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: gridRow.dows[index]
                      textFormat: Text.PlainText
                      color: root.foreground
                      opacity: 0.45
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }

              Repeater {
                model: gridRow.parent.grid.weeks
                delegate: Column {
                  required property var modelData
                  spacing: gridRow.parent.gap
                  Repeater {
                    model: modelData
                    delegate: DayCell {
                      required property var modelData
                      day: modelData
                      size: gridRow.parent.cell
                    }
                  }
                }
              }
            }

            // The record, one line; a hovered day replaces it with its figure.
            Text {
              Layout.alignment: Qt.AlignRight
              Layout.topMargin: Style.space(2)
              text: root.hoverDayText !== "" ? root.hoverDayText : root.recordText()
              textFormat: Text.PlainText
              color: root.foreground
              opacity: root.hoverDayText !== "" ? 0.9 : 0.55
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

        // ---------------------------------------------------- position value
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)
          SectionTitle { text: "POSITION VALUE" }
          Item { Layout.fillWidth: true }
          Row {
            spacing: Style.space(2)
            Repeater {
              model: root.navRanges
              delegate: RangePill {
                required property var modelData
                label: modelData.toUpperCase()
                selected: root.navRange === modelData
                onActivated: root.setRange(modelData)
              }
            }
          }
        }

        Item {
          Layout.fillWidth: true
          implicitHeight: Style.space(150)

          Canvas {
            id: chart
            anchors.fill: parent
            anchors.rightMargin: Style.space(54)
            renderStrategy: Canvas.Cooperative

            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()
              var w = width, h = height
              var pts = root.navPoints
              if (!pts || pts.length < 2) return
              // The range is the series' own, like the console: a high-water
              // mark far above it stays in the caption rather than squashing
              // the line into the bottom of the chart.
              var lo = root.navMin, hi = root.navMax
              if (hi - lo < 1e-9) { hi = lo + 1 }
              var pad = (hi - lo) * 0.08
              lo -= pad; hi += pad
              var t0 = pts[0].t, t1 = pts[pts.length - 1].t
              if (t1 - t0 < 1) t1 = t0 + 1
              var top = Style.space(6), bottom = h - Style.space(4)
              function X(t) { return (t - t0) / (t1 - t0) * w }
              function Y(v) { return bottom - (v - lo) / (hi - lo) * (bottom - top) }

              // Area under the line, faded.
              ctx.beginPath()
              ctx.moveTo(X(pts[0].t), bottom)
              for (var i = 0; i < pts.length; i++) ctx.lineTo(X(pts[i].t), Y(pts[i].v))
              ctx.lineTo(X(pts[pts.length - 1].t), bottom)
              ctx.closePath()
              var grad = ctx.createLinearGradient(0, top, 0, bottom)
              grad.addColorStop(0, Qt.alpha(root.gain, 0.28))
              grad.addColorStop(1, Qt.alpha(root.gain, 0.02))
              ctx.fillStyle = grad
              ctx.fill()

              // The current-value line, the console's horizontal reference.
              var cur = pts[pts.length - 1].v
              ctx.beginPath()
              ctx.strokeStyle = Qt.alpha(root.foreground, 0.45)
              ctx.lineWidth = 1
              ctx.moveTo(0, Y(cur)); ctx.lineTo(w, Y(cur))
              ctx.stroke()

              // The high-water mark, dashed, only when it falls inside the
              // range. Dashes drawn by hand: QML's Canvas has no setLineDash.
              if (root.navHwm > 0 && root.navHwm >= lo && root.navHwm <= hi) {
                ctx.beginPath()
                ctx.strokeStyle = Qt.alpha(root.foreground, 0.55)
                ctx.lineWidth = 1
                var yh = Y(root.navHwm)
                for (var xd = 0; xd < w; xd += 6) { ctx.moveTo(xd, yh); ctx.lineTo(Math.min(w, xd + 3), yh) }
                ctx.stroke()
              }

              // The line.
              ctx.beginPath()
              ctx.strokeStyle = root.gain
              ctx.lineWidth = 1.5
              ctx.lineJoin = "round"
              for (var j = 0; j < pts.length; j++) {
                if (j === 0) ctx.moveTo(X(pts[j].t), Y(pts[j].v))
                else ctx.lineTo(X(pts[j].t), Y(pts[j].v))
              }
              ctx.stroke()

              // Current value marker.
              var last = pts[pts.length - 1]
              ctx.beginPath()
              ctx.fillStyle = root.gain
              ctx.arc(X(last.t), Y(last.v), 2.5, 0, Math.PI * 2)
              ctx.fill()
            }
          }

          // Axis labels on the right: max, HWM, current, min.
          Column {
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: Style.space(50)
            Text { text: root.navCount > 0 ? root.fmtMoney(root.navMax) : ""; textFormat: Text.PlainText
                   color: root.foreground; opacity: 0.45; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            Item { width: 1; height: parent.height - Style.font.caption * 3 - Style.space(10) }
            Text { text: root.navCount > 0 ? root.fmtMoney(root.navMin) : ""; textFormat: Text.PlainText
                   color: root.foreground; opacity: 0.45; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
          }
          Rectangle {
            visible: root.navCount > 0
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            radius: Style.space(3)
            color: Qt.alpha(root.gain, 0.18)
            border.color: root.gain
            border.width: 1
            implicitWidth: curText.implicitWidth + Style.space(8)
            implicitHeight: curText.implicitHeight + Style.space(3)
            Text {
              id: curText
              anchors.centerIn: parent
              text: root.plain(root.navCurrentText)
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }
          Text {
            visible: root.navLoading && root.navCount === 0
            anchors.centerIn: parent
            text: "loading…"
            textFormat: Text.PlainText
            color: root.foreground
            opacity: 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

      }
    }
  }

  // ------------------------------------------------------------ helpers

  function signColor(v) {
    var n = Number(v)
    if (isNaN(n) || Math.abs(n) < 0.005) return foreground
    return n > 0 ? gain : loss
  }

  function fmtMoney(v) {
    var n = Number(v) || 0
    return (n < 0 ? "-$" : "$") + Math.abs(n).toFixed(2)
  }

  function ageText(sec) {
    var s = Number(sec)
    if (isNaN(s)) return "?"
    if (s < 90) return s + "s ago"
    if (s < 5400) return Math.floor(s / 60) + "m ago"
    if (s < 129600) return Math.floor(s / 3600) + "h ago"
    return Math.floor(s / 86400) + "d ago"
  }

  function recordText() {
    var r = record || {}
    if (r.wins === undefined) return ""
    var rate = r.winRate === null || r.winRate === undefined ? "" : " · " + r.winRate + "%"
    var sums = r.gainText ? "    " + plain(r.gainText) + " · " + plain(r.lossText) : ""
    return r.wins + "W · " + r.losses + "L" + rate + sums
  }

  // The console's buildGrid: the last `days` UTC days, Monday-first columns,
  // leading blanks so the first day lands on its weekday. Each cell carries
  // its row (or null) so the delegate needs no lookup.
  function buildGrid(rows, days, todayKey) {
    var byDay = {}
    for (var i = 0; i < rows.length; i++) byDay[rows[i].day] = rows[i]
    var now = todayKey ? Date.parse(todayKey + "T00:00:00Z") : Date.now()
    var cells = []
    var first = new Date(now - (days - 1) * 86400000)
    var firstDow = (first.getUTCDay() + 6) % 7
    for (var p = 0; p < firstDow; p++) cells.push(null)
    var months = []
    var lastMonth = -1
    for (var d = days - 1; d >= 0; d--) {
      var dt = new Date(now - d * 86400000)
      var key = dt.toISOString().slice(0, 10)
      var col = Math.floor(cells.length / 7)
      if (dt.getUTCMonth() !== lastMonth) {
        lastMonth = dt.getUTCMonth()
        if (months.length === 0 || months[months.length - 1].col !== col)
          months.push({ col: col, label: ["JAN","FEB","MAR","APR","MAY","JUN","JUL","AUG","SEP","OCT","NOV","DEC"][lastMonth] })
      }
      var row = byDay[key]
      cells.push({ key: key, today: key === todayKey, net: row ? row.netRealized : null,
                   cycles: row ? row.cycleCount : 0, fills: row ? row.fillCount : 0 })
    }
    while (cells.length % 7 !== 0) cells.push(null)
    var weeks = []
    for (var w = 0; w < cells.length; w += 7) weeks.push(cells.slice(w, w + 7))
    // Drop a month label that would sit on the first, padded column with no
    // real day, and keep the first label only when it has room.
    return { weeks: weeks, months: months }
  }

  function cellColor(net) {
    if (net === null || net === undefined) return Qt.alpha(foreground, 0.05)
    var n = Number(net)
    var maxAbs = Number(daily.maxAbs) || 0
    if (Math.abs(n) < 0.005 || maxAbs <= 0) return Qt.alpha(foreground, 0.08)
    var intensity = Math.min(1, Math.abs(n) / maxAbs)
    var lvl = Math.min(4, Math.floor(intensity * 5))
    var alphas = [0.18, 0.32, 0.48, 0.66, 0.85]
    return Qt.alpha(n > 0 ? gain : loss, alphas[lvl])
  }

  function cellText(net) {
    if (net === null || net === undefined) return ""
    var n = Number(net)
    if (Math.abs(n) < 0.005) return ""
    var a = Math.abs(n)
    var s = a >= 100 ? a.toFixed(0) : a >= 10 ? a.toFixed(0) : a.toFixed(1)
    return (n > 0 ? "+" : "-") + s
  }

  // ---------------------------------------------------------- components

  component Badge: Rectangle {
    property string text: ""
    property color tint: root.foreground
    color: "transparent"
    border.color: tint
    border.width: 1
    radius: Style.space(3)
    implicitWidth: badgeText.implicitWidth + Style.space(8)
    implicitHeight: badgeText.implicitHeight + Style.space(3)
    Text {
      id: badgeText
      anchors.centerIn: parent
      text: parent.text
      textFormat: Text.PlainText
      color: parent.tint
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  component SectionTitle: Text {
    textFormat: Text.PlainText
    color: root.foreground
    opacity: 0.7
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 1.5
  }

  component Stat: Column {
    property string label: ""
    property string value: ""
    property color tint: root.foreground
    property bool big: false
    spacing: Style.space(1)
    Text {
      text: parent.label
      textFormat: Text.PlainText
      color: root.foreground
      opacity: 0.5
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
    }
    Text {
      text: parent.value
      textFormat: Text.PlainText
      color: parent.tint
      font.family: root.fontFamily
      font.pixelSize: parent.big ? Style.font.heading : Style.font.title
      font.bold: true
    }
  }

  component FocusableGlyph: Rectangle {
    id: glyphButton
    property string glyph: ""
    property string tip: ""
    signal activated()
    implicitWidth: Style.space(24)
    implicitHeight: Style.space(24)
    radius: Style.space(4)
    color: glyphMouse.containsMouse || activeFocus ? Qt.alpha(root.accent, 0.18) : "transparent"
    activeFocusOnTab: true
    Text {
      anchors.centerIn: parent
      text: glyphButton.glyph
      textFormat: Text.PlainText
      color: glyphButton.activeFocus ? root.accent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
    }
    MouseArea {
      id: glyphMouse
      anchors.fill: parent
      hoverEnabled: true
      onClicked: glyphButton.activated()
    }
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
        glyphButton.activated()
        event.accepted = true
      }
    }
  }

  component RangePill: Rectangle {
    id: pill
    property string label: ""
    property bool selected: false
    signal activated()
    implicitWidth: pillText.implicitWidth + Style.space(8)
    implicitHeight: pillText.implicitHeight + Style.space(4)
    radius: Style.space(3)
    color: pill.selected ? Qt.alpha(root.accent, 0.25)
      : (pillMouse.containsMouse || activeFocus ? Qt.alpha(root.accent, 0.12) : "transparent")
    border.color: pill.selected ? root.accent : Qt.alpha(root.foreground, 0.15)
    border.width: 1
    activeFocusOnTab: true
    Text {
      id: pillText
      anchors.centerIn: parent
      text: pill.label
      textFormat: Text.PlainText
      color: pill.selected ? root.accent : root.foreground
      opacity: pill.selected ? 1 : 0.7
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: pill.selected
    }
    MouseArea {
      id: pillMouse
      anchors.fill: parent
      hoverEnabled: true
      onClicked: pill.activated()
    }
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
        pill.activated()
        event.accepted = true
      }
    }
  }

  component DayCell: Rectangle {
    id: cell
    property var day: null
    property int size: Style.space(30)
    width: size
    height: size
    radius: Style.space(4)
    color: day ? root.cellColor(day.net) : "transparent"
    border.color: day && day.today ? root.accent
      : (day && day.net !== null && day.net !== undefined && Math.abs(Number(day.net)) >= 0.005
         ? Qt.alpha(Number(day.net) > 0 ? root.gain : root.loss, 0.5)
         : Qt.alpha(root.foreground, day ? 0.1 : 0))
    border.width: day && day.today ? 2 : 1
    Text {
      anchors.centerIn: parent
      text: cell.day ? root.cellText(cell.day.net) : ""
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      enabled: cell.day !== null
      onEntered: {
        if (!cell.day) return
        var d = cell.day
        var v = d.net === null || d.net === undefined ? "no fills" : root.fmtMoney(d.net)
        root.hoverDayText = d.key + "  " + v + (d.cycles ? "  · " + d.cycles + " cycles" : "")
      }
      onExited: root.hoverDayText = ""
    }
  }
}
