import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Chart panel for the Omastonk watchlist. Chart data comes from the Rust
// backend (`omastonk-qs chart`); this file owns presentation, the symbol
// tabs, the interval picker, and the watchlist editor.
Panel {
  id: root
  moduleName: "luca.omastonk"
  manageIpc: false

  property var anchorItem: null
  property var host: null
  property var draftSymbols: []
  property bool editing: true
  property int intervalIndex: 6
  property string activeSymbol: ""
  property var chartPoints: []
  property string chartStatus: "idle"
  property string chartErrorMessage: ""
  property string chartOutput: ""
  property string requestedChartKey: ""
  property string prefetchChartKey: ""
  property bool chartPrefetch: false
  property var chartCache: ({})
  property var prefetchQueue: []
  property string editorError: ""
  property var searchSuggestions: []
  property int searchHighlight: 0
  property string searchQuery: ""
  property string searchOutput: ""

  readonly property color foreground: Color.popups.text
  readonly property color dim: Qt.darker(foreground, 1.65)
  readonly property bool intervalDown: chartPoints.length > 1 && chartPoints[chartPoints.length - 1] < chartPoints[0]
  readonly property bool intervalUp: chartPoints.length > 1 && chartPoints[chartPoints.length - 1] > chartPoints[0]
  readonly property color upColor: host && host.upColor !== undefined ? host.upColor : "#6a9f72"
  readonly property color chartColor: intervalDown ? Color.bar.active : (intervalUp ? upColor : Color.bar.text)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string backendBinary: host ? host.backendBinary : "omastonk-qs"
  readonly property var symbols: host ? host.symbols : fallbackSymbols()
  readonly property int activeIndex: symbols.indexOf(activeSymbol)
  readonly property real intervalPriceChange: chartPoints.length > 1 ? chartPoints[chartPoints.length - 1] - chartPoints[0] : NaN
  readonly property real intervalPercentChange: chartPoints.length > 1 && chartPoints[0] !== 0 ? intervalPriceChange / chartPoints[0] * 100 : NaN
  readonly property var intervalOptions: [
    { label: "5Y", range: "5y", interval: "1wk" },
    { label: "1Y", range: "1y", interval: "1d" },
    { label: "YTD", range: "ytd", interval: "1d" },
    { label: "6M", range: "6mo", interval: "1d" },
    { label: "1M", range: "1mo", interval: "1d" },
    { label: "5D", range: "5d", interval: "15m" },
    { label: "1D", range: "1d", interval: "5m" }
  ]
  readonly property int chartPanelWidth: Math.ceil(Math.max(intervalSizer.implicitWidth, tabSizer.implicitWidth, changeSizer.implicitWidth + Style.space(88)) + Style.space(28))
  readonly property var selectedInterval: intervalOptions[Math.max(0, Math.min(intervalIndex, intervalOptions.length - 1))]
  readonly property string selectedIntervalLabel: selectedInterval ? selectedInterval.label : "1D"
  readonly property string chartStatusText: chartStatus === "loading" ? "Loading" : (chartStatus === "error" ? (chartErrorMessage !== "" ? chartErrorMessage : "No data") : "")
  readonly property string intervalChangeText: chartStatus === "ready" && isFinite(intervalPriceChange)
    ? Model.formatSignedPrice(intervalPriceChange) + " (" + Model.formatSignedPercent(intervalPercentChange) + ")"
    : (chartStatus === "loading" ? "..." : "?")
  readonly property int chartCacheTtlMs: (host && host.pollIntervalSecs ? host.pollIntervalSecs : 60) * 1000
  readonly property int draftCount: draftSymbols.length
  readonly property bool atSymbolCap: draftCount >= Model.MAX_SYMBOLS
  readonly property bool searchOpen: editing && searchSuggestions.length > 0

  function chartKeyFor(symbol, intervalLabel) {
    return symbol + "|" + intervalLabel
  }

  function chartKey() {
    return chartKeyFor(activeSymbol, selectedIntervalLabel)
  }

  // Property reads inside imported JS files are not tracked by QML
  // bindings, so the settings fallback must live here. Injected settings
  // hold QML lists, which Array.isArray rejects.
  function fallbackSymbols() {
    var raw = settings ? settings.symbols : undefined
    if (raw !== null && typeof raw === "object" && typeof raw.length === "number")
      return Model.normalizeSymbols(raw)
    var legacy = Model.normalizeSymbol(setting("symbol", ""))
    return legacy === "" ? [] : [legacy]
  }

  function syncIntervalFromHost() {
    var label = host && host.chartInterval
      ? host.chartInterval
      : Model.normalizeChartInterval(setting("chartInterval", "1D"))
    intervalIndex = Model.intervalIndexForLabel(label, intervalOptions.length)
  }

  function openSymbol(symbol) {
    syncIntervalFromHost()
    var next = Model.normalizeSymbol(symbol)
    if (next !== "" && symbols.indexOf(next) !== -1) activeSymbol = next
    editing = symbols.length === 0
    editorError = ""
    clearSearch()
    root.controller.show()
    Qt.callLater(function() {
      if (root.editing) focusAddField()
      else {
        keyCatcher.forceActiveFocus()
        refreshChart(false)
      }
    })
  }

  function open() {
    var next = symbols.indexOf(activeSymbol) !== -1 ? activeSymbol : (symbols.length > 0 ? symbols[0] : "")
    openSymbol(next)
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function focusAddField() {
    if (!addField) return
    addField.forceActiveFocus()
    addField.selectAll()
  }

  function editSymbols() {
    draftSymbols = symbols.slice()
    editorError = ""
    clearSearch()
    editing = true
    Qt.callLater(focusAddField)
  }

  function openEditor() {
    editSymbols()
    root.controller.show()
  }

  function cancelEdit() {
    clearSearch()
    if (symbols.length === 0) {
      root.close()
      return
    }

    editing = false
    editorError = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function submit() {
    addDraftSymbol(addField.text)
    var next = Model.normalizeSymbols(draftSymbols)
    if (next.length > Model.MAX_SYMBOLS) {
      editorError = "Watchlist exceeds " + Model.MAX_SYMBOLS + " symbols"
      return
    }
    editorError = ""
    clearSearch()
    if (host && host.setSymbols) host.setSymbols(next)
    else draftSymbols = next

    if (next.length === 0) {
      chartPoints = []
      chartStatus = "idle"
      editing = true
      Qt.callLater(focusAddField)
      return
    }

    if (next.indexOf(activeSymbol) === -1) activeSymbol = next[0]
    editing = false
    Qt.callLater(function() {
      keyCatcher.forceActiveFocus()
      refreshChart(true)
    })
  }

  function addDraftSymbol(value) {
    var parts = String(value || "").trim().toUpperCase().split(/\s+/)
    var next = draftSymbols.slice()
    for (var i = 0; i < parts.length; i++) {
      var symbol = Model.normalizeSymbol(parts[i])
      if (symbol === "" || next.indexOf(symbol) !== -1) continue
      if (next.length >= Model.MAX_SYMBOLS) {
        editorError = "Watchlist is full (" + Model.MAX_SYMBOLS + "/" + Model.MAX_SYMBOLS + ")"
        draftSymbols = next
        addField.text = ""
        addField.forceActiveFocus()
        return
      }
      next.push(symbol)
    }
    draftSymbols = next
    editorError = ""
    clearSearch()
    addField.text = ""
    addField.forceActiveFocus()
  }

  function removeDraftSymbol(index) {
    if (index < 0 || index >= draftSymbols.length) return
    var next = []
    for (var i = 0; i < draftSymbols.length; i++) {
      if (i !== index) next.push(draftSymbols[i])
    }
    draftSymbols = next
    if (draftSymbols.length < Model.MAX_SYMBOLS) editorError = ""
  }

  function moveDraftSymbol(index, delta) {
    var target = index + delta
    if (index < 0 || index >= draftSymbols.length) return
    if (target < 0 || target >= draftSymbols.length) return
    var next = draftSymbols.slice()
    var tmp = next[index]
    next[index] = next[target]
    next[target] = tmp
    draftSymbols = next
  }

  function clearSearch() {
    searchSuggestions = []
    searchHighlight = 0
    searchQuery = ""
    searchDebounce.stop()
    searchProc.running = false
  }

  function scheduleSearch(text) {
    searchQuery = String(text || "").trim()
    if (searchQuery.length < 1) {
      clearSearch()
      return
    }
    searchDebounce.restart()
  }

  function runSearch() {
    if (searchQuery.length < 1) return
    searchProc.command = [backendBinary, "search", "--query", searchQuery]
    searchProc.running = false
    Qt.callLater(function() { searchProc.running = true })
  }

  function applySearch(raw) {
    var parsed = Model.parseSearchLine(raw)
    if (parsed.state !== "ok") {
      searchSuggestions = []
      return
    }
    var filtered = []
    for (var i = 0; i < parsed.suggestions.length; i++) {
      var entry = parsed.suggestions[i]
      if (draftSymbols.indexOf(entry.symbol) !== -1) continue
      filtered.push(entry)
    }
    searchSuggestions = filtered
    searchHighlight = 0
  }

  function acceptSearchHighlight() {
    if (searchSuggestions.length === 0) return false
    var index = Math.max(0, Math.min(searchHighlight, searchSuggestions.length - 1))
    addDraftSymbol(searchSuggestions[index].symbol)
    return true
  }

  function selectSymbol(index) {
    if (symbols.length === 0) return
    var next = ((index % symbols.length) + symbols.length) % symbols.length
    if (symbols[next] === activeSymbol) return
    activeSymbol = symbols[next]
    if (host && host.setActiveSymbol) host.setActiveSymbol(activeSymbol)
    refreshChart(false)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function moveSymbol(delta) {
    if (activeIndex === -1) return
    selectSymbol(activeIndex + delta)
  }

  function selectInterval(index) {
    var next = Model.clampIntervalIndex(index, intervalOptions.length)
    if (next === intervalIndex) return
    intervalIndex = next
    var label = intervalOptions[next] ? intervalOptions[next].label : "1D"
    if (host && host.setChartInterval) host.setChartInterval(label)
    refreshChart(false)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function moveInterval(delta) {
    selectInterval(intervalIndex + delta)
  }

  function cacheGet(key) {
    var entry = chartCache[key]
    if (!entry || entry.status !== "ready") return null
    if ((Date.now() - entry.at) > chartCacheTtlMs) return null
    return entry
  }

  function cachePut(key, points, status, message) {
    var next = {}
    for (var existing in chartCache) next[existing] = chartCache[existing]
    next[key] = {
      points: points,
      status: status,
      message: message || "",
      at: Date.now()
    }
    chartCache = next
  }

  function enqueuePrefetch() {
    if (!opened || editing || activeSymbol === "" || symbols.length === 0) return
    var neighbors = []
    if (activeIndex >= 0) {
      if (symbols.length > 1) {
        neighbors.push(symbols[(activeIndex + 1) % symbols.length])
        if (symbols.length > 2)
          neighbors.push(symbols[(activeIndex - 1 + symbols.length) % symbols.length])
      }
    }
    var queue = prefetchQueue.slice()
    for (var i = 0; i < neighbors.length; i++) {
      var key = chartKeyFor(neighbors[i], selectedIntervalLabel)
      if (neighbors[i] === activeSymbol) continue
      if (cacheGet(key)) continue
      if (queue.indexOf(key) !== -1) continue
      queue.push(key)
    }
    prefetchQueue = queue
    pumpPrefetch()
  }

  function pumpPrefetch() {
    if (chartProc.running || editing || !opened) return
    while (prefetchQueue.length > 0) {
      var key = prefetchQueue[0]
      prefetchQueue = prefetchQueue.slice(1)
      if (cacheGet(key)) continue
      var parts = key.split("|")
      if (parts.length < 2) continue
      startChartFetch(parts[0], parts[1], true)
      return
    }
  }

  function cancelPrefetchIfRunning() {
    if (!chartProc.running || !chartPrefetch) return
    chartProc.running = false
    chartPrefetch = false
    prefetchChartKey = ""
    chartWatchdog.stop()
  }

  function startChartFetch(symbol, intervalLabel, isPrefetch) {
    var option = null
    for (var i = 0; i < intervalOptions.length; i++) {
      if (intervalOptions[i].label === intervalLabel) {
        option = intervalOptions[i]
        break
      }
    }
    if (!option) option = selectedInterval || intervalOptions[0]
    var key = chartKeyFor(symbol, option.label)
    chartOutput = ""
    if (isPrefetch === true) {
      chartPrefetch = true
      prefetchChartKey = key
    } else {
      chartPrefetch = false
      prefetchChartKey = ""
      requestedChartKey = key
      chartPoints = []
      chartStatus = "loading"
      chartErrorMessage = ""
    }
    chartProc.command = [backendBinary, "chart", "--symbol", symbol, "--range", option.range, "--interval", option.interval]
    chartProc.running = true
    chartWatchdog.restart()
  }

  function refreshChart(force) {
    if (editing || activeSymbol === "") return
    var key = chartKey()
    if (!force) {
      var cached = cacheGet(key)
      if (cached) {
        chartPoints = cached.points
        chartStatus = "ready"
        chartErrorMessage = ""
        requestedChartKey = key
        Qt.callLater(enqueuePrefetch)
        return
      }
      if (chartStatus === "ready" && requestedChartKey === key) return
    }

    if (chartProc.running) {
      if (chartPrefetch) cancelPrefetchIfRunning()
      else return
    }

    startChartFetch(activeSymbol, selectedIntervalLabel, false)
  }

  function applyChart(raw) {
    var parsed = Model.parseChartLine(raw)
    var status = parsed.state === "ok" ? "ready" : "error"
    if (chartPrefetch) {
      var prefetchKey = prefetchChartKey
      cachePut(prefetchKey, parsed.points, status, parsed.message || "")
      chartPrefetch = false
      prefetchChartKey = ""
      Qt.callLater(pumpPrefetch)
      return
    }
    cachePut(requestedChartKey, parsed.points, status, parsed.message || "")
    chartPoints = parsed.points
    chartStatus = status
    chartErrorMessage = parsed.message || ""
    if (status === "ready") Qt.callLater(enqueuePrefetch)
  }

  onHostChanged: {
    syncIntervalFromHost()
    if (host && symbols.length > 0 && symbols.indexOf(activeSymbol) === -1) activeSymbol = symbols[0]
  }

  onSymbolsChanged: {
    if (symbols.indexOf(activeSymbol) === -1) {
      activeSymbol = symbols.length > 0 ? symbols[0] : ""
    }
    if (opened && !editing && activeSymbol !== "") Qt.callLater(function() { refreshChart(true) })
  }

  onActiveSymbolChanged: {
    cancelPrefetchIfRunning()
    var cached = cacheGet(chartKey())
    if (cached) {
      chartPoints = cached.points
      chartStatus = "ready"
      chartErrorMessage = ""
      requestedChartKey = chartKey()
      if (opened && !editing) Qt.callLater(enqueuePrefetch)
      return
    }
    chartPoints = []
    chartStatus = "idle"
    chartErrorMessage = ""
    if (opened && !editing && activeSymbol !== "") Qt.callLater(function() { refreshChart(false) })
  }

  onChartPointsChanged: chartCanvas.requestPaint()
  onChartColorChanged: chartCanvas.requestPaint()
  onIntervalIndexChanged: chartCanvas.requestPaint()

  Process {
    id: chartProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.chartOutput = text
    }
    onExited: function(exitCode) {
      chartWatchdog.stop()
      if (root.chartPrefetch) {
        root.applyChart(root.chartOutput)
        root.chartOutput = ""
        return
      }
      if (root.requestedChartKey !== root.chartKey()) {
        root.chartOutput = ""
        if (root.opened && !root.editing && root.activeSymbol !== "") Qt.callLater(function() { root.refreshChart(true) })
        return
      }

      root.applyChart(root.chartOutput)
      root.chartOutput = ""
    }
  }

  Process {
    id: searchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.searchOutput = text
    }
    onExited: function(exitCode) {
      root.applySearch(root.searchOutput)
      root.searchOutput = ""
    }
  }

  // A fetch must finish (or fail) within curl's own timeout plus margin.
  // Covers both a backend that fails to spawn and one that hangs: without
  // this the panel would sit on "Loading" forever.
  Timer {
    id: chartWatchdog
    interval: 10000
    onTriggered: {
      if (root.chartPrefetch) {
        chartProc.running = false
        root.chartPrefetch = false
        root.prefetchChartKey = ""
        Qt.callLater(root.pumpPrefetch)
        return
      }
      if (root.chartStatus !== "loading") return
      chartProc.running = false
      root.chartPoints = []
      root.chartStatus = "error"
      root.chartErrorMessage = "Backend unavailable"
    }
  }

  Timer {
    id: searchDebounce
    interval: 200
    repeat: false
    onTriggered: root.runSearch()
  }

  Row {
    id: intervalSizer
    opacity: 0
    height: 0
    enabled: false
    spacing: Style.space(6)

    Repeater {
      model: root.intervalOptions

      Button {
        required property var modelData
        text: modelData.label
        selected: true
        horizontalPadding: Style.space(8)
        verticalPadding: Style.space(5)
      }
    }
  }

  Row {
    id: tabSizer
    opacity: 0
    height: 0
    enabled: false
    spacing: Style.space(6)

    Repeater {
      model: root.symbols

      Button {
        required property var modelData
        text: modelData
        selected: true
        horizontalPadding: Style.space(8)
        verticalPadding: Style.space(5)
      }
    }
  }

  Text {
    id: changeSizer
    opacity: 0
    height: 0
    enabled: false
    text: root.intervalChangeText
    textFormat: Text.PlainText
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  KeyboardPanel {
    id: symbolPanel
    anchorItem: root.anchorItem
    owner: root.host || root
    bar: root.bar
    open: root.opened
    focusTarget: root.editing ? addField : keyCatcher
    contentWidth: symbolPanel.fittedContentWidth(root.editing ? Style.space(300) : root.chartPanelWidth)
    contentHeight: symbolPanel.fittedContentHeight(root.editing ? editorColumn.implicitHeight : chartColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editing
      onMoveRequested: function(dx, dy) {
        if (dx < 0) root.moveInterval(-1)
        else if (dx > 0) root.moveInterval(1)
        else if (dy < 0) root.moveSymbol(-1)
        else if (dy > 0) root.moveSymbol(1)
      }
      onCloseRequested: root.close()
      onTextKey: function(text) {
        if (!/^[1-9]$/.test(text)) return
        var index = Number(text) - 1
        if (index < root.symbols.length) root.selectSymbol(index)
      }

      Column {
        id: chartColumn
        visible: !root.editing
        width: parent.width
        spacing: Style.space(10)

        Row {
          id: headerRow
          width: parent.width
          height: Math.max(symbolTitle.implicitHeight, priceLabel.implicitHeight)
          spacing: Style.space(8)

          Text {
            id: symbolTitle
            width: Math.min(implicitWidth, Math.max(1, parent.width - priceLabel.implicitWidth - parent.spacing))
            height: parent.height
            text: root.activeSymbol
            textFormat: Text.PlainText
            color: root.chartColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            elide: Text.ElideRight
            verticalAlignment: Text.AlignVCenter
          }

          Item {
            width: Math.max(0, parent.width - symbolTitle.width - priceLabel.implicitWidth - parent.spacing * 2)
            height: parent.height
          }

          Text {
            id: priceLabel
            height: parent.height
            text: root.intervalChangeText
            textFormat: Text.PlainText
            color: root.chartColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            verticalAlignment: Text.AlignVCenter
          }
        }

        Rectangle {
          width: parent.width
          height: Style.space(152)
          color: "transparent"
          border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
          border.width: Math.max(1, Style.spacing.hairline)
          radius: Math.min(Style.cornerRadius, Style.space(6))

          Canvas {
            id: chartCanvas
            anchors.fill: parent
            anchors.margins: Style.space(10)

            onPaint: {
              var ctx = getContext("2d")
              ctx.clearRect(0, 0, width, height)

              var points = root.chartPoints || []
              if (points.length < 2) return

              var min = points[0]
              var max = points[0]
              for (var i = 1; i < points.length; i++) {
                min = Math.min(min, points[i])
                max = Math.max(max, points[i])
              }

              if (max === min) {
                max += 1
                min -= 1
              }

              var pad = Style.space(2)
              var drawW = Math.max(1, width - pad * 2)
              var drawH = Math.max(1, height - pad * 2)

              ctx.strokeStyle = Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10)
              ctx.lineWidth = 1
              ctx.beginPath()
              for (var grid = 1; grid < 4; grid++) {
                var gy = pad + drawH * grid / 4
                ctx.moveTo(pad, gy)
                ctx.lineTo(width - pad, gy)
              }
              ctx.stroke()

              ctx.strokeStyle = root.chartColor
              ctx.fillStyle = Qt.rgba(root.chartColor.r, root.chartColor.g, root.chartColor.b, 0.16)
              ctx.lineWidth = 0.5
              ctx.lineJoin = "round"
              ctx.lineCap = "round"
              ctx.beginPath()

              for (var p = 0; p < points.length; p++) {
                var x = pad + (points.length === 1 ? 0 : p * drawW / (points.length - 1))
                var y = pad + (1 - (points[p] - min) / (max - min)) * drawH
                if (p === 0) ctx.moveTo(x, y)
                else ctx.lineTo(x, y)
              }

              ctx.stroke()
              ctx.lineTo(width - pad, height - pad)
              ctx.lineTo(pad, height - pad)
              ctx.closePath()
              ctx.fill()
            }
          }

          Text {
            anchors.centerIn: parent
            width: parent.width - Style.space(16)
            visible: root.chartStatusText !== ""
            text: root.chartStatusText
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.Wrap
            elide: Text.ElideRight
            maximumLineCount: 3
            horizontalAlignment: Text.AlignHCenter
          }
        }

        Row {
          id: symbolRow
          width: parent.width
          visible: root.symbols.length > 1
          spacing: Style.space(6)

          Repeater {
            model: root.symbols

            Button {
              required property var modelData
              required property int index

              text: modelData
              selected: index === root.activeIndex
              foreground: index === root.activeIndex ? root.chartColor : root.dim
              accent: root.chartColor
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(5)
              onClicked: root.selectSymbol(index)
            }
          }
        }

        Row {
          id: intervalRow
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.intervalOptions

            Button {
              required property var modelData
              required property int index

              text: modelData.label
              selected: index === root.intervalIndex
              foreground: index === root.intervalIndex ? root.chartColor : root.dim
              accent: root.chartColor
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(5)
              onClicked: root.selectInterval(index)
            }
          }
        }
      }

      Column {
        id: editorColumn
        visible: root.editing
        width: parent.width
        spacing: Style.space(10)

        Text {
          width: parent.width
          text: "Symbols (" + root.draftCount + "/" + Model.MAX_SYMBOLS + ")"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
          elide: Text.ElideRight
        }

        Column {
          id: symbolList
          width: parent.width
          visible: root.draftSymbols.length > 0
          spacing: Style.space(8)

          Repeater {
            model: root.draftSymbols

            Row {
              required property var modelData
              required property int index

              width: parent.width
              spacing: Style.space(8)

              TextField {
                width: parent.width - upButton.implicitWidth - downButton.implicitWidth - removeButton.implicitWidth - parent.spacing * 3
                text: modelData
                foreground: root.foreground
                onTextChanged: {
                  var next = Model.normalizeSymbol(text)
                  if (root.draftSymbols[index] !== next) root.draftSymbols[index] = next
                }
                Keys.onEscapePressed: root.cancelEdit()
                Keys.onPressed: function(event) {
                  if (!(event.modifiers & Qt.AltModifier)) return
                  if (event.key === Qt.Key_Up) {
                    root.moveDraftSymbol(index, -1)
                    event.accepted = true
                  } else if (event.key === Qt.Key_Down) {
                    root.moveDraftSymbol(index, 1)
                    event.accepted = true
                  }
                }
              }

              Button {
                id: upButton
                text: "\u25B2"
                tooltipText: "Move up"
                foreground: root.dim
                accent: root.dim
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(5)
                onClicked: root.moveDraftSymbol(index, -1)
              }

              Button {
                id: downButton
                text: "\u25BC"
                tooltipText: "Move down"
                foreground: root.dim
                accent: root.dim
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(5)
                onClicked: root.moveDraftSymbol(index, 1)
              }

              Button {
                id: removeButton
                text: "\u2715"
                tooltipText: "Remove " + modelData
                foreground: root.dim
                accent: root.dim
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(5)
                onClicked: root.removeDraftSymbol(index)
              }
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(4)

          TextField {
            id: addField
            width: parent.width
            text: ""
            placeholderText: "AAPL SPY BTC-USD"
            foreground: root.foreground
            onTextChanged: root.scheduleSearch(text)
            onAccepted: {
              if (root.acceptSearchHighlight()) return
              root.addDraftSymbol(text)
            }
            Keys.onEscapePressed: function(event) {
              if (root.searchOpen) {
                root.clearSearch()
                event.accepted = true
                return
              }
              root.cancelEdit()
            }
            Keys.onPressed: function(event) {
              if (!root.searchOpen) return
              if (event.key === Qt.Key_Down) {
                root.searchHighlight = Math.min(root.searchHighlight + 1, root.searchSuggestions.length - 1)
                event.accepted = true
              } else if (event.key === Qt.Key_Up) {
                root.searchHighlight = Math.max(root.searchHighlight - 1, 0)
                event.accepted = true
              }
            }
          }

          Column {
            width: parent.width
            visible: root.searchOpen
            spacing: Style.space(2)

            Repeater {
              model: root.searchSuggestions

              Button {
                required property var modelData
                required property int index
                width: parent.width
                text: modelData.name !== "" ? modelData.symbol + " — " + modelData.name : modelData.symbol
                selected: index === root.searchHighlight
                foreground: index === root.searchHighlight ? root.chartColor : root.dim
                accent: root.chartColor
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(5)
                onClicked: root.addDraftSymbol(modelData.symbol)
              }
            }
          }
        }

        Text {
          width: parent.width
          visible: root.editorError !== ""
          text: root.editorError
          color: Color.bar.active
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.Wrap
        }

        Row {
          width: parent.width
          spacing: Style.space(8)

          Button {
            text: "Add"
            foreground: root.foreground
            accent: Color.accent
            enabled: !root.atSymbolCap
            onClicked: root.addDraftSymbol(addField.text)
          }

          Button {
            text: "Save"
            foreground: root.foreground
            accent: Color.accent
            selected: true
            onClicked: root.submit()
          }
        }
      }
    }
  }
}
