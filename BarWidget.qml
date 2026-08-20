import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "luca.omastonk"

  property var quotes: ({})
  property int pollIndex: 0
  property string requestedSymbol: ""
  property string transientInstanceId: ""
  property string displaySymbol: ""
  property bool displaySymbolResolved: false

  readonly property string symbolLegacy: normalizeSymbol(setting("symbol", ""))
  readonly property var symbols: normalizeSymbols(settingsSymbols())
  readonly property string savedActive: normalizeSymbol(setting("activeSymbol", ""))
  readonly property int rotateSeconds: clampRotateSeconds(Number(setting("rotateSeconds", 5)))
  readonly property string instanceId: String(setting("instanceId", "")) || transientInstanceId
  readonly property var activeQuote: quotes[displaySymbol] || null
  readonly property bool quoteReady: activeQuote !== null && activeQuote.status === "ready" && isFinite(activeQuote.price)
  readonly property bool priceDown: quoteReady && activeQuote.change < 0
  readonly property string trendGlyph: quoteReady ? (priceDown ? "\u25BC" : "\u25B2") : ""
  readonly property string priceText: quoteReady ? formatPrice(activeQuote.price) : (activeQuote !== null && activeQuote.status === "loading" ? "..." : "?")
  readonly property string labelText: displaySymbol === "" ? "$" : displaySymbol + " " + priceText + (trendGlyph === "" ? "" : " " + trendGlyph)
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function settingsSymbols() {
    var raw = setting("symbols")
    if (Array.isArray(raw)) return raw
    return symbolLegacy === "" ? [] : [symbolLegacy]
  }

  function normalizeSymbols(list) {
    var seen = {}
    var result = []
    for (var i = 0; i < list.length; i++) {
      var value = normalizeSymbol(list[i])
      if (value === "" || seen[value]) continue
      seen[value] = true
      result.push(value)
    }
    return result
  }

  function clampRotateSeconds(value) {
    if (!isFinite(value) || value <= 0) return 0
    return Math.min(Math.round(value), 3600)
  }

  function normalizeSymbol(value) {
    return String(value || "").trim().toUpperCase().replace(/\s+/g, "")
  }

  function numericValue(value) {
    if (value === undefined || value === null || value === "") return NaN
    var number = Number(value)
    return isFinite(number) ? number : NaN
  }

  function formatPrice(value) {
    var number = Number(value)
    if (!isFinite(number)) return "?"

    var absolute = Math.abs(number)
    var decimals = absolute >= 1 ? 2 : 4
    return number.toFixed(decimals)
  }

  function generateInstanceId() {
    return "omastonk-" + Date.now().toString(36)
      + "-" + Math.floor(Math.random() * 0x100000000).toString(36)
  }

  function quoteUrl(symbol) {
    return "https://query1.finance.yahoo.com/v8/finance/chart/"
      + encodeURIComponent(symbol)
      + "?range=1d&interval=1m"
  }

  function updateQuote(symbol, entry) {
    var next = {}
    for (var key in quotes) next[key] = quotes[key]
    next[symbol] = entry
    quotes = next
  }

  function resetQuoteFor(symbol) {
    if (symbol === "") return
    updateQuote(symbol, { price: NaN, change: 0, status: "loading" })
  }

  function requestQuote(symbol) {
    if (symbol === "" || quoteProc.running) return

    resetQuoteFor(symbol)
    requestedSymbol = symbol
    quoteProc.command = ["curl", "-fsS", "--max-time", "6", "-A", "Mozilla/5.0", quoteUrl(symbol)]
    quoteProc.running = true
  }

  function pollNext() {
    if (symbols.length === 0) return
    pollIndex = (pollIndex + 1) % symbols.length
    requestQuote(symbols[pollIndex])
  }

  function applyQuote(raw) {
    var symbol = requestedSymbol
    var text = String(raw || "").trim()
    if (symbol === "" || text === "") {
      if (symbol !== "") updateQuote(symbol, { price: NaN, change: 0, status: "error" })
      return
    }

    try {
      var parsed = JSON.parse(text)
      var chart = parsed && parsed.chart ? parsed.chart : null
      if (chart && chart.error) {
        updateQuote(symbol, { price: NaN, change: 0, status: "error" })
        return
      }

      var result = chart && chart.result && chart.result.length > 0 ? chart.result[0] : null
      var meta = result && result.meta ? result.meta : null
      var price = numericValue(meta ? meta.regularMarketPrice : NaN)
      var previous = numericValue(meta ? meta.chartPreviousClose : NaN)
      if (!isFinite(previous)) previous = numericValue(meta ? meta.previousClose : NaN)
      if (!isFinite(price)) {
        updateQuote(symbol, { price: NaN, change: 0, status: "error" })
        return
      }

      updateQuote(symbol, { price: price, change: isFinite(previous) ? price - previous : 0, status: "ready" })
    } catch (e) {
      updateQuote(symbol, { price: NaN, change: 0, status: "error" })
    }
  }

  function slotHost() {
    var item = root.parent
    while (item) {
      if (slotItem(item)) return item
      item = item.parent
    }
    return null
  }

  function slotItem(item) {
    if (!item) return false
    try {
      return item.region !== undefined && item.entry !== undefined
    } catch (e) {
      return false
    }
  }

  function siblingModuleOccurrence(host, section) {
    var itemParent = host ? host.parent : null
    if (!itemParent || !itemParent.children) return -1

    var occurrence = 0
    for (var i = 0; i < itemParent.children.length; i++) {
      var child = itemParent.children[i]
      if (!slotItem(child) || String(child.region || "") !== section) continue
      if (entryId(child.entry) !== root.moduleName) continue
      if (child === host) return occurrence
      occurrence++
    }

    return -1
  }

  function entryId(entry) {
    return typeof entry === "string" ? entry : String(entry && entry.id ? entry.id : "")
  }

  function entryInstanceId(entry) {
    return entry && typeof entry === "object" ? String(entry.instanceId || "") : ""
  }

  function locationByInstanceId(layout, value) {
    var id = String(value || "")
    if (id === "" || !layout) return null

    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var section = sections[s]
      var entries = layout[section]
      if (!Array.isArray(entries)) continue

      for (var i = 0; i < entries.length; i++) {
        var entry = entries[i]
        if (entryId(entry) === root.moduleName && entryInstanceId(entry) === id)
          return { section: section, index: i }
      }
    }

    return null
  }

  function locationBySlotContext(layout, context) {
    if (!layout || !context || context.occurrence < 0) return null

    // The rendered bar can reorder normalized entries; map by same-widget
    // occurrence so the first save updates the raw shell.json entry.
    var entries = layout[context.section]
    if (!Array.isArray(entries)) return null

    var occurrence = 0
    for (var i = 0; i < entries.length; i++) {
      if (entryId(entries[i]) !== root.moduleName) continue
      if (occurrence === context.occurrence) return { section: context.section, index: i }
      occurrence++
    }

    return null
  }

  function currentSlotContext() {
    var host = slotHost()
    if (!host) return null

    var section = String(host.region || "")
    return {
      section: section,
      occurrence: siblingModuleOccurrence(host, section)
    }
  }

  function saveInstanceSettings(next) {
    root.settings = next

    if (!bar || !bar.shell || typeof bar.shell.mutateShellConfig !== "function") return

    var slotContext = currentSlotContext()
    var nextInstanceId = String(next.instanceId || "")

    bar.shell.mutateShellConfig(function(config) {
      if (!config.bar) config.bar = {}
      if (!config.bar.layout) config.bar.layout = { left: [], center: [], right: [] }

      var location = locationByInstanceId(config.bar.layout, nextInstanceId)
        || locationBySlotContext(config.bar.layout, slotContext)
      if (!location) return

      var entries = config.bar.layout[location.section]
      if (!Array.isArray(entries) || location.index < 0 || location.index >= entries.length) return

      var current = entries[location.index]
      var currentId = entryId(current)
      if (currentId !== root.moduleName) return

      var updated = { id: currentId }
      for (var key in next) {
        if (key !== "id") updated[key] = next[key]
      }
      entries[location.index] = updated
    })
  }

  function settingsCopy() {
    var next = {}
    for (var key in settings) {
      if (key !== "id" && key !== "symbol") next[key] = settings[key]
    }
    return next
  }

  function setSymbols(values) {
    var nextSymbols = normalizeSymbols(values)
    var next = settingsCopy()
    next.instanceId = instanceId || generateInstanceId()
    next.symbols = nextSymbols
    if (nextSymbols.indexOf(savedActive) === -1) next.activeSymbol = nextSymbols.length > 0 ? nextSymbols[0] : ""
    saveInstanceSettings(next)
  }

  function setActiveSymbol(value) {
    var nextSymbol = normalizeSymbol(value)
    if (nextSymbol === "" || symbols.indexOf(nextSymbol) === -1) return

    displaySymbol = nextSymbol
    var next = settingsCopy()
    next.instanceId = instanceId || generateInstanceId()
    next.activeSymbol = nextSymbol
    saveInstanceSettings(next)
  }

  function resolveDisplaySymbol() {
    if (savedActive !== "" && symbols.indexOf(savedActive) !== -1) {
      displaySymbol = savedActive
      return
    }
    displaySymbol = symbols.length > 0 ? symbols[0] : ""
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("host" in target) target.host = root
  }

  function openPanel() {
    if (!panelLoader.item) return
    if (displaySymbol === "" && symbols.length > 0) resolveDisplaySymbol()
    if (typeof panelLoader.item.openSymbol === "function") panelLoader.item.openSymbol(displaySymbol)
    else if (typeof panelLoader.item.open === "function") panelLoader.item.open()
  }

  function closePanel() {
    if (panelLoader.item && typeof panelLoader.item.close === "function") panelLoader.item.close()
  }

  function close() {
    closePanel()
  }

  function togglePanel() {
    if (!panelLoader.item) return
    if (opened) closePanel()
    else openPanel()
  }

  function openEditor() {
    if (panelLoader.item && typeof panelLoader.item.openEditor === "function") panelLoader.item.openEditor()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  onSymbolsChanged: {
    var kept = {}
    for (var key in quotes) {
      if (symbols.indexOf(key) !== -1) kept[key] = quotes[key]
    }
    for (var i = 0; i < symbols.length; i++) {
      if (kept[symbols[i]] === undefined) kept[symbols[i]] = { price: NaN, change: 0, status: "loading" }
    }
    quotes = kept

    if (!displaySymbolResolved) resolveDisplaySymbol()
    else if (symbols.indexOf(displaySymbol) === -1) displaySymbol = symbols.length > 0 ? symbols[0] : ""

    pollIndex = 0
    Qt.callLater(pollNext)
  }

  Component.onCompleted: {
    transientInstanceId = generateInstanceId()
    resolveDisplaySymbol()
    displaySymbolResolved = true
    if (symbols.length > 0) Qt.callLater(pollNext)
  }

  Process {
    id: quoteProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyQuote(text)
    }
    onExited: function(exitCode) {
      var symbol = root.requestedSymbol
      root.requestedSymbol = ""
      if (exitCode !== 0 && symbol !== "") root.updateQuote(symbol, { price: NaN, change: 0, status: "error" })
    }
  }

  Timer {
    id: pollTimer
    interval: root.symbols.length > 0 ? Math.max(2, Math.round(60 / root.symbols.length)) * 1000 : 60 * 1000
    running: root.symbols.length > 0
    repeat: true
    triggeredOnStart: false
    onTriggered: root.pollNext()
  }

  Timer {
    id: rotateTimer
    interval: root.rotateSeconds * 1000
    running: root.rotateSeconds > 0 && root.symbols.length > 1
    repeat: true
    triggeredOnStart: false
    onTriggered: {
      var index = root.symbols.indexOf(root.displaySymbol)
      root.displaySymbol = root.symbols[(index + 1 + root.symbols.length) % root.symbols.length]
    }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.labelText
    foreground: Color.bar.text
    activeColor: Color.bar.active
    active: root.priceDown
    horizontalMargin: 8.5
    verticalPadding: 6
    tooltipText: root.symbols.length === 0 ? "Add symbols" : ""
    onPressed: function(button) {
      if (button === Qt.RightButton) root.openEditor()
      else root.togglePanel()
    }
  }
}
