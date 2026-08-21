//! Watchlist quote state and the staggered round-robin poller.

use std::io::{self, Write};
use std::thread;
use std::time::Duration;

use serde::Serialize;

use crate::yahoo;

/// Upper bound on the watchlist. Keeps the poller's state and the request
/// churn sane no matter what the widget settings contain.
pub const MAX_SYMBOLS: usize = 64;
/// Floor on the poll tick. `interval / symbols` rounds down, so without a
/// floor a long watchlist (or `--interval-secs 0`) would degrade to a tight
/// request loop.
pub const MIN_TICK: Duration = Duration::from_secs(2);

/// Per-symbol render state streamed to the widget.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(tag = "state", rename_all = "lowercase")]
pub enum SymbolState {
    Ok {
        symbol: String,
        price: f64,
        #[serde(skip_serializing_if = "Option::is_none")]
        change: Option<f64>,
    },
    Error {
        symbol: String,
        message: String,
    },
}

impl SymbolState {
    pub fn symbol(&self) -> &str {
        match self {
            SymbolState::Ok { symbol, .. } | SymbolState::Error { symbol, .. } => symbol,
        }
    }
}

/// One JSON line as the widget sees it.
#[derive(Debug, Clone, Serialize)]
pub struct QuotesLine<'a> {
    pub quotes: &'a [SymbolState],
}

pub fn normalize_symbols(raw: &str) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    raw.split(|c: char| c == ',' || c.is_whitespace())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| s.to_uppercase())
        .filter(|s| seen.insert(s.clone()))
        .collect()
}

/// Split `raw` into normalized symbols, refusing watchlists beyond the cap.
pub fn parse_symbols(raw: &str) -> Result<Vec<String>, String> {
    // Count the deduplicated list, not raw tokens: duplicates must not
    // push a valid watchlist over the cap.
    let symbols = normalize_symbols(raw);
    if symbols.len() > MAX_SYMBOLS {
        return Err(format!(
            "watchlist exceeds {MAX_SYMBOLS} symbols ({} given)",
            symbols.len()
        ));
    }
    if symbols.is_empty() {
        return Err("no symbols given; pass --symbols \"AAPL,SPY\"".to_string());
    }
    Ok(symbols)
}

/// Round-robin tick: one request every `interval / len` seconds, never below
/// `MIN_TICK`.
pub fn poll_tick(interval: Duration, len: usize) -> Duration {
    let len = len.max(1) as u32;
    std::cmp::max(interval / len, MIN_TICK)
}

fn fetch_state(
    symbol: &str,
    suggestions: &mut std::collections::HashMap<String, String>,
) -> SymbolState {
    match yahoo::fetch_chart(symbol, "1d", "1m") {
        Ok(data) => SymbolState::Ok {
            symbol: symbol.to_string(),
            price: data.price,
            change: data.change,
        },
        Err(message) => {
            // A delisted-style failure usually means the user typed an ISIN
            // or a bare company name. Ask Yahoo's search endpoint once per
            // run what it would call this instrument instead — negative
            // results are cached as the empty string so a permanently
            // unresolvable symbol does not re-query every tick.
            let message = if message.contains("may be delisted") {
                let hint = match suggestions.get(symbol) {
                    Some(cached) if cached.is_empty() => None,
                    Some(cached) => Some(cached.clone()),
                    None => {
                        let found = yahoo::suggest_symbol(symbol);
                        suggestions.insert(symbol.to_string(), found.clone().unwrap_or_default());
                        found
                    }
                };
                match hint {
                    Some(hint) => format!("{message} (did you mean {hint}?)"),
                    None => message,
                }
            } else {
                message
            };
            SymbolState::Error {
                symbol: symbol.to_string(),
                message,
            }
        }
    }
}

/// Returns false when stdout is broken (consumer gone), so callers exit
/// instead of leaking a detached process.
fn emit(states: &[SymbolState]) -> bool {
    let line = serde_json::to_string(&QuotesLine { quotes: states }).expect("quotes serialize");
    let mut out = io::stdout().lock();
    let mut broken = writeln!(out, "{line}").is_err();
    broken |= out.flush().is_err();
    !broken
}

/// Poll the watchlist round-robin: with N symbols and interval I each symbol
/// refreshes every I seconds while requests stay I/N apart (never faster than
/// MIN_TICK). Runs until stdout closes.
pub fn watch(symbols: &[String], interval: Duration) {
    if symbols.is_empty() {
        return;
    }
    let tick = poll_tick(interval, symbols.len());
    let mut states: Vec<SymbolState> = symbols
        .iter()
        .map(|symbol| SymbolState::Error {
            symbol: symbol.clone(),
            message: "loading".to_string(),
        })
        .collect();
    let mut index = 0usize;
    let mut suggestions = std::collections::HashMap::new();
    loop {
        states[index] = fetch_state(&symbols[index], &mut suggestions);
        if !emit(&states) {
            return;
        }
        index = (index + 1) % symbols.len();
        thread::sleep(tick);
    }
}

/// One quotes snapshot on stdout, then done.
pub fn quote_once(symbols: &[String]) {
    let mut suggestions = std::collections::HashMap::new();
    let states: Vec<SymbolState> = symbols
        .iter()
        .map(|s| fetch_state(s, &mut suggestions))
        .collect();
    emit(&states);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_dedupes_and_uppercases() {
        assert_eq!(
            normalize_symbols(" aapl , Spy\nBTC-USD  aapl"),
            vec!["AAPL".to_string(), "SPY".to_string(), "BTC-USD".to_string()]
        );
        assert!(normalize_symbols(" , ").is_empty());
    }

    #[test]
    fn ok_states_serialize_flat() {
        let state = SymbolState::Ok {
            symbol: "AAPL".into(),
            price: 1.5,
            change: Some(-0.25),
        };
        let json = serde_json::to_string(&state).unwrap();
        assert!(json.contains(r#""state":"ok""#));
        assert!(json.contains(r#""price":1.5"#));
        assert!(json.contains(r#""change":-0.25"#));
    }

    #[test]
    fn error_states_carry_message() {
        let state = SymbolState::Error {
            symbol: "SPY".into(),
            message: "boom".into(),
        };
        let json = serde_json::to_string(&state).unwrap();
        assert!(json.contains(r#""state":"error""#));
        assert!(json.contains(r#""message":"boom""#));
    }

    #[test]
    fn poll_tick_never_falls_below_floor() {
        assert_eq!(
            poll_tick(Duration::from_secs(60), 2),
            Duration::from_secs(30)
        );
        assert_eq!(poll_tick(Duration::from_secs(0), 2), MIN_TICK);
        assert_eq!(poll_tick(Duration::from_secs(60), 100), MIN_TICK);
        assert_eq!(poll_tick(Duration::from_secs(5), 100), MIN_TICK);
        assert_eq!(
            poll_tick(Duration::from_secs(60), 1),
            Duration::from_secs(60)
        );
    }

    #[test]
    fn parse_symbols_refuses_watchlists_beyond_cap() {
        let big = (0..MAX_SYMBOLS + 1)
            .map(|i| format!("SYM{i}"))
            .collect::<Vec<_>>()
            .join(",");
        let err = parse_symbols(&big).unwrap_err();
        assert!(err.contains("exceeds"), "err: {err}");
        assert!(parse_symbols("").is_err());
        assert!(parse_symbols("  ,  ").is_err());
    }

    #[test]
    fn parse_symbols_allows_duplicates_up_to_the_cap() {
        let mut tokens: Vec<String> = (0..MAX_SYMBOLS).map(|i| format!("SYM{i}")).collect();
        tokens.extend((0..MAX_SYMBOLS).map(|i| format!("SYM{i}")));
        let parsed = parse_symbols(&tokens.join(",")).unwrap();
        assert_eq!(parsed.len(), MAX_SYMBOLS);
    }

    #[test]
    fn normalize_symbols_keeps_every_unique_symbol() {
        let big = (0..MAX_SYMBOLS * 2)
            .map(|i| format!("SYM{i}"))
            .collect::<Vec<_>>()
            .join(",");
        assert_eq!(normalize_symbols(&big).len(), MAX_SYMBOLS * 2);
    }
}
