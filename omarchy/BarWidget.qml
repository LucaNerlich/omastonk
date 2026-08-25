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

  readonly property var symbols: normalizeSymbols(settingsSymbols())
  readonly property string savedActive: normalizeSymbol(setting("activeSymbol", ""))
  readonly property int rotateSeconds: clampRotateSeconds(setting("rotateSeconds", 5))
  readonly property string instanceId: String(setting("instanceId", "")) || transientInstanceId
  readonly property var activeQuote: quotes[displaySymbol] || null
  readonly property bool quoteReady: activeQuote !== null && activeQuote.status === "ready" && isFinite(activeQuote.price)
  readonly property bool priceDown: quoteReady && activeQuote.change < 0
  readonly property string labelText: labelForSymbol(displaySymbol)
  readonly property string errorHint: activeQuote !== null && activeQuote.status === "error" && activeQuote.message !== ""
    ? displaySymbol + ": " + activeQuote.message
    : ""
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  // Property reads inside imported JS files are not tracked by QML
  // bindings, so every function a binding depends on must live here.
  function normalizeSymbol(value) {
    return String(value || "").trim().toUpperCase().replace(/\s+/g, "")
  }

  // Same format as the visible bar label, for any watchlist symbol. Used by
  // the offscreen sizer so rotation reserves the widest label up front.
  function labelForSymbol(symbol) {
    var name = normalizeSymbol(symbol)
    if (name === "") return "$"
    var quote = quotes[name] || null
    var ready = quote !== null && quote.status === "ready" && isFinite(quote.price)
    var price = ready ? Model.formatPrice(quote.price)
      : (quote !== null && quote.status === "loading" ? "..." : "?")
    var glyph = ready ? (quote.change < 0 ? "\u25BC" : "\u25B2") : ""
    return name + " " + price + (glyph === "" ? "" : " " + glyph)
  }

  // Injected settings hold QML lists, which Array.isArray rejects.
  function isList(value) {
    return value !== null && typeof value === "object" && typeof value.length === "number"
  }

  function normalizeSymbols(list) {
    var result = []
    if (!isList(list)) return result
    var seen = {}
    for (var i = 0; i < list.length; i++) {
      var value = normalizeSymbol(list[i])
      if (value === "" || seen[value]) continue
      seen[value] = true
      result.push(value)
    }
    return result
  }

  function settingsSymbols() {
    var raw = settings ? settings.symbols : undefined
    if (isList(raw)) return raw
    var legacy = normalizeSymbol(setting("symbol", ""))
    return legacy === "" ? [] : [legacy]
  }

  function clampRotateSeconds(value) {
    var number = Number(value)
    if (!isFinite(number) || number <= 0) return 0
    return Math.min(Math.round(number), 3600)
  }

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
      if (!isList(entries)) continue

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
    if (!isList(entries)) return null

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
      if (!isList(entries) || location.index < 0 || location.index >= entries.length) return

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
    // Prefer the persisted selection: rotation moves displaySymbol, but the
    // symbol the user explicitly picked should win when the panel opens.
    if (savedActive !== "" && symbols.indexOf(savedActive) !== -1) displaySymbol = savedActive
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

  // Size to the widest watchlist label so rotating AAPL ↔ BTC-USD does not
  // jump the bar slot. Column implicitWidth is max(children), matching the
  // panel's offscreen sizer pattern.
  implicitWidth: Math.max(button.implicitWidth, labelSizer.implicitWidth)
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  onSymbolsChanged: {
    if (!displaySymbolResolved) resolveDisplaySymbol()
    else if (symbols.indexOf(displaySymbol) === -1) displaySymbol = symbols.length > 0 ? symbols[0] : ""

    seedQuotes()
    restartWatch()
  }

  Column {
    id: labelSizer
    opacity: 0
    height: 0
    enabled: false

    Repeater {
      model: root.symbols.length > 0 ? root.symbols : [""]

      WidgetButton {
        required property var modelData

        bar: root.bar
        text: root.labelForSymbol(modelData)
        foreground: Color.bar.text
        activeColor: Color.bar.active
        horizontalMargin: 8.5
        verticalPadding: 6
      }
    }
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
    property real startedAt: 0
    function ranMs() { return Date.now() - startedAt }
    stdout: SplitParser {
      onRead: function(line) { root.applyQuotesLine(line) }
    }
    onStarted: {
      watchProc.startedOnce = true
      watchProc.startedAt = Date.now()
      root.watchFailures = 0
    }
    onExited: {
      // Never leave the last snapshot looking live while the watcher is down.
      root.quotes = {}
      root.seedQuotes()
      watchRestartTimer.restart()
    }
    onRunningChanged: {
      if (watchProc.running) return
      var failedStart = !watchProc.startedOnce
      if (watchProc.startedOnce && watchProc.ranMs() < 1000) {
        // Spawned but died immediately: counts as a failed start too, or a
        // corrupt binary would crash-loop here forever.
        failedStart = true
      }
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

  Timer {
    id: rotateTimer
    interval: root.rotateSeconds * 1000
    // Rotation pauses while the panel is open: an explicitly selected symbol
    // must not be rotated away underneath the user.
    running: root.rotateSeconds > 0 && root.symbols.length > 1 && !root.opened
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
    tooltipText: root.errorHint !== "" ? root.errorHint : (root.symbols.length === 0 ? "Add symbols" : "")
    onPressed: function(button) {
      if (button === Qt.RightButton) root.openEditor()
      else root.togglePanel()
    }
  }
}
