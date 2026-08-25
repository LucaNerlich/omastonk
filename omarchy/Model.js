// Pure parsing/formatting shared by BarWidget.qml and Panel.qml.

/// Mirror of quotes::MAX_SYMBOLS in the Rust backend.
var MAX_SYMBOLS = 64;

var DISPLAY_MODES = ["full", "symbolPrice", "priceOnly", "symbolOnly"];

var INTERVAL_LABELS = ["5Y", "1Y", "YTD", "6M", "1M", "5D", "1D"];

function normalizeSymbol(value) {
  // Commas and semicolons would break the --symbols CSV round-trip to the
  // backend, so they never survive normalization.
  return String(value || "")
    .replace(/[,;\s]+/g, "")
    .trim()
    .toUpperCase();
}

function normalizeSymbols(list) {
  var result = [];
  if (!isList(list)) return result;
  var seen = {};
  for (var i = 0; i < list.length; i++) {
    var value = normalizeSymbol(list[i]);
    if (value === "" || seen[value]) continue;
    seen[value] = true;
    result.push(value);
  }
  return result;
}

// Injected shell settings hold QML lists, which Array.isArray rejects.
function isList(value) {
  return value !== null && typeof value === "object" && typeof value.length === "number";
}

/**
 * Settings for the widget: symbols array with legacy single-symbol fallback.
 * @param {*} settings - The inline shell.json entry values.
 * @return {string[]} Normalized watchlist.
 */
function settingsSymbols(settings) {
  var raw = settings ? settings.symbols : undefined;
  if (isList(raw)) return normalizeSymbols(raw);
  var legacy = normalizeSymbol(settings ? settings.symbol : "");
  return legacy === "" ? [] : [legacy];
}

function clampRotateSeconds(value) {
  var number = Number(value);
  if (!isFinite(number) || number <= 0) return 0;
  return Math.min(Math.round(number), 3600);
}

function clampPollIntervalSecs(value) {
  var number = Number(value);
  if (!isFinite(number)) return 60;
  return Math.max(5, Math.min(Math.round(number), 3600));
}

function normalizeDisplayMode(value) {
  var mode = String(value || "").trim();
  for (var i = 0; i < DISPLAY_MODES.length; i++) {
    if (DISPLAY_MODES[i] === mode) return mode;
  }
  return "full";
}

function normalizeChartInterval(value) {
  var label = String(value || "").trim().toUpperCase();
  for (var i = 0; i < INTERVAL_LABELS.length; i++) {
    if (INTERVAL_LABELS[i] === label) return label;
  }
  return "1D";
}

function intervalIndexForLabel(label, count) {
  var normalized = normalizeChartInterval(label);
  var index = INTERVAL_LABELS.indexOf(normalized);
  if (index < 0) index = INTERVAL_LABELS.length - 1;
  return clampIntervalIndex(index, count || INTERVAL_LABELS.length);
}

function numericValue(value) {
  if (value === undefined || value === null || value === "") return NaN;
  var number = Number(value);
  return isFinite(number) ? number : NaN;
}

function formatPrice(value) {
  // Natural sign: negatives render with "-", positives without a prefix
  // (the bar label adds its own trend glyph).
  var number = Number(value);
  if (!isFinite(number)) return "?";

  var absolute = Math.abs(number);
  var decimals = absolute >= 1 ? 2 : 4;
  return (number < 0 ? "-" : "") + absolute.toFixed(decimals);
}

function signPrefix(value) {
  return Number(value) < 0 ? "-" : "+";
}

function formatSignedPrice(value) {
  var number = Number(value);
  if (!isFinite(number)) return "?";
  var absolute = Math.abs(number);
  var decimals = absolute >= 1 ? 2 : 4;
  return signPrefix(number) + absolute.toFixed(decimals);
}

function formatSignedPercent(value) {
  var number = Number(value);
  if (!isFinite(number)) return "?";
  return signPrefix(number) + Math.abs(number).toFixed(2) + "%";
}

/**
 * Daily percent from absolute change (price - previousClose).
 * @return {number} Percent, or NaN when undefined.
 */
function percentChange(price, change) {
  var p = Number(price);
  var c = Number(change);
  if (!isFinite(p) || !isFinite(c)) return NaN;
  var previous = p - c;
  if (previous === 0) return NaN;
  return (c / previous) * 100;
}

/**
 * Format a bar label for one symbol under the given display mode.
 * @param {string} symbol
 * @param {Object|null} quote - {price, change, status} or null
 * @param {string} displayMode - full|symbolPrice|priceOnly|symbolOnly
 */
function formatBarLabel(symbol, quote, displayMode) {
  var name = normalizeSymbol(symbol);
  if (name === "") return "$";
  var mode = normalizeDisplayMode(displayMode);
  if (mode === "symbolOnly") return name;

  var ready = quote !== null && quote !== undefined && quote.status === "ready" && isFinite(quote.price);
  var price = ready
    ? formatPrice(quote.price)
    : quote !== null && quote !== undefined && quote.status === "loading"
      ? "..."
      : "?";
  var glyph = ready ? (quote.change < 0 ? "\u25BC" : "\u25B2") : "";
  var percent = ready ? formatSignedPercent(percentChange(quote.price, quote.change)) : "";

  var parts = [];
  if (mode !== "priceOnly") parts.push(name);
  parts.push(price);
  if (mode === "full" && percent !== "" && percent !== "?") parts.push(percent);
  if (glyph !== "") parts.push(glyph);
  return parts.join(" ");
}

function formatRelativeAge(msAgo) {
  var ms = Number(msAgo);
  if (!isFinite(ms) || ms < 0) return "";
  var secs = Math.floor(ms / 1000);
  if (secs < 60) return secs <= 1 ? "1s ago" : secs + "s ago";
  var mins = Math.floor(secs / 60);
  if (mins < 60) return mins === 1 ? "1m ago" : mins + "m ago";
  var hours = Math.floor(mins / 60);
  return hours === 1 ? "1h ago" : hours + "h ago";
}

function clampIntervalIndex(value, count) {
  var max = Math.max(0, count - 1);
  return Math.max(0, Math.min(max, Math.round(Number(value) || 0)));
}

/**
 * Parse one `watch`/`quote` JSON line into a symbol->quote map.
 * @param {*} line - The JSON line from the backend.
 * @return {Object|null} Map of symbol to {price, change, status}, or null.
 */
function parseQuotesLine(line) {
  var text = String(line || "").trim();
  if (text === "") return null;
  var parsed;
  try {
    parsed = JSON.parse(text);
  } catch (e) {
    return null;
  }
  if (parsed === null || typeof parsed !== "object" || !isList(parsed.quotes)) return null;

  var quotes = {};
  for (var i = 0; i < parsed.quotes.length; i++) {
    var entry = parsed.quotes[i];
    if (entry === null || typeof entry !== "object") continue;
    var symbol = normalizeSymbol(entry.symbol);
    if (symbol === "") continue;
    if (entry.state === "ok") {
      var price = numericValue(entry.price);
      if (!isFinite(price)) continue;
      quotes[symbol] = {
        price: price,
        change: isFinite(Number(entry.change)) ? Number(entry.change) : 0,
        status: "ready"
      };
    } else {
      quotes[symbol] = { price: NaN, change: 0, status: "error", message: String(entry.message || "") };
    }
  }
  return quotes;
}

/**
 * Parse one `chart` JSON line into close points.
 * @param {*} line - The JSON line from the backend.
 * @return {Object} {state: "ok"|"error", points: number[]}.
 */
function parseChartLine(line) {
  var text = String(line || "").trim();
  var parsed = null;
  try {
    parsed = JSON.parse(text);
  } catch (e) {
    parsed = null;
  }
  if (parsed === null || typeof parsed !== "object") return { state: "error", points: [] };

  if (parsed.state === "ok" && isList(parsed.points)) {
    var points = [];
    for (var i = 0; i < parsed.points.length; i++) {
      var value = numericValue(parsed.points[i]);
      if (isFinite(value)) points.push(value);
    }
    return { state: points.length > 1 ? "ok" : "error", points: points, message: "" };
  }
  return { state: "error", points: [], message: String(parsed.message || "") };
}

/**
 * Parse one `search` JSON line into suggestions.
 * @return {Object} {state, suggestions: [{symbol, name}], message}
 */
function parseSearchLine(line) {
  var text = String(line || "").trim();
  var parsed = null;
  try {
    parsed = JSON.parse(text);
  } catch (e) {
    parsed = null;
  }
  if (parsed === null || typeof parsed !== "object") {
    return { state: "error", suggestions: [], message: "" };
  }
  if (parsed.state === "ok" && isList(parsed.suggestions)) {
    var suggestions = [];
    for (var i = 0; i < parsed.suggestions.length; i++) {
      var entry = parsed.suggestions[i];
      if (entry === null || typeof entry !== "object") continue;
      var symbol = normalizeSymbol(entry.symbol);
      if (symbol === "") continue;
      suggestions.push({ symbol: symbol, name: String(entry.name || "") });
    }
    return { state: "ok", suggestions: suggestions, message: "" };
  }
  return {
    state: "error",
    suggestions: [],
    message: String(parsed.message || "")
  };
}
