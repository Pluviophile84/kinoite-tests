use std::io::{self, Read, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, Instant};

pub const UI_SOCKET: &str = "/run/wm006a/ui/sock";
pub const CUSTODY_SOCKET: &str = "/run/wm006a/custody/sock";
pub const GATEWAY_SOCKET: &str = "/run/wm006a/gateway/sock";

pub const UI_PING: &[u8] = b"UI_PING\n";
pub const CUSTODY_PING: &[u8] = b"CUSTODY_PING\n";
pub const GATEWAY_PING: &[u8] = b"GATEWAY_PING\n";
pub const UI_OK: &[u8] = b"OK UI+GATEWAY\n";
pub const CUSTODY_OK: &[u8] = b"OK CUSTODY\n";
pub const GATEWAY_OK: &[u8] = b"OK GATEWAY\n";
pub const BAD_REQUEST: &[u8] = b"ERR REQUEST\n";
pub const UNAVAILABLE: &[u8] = b"ERR UNAVAILABLE\n";
const LIMIT: usize = 32;

pub fn read_frame(stream: &mut UnixStream, budget: Duration) -> io::Result<Vec<u8>> {
    let deadline = Instant::now() + budget;
    let mut bytes = Vec::with_capacity(LIMIT);
    let mut buffer = [0; LIMIT + 1];
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(io::ErrorKind::TimedOut.into());
        }
        stream.set_read_timeout(Some(remaining))?;
        let count = stream.read(&mut buffer)?;
        if count == 0 {
            return Ok(bytes);
        }
        if bytes.len() + count > LIMIT {
            return Err(io::ErrorKind::InvalidData.into());
        }
        bytes.extend_from_slice(&buffer[..count]);
    }
}

pub fn request(path: &Path, message: &[u8]) -> io::Result<Vec<u8>> {
    // Nonblocking connect also bounds failure when an untrusted peer fills the backlog.
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::ffi::OsStrExt;

    let path = path.as_os_str().as_bytes();
    // sockaddr_un contains plain C integers and bytes; zeros initialize the padding.
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    if path.first() != Some(&b'/') || path.len() >= address.sun_path.len() || path.contains(&0) {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    address.sun_family = libc::AF_UNIX as _;
    for (destination, source) in address.sun_path.iter_mut().zip(path) {
        *destination = *source as _;
    }
    // socket() returns a fresh owned descriptor on success.
    let raw = unsafe {
        libc::socket(
            libc::AF_UNIX,
            libc::SOCK_STREAM | libc::SOCK_CLOEXEC | libc::SOCK_NONBLOCK,
            0,
        )
    };
    if raw < 0 {
        return Err(io::Error::last_os_error());
    }
    let file = unsafe { OwnedFd::from_raw_fd(raw) };
    let result = unsafe {
        libc::connect(
            file.as_raw_fd(),
            std::ptr::from_ref(&address).cast(),
            std::mem::size_of_val(&address) as _,
        )
    };
    if result != 0 {
        return Err(io::Error::last_os_error());
    }
    let mut stream = UnixStream::from(file);
    stream.set_nonblocking(false)?;
    stream.set_write_timeout(Some(Duration::from_millis(500)))?;
    stream.write_all(message)?;
    stream.shutdown(Shutdown::Write)?;
    read_frame(&mut stream, Duration::from_secs(3))
}
