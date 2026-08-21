//! Watchlist quote state and the staggered round-robin poller.

use std::io::{self, Write};
use std::thread;
use std::time::Duration;

use serde::Serialize;

use crate::yahoo;

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

fn fetch_state(symbol: &str) -> SymbolState {
    match yahoo::fetch_chart(symbol, "1d", "1m") {
        Ok(data) => SymbolState::Ok {
            symbol: symbol.to_string(),
            price: data.price,
            change: data.change,
        },
        Err(message) => SymbolState::Error {
            symbol: symbol.to_string(),
            message,
        },
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
/// refreshes every I seconds while requests stay I/N apart. Runs until stdout
/// closes.
pub fn watch(symbols: &[String], interval: Duration) {
    if symbols.is_empty() {
        return;
    }
    let tick = interval / symbols.len() as u32;
    let mut states: Vec<SymbolState> = symbols
        .iter()
        .map(|symbol| SymbolState::Error {
            symbol: symbol.clone(),
            message: "loading".to_string(),
        })
        .collect();
    let mut index = 0usize;
    loop {
        states[index] = fetch_state(&symbols[index]);
        if !emit(&states) {
            return;
        }
        index = (index + 1) % symbols.len();
        thread::sleep(tick);
    }
}

/// One quotes snapshot on stdout, then done.
pub fn quote_once(symbols: &[String]) {
    let states: Vec<SymbolState> = symbols.iter().map(|s| fetch_state(s)).collect();
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
}
