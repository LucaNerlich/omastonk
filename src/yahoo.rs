//! Yahoo Finance chart API client and response parsing.
//!
//! Transport goes through `curl` (already a widget dependency) so the crate
//! stays pure Rust and the musl bundle needs no C toolchain. Parsing,
//! scheduling, and state live here.

use std::process::Command;

use serde::Deserialize;

const USER_AGENT: &str = "Mozilla/5.0";
const CHART_URL: &str = "https://query1.finance.yahoo.com/v8/finance/chart/";
const CURL_TIMEOUT_SECS: &str = "8";

/// A single symbol's latest quote as the widget renders it.
#[derive(Debug, Clone, PartialEq)]
pub struct Quote {
    pub symbol: String,
    pub price: f64,
    /// Price minus previous close; `None` when Yahoo gave no reference.
    pub change: Option<f64>,
}

/// One parsed chart response: last price plus the close series.
#[derive(Debug, Clone, PartialEq)]
pub struct ChartData {
    pub price: f64,
    pub change: Option<f64>,
    /// Close prices for the requested range/interval, gaps removed.
    pub points: Vec<f64>,
}

#[derive(Deserialize)]
struct ChartResponse {
    chart: ChartEnvelope,
}

#[derive(Deserialize)]
struct ChartEnvelope {
    result: Option<Vec<ChartResult>>,
    error: Option<serde_json::Value>,
}

#[derive(Deserialize)]
struct ChartResult {
    meta: ChartMeta,
    indicators: Option<ChartIndicators>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChartMeta {
    regular_market_price: Option<f64>,
    chart_previous_close: Option<f64>,
    previous_close: Option<f64>,
}

#[derive(Deserialize)]
struct ChartIndicators {
    quote: Option<Vec<QuoteSeries>>,
}

#[derive(Deserialize)]
struct QuoteSeries {
    close: Option<Vec<Option<f64>>>,
}

fn chart_url(symbol: &str, range: &str, interval: &str) -> String {
    format!(
        "{CHART_URL}{}?range={}&interval={}",
        urlencode(symbol),
        urlencode(range),
        urlencode(interval)
    )
}

/// Percent-encode everything outside the RFC 3986 unreserved set. Symbols such
/// as `^GSPC` and `BRK-B` must survive a URL path untouched.
fn urlencode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(byte as char);
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

/// Fetch and parse one chart request. `range`/`interval` follow Yahoo's
/// vocabulary (1d, 5m, 1mo, ...); the caller picks the pair.
pub fn fetch_chart(symbol: &str, range: &str, interval: &str) -> Result<ChartData, String> {
    let url = chart_url(symbol, range, interval);
    let output = Command::new("curl")
        .args([
            "-fsS",
            "--max-time",
            CURL_TIMEOUT_SECS,
            "-A",
            USER_AGENT,
            &url,
        ])
        .output()
        .map_err(|e| format!("run curl: {e}"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let detail = stderr.lines().last().unwrap_or("request failed");
        return Err(detail.to_string());
    }
    let text = String::from_utf8_lossy(&output.stdout);
    parse_chart(&text).ok_or_else(|| "unexpected chart payload".to_string())
}

/// Parse a v8 chart payload. Returns `None` for anything structurally wrong
/// (transport errors surface before this as `Err`).
pub fn parse_chart(text: &str) -> Option<ChartData> {
    let parsed: ChartResponse = serde_json::from_str(text).ok()?;
    if parsed.chart.error.is_some() {
        return None;
    }
    let result = parsed.chart.result?.into_iter().next()?;
    let price = result.meta.regular_market_price?;
    let change = result
        .meta
        .chart_previous_close
        .or(result.meta.previous_close)
        .map(|prev| price - prev);
    let closes = result
        .indicators
        .and_then(|ind| ind.quote)
        .and_then(|mut q| q.drain(..).next())
        .and_then(|series| series.close);
    let points = closes
        .map(|closes| closes.into_iter().flatten().collect())
        .unwrap_or_default();
    Some(ChartData {
        price,
        change,
        points,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"{
      "chart": {"result": [{
          "meta": {"regularMarketPrice": 123.45, "chartPreviousClose": 120.0},
          "timestamp": [1, 2, 3],
          "indicators": {"quote": [{"close": [120.0, null, 121.5, 123.45]}]}
      }], "error": null}
    }"#;

    #[test]
    fn parses_price_change_and_drops_gaps() {
        let data = parse_chart(SAMPLE).expect("parses");
        assert_eq!(data.price, 123.45);
        let change = data.change.expect("change present");
        assert!((change - 3.45).abs() < 1e-9, "change: {change}");
        assert_eq!(data.points, vec![120.0, 121.5, 123.45]);
    }

    #[test]
    fn rejects_error_payloads() {
        assert!(parse_chart(r#"{"chart":{"result":null,"error":{"code":"Bad"}}}"#).is_none());
        assert!(parse_chart("not json").is_none());
        assert!(parse_chart(r#"{"chart":{}}"#).is_none());
    }

    #[test]
    fn falls_back_to_previous_close() {
        let text = r#"{"chart":{"result":[{"meta":{"regularMarketPrice":10.0,"previousClose":9.0}}],"error":null}}"#;
        let data = parse_chart(text).expect("parses");
        assert_eq!(data.change, Some(1.0));
        assert!(data.points.is_empty());
    }

    #[test]
    fn urlencodes_caret_symbols() {
        assert_eq!(
            chart_url("^GSPC", "1d", "5m"),
            format!("{CHART_URL}%5EGSPC?range=1d&interval=5m")
        );
    }
}
