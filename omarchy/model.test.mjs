import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";
import vm from "node:vm";

const __dirname = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(__dirname, "Model.js"), "utf8");
const sandbox = { console };
vm.createContext(sandbox);
vm.runInContext(source, sandbox);
const Model = sandbox;

function test(name, fn) {
  try {
    fn();
    console.log(`ok - ${name}`);
  } catch (err) {
    console.error(`not ok - ${name}`);
    throw err;
  }
}

test("normalizeSymbol trims, uppercases, strips whitespace", () => {
  assert.equal(Model.normalizeSymbol("  aapl \n"), "AAPL");
  assert.equal(Model.normalizeSymbol("BTC USD"), "BTCUSD");
  assert.equal(Model.normalizeSymbol(null), "");
});

test("normalizeSymbols dedupes and drops empties", () => {
  assert.equal(
    JSON.stringify(Model.normalizeSymbols(["aapl", "", "SPY", "Aapl"])),
    JSON.stringify(["AAPL", "SPY"])
  );
});

test("settingsSymbols reads arrays and migrates legacy symbol", () => {
  assert.equal(JSON.stringify(Model.settingsSymbols({ symbols: ["spy", "aapl"] })), JSON.stringify(["SPY", "AAPL"]));
  assert.equal(JSON.stringify(Model.settingsSymbols({ symbol: "adbe" })), JSON.stringify(["ADBE"]));
  assert.equal(JSON.stringify(Model.settingsSymbols({})), "[]");
  assert.equal(JSON.stringify(Model.settingsSymbols(null)), "[]");
});

test("settingsSymbols accepts QML list-like values (Array.isArray is false)", () => {
  const qmlList = { length: 2, 0: "msft", 1: "aapl" };
  assert.equal(Array.isArray(qmlList), false);
  assert.equal(JSON.stringify(Model.settingsSymbols({ symbols: qmlList })), JSON.stringify(["MSFT", "AAPL"]));
});

test("parseQuotesLine accepts list-like quotes", () => {
  const line = JSON.stringify({
    quotes: { length: 1, 0: { state: "ok", symbol: "spy", price: 1.25, change: 0.1 } }
  });
  const quotes = Model.parseQuotesLine(line);
  assert.equal(quotes.SPY.status, "ready");
  assert.equal(quotes.SPY.price, 1.25);
});

test("clampRotateSeconds bounds and disables on junk", () => {
  assert.equal(Model.clampRotateSeconds(5), 5);
  assert.equal(Model.clampRotateSeconds(0), 0);
  assert.equal(Model.clampRotateSeconds(-3), 0);
  assert.equal(Model.clampRotateSeconds("x"), 0);
  assert.equal(Model.clampRotateSeconds(99999), 3600);
});

test("formatPrice picks decimals by magnitude", () => {
  assert.equal(Model.formatPrice(123.456), "123.46");
  assert.equal(Model.formatPrice(0.5), "0.5000");
  assert.equal(Model.formatPrice(NaN), "?");
});

test("signed formatting keeps the sign out of digits", () => {
  assert.equal(Model.formatSignedPrice(-1.2), "-1.20");
  assert.equal(Model.formatSignedPrice(1.2), "+1.20");
  assert.equal(Model.formatSignedPercent(-2.5), "-2.50%");
  assert.equal(Model.formatSignedPercent(NaN), "?");
});

test("clampIntervalIndex wraps into range", () => {
  const count = 7;
  assert.equal(Model.clampIntervalIndex(0, count), 0);
  assert.equal(Model.clampIntervalIndex(99, count), 6);
  assert.equal(Model.clampIntervalIndex(-1, count), 0);
  assert.equal(Model.clampIntervalIndex("junk", count), 0);
});

test("parseQuotesLine maps ok and error states", () => {
  const line = JSON.stringify({
    quotes: [
      { state: "ok", symbol: "aapl", price: 10.5, change: -0.25 },
      { state: "error", symbol: "SPY", message: "boom" },
      { state: "ok", symbol: "", price: 1 },
      { state: "ok", symbol: "BAD", price: "junk" }
    ]
  });
  const quotes = Model.parseQuotesLine(line);
  assert.equal(quotes.AAPL.status, "ready");
  assert.equal(quotes.AAPL.price, 10.5);
  assert.equal(quotes.AAPL.change, -0.25);
  assert.equal(quotes.SPY.status, "error");
  assert.equal(quotes.SPY.message, "boom");
  assert.ok(!("BAD" in quotes));
  assert.ok(!("" in quotes));
});

test("parseQuotesLine rejects garbage", () => {
  assert.equal(Model.parseQuotesLine(""), null);
  assert.equal(Model.parseQuotesLine("not json"), null);
  assert.equal(Model.parseQuotesLine(JSON.stringify({ nope: 1 })), null);
  assert.equal(Model.parseQuotesLine(null), null);
});

test("parseChartLine keeps finite points and flags thin series", () => {
  const ok = Model.parseChartLine(JSON.stringify({ state: "ok", points: [1, null, 2.5, "x"] }));
  assert.equal(ok.state, "ok");
  assert.equal(JSON.stringify(ok.points), JSON.stringify([1, 2.5]));

  const thin = Model.parseChartLine(JSON.stringify({ state: "ok", points: [1] }));
  assert.equal(thin.state, "error");

  const bad = Model.parseChartLine(JSON.stringify({ state: "error", message: "no data" }));
  assert.equal(bad.state, "error");
  assert.equal(bad.message, "no data");
});
