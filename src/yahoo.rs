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
const CURL_TIMEOUT_SECS: &str = "8";
/// Hard cap on the chart payload. A 5y/1wk series is ~80 KiB; 4 MiB leaves
/// enormous headroom while bounding what a compromised endpoint can push into
/// the long-lived watch process.
pub const MAX_RESPONSE_BYTES: u64 = 4 * 1024 * 1024;
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

/// Fetch and parse one chart request. `range`/`interval` follow Yahoo's
/// vocabulary (1d, 5m, 1mo, ...); the caller picks the pair.
pub fn fetch_chart(symbol: &str, range: &str, interval: &str) -> Result<ChartData, String> {
    let url = chart_url(symbol, range, interval);
    let mut child = Command::new("curl")
        .args([
            "-fsS",
            "--max-time",
            CURL_TIMEOUT_SECS,
            // Second boundary on the same resource: curl aborts the transfer
            // itself once the body exceeds the cap, so a rogue endpoint cannot
            // keep the pipe full while we stop reading.
            "--max-filesize",
            &MAX_RESPONSE_BYTES.to_string(),
            "--proto",
            "=https",
            "-A",
            USER_AGENT,
            &url,
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("run curl: {e}"))?;

    let stdout = child.stdout.take().ok_or("curl stdout is not piped")?;
    let stderr = child.stderr.take().ok_or("curl stderr is not piped")?;

    let (stdout_bytes, stdout_overflowed) =
        read_capped(stdout, MAX_RESPONSE_BYTES).map_err(|e| format!("read curl stdout: {e}"))?;
    let (stderr_bytes, stderr_overflowed) =
        read_capped(stderr, MAX_ERROR_BYTES).map_err(|e| format!("read curl stderr: {e}"))?;

    if stdout_overflowed || stderr_overflowed {
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
    let text = String::from_utf8_lossy(&stdout_bytes);
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
