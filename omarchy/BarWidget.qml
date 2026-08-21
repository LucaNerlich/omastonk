import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Quattro bar entry point for the Omastonk market watchlist. Quote fetching
// lives in the Rust backend (`omastonk-qs watch`); this file owns the bar
// button, display rotation, and the watch process lifecycle.
BarWidget {
  id: root
  moduleName: "luca.omastonk"

  function decodeFileUrl(urlString) {
    var path = String(urlString).replace(/^file:\/\//, "")
    try {
      return decodeURIComponent(path)
    } catch (e) {
      return path
    }
  }

  readonly property string bundledBinary: root.decodeFileUrl(
    Qt.resolvedUrl("bin/omastonk-qs").toString())
  readonly property int fallbackThreshold: 2
  property bool watchFallback: false
  property int watchFailures: 0
  readonly property string backendBinary: watchFallback ? "omastonk-qs" : bundledBinary
  readonly property int pollIntervalSecs: 60

  property var quotes: ({})
  property string transientInstanceId: ""
  property string displaySymbol: ""
  property bool displaySymbolResolved: false
  property string watchArgs: ""

  readonly property var symbols: Model.normalizeSymbols(Model.settingsSymbols(settings))
  readonly property string savedActive: Model.normalizeSymbol(setting("activeSymbol", ""))
  readonly property int rotateSeconds: Model.clampRotateSeconds(setting("rotateSeconds", 5))
  readonly property string instanceId: String(setting("instanceId", "")) || transientInstanceId
  readonly property var activeQuote: quotes[displaySymbol] || null
  readonly property bool quoteReady: activeQuote !== null && activeQuote.status === "ready" && isFinite(activeQuote.price)
  readonly property bool priceDown: quoteReady && activeQuote.change < 0
  readonly property string trendGlyph: quoteReady ? (priceDown ? "\u25BC" : "\u25B2") : ""
  readonly property string priceText: quoteReady ? Model.formatPrice(activeQuote.price) : (activeQuote !== null && activeQuote.status === "loading" ? "..." : "?")
  readonly property string labelText: displaySymbol === "" ? "$" : displaySymbol + " " + priceText + (trendGlyph === "" ? "" : " " + trendGlyph)
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function generateInstanceId() {
    return "omastonk-" + Date.now().toString(36)
      + "-" + Math.floor(Math.random() * 0x100000000).toString(36)
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
    var nextSymbols = Model.normalizeSymbols(values)
    var next = settingsCopy()
    next.instanceId = instanceId || generateInstanceId()
    next.symbols = nextSymbols
    if (nextSymbols.indexOf(savedActive) === -1) next.activeSymbol = nextSymbols.length > 0 ? nextSymbols[0] : ""
    saveInstanceSettings(next)
  }

  function setActiveSymbol(value) {
    var nextSymbol = Model.normalizeSymbol(value)
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

  function seedQuotes() {
    var next = {}
    for (var i = 0; i < symbols.length; i++) {
      var symbol = symbols[i]
      next[symbol] = quotes[symbol] !== undefined ? quotes[symbol] : { price: NaN, change: 0, status: "loading" }
    }
    quotes = next
  }

  function applyQuotesLine(line) {
    var parsed = Model.parseQuotesLine(line)
    if (parsed === null) return
    quotes = parsed
  }

  function restartWatch() {
    var args = symbols.join(",")
    if (args === "") {
      watchArgs = ""
      watchProc.running = false
      return
    }
    if (args === watchArgs && watchProc.running) return

    watchArgs = args
    watchProc.command = [backendBinary, "watch", "--symbols", args, "--interval-secs", String(pollIntervalSecs)]
    watchProc.running = false
    Qt.callLater(function() { watchProc.running = true })
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
    if (!displaySymbolResolved) resolveDisplaySymbol()
    else if (symbols.indexOf(displaySymbol) === -1) displaySymbol = symbols.length > 0 ? symbols[0] : ""

    seedQuotes()
    restartWatch()
  }

  Component.onCompleted: {
    transientInstanceId = generateInstanceId()
    resolveDisplaySymbol()
    displaySymbolResolved = true
    seedQuotes()
    restartWatch()
  }

  Process {
    id: watchProc
    property bool startedOnce: false
    stdout: SplitParser {
      onRead: function(line) { root.applyQuotesLine(line) }
    }
    onStarted: {
      watchProc.startedOnce = true
      root.watchFailures = 0
    }
    onExited: {
      if (!root.watchFallback && root.symbols.length > 0) {
        root.quotes = {}
        root.seedQuotes()
      }
      watchRestartTimer.restart()
    }
    onRunningChanged: {
      if (watchProc.running) return
      var failedStart = !watchProc.startedOnce
      watchProc.startedOnce = false
      if (failedStart) {
        root.watchFailures += 1
        if (root.watchFailures >= root.fallbackThreshold) {
          root.watchFailures = 0
          root.watchFallback = !root.watchFallback
          root.watchArgs = ""
          Qt.callLater(root.restartWatch)
          return
        }
      }
      watchRestartTimer.restart()
    }
  }

  Timer {
    id: watchRestartTimer
    interval: 5000
    repeat: false
    onTriggered: root.restartWatch()
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
