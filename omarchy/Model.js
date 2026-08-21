// Pure parsing/formatting shared by BarWidget.qml and Panel.qml.

function normalizeSymbol(value) {
  return String(value || "").trim().toUpperCase().replace(/\s+/g, "");
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

function numericValue(value) {
  if (value === undefined || value === null || value === "") return NaN;
  var number = Number(value);
  return isFinite(number) ? number : NaN;
}

function formatPrice(value) {
  var number = Number(value);
  if (!isFinite(number)) return "?";

  var absolute = Math.abs(number);
  var decimals = absolute >= 1 ? 2 : 4;
  return absolute.toFixed(decimals);
}

function signPrefix(value) {
  return Number(value) < 0 ? "-" : "+";
}

function formatSignedPrice(value) {
  var number = Number(value);
  if (!isFinite(number)) return "?";
  return signPrefix(number) + formatPrice(number);
}

function formatSignedPercent(value) {
  var number = Number(value);
  if (!isFinite(number)) return "?";
  return signPrefix(number) + Math.abs(number).toFixed(2) + "%";
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
