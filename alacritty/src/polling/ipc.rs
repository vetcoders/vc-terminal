//! Alacritty socket IPC.

use serde::{Deserialize, Serialize};
use std::ffi::OsStr;
use std::io::{BufRead, BufReader, Error as IoError, ErrorKind, Read, Result as IoResult, Write};
use std::net::Shutdown;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use std::{env, fs};

use log::{error, warn};
use std::result::Result;
use winit::event_loop::EventLoopProxy;
use winit::window::WindowId;

use crate::cli::{Options, SocketMessage};
use crate::event::{Event, EventType};

/// Environment variable name for the IPC socket path.
const ALACRITTY_SOCKET_ENV: &str = "ALACRITTY_SOCKET";

/// Read timeout for accepted IPC connections.
const IPC_READ_TIMEOUT: Duration = Duration::from_secs(1);

/// Maximum size for an IPC message payload (64 KiB).
const MAX_IPC_MESSAGE_SIZE: u64 = 64 * 1024;

/// IPC socket listener.
pub struct IpcListener<S = EventLoopProxy<Event>> {
    pub socket: UnixListener,

    event_proxy: S,
    data: String,
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

        Ok(Self { event_proxy, socket, data: Default::default() })
    }

    #[cfg(test)]
    pub fn new_with_listener(socket: UnixListener, event_proxy: S) -> Self {
        Self { event_proxy, socket, data: Default::default() }
    }

    /// Process the next IPC message.
    pub fn process_message(&mut self) -> Result<(), IoError> {
        let (stream, _) = self.socket.accept()?;

        // Darwin UnixListener::accept inherits O_NONBLOCK from the listener; clear it
        // so that peer reads do not immediately fail with WouldBlock.
        let _ = stream.set_nonblocking(false);

        // Bound read duration so an idle peer cannot park the polling thread indefinitely.
        // On Darwin, setting SO_RCVTIMEO may return EINVAL if the peer already closed/exited,
        // in which case any buffered data is still readable and will immediately hit EOF.
        let _ = stream.set_read_timeout(Some(IPC_READ_TIMEOUT));

        self.data.clear();
        let mut reader = BufReader::new(&stream).take(MAX_IPC_MESSAGE_SIZE);

        match reader.read_line(&mut self.data) {
            Ok(0) | Err(_) => return Ok(()),
            Ok(_) => (),
        };

        let message: SocketMessage = match serde_json::from_str(&self.data) {
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
    let mut socket = find_socket(socket)?;

    // Write message to socket.
    let message_json = serde_json::to_string(&message)?;
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
}
