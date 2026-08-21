//! Chart snapshots for the panel: one request, one JSON line.

use serde::Serialize;

use crate::yahoo;

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "state", rename_all = "lowercase")]
pub enum ChartLine {
    Ok { symbol: String, points: Vec<f64> },
    Error { symbol: String, message: String },
}

/// Fetch the close series for one symbol/range/interval and print it as a
/// single JSON line. Transport and payload failures become `state:"error"`
/// lines with exit code 0 so the widget parses every outcome uniformly.
pub fn chart_once(symbol: &str, range: &str, interval: &str) {
    let line = match yahoo::fetch_chart(symbol, range, interval) {
        Ok(data) => ChartLine::Ok {
            symbol: symbol.to_string(),
            points: data.points,
        },
        Err(message) => ChartLine::Error {
            symbol: symbol.to_string(),
            message,
        },
    };
    println!(
        "{}",
        serde_json::to_string(&line).expect("chart line serializes")
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ok_lines_carry_points() {
        let line = ChartLine::Ok {
            symbol: "SPY".into(),
            points: vec![1.0, 2.0],
        };
        let json = serde_json::to_string(&line).unwrap();
        assert!(json.contains(r#""state":"ok""#));
        assert!(json.contains(r#""points":[1.0,2.0]"#));
    }
}
