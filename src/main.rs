//! Omarchy Quattro backend for the Omastonk market watchlist widget.

use std::io::Write;
use std::process::ExitCode;
use std::time::Duration;

use clap::{Parser, Subcommand};

use omastonk_qs::chart;
use omastonk_qs::quotes::{self, QuotesLine};
use omastonk_qs::search;
use omastonk_qs::serve;

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
    /// Print symbol search suggestions as a single JSON line and exit
    Search {
        /// Free-text query (ticker fragment, company name, ISIN, ...)
        #[arg(long)]
        query: String,
    },
    /// Run the shared watch daemon (usually started automatically by `watch`)
    #[command(hide = true)]
    Serve,
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
        } => match quotes::parse_symbols(&symbols) {
            Ok(symbols) => {
                serve::watch_shared(&symbols, Duration::from_secs(interval_secs));
                // stdout closed: the shell is gone.
                ExitCode::from(0)
            }
            Err(message) => fail(&message),
        },
        Command::Quote { symbols } => match quotes::parse_symbols(&symbols) {
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
        Command::Search { query } => {
            search::search_once(&query);
            ExitCode::from(0)
        }
        Command::Serve => {
            serve::run();
            ExitCode::from(0)
        }
    }
}
