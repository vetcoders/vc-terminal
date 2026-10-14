//! Alacritty socket IPC.

use serde::{Deserialize, Serialize};
use std::ffi::OsStr;
use std::io::{BufRead, BufReader, Error as IoError, ErrorKind, Result as IoResult, Write};
use std::net::Shutdown;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};
use std::{env, fs};

use log::{error, warn};
use std::result::Result;
use winit::event_loop::EventLoopProxy;
use winit::window::WindowId;

use crate::cli::{Options, SocketMessage};
use crate::event::{Event, EventType};

/// Environment variable name for the IPC socket path.
const ALACRITTY_SOCKET_ENV: &str = "ALACRITTY_SOCKET";

/// Total monotonic timeout budget for reading an entire IPC message.
const IPC_TOTAL_TIMEOUT: Duration = Duration::from_secs(1);

/// Maximum size for an IPC message payload (8 MiB).
///
/// On Darwin, the kernel argv/envp space is bounded by `ARG_MAX` (`sysctl kern.argmax` = 1,048,576 bytes = 1 MiB).
/// The previous derivation assumed a 2x factor based on backslash escaping, which was falsified
/// because ASCII control characters (U+0000..=U+001F) expand 6x in JSON (`\u00xx`). That 2x claim
/// is explicitly withdrawn.
///
/// In the worst case, 1 MiB of control arguments expands to 6 MiB (6,291,456 bytes) in JSON.
/// Adding a 2 MiB structural allowance for field keys, quotes, array punctuation, and delimiters,
/// 8 MiB (8,388,608 bytes) provides a producer-consumer compatible upper bound.
pub const MAX_IPC_MESSAGE_SIZE: usize = 8 * 1024 * 1024;

#[cfg(test)]
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub(crate) enum FaultInjection {
    FailSetNonblocking,
    FailSetReadTimeout,
}

/// IPC socket listener.
pub struct IpcListener<S = EventLoopProxy<Event>> {
    pub socket: UnixListener,

    event_proxy: S,
    data: Vec<u8>,

    #[cfg(test)]
    fault_injection: Option<FaultInjection>,
}

/// Seam for dispatching IPC events to the event loop.
pub trait IpcEventSender: Send + 'static {
    fn send_event(&self, event: Event) -> Result<(), ()>;
}

impl IpcEventSender for EventLoopProxy<Event> {
    fn send_event(&self, event: Event) -> Result<(), ()> {
        EventLoopProxy::send_event(self, event).map_err(|_| ())
    }
}

impl<S: IpcEventSender> IpcListener<S> {
    pub fn new(options: &Options, event_proxy: S, path: &Path) -> Result<Self, IoError> {
        // Create unix socket in nonblocking mode.
        let socket = UnixListener::bind(path)?;
        socket.set_nonblocking(true)?;

        // Register socket path as environment variable for `alacritty msg`.
        unsafe { env::set_var(ALACRITTY_SOCKET_ENV, path.as_os_str()) };
        if options.daemon {
            println!("ALACRITTY_SOCKET={}; export ALACRITTY_SOCKET", path.display());
        }

        Ok(Self {
            event_proxy,
            socket,
            data: Default::default(),
            #[cfg(test)]
            fault_injection: None,
        })
    }

    #[cfg(test)]
    pub fn new_with_listener(socket: UnixListener, event_proxy: S) -> Self {
        Self {
            event_proxy,
            socket,
            data: Default::default(),
            #[cfg(test)]
            fault_injection: None,
        }
    }

    #[cfg(test)]
    pub fn set_fault_injection(&mut self, fault: Option<FaultInjection>) {
        self.fault_injection = fault;
    }

    fn configure_stream(&self, stream: &UnixStream) -> Result<(), IoError> {
        #[cfg(test)]
        if self.fault_injection == Some(FaultInjection::FailSetNonblocking) {
            return Err(IoError::other("injected set_nonblocking failure"));
        }
        stream.set_nonblocking(false)
    }

    fn set_stream_timeout(
        &self,
        stream: &UnixStream,
        timeout: Option<Duration>,
    ) -> Result<(), IoError> {
        #[cfg(test)]
        if self.fault_injection == Some(FaultInjection::FailSetReadTimeout) {
            return Err(IoError::other("injected set_read_timeout failure"));
        }
        stream.set_read_timeout(timeout)
    }

    /// Process the next IPC message.
    pub fn process_message(&mut self) -> Result<(), IoError> {
        let (stream, _) = self.socket.accept()?;

        // Darwin UnixListener::accept inherits O_NONBLOCK from the listener; clear it
        // so that peer reads do not immediately fail with WouldBlock.
        // If setup cannot bound a blocking read, do not perform an unbounded read.
        if let Err(err) = self.configure_stream(&stream) {
            warn!("Failed to configure IPC stream blocking mode: {err}");
            return Ok(());
        }

        self.data.clear();
        let deadline = Instant::now() + IPC_TOTAL_TIMEOUT;
        let mut reader = BufReader::new(&stream);
        let mut overflow = false;

        loop {
            let now = Instant::now();
            if now >= deadline {
                warn!("IPC message read exceeded total timeout budget");
                return Ok(());
            }
            let remaining = deadline.saturating_duration_since(now);
            if remaining.is_zero() {
                warn!("IPC message read exceeded total timeout budget");
                return Ok(());
            }
            if let Err(err) = self.set_stream_timeout(&stream, Some(remaining)) {
                #[cfg(target_os = "macos")]
                if err.raw_os_error() == Some(22) {
                    // On Darwin, setsockopt(SO_RCVTIMEO) returns EINVAL (code 22) if the peer
                    // has already shut down its write end. In this state (SS_CANTRCVMORE), any
                    // buffered data is immediately readable and will hit EOF without blocking.
                } else {
                    warn!("Failed to set IPC stream read timeout: {err}");
                    return Ok(());
                }
                #[cfg(not(target_os = "macos"))]
                {
                    warn!("Failed to set IPC stream read timeout: {err}");
                    return Ok(());
                }
            }

            let buf = match reader.fill_buf() {
                Ok([]) => break,
                Ok(buf) => buf,
                Err(err) if err.kind() == ErrorKind::Interrupted => continue,
                Err(_) => return Ok(()),
            };

            // A blocking fill may have taken time and completed after deadline.
            if Instant::now() >= deadline {
                warn!("IPC message read exceeded total timeout budget after fill");
                return Ok(());
            }

            if let Some(pos) = buf.iter().position(|&b| b == b'\n') {
                let to_consume = pos + 1;
                if self.data.len() + to_consume > MAX_IPC_MESSAGE_SIZE {
                    overflow = true;
                    break;
                }
                self.data.extend_from_slice(&buf[..to_consume]);
                reader.consume(to_consume);
                break;
            } else {
                let to_consume = buf.len();
                if self.data.len() + to_consume > MAX_IPC_MESSAGE_SIZE {
                    overflow = true;
                    break;
                }
                self.data.extend_from_slice(buf);
                reader.consume(to_consume);
            }
        }

        if overflow {
            warn!("Rejected oversized IPC message exceeding {MAX_IPC_MESSAGE_SIZE} bytes");
            return Ok(());
        }

        // Final deadline check before dispatch so expired input cannot become an accepted command.
        if Instant::now() >= deadline {
            warn!("IPC message read exceeded total timeout budget before dispatch");
            return Ok(());
        }

        let data_str = match std::str::from_utf8(&self.data) {
            Ok(s) => s.trim(),
            Err(err) => {
                warn!("Failed to parse UTF-8 IPC message: {err}");
                return Ok(());
            },
        };

        if data_str.is_empty() {
            return Ok(());
        }

        let message: SocketMessage = match serde_json::from_str(data_str) {
            Ok(message) => message,
            Err(err) => {
                warn!("Failed to parse IPC message: {err}");
                return Ok(());
            },
        };

        // Handle IPC events.
        match message {
            SocketMessage::CreateWindow(options) => {
                let event = Event::new(EventType::CreateWindow(options), None);
                let _ = self.event_proxy.send_event(event);
            },
            SocketMessage::Config(ipc_config) => {
                let window_id =
                    ipc_config.window_id.and_then(|id| u64::try_from(id).ok()).map(WindowId::from);
                let event = Event::new(EventType::IpcConfig(ipc_config), window_id);
                let _ = self.event_proxy.send_event(event);
            },
            SocketMessage::GetConfig(config) => {
                let window_id =
                    config.window_id.and_then(|id| u64::try_from(id).ok()).map(WindowId::from);
                let event = Event::new(EventType::IpcGetConfig(Arc::new(stream)), window_id);
                let _ = self.event_proxy.send_event(event);
            },
        }

        Ok(())
    }
}

/// Send a message to the active Alacritty socket.
pub fn send_message(socket: Option<PathBuf>, message: SocketMessage) -> IoResult<()> {
    // Validate exact serialized size before connecting with a truthful supported limit.
    let message_json = serde_json::to_string(&message)?;
    if message_json.len() > MAX_IPC_MESSAGE_SIZE {
        return Err(IoError::new(
            ErrorKind::InvalidInput,
            format!(
                "IPC message payload ({} bytes) exceeds maximum supported size ({} bytes)",
                message_json.len(),
                MAX_IPC_MESSAGE_SIZE
            ),
        ));
    }

    let mut socket = find_socket(socket)?;

    // Write message to socket.
    socket.write_all(message_json.as_bytes())?;
    let _ = socket.flush();

    // Shutdown write end, to allow reading.
    socket.shutdown(Shutdown::Write)?;

    // Get matching IPC reply.
    handle_reply(&socket, &message)?;

    Ok(())
}

/// Process IPC responses.
fn handle_reply(stream: &UnixStream, message: &SocketMessage) -> IoResult<()> {
    // Read reply, returning early if there is none.
    let mut buffer = String::new();
    let mut reader = BufReader::new(stream);
    if let Ok(0) | Err(_) = reader.read_line(&mut buffer) {
        return Ok(());
    }

    // Parse IPC reply.
    let reply: SocketReply = serde_json::from_str(&buffer)
        .map_err(|err| IoError::other(format!("Invalid IPC format: {err}")))?;

    // Ensure reply matches request.
    match (message, &reply) {
        // Write requested config to STDOUT.
        (SocketMessage::GetConfig(..), SocketReply::GetConfig(config)) => {
            println!("{config}");
            Ok(())
        },
        // Ignore requests without reply.
        _ => Ok(()),
    }
}

/// Send IPC message reply.
pub fn send_reply(stream: &mut UnixStream, message: SocketReply) {
    if let Err(err) = send_reply_fallible(stream, message) {
        error!("Failed to send IPC reply: {err}");
    }
}

/// Send IPC message reply, returning possible errors.
fn send_reply_fallible(stream: &mut UnixStream, message: SocketReply) -> IoResult<()> {
    let json = serde_json::to_string(&message).map_err(IoError::other)?;
    stream.write_all(json.as_bytes())?;
    stream.flush()?;
    Ok(())
}

/// Directory for the IPC socket file.
#[cfg(not(target_os = "macos"))]
pub fn socket_dir() -> PathBuf {
    xdg::BaseDirectories::with_prefix("alacritty")
        .get_runtime_directory()
        .map(ToOwned::to_owned)
        .ok()
        .and_then(|path| fs::create_dir_all(&path).map(|_| path).ok())
        .unwrap_or_else(env::temp_dir)
}

/// Directory for the IPC socket file.
#[cfg(target_os = "macos")]
pub fn socket_dir() -> PathBuf {
    env::temp_dir()
}

/// Find the IPC socket path.
fn find_socket(socket_path: Option<PathBuf>) -> IoResult<UnixStream> {
    // Handle --socket CLI override.
    if let Some(socket_path) = socket_path {
        // Ensure we inform the user about an invalid path.
        return UnixStream::connect(&socket_path).map_err(|err| {
            let message = format!("invalid socket path {socket_path:?}");
            IoError::new(err.kind(), message)
        });
    }

    // Handle environment variable.
    if let Ok(path) = env::var(ALACRITTY_SOCKET_ENV) {
        let socket_path = PathBuf::from(path);
        if let Ok(socket) = UnixStream::connect(socket_path) {
            return Ok(socket);
        }
    }

    // Search for sockets files.
    for entry in fs::read_dir(socket_dir())?.filter_map(|entry| entry.ok()) {
        let path = entry.path();

        // Skip files that aren't Alacritty sockets.
        let socket_prefix = socket_prefix();
        if path
            .file_name()
            .and_then(OsStr::to_str)
            .filter(|file| file.starts_with(&socket_prefix) && file.ends_with(".sock"))
            .is_none()
        {
            continue;
        }

        // Attempt to connect to the socket.
        match UnixStream::connect(&path) {
            Ok(socket) => return Ok(socket),
            // Delete orphan sockets.
            Err(error) if error.kind() == ErrorKind::ConnectionRefused => {
                let _ = fs::remove_file(&path);
            },
            // Ignore other errors like permission issues.
            Err(_) => (),
        }
    }

    Err(IoError::new(ErrorKind::NotFound, "no socket found"))
}

/// File prefix matching all available sockets.
///
/// This prefix will include display server information to allow for environments with multiple
/// display servers running for the same user.
#[cfg(not(target_os = "macos"))]
pub fn socket_prefix() -> String {
    let display = env::var("WAYLAND_DISPLAY").or_else(|_| env::var("DISPLAY")).unwrap_or_default();
    format!("Alacritty-{}", display.replace('/', "-"))
}

/// File prefix matching all available sockets.
#[cfg(target_os = "macos")]
pub fn socket_prefix() -> String {
    String::from("Alacritty")
}

/// IPC socket replies.
#[derive(Serialize, Deserialize, Debug)]
pub enum SocketReply {
    GetConfig(String),
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cli::{IpcConfig, IpcGetConfig, WindowOptions};
    use crate::config::ui_config::Program;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::Mutex;
    use std::thread;
    use std::time::{Duration, Instant};
    use tempfile::tempdir;

    #[derive(Clone, Default)]
    struct InertEventProxy {
        events: Arc<Mutex<Vec<Event>>>,
    }

    impl IpcEventSender for InertEventProxy {
        fn send_event(&self, event: Event) -> Result<(), ()> {
            self.events.lock().unwrap().push(event);
            Ok(())
        }
    }

    fn setup_listener(
    ) -> (tempfile::TempDir, PathBuf, IpcListener<InertEventProxy>, Arc<Mutex<Vec<Event>>>) {
        let dir = tempdir().expect("failed to create tempdir");
        let socket_path = dir.path().join("test-ipc.sock");
        let listener = UnixListener::bind(&socket_path).expect("bind socket");
        listener.set_nonblocking(true).expect("set nonblocking");
        let events = Arc::new(Mutex::new(Vec::new()));
        let proxy = InertEventProxy { events: Arc::clone(&events) };
        let ipc_listener = IpcListener::new_with_listener(listener, proxy);
        (dir, socket_path, ipc_listener, events)
    }

    #[test]
    fn test_immediate_native_shaped_create_window() {
        let (_dir, socket_path, mut listener, events) = setup_listener();

        let client_thread = thread::spawn(move || {
            let mut client = UnixStream::connect(&socket_path).expect("client connect");
            let message = SocketMessage::CreateWindow(WindowOptions::default());
            let json = serde_json::to_string(&message).expect("serialize");
            client.write_all(json.as_bytes()).expect("client write");
            client.shutdown(Shutdown::Write).expect("shutdown write");
        });

        thread::sleep(Duration::from_millis(20));
        listener.process_message().expect("process message");

        client_thread.join().expect("join client thread");

        let recorded = events.lock().unwrap();
        assert_eq!(recorded.len(), 1);
        match &recorded[0].payload {
            EventType::CreateWindow(opts) => {
                assert_eq!(*opts, WindowOptions::default());
            },
            other => panic!("Unexpected event type: {:?}", other),
        }
    }

    #[test]
    fn test_connect_before_write() {
        let (_dir, socket_path, mut listener, events) = setup_listener();

        let client_thread = thread::spawn(move || {
            let mut client = UnixStream::connect(&socket_path).expect("client connect");
            thread::sleep(Duration::from_millis(100));
            let message = SocketMessage::CreateWindow(WindowOptions::default());
            let json = serde_json::to_string(&message).expect("serialize");
            client.write_all(json.as_bytes()).expect("client write");
            client.shutdown(Shutdown::Write).expect("shutdown write");
        });

        // Ensure client connects before server calls accept
        thread::sleep(Duration::from_millis(20));
        listener.process_message().expect("process message");

        client_thread.join().expect("join client thread");

        let recorded = events.lock().unwrap();
        assert_eq!(recorded.len(), 1, "Expected 1 event dispatched after connect-before-write");
        match &recorded[0].payload {
            EventType::CreateWindow(opts) => {
                assert_eq!(*opts, WindowOptions::default());
            },
            other => panic!("Unexpected event type: {:?}", other),
        }
    }

    #[test]
    fn test_partial_record_completion() {
        let (_dir, socket_path, mut listener, events) = setup_listener();

        let client_thread = thread::spawn(move || {
            let mut client = UnixStream::connect(&socket_path).expect("client connect");
            let message = SocketMessage::CreateWindow(WindowOptions::default());
            let mut json = serde_json::to_string(&message).expect("serialize");
            json.push('\n');
            let mid = json.len() / 2;
            let (first, second) = json.split_at(mid);
            client.write_all(first.as_bytes()).expect("client write first half");
            client.flush().expect("flush first half");
            thread::sleep(Duration::from_millis(50));
            client.write_all(second.as_bytes()).expect("client write second half");
            client.shutdown(Shutdown::Write).expect("shutdown write");
        });

        thread::sleep(Duration::from_millis(20));
        listener.process_message().expect("process message");

        client_thread.join().expect("join client thread");

        let recorded = events.lock().unwrap();
        assert_eq!(recorded.len(), 1);
        match &recorded[0].payload {
            EventType::CreateWindow(opts) => {
                assert_eq!(*opts, WindowOptions::default());
            },
            other => panic!("Unexpected event type: {:?}", other),
        }
    }

    #[test]
    fn test_idle_peer_finite_return() {
        let (_dir, socket_path, mut listener, events) = setup_listener();

        let client_thread = thread::spawn(move || {
            let _client = UnixStream::connect(&socket_path).expect("client connect");
            thread::sleep(Duration::from_millis(1500));
        });

        thread::sleep(Duration::from_millis(20));
        let start = Instant::now();
        listener.process_message().expect("process message");
        let elapsed = start.elapsed();

        client_thread.join().expect("join client thread");

        assert!(events.lock().unwrap().is_empty());
        assert!(elapsed < Duration::from_secs(4));
    }

    #[test]
    fn test_malformed_input_no_event() {
        let (_dir, socket_path, mut listener, events) = setup_listener();

        let client_thread = thread::spawn(move || {
            let mut client = UnixStream::connect(&socket_path).expect("client connect");
            client.write_all(b"{not valid json}\n").expect("client write");
            client.shutdown(Shutdown::Write).expect("shutdown write");
        });

        thread::sleep(Duration::from_millis(20));
        listener.process_message().expect("process message");

        client_thread.join().expect("join client thread");

        assert!(events.lock().unwrap().is_empty());
    }

    #[test]
    fn test_config_message() {
        let (_dir, socket_path, mut listener, events) = setup_listener();

        let client_thread = thread::spawn(move || {
            let mut client = UnixStream::connect(&socket_path).expect("client connect");
            let message = SocketMessage::Config(IpcConfig {
                options: vec!["window.title=\"Test\"".to_string()],
                window_id: None,
                reset: false,
            });
            let json = serde_json::to_string(&message).expect("serialize");
            client.write_all(json.as_bytes()).expect("client write");
            client.shutdown(Shutdown::Write).expect("shutdown write");
        });

        thread::sleep(Duration::from_millis(20));
        listener.process_message().expect("process message");

        client_thread.join().expect("join client thread");

        let recorded = events.lock().unwrap();
        assert_eq!(recorded.len(), 1);
        match &recorded[0].payload {
            EventType::IpcConfig(cfg) => {
                assert_eq!(cfg.options, vec!["window.title=\"Test\"".to_string()]);
            },
            other => panic!("Unexpected event type: {:?}", other),
        }
    }

    #[test]
    fn test_get_config_message() {
        let (_dir, socket_path, mut listener, events) = setup_listener();

        let client_thread = thread::spawn(move || {
            let mut client = UnixStream::connect(&socket_path).expect("client connect");
            client.set_read_timeout(Some(Duration::from_secs(2))).expect("set read timeout");
            let message = SocketMessage::GetConfig(IpcGetConfig { window_id: None });
            let json = serde_json::to_string(&message).expect("serialize");
            client.write_all(json.as_bytes()).expect("client write");
            client.shutdown(Shutdown::Write).expect("shutdown write");

            let mut reply_buf = String::new();
            let mut reader = BufReader::new(&client);
            reader.read_line(&mut reply_buf).expect("read reply");
            let reply: SocketReply = serde_json::from_str(&reply_buf).expect("parse reply");
            match reply {
                SocketReply::GetConfig(content) => {
                    assert_eq!(content, "mock-config-content");
                },
            }
        });

        thread::sleep(Duration::from_millis(20));
        listener.process_message().expect("process message");

        // Simulate reply send from event loop and drop stream to close connection
        {
            let mut recorded = events.lock().unwrap();
            assert_eq!(recorded.len(), 1);
            let event = recorded.pop().unwrap();
            match event.payload {
                EventType::IpcGetConfig(stream) => {
                    let mut stream_clone = stream.try_clone().expect("clone stream");
                    send_reply(
                        &mut stream_clone,
                        SocketReply::GetConfig("mock-config-content".to_string()),
                    );
                    drop(stream_clone);
                    drop(stream);
                },
                other => panic!("Unexpected event type: {:?}", other),
            }
        }

        client_thread.join().expect("join client thread");
    }

    #[test]
    fn test_continuous_trickle_beyond_budget() {
        let (_dir, socket_path, mut listener, events) = setup_listener();

        let stop_writer = Arc::new(AtomicBool::new(false));
        let completed_all = Arc::new(AtomicBool::new(false));
        let iterations = Arc::new(AtomicUsize::new(0));

        let stop_writer_clone = Arc::clone(&stop_writer);
        let completed_all_clone = Arc::clone(&completed_all);
        let iterations_clone = Arc::clone(&iterations);

        let client_thread = thread::spawn(move || {
            let mut client = UnixStream::connect(&socket_path).expect("client connect");
            // Writer is scheduled to run for up to 30 * 100ms = 3.0s (finite watchdog bound),
            // which is well beyond the 1.0s total budget and 1.8s assertion deadline.
            let mut count = 0;
            for _ in 0..30 {
                if stop_writer_clone.load(Ordering::SeqCst) {
                    break;
                }
                if client.write_all(b" ").is_err() || client.flush().is_err() {
                    // Connection closed by server
                    break;
                }
                count += 1;
                iterations_clone.store(count, Ordering::SeqCst);
                thread::sleep(Duration::from_millis(100));
            }
            if count == 30 {
                completed_all_clone.store(true, Ordering::SeqCst);
            }
        });

        thread::sleep(Duration::from_millis(20));
        let start = Instant::now();
        listener.process_message().expect("process message");
        let elapsed = start.elapsed();

        // The server MUST have returned BEFORE writer completed its scheduled 3.0s trickle!
        let writer_completed_all = completed_all.load(Ordering::SeqCst);
        let completed_iterations = iterations.load(Ordering::SeqCst);

        // Signal writer to stop to clean up promptly (no permanently parked fixture)
        stop_writer.store(true, Ordering::SeqCst);
        client_thread.join().expect("join client thread");

        assert!(
            !writer_completed_all,
            "Server must return due to total timeout budget before writer finishes all iterations"
        );
        assert!(
            completed_iterations < 20,
            "Writer must not reach late iterations ({completed_iterations} reached) before server returns"
        );
        assert!(
            elapsed >= Duration::from_millis(900),
            "Server must not return prematurely: elapsed was {elapsed:?}"
        );
        assert!(
            elapsed < Duration::from_millis(1800),
            "Server total budget exceeded: elapsed was {elapsed:?}"
        );
        assert!(events.lock().unwrap().is_empty());
    }

    #[test]
    fn test_cap_overflow_rejects_without_dispatching_prefix() {
        let (_dir, socket_path, mut listener, events) = setup_listener();

        let client_thread = thread::spawn(move || {
            let mut client = UnixStream::connect(&socket_path).expect("client connect");
            let message = SocketMessage::CreateWindow(WindowOptions::default());
            let mut json = serde_json::to_string(&message).expect("serialize");
            // Pad so total message size exceeds MAX_IPC_MESSAGE_SIZE without newline
            let padding_needed = (MAX_IPC_MESSAGE_SIZE + 1024).saturating_sub(json.len());
            json.extend(std::iter::repeat_n(' ', padding_needed));
            json.push('\n');
            client.write_all(json.as_bytes()).expect("client write");
            client.shutdown(Shutdown::Write).expect("shutdown write");
        });

        thread::sleep(Duration::from_millis(20));
        listener.process_message().expect("process message");

        client_thread.join().expect("join client thread");

        // Prefix was valid JSON, but overflow occurred, so NO event must be dispatched!
        assert!(
            events.lock().unwrap().is_empty(),
            "Must reject overflow without dispatching prefix"
        );
    }

    #[test]
    fn test_parent_counterexample_payload_accepted() {
        let (_dir, socket_path, mut listener, events) = setup_listener();

        // 400,000 bytes of control U+0001 expands 6x in JSON to >2.4 MB (2,400,002 bytes).
        let ctrl_escaped = "\\u0001".repeat(400_000);
        let raw_ctrl = "\u{0001}".repeat(400_000);
        let json = format!(
            r#"{{"CreateWindow":{{"terminal_options":{{"working_directory":null,"hold":false,"command":["/usr/bin/true","{ctrl_escaped}"]}},"window_identity":{{"title":null,"class":null}},"window_tabbing_id":null,"option":[]}}}}"#
        );
        assert!(json.len() >= 2_400_000, "Counterexample JSON must be > 2.4 MB");

        let client_thread = thread::spawn(move || {
            let mut client = UnixStream::connect(&socket_path).expect("client connect");
            let mut payload = json.into_bytes();
            payload.push(b'\n');
            client.write_all(&payload).expect("client write");
            client.shutdown(Shutdown::Write).expect("shutdown write");
        });

        thread::sleep(Duration::from_millis(20));
        listener.process_message().expect("process message");

        client_thread.join().expect("join client thread");

        let recorded = events.lock().unwrap();
        assert_eq!(recorded.len(), 1, "Counterexample payload must be accepted and dispatched");
        match &recorded[0].payload {
            EventType::CreateWindow(opts) => match opts.terminal_options.command().unwrap() {
                Program::WithArgs { program, args } => {
                    assert_eq!(program, "/usr/bin/true");
                    assert_eq!(args, vec![raw_ctrl]);
                },
                other => panic!("Unexpected program format: {:?}", other),
            },
            other => panic!("Unexpected event type: {:?}", other),
        }
    }

    #[test]
    fn test_sender_validates_oversized_payload_before_connect() {
        let json_str = format!(
            r#"{{"CreateWindow":{{"terminal_options":{{"working_directory":null,"hold":false,"command":["{}"]}},"window_identity":{{"title":null,"class":null}},"window_tabbing_id":null,"option":[]}}}}"#,
            "a".repeat(MAX_IPC_MESSAGE_SIZE + 1024)
        );
        let message: SocketMessage = serde_json::from_str(&json_str).expect("deserialize");

        // Use a nonexistent socket path to prove it fails BEFORE connecting
        let fake_path = PathBuf::from("/nonexistent/fake/socket.sock");
        let result = send_message(Some(fake_path), message);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert_eq!(err.kind(), ErrorKind::InvalidInput);
    }

    #[test]
    fn test_stream_configuration_failure_refuses_without_reading() {
        let (_dir, socket_path, mut listener, events) = setup_listener();
        listener.set_fault_injection(Some(FaultInjection::FailSetNonblocking));

        let client_thread = thread::spawn(move || {
            let mut client = UnixStream::connect(&socket_path).expect("client connect");
            let message = SocketMessage::CreateWindow(WindowOptions::default());
            let json = serde_json::to_string(&message).expect("serialize");
            let _ = client.write_all(json.as_bytes());
            let _ = client.shutdown(Shutdown::Write);
        });

        thread::sleep(Duration::from_millis(20));
        listener.process_message().expect("process message");

        client_thread.join().expect("join client thread");

        assert!(
            events.lock().unwrap().is_empty(),
            "Configuration failure must refuse connection without dispatching events"
        );
    }

    #[test]
    fn test_set_read_timeout_failure_refuses_without_reading() {
        let (_dir, socket_path, mut listener, events) = setup_listener();
        listener.set_fault_injection(Some(FaultInjection::FailSetReadTimeout));

        let client_thread = thread::spawn(move || {
            let mut client = UnixStream::connect(&socket_path).expect("client connect");
            let message = SocketMessage::CreateWindow(WindowOptions::default());
            let json = serde_json::to_string(&message).expect("serialize");
            let _ = client.write_all(json.as_bytes());
            let _ = client.shutdown(Shutdown::Write);
        });

        thread::sleep(Duration::from_millis(20));
        listener.process_message().expect("process message");

        client_thread.join().expect("join client thread");

        assert!(
            events.lock().unwrap().is_empty(),
            "Set read timeout failure must refuse connection without dispatching events"
        );
    }

    #[test]
    fn test_expired_input_after_deadline_not_dispatched() {
        let (_dir, socket_path, mut listener, events) = setup_listener();

        let client_thread = thread::spawn(move || {
            let mut client = UnixStream::connect(&socket_path).expect("client connect");
            // Sleep past the 1s deadline before sending valid command
            thread::sleep(Duration::from_millis(1100));
            let message = SocketMessage::CreateWindow(WindowOptions::default());
            let json = serde_json::to_string(&message).expect("serialize");
            let _ = client.write_all(json.as_bytes());
            let _ = client.shutdown(Shutdown::Write);
        });

        thread::sleep(Duration::from_millis(20));
        let start = Instant::now();
        listener.process_message().expect("process message");
        let elapsed = start.elapsed();

        client_thread.join().expect("join client thread");

        assert!(
            events.lock().unwrap().is_empty(),
            "Expired input arriving after deadline must not be dispatched"
        );
        assert!(elapsed >= Duration::from_millis(900));
        assert!(elapsed < Duration::from_millis(1800));
    }
}
