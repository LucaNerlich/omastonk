//! Shared watch daemon: one Yahoo poller, many local clients over a Unix socket.
//!
//! Clients speak NDJSON. Subscribe once:
//! `{"op":"subscribe","id":"...","symbols":["AAPL"],"interval_secs":60}`
//!
//! The daemon replies with the same `QuotesLine` snapshots `watch` prints to
//! stdout, filtered to each client's symbol set. When the last client leaves,
//! the process exits after a short grace period.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{BufRead, BufReader, ErrorKind, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::Deserialize;

use crate::quotes::{self, MAX_SYMBOLS, SymbolState, WriteOutcome};

const GRACE: Duration = Duration::from_secs(2);
const SLICE: Duration = Duration::from_millis(50);
const CONNECT_TRIES: u32 = 40;
const CONNECT_WAIT: Duration = Duration::from_millis(50);
const MAX_DRAIN_READS: usize = 32;
const MAX_DRAIN_BYTES: usize = 64 * 1024;

static CLIENT_SEQ: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Deserialize)]
struct ClientMessage {
    op: String,
    #[serde(default)]
    id: String,
    #[serde(default)]
    symbols: Vec<String>,
    #[serde(default)]
    interval_secs: u64,
}

struct Client {
    id: String,
    symbols: Vec<String>,
    interval_secs: u64,
    stream: UnixStream,
    reader: BufReader<UnixStream>,
    pending: Vec<u8>,
}

#[derive(Default)]
struct Registry {
    clients: HashMap<String, Client>,
}

impl Registry {
    fn union_symbols(&self) -> Vec<String> {
        let mut seen = HashSet::new();
        let mut out = Vec::new();
        for client in self.clients.values() {
            for symbol in &client.symbols {
                if seen.insert(symbol.clone()) {
                    out.push(symbol.clone());
                }
            }
        }
        out
    }

    fn min_interval(&self) -> Duration {
        let secs = self
            .clients
            .values()
            .map(|c| c.interval_secs.max(1))
            .min()
            .unwrap_or(60);
        Duration::from_secs(secs)
    }
}

fn runtime_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("XDG_RUNTIME_DIR")
        && !dir.is_empty()
    {
        return PathBuf::from(dir).join("omastonk-qs");
    }
    std::env::temp_dir().join(format!("omastonk-qs-{}", whoami_fallback()))
}

fn whoami_fallback() -> String {
    std::env::var("USER").unwrap_or_else(|_| "user".into())
}

fn socket_path() -> PathBuf {
    runtime_dir().join("serve.sock")
}

fn lock_path() -> PathBuf {
    runtime_dir().join("serve.lock")
}

fn ensure_runtime_dir() -> std::io::Result<PathBuf> {
    let dir = runtime_dir();
    fs::create_dir_all(&dir)?;
    Ok(dir)
}

fn next_client_id() -> String {
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let seq = CLIENT_SEQ.fetch_add(1, Ordering::Relaxed);
    format!("client-{millis}-{seq}")
}

/// Try to take the exclusive serve lock. Returns the lock file handle on success.
fn try_lock() -> Option<fs::File> {
    use std::os::unix::fs::OpenOptionsExt;
    let path = lock_path();
    let file = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .mode(0o600)
        .open(&path)
        .ok()?;
    let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if rc != 0 {
        return None;
    }
    Some(file)
}

fn remove_stale_socket(path: &Path) {
    let _ = fs::remove_file(path);
}

/// Entry point for `omastonk-qs serve`.
pub fn run() {
    let _ = ensure_runtime_dir();
    let _lock = match try_lock() {
        Some(file) => file,
        None => return,
    };

    let sock = socket_path();
    remove_stale_socket(&sock);
    let listener = match UnixListener::bind(&sock) {
        Ok(listener) => listener,
        Err(err) => {
            eprintln!("omastonk-qs serve: bind {}: {err}", sock.display());
            return;
        }
    };
    if let Err(err) = listener.set_nonblocking(true) {
        eprintln!("omastonk-qs serve: nonblocking: {err}");
        return;
    }

    let registry = Arc::new(Mutex::new(Registry::default()));
    let running = Arc::new(AtomicBool::new(true));

    let accept_registry = Arc::clone(&registry);
    let accept_running = Arc::clone(&running);
    let accept_listener = listener;
    thread::spawn(move || accept_loop(accept_listener, accept_registry, accept_running));

    poll_loop(registry, running);
    let _ = fs::remove_file(sock);
}

fn accept_loop(listener: UnixListener, registry: Arc<Mutex<Registry>>, running: Arc<AtomicBool>) {
    while running.load(Ordering::SeqCst) {
        match listener.accept() {
            Ok((stream, _)) => {
                if let Err(err) = stream.set_nonblocking(true) {
                    eprintln!("omastonk-qs serve: client nonblocking: {err}");
                    continue;
                }
                match read_subscribe(&stream) {
                    Ok(mut client) => {
                        let mut guard = registry.lock().expect("registry");
                        let union_count = {
                            let mut seen: HashSet<String> = guard
                                .clients
                                .values()
                                .flat_map(|c| c.symbols.iter().cloned())
                                .collect();
                            for symbol in &client.symbols {
                                seen.insert(symbol.clone());
                            }
                            seen.len()
                        };
                        if union_count > MAX_SYMBOLS {
                            let msg = format!(
                                "watchlist exceeds {MAX_SYMBOLS} symbols across instances ({union_count} given)"
                            );
                            client.pending = quotes::quotes_line_bytes(&[SymbolState::Error {
                                symbol: String::new(),
                                message: msg,
                            }]);
                            let _ = quotes::write_buf(&mut client.stream, &mut client.pending);
                            continue;
                        }
                        guard.clients.insert(client.id.clone(), client);
                    }
                    Err(err) => eprintln!("omastonk-qs serve: subscribe: {err}"),
                }
            }
            Err(err) if err.kind() == ErrorKind::WouldBlock => {
                thread::sleep(SLICE);
            }
            Err(err) => {
                eprintln!("omastonk-qs serve: accept: {err}");
                thread::sleep(SLICE);
            }
        }
    }
}

fn read_subscribe(stream: &UnixStream) -> Result<Client, String> {
    // Briefly block for the first subscribe line so slow clients still work.
    let _ = stream.set_nonblocking(false);
    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
    let reader_stream = stream.try_clone().map_err(|e| e.to_string())?;
    let mut reader = BufReader::new(reader_stream);
    let mut line = String::new();
    reader.read_line(&mut line).map_err(|e| e.to_string())?;
    let _ = stream.set_nonblocking(true);
    let _ = stream.set_read_timeout(None);

    let msg: ClientMessage =
        serde_json::from_str(line.trim()).map_err(|e| format!("bad subscribe json: {e}"))?;
    if msg.op != "subscribe" {
        return Err(format!("expected subscribe, got {}", msg.op));
    }
    let symbols = quotes::parse_symbols(&msg.symbols.join(","))?;
    let id = if msg.id.trim().is_empty() {
        next_client_id()
    } else {
        msg.id
    };
    let writer = stream.try_clone().map_err(|e| e.to_string())?;
    Ok(Client {
        id,
        symbols,
        interval_secs: if msg.interval_secs == 0 {
            60
        } else {
            msg.interval_secs
        },
        stream: writer,
        reader,
        pending: Vec::new(),
    })
}

fn poll_loop(registry: Arc<Mutex<Registry>>, running: Arc<AtomicBool>) {
    let mut states: HashMap<String, SymbolState> = HashMap::new();
    let mut suggestions = HashMap::new();
    let mut cursor = 0usize;
    let mut next_tick = Instant::now();
    let mut empty_since: Option<Instant> = None;

    while running.load(Ordering::SeqCst) {
        prune_clients(&registry);

        let (symbols, interval, client_count) = {
            let guard = registry.lock().expect("registry");
            (
                guard.union_symbols(),
                guard.min_interval(),
                guard.clients.len(),
            )
        };

        if client_count == 0 {
            let since = empty_since.get_or_insert_with(Instant::now);
            if since.elapsed() >= GRACE {
                running.store(false, Ordering::SeqCst);
                break;
            }
            thread::sleep(SLICE);
            continue;
        }
        empty_since = None;

        if symbols.is_empty() {
            thread::sleep(SLICE);
            continue;
        }

        // Drop state for symbols that left the union.
        states.retain(|symbol, _| symbols.iter().any(|s| s == symbol));
        for symbol in &symbols {
            states
                .entry(symbol.clone())
                .or_insert_with(|| SymbolState::Error {
                    symbol: symbol.clone(),
                    message: "loading".into(),
                });
        }

        if Instant::now() >= next_tick {
            if cursor >= symbols.len() {
                cursor = 0;
            }
            let symbol = symbols[cursor].clone();
            let state = quotes::fetch_state(&symbol, &mut suggestions);
            states.insert(symbol, state);
            cursor = (cursor + 1) % symbols.len();
            broadcast(&registry, &states);
            next_tick = Instant::now() + quotes::poll_tick(interval, symbols.len());
        } else {
            // Keep draining pending output between Yahoo ticks.
            flush_pending(&registry);
        }

        thread::sleep(SLICE);
    }
}

fn prune_clients(registry: &Mutex<Registry>) {
    // Disconnects are also detected when buffered writes fail. Drain any
    // inbound bytes so a chatty client cannot fill its send buffer forever,
    // but bound the work per pass so one flood cannot stall the poller.
    let mut guard = registry.lock().expect("registry");
    let mut dead = Vec::new();
    for (id, client) in guard.clients.iter_mut() {
        let mut buf = [0u8; 256];
        let mut reads = 0usize;
        let mut drained = 0usize;
        loop {
            if reads >= MAX_DRAIN_READS || drained >= MAX_DRAIN_BYTES {
                break;
            }
            match client.reader.get_mut().read(&mut buf) {
                Ok(0) => {
                    dead.push(id.clone());
                    break;
                }
                Ok(n) => {
                    reads += 1;
                    drained += n;
                }
                Err(err) if err.kind() == ErrorKind::WouldBlock => break,
                Err(err) if err.kind() == ErrorKind::Interrupted => continue,
                Err(_) => {
                    dead.push(id.clone());
                    break;
                }
            }
        }
    }
    for id in dead {
        guard.clients.remove(&id);
    }
}

fn flush_pending(registry: &Mutex<Registry>) {
    let mut guard = registry.lock().expect("registry");
    let mut dead = Vec::new();
    for (id, client) in guard.clients.iter_mut() {
        if client.pending.is_empty() {
            continue;
        }
        match quotes::write_buf(&mut client.stream, &mut client.pending) {
            WriteOutcome::Closed => dead.push(id.clone()),
            WriteOutcome::Done | WriteOutcome::Pending => {}
        }
    }
    for id in dead {
        guard.clients.remove(&id);
    }
}

fn broadcast(registry: &Mutex<Registry>, states: &HashMap<String, SymbolState>) {
    let mut guard = registry.lock().expect("registry");
    let mut dead = Vec::new();
    for (id, client) in guard.clients.iter_mut() {
        let snapshot: Vec<SymbolState> = client
            .symbols
            .iter()
            .map(|symbol| {
                states
                    .get(symbol)
                    .cloned()
                    .unwrap_or_else(|| SymbolState::Error {
                        symbol: symbol.clone(),
                        message: "loading".into(),
                    })
            })
            .collect();

        // Quotes are full snapshots: drop any unsent older line and queue the
        // latest, then write as much as the nonblocking socket will take.
        let _ = quotes::write_buf(&mut client.stream, &mut client.pending);
        client.pending = quotes::quotes_line_bytes(&snapshot);
        match quotes::write_buf(&mut client.stream, &mut client.pending) {
            WriteOutcome::Closed => dead.push(id.clone()),
            WriteOutcome::Done | WriteOutcome::Pending => {}
        }
    }
    for id in dead {
        guard.clients.remove(&id);
    }
}

/// Client-side watch: prefer the shared daemon, fall back to in-process polling.
pub fn watch_shared(symbols: &[String], interval: Duration) {
    if try_watch_client(symbols, interval) {
        return;
    }
    // Spawn a serve process, then retry briefly before falling back.
    let _ = spawn_serve();
    for _ in 0..CONNECT_TRIES {
        if try_watch_client(symbols, interval) {
            return;
        }
        thread::sleep(CONNECT_WAIT);
    }
    quotes::watch(symbols, interval);
}

fn spawn_serve() -> std::io::Result<()> {
    let exe = std::env::current_exe()?;
    Command::new(exe)
        .arg("serve")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;
    Ok(())
}

fn try_watch_client(symbols: &[String], interval: Duration) -> bool {
    let path = socket_path();
    let mut stream = match UnixStream::connect(&path) {
        Ok(stream) => stream,
        Err(_) => return false,
    };
    let id = format!("watch-{}", std::process::id());
    let subscribe = serde_json::json!({
        "op": "subscribe",
        "id": id,
        "symbols": symbols,
        "interval_secs": interval.as_secs().max(1),
    });
    if writeln!(stream, "{subscribe}").is_err() {
        return false;
    }
    if stream.flush().is_err() {
        return false;
    }

    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => return true,
            Ok(_) => {
                let mut out = std::io::stdout().lock();
                if write!(out, "{line}").is_err() || out.flush().is_err() {
                    return true;
                }
            }
            Err(_) => return true,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_client(id: &str, symbols: &[&str], interval_secs: u64) -> Client {
        let (stream, _peer) = UnixStream::pair().expect("pair");
        stream.set_nonblocking(true).expect("nonblocking");
        let reader_stream = stream.try_clone().expect("clone");
        Client {
            id: id.to_string(),
            symbols: symbols.iter().map(|s| (*s).to_string()).collect(),
            interval_secs,
            stream,
            reader: BufReader::new(reader_stream),
            pending: Vec::new(),
        }
    }

    #[test]
    fn runtime_dir_is_namespaced() {
        let dir = runtime_dir();
        assert!(dir.ends_with("omastonk-qs") || dir.to_string_lossy().contains("omastonk-qs"));
    }

    #[test]
    fn registry_unions_and_mins_interval() {
        let mut registry = Registry::default();
        assert_eq!(registry.min_interval(), Duration::from_secs(60));
        assert!(registry.union_symbols().is_empty());

        registry.clients.insert(
            "a".into(),
            test_client("a", &["AAPL", "SPY"], 0), // clamps to 1 via max(1) in min_interval
        );
        registry
            .clients
            .insert("b".into(), test_client("b", &["SPY", "BTC-USD"], 30));

        let mut union = registry.union_symbols();
        union.sort();
        assert_eq!(
            union,
            vec!["AAPL".to_string(), "BTC-USD".to_string(), "SPY".to_string()]
        );
        // Client a has interval_secs 0 → treated as 1; min across clients is 1.
        assert_eq!(registry.min_interval(), Duration::from_secs(1));

        registry
            .clients
            .insert("c".into(), test_client("c", &["AAPL"], 120));
        assert_eq!(registry.min_interval(), Duration::from_secs(1));
        registry.clients.remove("a");
        assert_eq!(registry.min_interval(), Duration::from_secs(30));
    }

    #[test]
    fn next_client_id_is_unique() {
        let a = next_client_id();
        let b = next_client_id();
        assert_ne!(a, b);
    }
}
