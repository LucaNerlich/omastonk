//! Omarchy Quattro backend for the Omastonk market watchlist widget.

use std::io::Write;
use std::process::ExitCode;
use std::time::Duration;

use clap::{Parser, Subcommand};

use omastonk_qs::chart;
use omastonk_qs::quotes::{self, QuotesLine};

const DEFAULT_INTERVAL_SECS: u64 = 60;

#[derive(Parser)]
#[command(
    name = "omastonk-qs",
    version,
    about = "Backend for the Omarchy Omastonk market watchlist widget",
    long_about = "Fetches Yahoo Finance quotes for a watchlist and streams them\nas JSON lines for the Omarchy Quattro bar widget."
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Stream watchlist quotes as JSON lines, one per fetch
    Watch {
        /// Comma- or whitespace-separated watchlist, e.g. `AAPL,SPY,BTC-USD`
        #[arg(long, default_value = "")]
        symbols: String,
        /// Seconds between refreshes of each individual symbol
        #[arg(long, default_value_t = DEFAULT_INTERVAL_SECS)]
        interval_secs: u64,
    },
    /// Print one quotes snapshot as a single JSON line and exit
    Quote {
        /// Comma- or whitespace-separated watchlist
        #[arg(long, default_value = "")]
        symbols: String,
    },
    /// Print one chart close-series as a single JSON line and exit
    Chart {
        /// Symbol to chart
        #[arg(long)]
        symbol: String,
        /// Yahoo range: 1d, 5d, 1mo, 6mo, ytd, 1y, 5y
        #[arg(long)]
        range: String,
        /// Yahoo interval: 1m, 5m, 15m, 1d, 1wk
        #[arg(long)]
        interval: String,
    },
}

fn parse_symbols(raw: &str) -> Result<Vec<String>, String> {
    let symbols = quotes::normalize_symbols(raw);
    if symbols.is_empty() {
        return Err("no symbols given; pass --symbols \"AAPL,SPY\"".to_string());
    }
    Ok(symbols)
}

/// Emit failures as JSON on stdout so the QML side can render every outcome,
/// then exit nonzero for scripting.
fn fail(message: &str) -> ExitCode {
    let _ = writeln!(std::io::stdout(), "{}", error_line(message));
    eprintln!("omastonk-qs: {message}");
    ExitCode::FAILURE
}

fn error_line(message: &str) -> String {
    serde_json::to_string(&QuotesLine {
        quotes: &[quotes::SymbolState::Error {
            symbol: String::new(),
            message: message.to_string(),
        }],
    })
    .expect("error line serializes")
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match cli.command {
        Command::Watch {
            symbols,
            interval_secs,
        } => match parse_symbols(&symbols) {
            Ok(symbols) => {
                quotes::watch(&symbols, Duration::from_secs(interval_secs));
                // stdout closed: the shell is gone.
                ExitCode::from(0)
            }
            Err(message) => fail(&message),
        },
        Command::Quote { symbols } => match parse_symbols(&symbols) {
            Ok(symbols) => {
                quotes::quote_once(&symbols);
                ExitCode::from(0)
            }
            Err(message) => fail(&message),
        },
        Command::Chart {
            symbol,
            range,
            interval,
        } => {
            chart::chart_once(&symbol.to_uppercase(), &range, &interval);
            ExitCode::from(0)
        }
    }
}
