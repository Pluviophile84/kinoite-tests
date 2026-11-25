use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::time::Duration;
use wm006a_native::wire::*;

struct Endpoint {
    listener: UnixListener,
    uid: libc::uid_t,
    role: Role,
}

enum Role {
    Ui(PathBuf),
    Custody,
    Gateway,
}

fn peer_uid(stream: &UnixStream) -> io::Result<libc::uid_t> {
    let mut credentials = libc::ucred {
        pid: 0,
        uid: 0,
        gid: 0,
    };
    let mut length = std::mem::size_of_val(&credentials) as libc::socklen_t;
    // Linux writes at most length bytes to credentials and returns the actual length.
    let result = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            std::ptr::from_mut(&mut credentials).cast(),
            &mut length,
        )
    };
    if result != 0 {
        return Err(io::Error::last_os_error());
    }
    if length as usize != std::mem::size_of_val(&credentials) {
        return Err(io::ErrorKind::InvalidData.into());
    }
    Ok(credentials.uid)
}

fn handle(mut stream: UnixStream, uid: libc::uid_t, role: &Role) {
    if peer_uid(&stream).ok() != Some(uid) {
        eprintln!("peer UID rejected");
        return;
    }
    let message = read_frame(&mut stream, Duration::from_millis(500));
    let response = match (role, message.as_deref()) {
        (Role::Ui(gateway), Ok(UI_PING)) => match request(gateway, GATEWAY_PING) {
            Ok(bytes) if bytes == GATEWAY_OK => UI_OK,
            _ => UNAVAILABLE,
        },
        (Role::Custody, Ok(CUSTODY_PING)) => CUSTODY_OK,
        (Role::Gateway, Ok(GATEWAY_PING)) => GATEWAY_OK,
        _ => BAD_REQUEST,
    };
    let _ = stream
        .set_write_timeout(Some(Duration::from_millis(500)))
        .and_then(|()| stream.write_all(response));
}

fn serve(endpoint: Endpoint) -> io::Result<()> {
    loop {
        match endpoint.listener.accept() {
            Ok((stream, _)) => handle(stream, endpoint.uid, &endpoint.role),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        }
    }
}

fn activated(expected: &[(&str, &str)]) -> io::Result<Vec<UnixListener>> {
    let expected_pid = std::process::id().to_string();
    let descriptors = expected.len().to_string();
    if env::var("LISTEN_PID").as_deref() != Ok(&expected_pid)
        || env::var("LISTEN_FDS").as_deref() != Ok(&descriptors)
    {
        return Err(io::Error::other(
            "missing or unexpected socket activation descriptors",
        ));
    }
    let names = env::var("LISTEN_FDNAMES").unwrap_or_default();
    let supplied: Vec<_> = names.split(':').collect();
    if supplied.len() != expected.len() {
        return Err(io::Error::other("unexpected socket descriptor names"));
    }
    expected
        .iter()
        .map(|(name, path)| {
            let mut matching = supplied
                .iter()
                .enumerate()
                .filter(|(_, actual)| *actual == name);
            let (index, _) = matching
                .next()
                .ok_or_else(|| io::Error::other("missing socket name"))?;
            if matching.next().is_some() {
                return Err(io::Error::other("duplicate socket name"));
            }
            let fd = 3 + index as i32;
            // systemd supplied this owned listener FD; restore close-on-exec before adopting it.
            if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } < 0 {
                return Err(io::Error::last_os_error());
            }
            let listener = unsafe { UnixListener::from_raw_fd(fd) };
            if listener.local_addr()?.as_pathname() != Some(Path::new(path)) {
                return Err(io::Error::other("unexpected listening path"));
            }
            listener.set_nonblocking(false)?;
            Ok(listener)
        })
        .collect()
}

fn signer_marker(directory: &Path) -> io::Result<String> {
    // Disable dumpability before creating or loading any synthetic marker.
    if unsafe { libc::prctl(libc::PR_SET_DUMPABLE, 0, 0, 0, 0) } != 0 {
        return Err(io::Error::last_os_error());
    }
    use std::fmt::Write as _;
    let mut entropy = [0; 24];
    File::open("/dev/urandom")?.read_exact(&mut entropy)?;
    let mut marker = String::from("WM006A_TEST:");
    for value in entropy {
        write!(marker, "{value:02x}").expect("write to String");
    }
    let pending = directory.join(format!("marker.{}", std::process::id()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&pending)?;
    let result = file
        .write_all(marker.as_bytes())
        .and_then(|()| fs::rename(&pending, directory.join("marker")));
    if result.is_err() {
        let _ = fs::remove_file(&pending);
    }
    result?;
    Ok(marker)
}

fn signer(
    ui: UnixListener,
    custody: UnixListener,
    gateway: PathBuf,
    state: &Path,
    ui_uid: u32,
    custody_uid: u32,
) -> io::Result<()> {
    let marker = signer_marker(state)?;
    eprintln!("signer ready");
    let ui_endpoint = Endpoint {
        listener: ui,
        uid: ui_uid,
        role: Role::Ui(gateway),
    };
    let custody_endpoint = Endpoint {
        listener: custody,
        uid: custody_uid,
        role: Role::Custody,
    };
    let (fail, outcome) = std::sync::mpsc::channel();
    let other = fail.clone();
    std::thread::spawn(move || {
        let _ = fail.send(serve(ui_endpoint));
    });
    std::thread::spawn(move || {
        let _ = other.send(serve(custody_endpoint));
    });
    let result = outcome.recv().map_err(io::Error::other)?;
    std::hint::black_box(&marker);
    result
}

fn gateway(listener: UnixListener, uid: u32) -> io::Result<()> {
    eprintln!("gateway ready");
    serve(Endpoint {
        listener,
        uid,
        role: Role::Gateway,
    })
}

fn number(value: &str) -> io::Result<u32> {
    value.parse().map_err(io::Error::other)
}

fn env_uid(name: &str) -> io::Result<u32> {
    number(&env::var(name).map_err(io::Error::other)?)
}

fn ip_probe() -> io::Result<()> {
    let mut denied = true;
    for (name, family) in [("IPv4", libc::AF_INET), ("IPv6", libc::AF_INET6)] {
        let raw = unsafe { libc::socket(family, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0) };
        if raw >= 0 {
            unsafe { libc::close(raw) };
            println!("{name}: socket creation permitted");
            denied = false;
        } else {
            let error = io::Error::last_os_error();
            println!("{name}: {error}");
            denied &= matches!(
                error.raw_os_error(),
                Some(libc::EAFNOSUPPORT | libc::EPERM | libc::EACCES)
            );
        }
    }
    if denied {
        Ok(())
    } else {
        Err(io::Error::other("IP denial not established"))
    }
}

fn main() -> io::Result<()> {
    let args: Vec<_> = env::args().skip(1).collect();
    match args
        .iter()
        .map(String::as_str)
        .collect::<Vec<_>>()
        .as_slice()
    {
        ["local-signer", ui, custody, gateway_path, state, ui_uid, custody_uid] => signer(
            UnixListener::bind(ui)?,
            UnixListener::bind(custody)?,
            gateway_path.into(),
            Path::new(state),
            number(ui_uid)?,
            number(custody_uid)?,
        ),
        ["local-gateway", path, uid] => gateway(UnixListener::bind(path)?, number(uid)?),
        ["system-signer"] => {
            let mut listeners =
                activated(&[("ui", UI_SOCKET), ("custody", CUSTODY_SOCKET)])?.into_iter();
            signer(
                listeners.next().unwrap(),
                listeners.next().unwrap(),
                GATEWAY_SOCKET.into(),
                Path::new("/var/lib/wm006a-signer"),
                env_uid("WM006A_OPERATOR_UID")?,
                env_uid("WM006A_CUSTODY_UID")?,
            )
        }
        ["system-gateway"] => {
            let listener = activated(&[("gateway", GATEWAY_SOCKET)])?.remove(0);
            gateway(listener, env_uid("WM006A_SIGNER_UID")?)
        }
        ["ip-probe"] => ip_probe(),
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "unknown mode or arguments",
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn exchange(body: &[u8], expected_uid: u32) -> Vec<u8> {
        let (mut client, server) = UnixStream::pair().expect("AF_UNIX socketpair");
        client.write_all(body).unwrap();
        client.shutdown(std::net::Shutdown::Write).unwrap();
        handle(server, expected_uid, &Role::Custody);
        read_frame(&mut client, Duration::from_secs(1)).unwrap()
    }

    #[test]
    fn accepts_fixed_request_from_expected_uid_and_rejects_other_messages() {
        let uid = unsafe { libc::geteuid() };
        assert_eq!(exchange(CUSTODY_PING, uid), CUSTODY_OK);
        assert_eq!(exchange(UI_PING, uid), BAD_REQUEST);
        assert_eq!(exchange(b"CUSTODY_PING\nextra", uid), BAD_REQUEST);
        assert_eq!(exchange(&[b'X'; 33], uid), BAD_REQUEST);
    }

    #[test]
    fn rejects_kernel_uid_that_does_not_match_policy() {
        let (mut client, server) = UnixStream::pair().expect("AF_UNIX socketpair");
        let uid = unsafe { libc::geteuid() };
        assert_eq!(peer_uid(&server).unwrap(), uid);
        handle(server, uid ^ 1, &Role::Custody);
        assert!(read_frame(&mut client, Duration::from_secs(1))
            .unwrap()
            .is_empty());
    }

    #[test]
    fn incomplete_frame_has_a_deadline() {
        let (mut client, mut server) = UnixStream::pair().expect("AF_UNIX socketpair");
        client.write_all(b"CUSTODY").unwrap();
        let error = read_frame(&mut server, Duration::from_millis(50)).unwrap_err();
        assert!(matches!(
            error.kind(),
            io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
        ));
    }

    #[test]
    fn synthetic_marker_is_private_and_fresh() {
        use std::os::unix::fs::{DirBuilderExt, PermissionsExt};

        let directory = env::temp_dir().join(format!("wm006a-marker-test-{}", std::process::id()));
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&directory)
            .unwrap();
        let first = signer_marker(&directory).unwrap();
        let second = signer_marker(&directory).unwrap();
        let path = directory.join("marker");
        let contents = fs::read(&path).unwrap();
        let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        fs::remove_dir_all(directory).unwrap();
        assert_eq!(mode, 0o600);
        assert!(first.starts_with("WM006A_TEST:"));
        assert_eq!(first.len(), "WM006A_TEST:".len() + 48);
        assert_ne!(first, second);
        assert!(contents == second.as_bytes());
        // The test process is separate from any other process using the library.
        assert_eq!(unsafe { libc::prctl(libc::PR_GET_DUMPABLE, 0, 0, 0, 0) }, 0);
    }
}
