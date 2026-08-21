//! Yahoo Finance chart API client and response parsing.
//!
//! Transport goes through `curl` (already a widget dependency) so the crate
//! stays pure Rust and the musl bundle needs no C toolchain. Parsing,
//! scheduling, and state live here.

use std::io::Read;
use std::process::{Command, Stdio};

use serde::Deserialize;

const USER_AGENT: &str = "Mozilla/5.0";
const CHART_URL: &str = "https://query1.finance.yahoo.com/v8/finance/chart/";
const SEARCH_URL: &str = "https://query1.finance.yahoo.com/v1/finance/search?q=";
const CURL_TIMEOUT_SECS: &str = "8";
/// Hard cap on the chart payload. A 5y/1wk series is ~80 KiB; 4 MiB leaves
/// enormous headroom while bounding what a compromised endpoint can push into
/// the long-lived watch process.
pub const MAX_RESPONSE_BYTES: u64 = 4 * 1024 * 1024;
/// Search responses are tiny; cap them tighter than chart payloads.
const MAX_SEARCH_BYTES: u64 = 256 * 1024;
/// Error detail embedded in a JSON status line; keep it small.
pub const MAX_ERROR_BYTES: u64 = 4 * 1024;

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

/// Read at most `cap` bytes from `reader`. Returns the collected bytes and
/// whether more input was available (the caller should then kill the source).
/// Never buffers more than `cap` bytes regardless of what the source sends.
fn read_capped(mut reader: impl Read, cap: u64) -> std::io::Result<(Vec<u8>, bool)> {
    let mut buf = Vec::with_capacity(cap.min(64 * 1024) as usize);
    let mut overflowed = false;
    let mut chunk = [0u8; 8192];
    loop {
        let read = match reader.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        };
        let remaining = cap - buf.len() as u64;
        if read as u64 > remaining {
            buf.extend_from_slice(&chunk[..remaining as usize]);
            overflowed = true;
            break;
        }
        buf.extend_from_slice(&chunk[..read]);
    }
    Ok((buf, overflowed))
}

/// Run curl for `url`, returning at most `cap` bytes of the body. Kills curl
/// if it keeps writing past the cap; curl also aborts oversized bodies itself
/// (`--max-filesize`) and is pinned to HTTPS. HTTP-level errors (4xx/5xx) are
/// returned as bodies so callers can read API error payloads; transport
/// failures return Err with curl's stderr detail.
fn fetch_url(url: &str, cap: u64) -> Result<Vec<u8>, String> {
    let mut child = Command::new("curl")
        .args([
            "-sS",
            "--max-time",
            CURL_TIMEOUT_SECS,
            "--max-filesize",
            &cap.to_string(),
            "--proto",
            "=https",
            "-A",
            USER_AGENT,
            url,
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("run curl: {e}"))?;

    let stdout = child.stdout.take().ok_or("curl stdout is not piped")?;
    let stderr = child.stderr.take().ok_or("curl stderr is not piped")?;

    let (stdout_bytes, stdout_overflowed) =
        read_capped(stdout, cap).map_err(|e| format!("read curl stdout: {e}"))?;
    let (stderr_bytes, _) =
        read_capped(stderr, MAX_ERROR_BYTES).map_err(|e| format!("read curl stderr: {e}"))?;

    if stdout_overflowed {
        // curl is still trying to write; stop it instead of waiting it out.
        let _ = child.kill();
        let _ = child.wait();
        return Err("response exceeds size cap".to_string());
    }

    let status = child.wait().map_err(|e| format!("wait for curl: {e}"))?;
    if !status.success() {
        let stderr = String::from_utf8_lossy(&stderr_bytes);
        let detail = stderr.lines().last().unwrap_or("request failed");
        return Err(detail.to_string());
    }
    Ok(stdout_bytes)
}

/// Fetch and parse one chart request. `range`/`interval` follow Yahoo's
/// vocabulary (1d, 5m, 1mo, ...); the caller picks the pair.
pub fn fetch_chart(symbol: &str, range: &str, interval: &str) -> Result<ChartData, String> {
    let body = fetch_url(&chart_url(symbol, range, interval), MAX_RESPONSE_BYTES)?;
    let text = String::from_utf8_lossy(&body);
    match parse_chart(&text) {
        Some(data) => Ok(data),
        None => {
            Err(api_error_description(&text)
                .unwrap_or_else(|| "unexpected chart payload".to_string()))
        }
    }
}

/// Extract Yahoo's own error description (for example "No data found, symbol
/// may be delisted") from a chart payload that carries an API-level error.
fn api_error_description(text: &str) -> Option<String> {
    #[derive(Deserialize)]
    struct ApiError {
        description: Option<String>,
    }
    #[derive(Deserialize)]
    struct ErrorEnvelope {
        error: Option<ApiError>,
    }
    #[derive(Deserialize)]
    struct Envelope {
        chart: Option<ErrorEnvelope>,
    }
    let parsed: Envelope = serde_json::from_str(text).ok()?;
    parsed.chart?.error?.description.filter(|d| !d.is_empty())
}

#[derive(Deserialize)]
struct SearchResponse {
    #[serde(default)]
    quotes: Vec<SearchQuote>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SearchQuote {
    symbol: String,
    is_yahoo_finance: Option<bool>,
}

/// Ask Yahoo's search endpoint what `query` (an ISIN, a company name, ...)
/// refers to; returns the first finance-listed symbol other than the query
/// itself. Best effort: `None` on any failure.
pub fn suggest_symbol(query: &str) -> Option<String> {
    let url = format!("{SEARCH_URL}{}&quotesCount=6&newsCount=0", urlencode(query));
    let body = fetch_url(&url, MAX_SEARCH_BYTES).ok()?;
    let parsed: SearchResponse = serde_json::from_slice(&body).ok()?;
    parsed
        .quotes
        .into_iter()
        .filter(|q| q.is_yahoo_finance.unwrap_or(false))
        .map(|q| q.symbol)
        .find(|s| !s.is_empty() && !s.eq_ignore_ascii_case(query))
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

    #[test]
    fn suggest_symbol_skips_query_and_non_finance() {
        let body = r#"{"quotes":[
            {"symbol":"IE00BK5BQT80","isYahooFinance":false},
            {"symbol":"VWRA.L","isYahooFinance":true},
            {"symbol":"IE00BK5BQT80.SG","isYahooFinance":true}
        ]}"#;
        let parsed: SearchResponse = serde_json::from_str(body).unwrap();
        let found = parsed
            .quotes
            .into_iter()
            .filter(|q| q.is_yahoo_finance.unwrap_or(false))
            .map(|q| q.symbol)
            .find(|s| !s.is_empty() && !s.eq_ignore_ascii_case("IE00BK5BQT80"));
        assert_eq!(found.as_deref(), Some("VWRA.L"));
    }

    #[test]
    fn extracts_api_error_description() {
        let text = r#"{"chart":{"result":null,"error":{"code":"Not Found","description":"No data found, symbol may be delisted"}}}"#;
        assert_eq!(
            api_error_description(text).as_deref(),
            Some("No data found, symbol may be delisted")
        );
        assert!(api_error_description(r#"{"chart":{"result":[]}}"#).is_none());
    }

    #[test]
    fn read_capped_stops_at_the_cap_and_reports_overflow() {
        let data: Vec<u8> = (0..200u32).map(|i| i as u8).collect();
        let (bytes, overflowed) = read_capped(&data[..], 100).unwrap();
        assert_eq!(bytes.len(), 100);
        assert!(overflowed);

        let (bytes, overflowed) = read_capped(&data[..50], 100).unwrap();
        assert_eq!(bytes, data[..50].to_vec());
        assert!(!overflowed);

        let (bytes, overflowed) = read_capped(&data[..100], 100).unwrap();
        assert_eq!(bytes.len(), 100);
        assert!(!overflowed);
    }
}
