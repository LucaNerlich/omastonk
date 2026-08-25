//! One-shot symbol search for the watchlist editor autocomplete.

use std::io::{self, Write};

use serde::Serialize;

use crate::yahoo;

#[derive(Debug, Serialize)]
#[serde(tag = "state", rename_all = "lowercase")]
enum SearchLine {
    Ok { suggestions: Vec<SearchSuggestion> },
}

#[derive(Debug, Serialize)]
struct SearchSuggestion {
    symbol: String,
    name: String,
}

/// Print one search JSON line and exit.
pub fn search_once(query: &str) {
    let hits = yahoo::search_symbols(query, 6);
    let line = SearchLine::Ok {
        suggestions: hits
            .into_iter()
            .map(|hit| SearchSuggestion {
                symbol: hit.symbol,
                name: hit.name,
            })
            .collect(),
    };
    emit(&line);
}

fn emit(line: &SearchLine) {
    let text = serde_json::to_string(line).expect("search line serializes");
    let mut out = io::stdout().lock();
    let _ = writeln!(out, "{text}");
    let _ = out.flush();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ok_line_serializes_suggestions() {
        let line = SearchLine::Ok {
            suggestions: vec![SearchSuggestion {
                symbol: "VWRA.L".into(),
                name: "Vanguard FTSE All-World".into(),
            }],
        };
        let json = serde_json::to_string(&line).unwrap();
        assert!(json.contains(r#""state":"ok""#));
        assert!(json.contains("VWRA.L"));
        assert!(json.contains("Vanguard"));
    }
}
