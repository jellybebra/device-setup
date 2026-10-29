//! Root helper with a deliberately small local API. Never modifies default
//! routes, system DNS, other PF anchors, v2rayN or unrelated processes.
mod strategies;
use strategies::Selection;

use anyhow::{anyhow, bail, ensure, Context, Result};
use regex::Regex;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs::{self, File, OpenOptions},
    io::{BufRead, BufReader, Read, Seek, SeekFrom, Write},
    net::{Ipv4Addr, TcpListener, TcpStream, UdpSocket},
    os::{
        fd::AsRawFd,
        unix::{
            fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt},
            net::{UnixListener, UnixStream},
        },
    },
    path::{Path, PathBuf},
    process::{Child, ChildStdin, ChildStdout, Command, ExitStatus, Stdio},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex,
    },
    thread,
    time::{Duration, Instant},
};

const LABEL: &str = "com.jellybebra.zapret-local";
const INSTALL: &str = "/Library/PrivilegedHelperTools/com.jellybebra.zapret-local";
const PLIST: &str = "/Library/LaunchDaemons/com.jellybebra.zapret-local.plist";
const SOCKET: &str = "/var/run/com.jellybebra.zapret-local.sock";
const WORKER_LOCK: &str = "/var/run/com.jellybebra.zapret-local.worker.lock";
const SERVICE_LOCK: &str = "/var/run/com.jellybebra.zapret-local.service.lock";
const ANCHOR: &str = "com.apple/zapret-local-app";
const BROKER_UID: u32 = 60004;
const ENGINE_UID: u32 = 60005;
const GROUP: u32 = 65534;
const PORT_FIRST: u16 = 42600;
const PORT_LAST: u16 = 43623;
const DEFAULT_PORT: u16 = 49946;
const COMMIT: &str = "94c3b5125b4904ce2f6aec0e2197fe17f2fadf14";
const FILES: [&str; 20] = [
    "utunws",
    "ACTIVE_DISCORD_UDP.bin",
    "quic_initial_www_google_com.bin",
    "tls_clienthello_www_google_com.bin",
    "tls_clienthello_4pda_to.bin",
    "tls_clienthello_max_ru.bin",
    "list-general.txt",
    "list-google.txt",
    "list-general-user.txt",
    "list-exclude.txt",
    "list-exclude-user.txt",
    "ipset-all.txt",
    "ipset-exclude.txt",
    "ipset-exclude-user.txt",
    "ipset-any.txt",
    "ipset-none.txt",
    "cloudflare-ipv4.txt",
    "strategies.json",
    "stun.bin",
    "stun2.bin",
];
const YOUTUBE: &str = "youtube.com,youtu.be,youtube-nocookie.com,youtubekids.com,googlevideo.com,ytimg.com,youtubei.googleapis.com,youtube.googleapis.com,youtubeembeddedplayer.googleapis.com,yt3.ggpht.com,yt4.ggpht.com,yt3.googleusercontent.com,ytimg.l.google.com,wide-youtube.l.google.com,youtube-ui.l.google.com,yt-video-upload.l.google.com,jnn-pa.googleapis.com";
// X itself works with the existing fake profile; its media needs multidisorder.
const SOCIAL: &str =
    "instagram.com,cdninstagram.com,igcdn.com,ig.me,fbcdn.net,twitter.com,twimg.com,t.co";
static STOP: AtomicBool = AtomicBool::new(false);
extern "C" fn stop_signal(_: libc::c_int) {
    STOP.store(true, Ordering::SeqCst);
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    command: String,
    port: Option<u16>,
    selection: Option<Selection>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Response {
    ok: bool,
    running: bool,
    port: u16,
    error: Option<String>,
    version: String,
    #[serde(default)]
    selection: Selection,
    #[serde(rename = "protocolVersion", default)]
    protocol_version: u32,
}
impl Response {
    fn stopped(port: u16) -> Self {
        Self {
            ok: true,
            running: false,
            port,
            error: None,
            version: env!("CARGO_PKG_VERSION").into(),
            selection: Selection::default(),
            protocol_version: 2,
        }
    }
    fn failure(port: u16, error: impl ToString) -> Self {
        Self {
            ok: false,
            error: Some(error.to_string()),
            ..Self::stopped(port)
        }
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Owner {
    uid: u32,
}
#[derive(Deserialize)]
struct Manifest {
    commit: String,
    sha256: BTreeMap<String, String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct Network {
    interface: String,
    source: Ipv4Addr,
    gateway: Ipv4Addr,
    mac: String,
}

fn root_required() -> Result<()> {
    ensure!(
        unsafe { libc::geteuid() } == 0,
        "Administrator rights are required"
    );
    Ok(())
}
fn signals() {
    for signal in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
        unsafe {
            libc::signal(signal, stop_signal as *const () as libc::sighandler_t);
        }
    }
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
    }
}
fn valid_port(port: u16) -> Result<()> {
    ensure!(
        port >= 1024 && !(PORT_FIRST..=PORT_LAST).contains(&port),
        "Choose a port from 1024–65535, excluding 42600–43623"
    );
    Ok(())
}
fn validate_interface(name: &str) -> Result<()> {
    ensure!(
        name.starts_with("en")
            && !name[2..].is_empty()
            && name[2..].bytes().all(|b| b.is_ascii_digit()),
        "Physical interface must be enN"
    );
    Ok(())
}

/// All subprocesses use fixed executable paths, no shell, bounded output/time.
fn run(program: &str, args: &[&str], input: Option<&str>) -> Result<(ExitStatus, String, String)> {
    run_bounded(program, args, input, Duration::from_secs(10))
}
fn run_bounded(
    program: &str,
    args: &[&str],
    input: Option<&str>,
    timeout: Duration,
) -> Result<(ExitStatus, String, String)> {
    let mut out = tempfile::tempfile()?;
    let mut err = tempfile::tempfile()?;
    let mut child = Command::new(program)
        .args(args)
        .env_clear()
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(out.try_clone()?)
        .stderr(err.try_clone()?)
        .spawn()
        .with_context(|| format!("Cannot run {program}"))?;
    if let Some(text) = input {
        child
            .stdin
            .take()
            .context("Missing stdin")?
            .write_all(text.as_bytes())?;
    }
    let deadline = Instant::now() + timeout;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if Instant::now() > deadline {
            let _ = child.kill();
            let _ = child.wait();
            bail!("{program} timed out");
        }
        thread::sleep(Duration::from_millis(20));
    };
    out.seek(SeekFrom::Start(0))?;
    err.seek(SeekFrom::Start(0))?;
    let mut stdout = String::new();
    let mut stderr = String::new();
    out.take(262144).read_to_string(&mut stdout)?;
    err.take(262144).read_to_string(&mut stderr)?;
    Ok((status, stdout, stderr))
}
fn checked(program: &str, args: &[&str], input: Option<&str>) -> Result<String> {
    let (status, out, err) = run(program, args, input)?;
    ensure!(
        status.success(),
        "{program}: {}",
        err.trim().chars().take(2000).collect::<String>()
    );
    Ok(format!("{out}{err}"))
}

fn physical_network(interface: &str) -> Result<Network> {
    validate_interface(interface)?;
    let info = checked("/sbin/ifconfig", &[interface], None)?;
    ensure!(
        info.contains("status: active"),
        "No active physical connection on {interface}"
    );
    let source: Ipv4Addr = Regex::new(r"(?m)^\s+inet (\S+)")?
        .captures(&info)
        .context("Physical interface has no IPv4 address")?[1]
        .parse()?;
    let route = checked(
        "/sbin/route",
        &["-n", "get", "-ifscope", interface, "default"],
        None,
    )?;
    let gateway: Ipv4Addr = Regex::new(r"(?m)^\s*gateway: (\S+)")?
        .captures(&route)
        .context("No interface-scoped gateway")?[1]
        .parse()?;
    ensure!(
        Regex::new(r"(?m)^\s*interface: (\S+)")?
            .captures(&route)
            .is_some_and(|c| &c[1] == interface),
        "Unexpected gateway interface"
    );
    let (_, arp, _) = run("/usr/sbin/arp", &["-n", &gateway.to_string()], None)?;
    let mac = Regex::new(&format!(
        r" at ([0-9a-fA-F:]+) on {}\b",
        regex::escape(interface)
    ))?
    .captures(&arp)
    .context("Gateway is missing from the ARP cache; reconnect Wi-Fi and retry")?[1]
        .to_string();
    ensure!(mac.split(':').count() == 6, "Invalid gateway MAC address");
    Ok(Network {
        interface: interface.into(),
        source,
        gateway,
        mac,
    })
}

fn choose_network() -> Result<Network> {
    // SystemConfiguration's physical service order; scoped routes avoid the VPN default.
    let order = checked(
        "/usr/sbin/networksetup",
        &["-listnetworkserviceorder"],
        None,
    )
    .unwrap_or_default();
    let mut interfaces: Vec<String> = Regex::new(r"Device: (en[0-9]+)")?
        .captures_iter(&order)
        .map(|c| c[1].into())
        .collect();
    for name in checked("/sbin/ifconfig", &["-l"], None)?.split_whitespace() {
        if validate_interface(name).is_ok() && !interfaces.iter().any(|x| x == name) {
            interfaces.push(name.into());
        }
    }
    let mut last = None;
    for name in interfaces {
        match physical_network(&name) {
            Ok(n) => return Ok(n),
            Err(e) => last = Some(e),
        }
    }
    Err(last.unwrap_or_else(|| anyhow!("No physical IPv4 network is available")))
}

fn assert_unused_uid(uid: u32) -> Result<()> {
    ensure!(
        unsafe { libc::getpwuid(uid) }.is_null(),
        "Reserved UID {uid} belongs to an existing account"
    );
    let uids = checked("/bin/ps", &["-axo", "uid="], None)?;
    ensure!(
        !uids.split_whitespace().any(|u| u == uid.to_string()),
        "Another process uses reserved UID {uid}"
    );
    Ok(())
}
fn choose_utun() -> Result<(u32, String, String, String)> {
    let interfaces = checked("/sbin/ifconfig", &["-l"], None)?;
    let addresses = checked("/sbin/ifconfig", &[], None)?;
    for unit in 61..=90 {
        let name = format!("utun{}", unit - 1);
        if !interfaces.split_whitespace().any(|n| n == name)
            && !addresses.contains(&format!("10.254.{unit}."))
        {
            return Ok((
                unit,
                name,
                format!("10.254.{unit}.1"),
                format!("10.254.{unit}.2"),
            ));
        }
    }
    bail!("No unused private utun slot")
}
fn rules(source: Ipv4Addr, utun: &str, peer: &str) -> String {
    format!("pass out quick route-to ({utun} {peer}) inet proto {{ tcp udp }} from {source} port {PORT_FIRST}:{PORT_LAST} to any user {BROKER_UID} no state\n")
}
fn engine_args(dir: &Path, drop_root: bool) -> Vec<String> {
    let mut args = Vec::new();
    if drop_root {
        args.push(format!("--uid={ENGINE_UID}:{GROUP}"));
    }
    args.extend(
        [
            "--filter-udp=*",
            "--filter-l7=discord,stun",
            "--dpi-desync=fake",
        ]
        .map(String::from),
    );
    for name in ["discord", "stun"] {
        args.push(format!(
            "--dpi-desync-fake-{name}={}",
            dir.join(FILES[1]).display()
        ));
    }
    args.extend(
        [
            "--dpi-desync-repeats=6",
            "--new",
            "--filter-udp=443",
            "--dpi-desync=fake",
            "--dpi-desync-repeats=6",
        ]
        .map(String::from),
    );
    args.push(format!(
        "--dpi-desync-fake-quic={}",
        dir.join(FILES[2]).display()
    ));
    args.extend(["--new", "--filter-tcp=80,443"].map(String::from));
    // X itself needs fake TLS rather than the media split profile. Extra
    // repeats reduce intermittent first-response stalls on its rotating edges.
    args.extend(
        [
            "--hostlist-domains=x.com",
            "--dpi-desync=fake",
            "--dpi-desync-repeats=12",
            "--dpi-desync-fooling=ts",
        ]
        .map(String::from),
    );
    args.push(format!(
        "--dpi-desync-fake-tls={}",
        dir.join(FILES[3]).display()
    ));
    args.extend(["--new", "--filter-tcp=80,443"].map(String::from));
    args.push(format!("--hostlist-domains={YOUTUBE},{SOCIAL}"));
    args.extend(
        [
            "--dpi-desync=multidisorder",
            "--dpi-desync-split-pos=1,midsld",
            "--new",
            "--filter-tcp=80,443,2053,2083,2087,2096,8443",
            "--dpi-desync=fake",
            "--dpi-desync-repeats=6",
            "--dpi-desync-fooling=ts",
        ]
        .map(String::from),
    );
    args.push(format!(
        "--dpi-desync-fake-tls={}",
        dir.join(FILES[3]).display()
    ));
    args
}

fn read_regular(path: &Path, root_owned: bool, limit: u64) -> Result<Vec<u8>> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    let meta = file.metadata()?;
    ensure!(
        meta.is_file() && meta.len() <= limit,
        "Invalid resource {}",
        path.display()
    );
    if root_owned {
        ensure!(
            meta.uid() == 0 && meta.mode() & 0o022 == 0,
            "Resource is not protected: {}",
            path.display()
        );
    }
    let mut data = Vec::new();
    file.take(limit + 1).read_to_end(&mut data)?;
    ensure!(data.len() as u64 <= limit, "Resource too large");
    Ok(data)
}
fn resources(dir: &Path, protected: bool) -> Result<Vec<(String, Vec<u8>)>> {
    let manifest_bytes = read_regular(&dir.join("manifest.json"), protected, 65536)?;
    let manifest: Manifest = serde_json::from_slice(&manifest_bytes)?;
    ensure!(manifest.commit == COMMIT, "Unexpected Flowseal revision");
    let mut output = vec![("manifest.json".into(), manifest_bytes)];
    for name in FILES {
        let bytes = read_regular(&dir.join(name), protected, 64 * 1024 * 1024)?;
        let actual = format!("{:x}", Sha256::digest(&bytes));
        ensure!(
            manifest.sha256.get(name) == Some(&actual),
            "Resource integrity check failed: {name}"
        );
        output.push((name.into(), bytes));
    }
    Ok(output)
}
fn protected_dir(path: &Path) -> Result<()> {
    if !path.exists() {
        fs::create_dir(path)?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o755))?;
    }
    let m = fs::symlink_metadata(path)?;
    ensure!(
        m.is_dir() && m.uid() == 0 && m.mode() & 0o022 == 0,
        "Unsafe directory {}",
        path.display()
    );
    Ok(())
}
fn atomic_write(path: &Path, bytes: &[u8], mode: u32) -> Result<()> {
    let mut temp = tempfile::NamedTempFile::new_in(path.parent().context("Missing parent")?)?;
    temp.write_all(bytes)?;
    temp.as_file().sync_all()?;
    temp.as_file()
        .set_permissions(fs::Permissions::from_mode(mode))?;
    temp.persist(path).map_err(|e| e.error)?;
    Ok(())
}
fn lock_file(path: &str) -> Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    let meta = file.metadata()?;
    ensure!(
        meta.is_file() && meta.uid() == 0 && meta.mode() & 0o077 == 0,
        "Unsafe lock file"
    );
    ensure!(
        unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0,
        "Another instance is still running"
    );
    Ok(file)
}
fn descriptor_limit() -> Result<()> {
    unsafe {
        let mut limit = std::mem::zeroed::<libc::rlimit>();
        ensure!(
            libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) == 0,
            "Cannot read descriptor limit"
        );
        let target = 8192.min(limit.rlim_max);
        ensure!(target >= 2048, "File descriptor limit is too low");
        if limit.rlim_cur < target {
            limit.rlim_cur = target;
            ensure!(
                libc::setrlimit(libc::RLIMIT_NOFILE, &limit) == 0,
                "Cannot increase process descriptor limit"
            );
        }
    }
    Ok(())
}

fn stop_installed_service() -> Result<(File, File)> {
    let service = format!("system/{LABEL}");
    if run("/bin/launchctl", &["print", &service], None)?
        .0
        .success()
    {
        checked("/bin/launchctl", &["bootout", &service], None)?;
    }
    // Wait for the old service/worker to relinquish its resources before update.
    let deadline = Instant::now() + Duration::from_secs(45);
    let locks = loop {
        match (lock_file(SERVICE_LOCK), lock_file(WORKER_LOCK)) {
            (Ok(a), Ok(b)) => break (a, b),
            _ if Instant::now() < deadline => thread::sleep(Duration::from_millis(100)),
            _ => bail!("Previous helper has not finished stopping; retry the installation"),
        }
    };
    Ok(locks)
}

fn install(owner: u32, source: &Path) -> Result<()> {
    root_required()?;
    ensure!((501..60000).contains(&owner), "Invalid desktop user UID");
    ensure!(
        !unsafe { libc::getpwuid(owner) }.is_null(),
        "Desktop user does not exist"
    );
    // Read all source files before touching the running installation; no source
    // path is later executed by the daemon or accepted over IPC.
    let mut data = resources(source, false)?;
    for name in ["FLOWSEAL-LICENSE.txt", "THIRD_PARTY_NOTICES.md"] {
        let path = source.join(name);
        if path.exists() {
            data.push((
                name.to_string(),
                read_regular(&path, false, 2 * 1024 * 1024)?,
            ));
        }
    }
    let executable = read_regular(&std::env::current_exe()?, false, 128 * 1024 * 1024)?;
    protected_dir(Path::new("/Library/PrivilegedHelperTools"))?;
    protected_dir(Path::new(INSTALL))?;
    protected_dir(&Path::new(INSTALL).join("engine"))?;
    protected_dir(Path::new("/Library/LaunchDaemons"))?;
    let (_service_lock, _worker_lock) = stop_installed_service()?;
    atomic_write(
        &Path::new(INSTALL).join("zapret-helper"),
        &executable,
        0o755,
    )?;
    for (name, bytes) in data {
        atomic_write(
            &Path::new(INSTALL).join("engine").join(&name),
            &bytes,
            if name == "utunws" { 0o755 } else { 0o644 },
        )?;
    }
    atomic_write(
        &Path::new(INSTALL).join("owner.json"),
        &serde_json::to_vec(&Owner { uid: owner })?,
        0o600,
    )?;
    let plist = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>{LABEL}</string>
<key>ProgramArguments</key><array><string>{INSTALL}/zapret-helper</string><string>--serve</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>5</integer>
<key>ProcessType</key><string>Background</string>
<key>ExitTimeOut</key><integer>60</integer>
<key>Umask</key><integer>63</integer>
</dict></plist>
"#
    );
    atomic_write(Path::new(PLIST), plist.as_bytes(), 0o644)?;
    drop(_service_lock);
    drop(_worker_lock);
    checked("/bin/launchctl", &["bootstrap", "system", PLIST], None)?;
    println!(
        "{}",
        serde_json::to_string(&Response::stopped(DEFAULT_PORT))?
    );
    Ok(())
}

fn uninstall() -> Result<()> {
    root_required()?;
    // These are the app's fixed root-owned paths, never paths supplied by IPC.
    let metadata = fs::symlink_metadata(INSTALL).context("Helper is not installed")?;
    ensure!(
        metadata.is_dir() && metadata.uid() == 0 && metadata.mode() & 0o022 == 0,
        "Unsafe installation directory"
    );
    let owner: Owner = serde_json::from_slice(&read_regular(
        &Path::new(INSTALL).join("owner.json"),
        true,
        1024,
    )?)?;
    let (_service_lock, _worker_lock) = stop_installed_service()?;
    if let Ok(meta) = fs::symlink_metadata(SOCKET) {
        ensure!(
            meta.file_type().is_socket() && (meta.uid() == owner.uid || meta.uid() == 0),
            "Unexpected socket object"
        );
        fs::remove_file(SOCKET)?;
    }
    if Path::new(PLIST).exists() {
        read_regular(Path::new(PLIST), true, 65536)?;
        fs::remove_file(PLIST)?;
    }
    // remove_dir_all does not follow directory symlinks; the verified parent
    // is writable only by root. No user's app/settings directory is touched.
    fs::remove_dir_all(INSTALL)?;
    fs::remove_file(WORKER_LOCK)?;
    fs::remove_file(SERVICE_LOCK)?;
    println!(
        "{}",
        serde_json::to_string(&Response::stopped(DEFAULT_PORT))?
    );
    Ok(())
}

struct Runtime {
    engine: Option<Child>,
    broker: Option<Child>,
    token: Option<String>,
    loaded: bool,
}
impl Runtime {
    fn new() -> Self {
        Self {
            engine: None,
            broker: None,
            token: None,
            loaded: false,
        }
    }
    fn children_alive(&mut self) -> Result<()> {
        for child in [&mut self.engine, &mut self.broker].into_iter().flatten() {
            ensure!(child.try_wait()?.is_none(), "Proxy or packet engine exited");
        }
        Ok(())
    }
    fn cleanup(&mut self) -> Result<()> {
        for child in [&mut self.broker, &mut self.engine] {
            if let Some(mut owned) = child.take() {
                stop_child(&mut owned);
            }
        }
        let mut errors = Vec::new();
        if self.loaded {
            match cleanup_pf(&["-a", ANCHOR, "-F", "rules"]) {
                Ok(()) => self.loaded = false,
                Err(e) => errors.push(format!("PF rules cleanup: {e:#}")),
            }
        }
        if let Some(token) = &self.token {
            match cleanup_pf(&["-X", token]) {
                Ok(()) => self.token = None,
                Err(e) => errors.push(format!("PF reference cleanup: {e:#}")),
            }
        }
        ensure!(errors.is_empty(), "{}", errors.join("; "));
        Ok(())
    }
}
fn cleanup_pf(args: &[&str]) -> Result<()> {
    // Bound each cleanup operation so the supervisor's shutdown grace covers
    // an in-flight network check, both child exits and two cleanup attempts.
    let (status, _, err) = run_bounded("/sbin/pfctl", args, None, Duration::from_secs(3))?;
    ensure!(status.success(), "{}", err.trim());
    Ok(())
}
impl Drop for Runtime {
    fn drop(&mut self) {
        // Failed fields remain owned, so a failed explicit cleanup is retried.
        if let Err(error) = self.cleanup() {
            eprintln!("{error:#}");
        }
    }
}
fn stop_child(child: &mut Child) {
    if child.try_wait().ok().flatten().is_some() {
        return;
    }
    // Child ownership (unreaped PID) prevents accidentally signalling a reused PID.
    unsafe {
        libc::kill(child.id() as i32, libc::SIGTERM);
    }
    let deadline = Instant::now() + Duration::from_secs(4);
    while Instant::now() < deadline {
        if child.try_wait().ok().flatten().is_some() {
            return;
        }
        thread::sleep(Duration::from_millis(30));
    }
    let _ = child.kill();
    let _ = child.wait();
}
fn lifetime_alive(raw_fd: i32) -> bool {
    let mut fd = libc::pollfd {
        fd: raw_fd,
        events: libc::POLLIN | libc::POLLHUP,
        revents: 0,
    };
    let n = unsafe { libc::poll(&mut fd, 1, 0) };
    if n < 0 {
        return false;
    }
    if n == 0 {
        return true;
    }
    let mut byte = [0u8];
    unsafe { libc::read(raw_fd, byte.as_mut_ptr().cast(), 1) > 0 }
}
fn parent_alive() -> bool {
    lifetime_alive(0)
}
fn interrupted() -> Result<()> {
    ensure!(
        !STOP.load(Ordering::SeqCst) && parent_alive(),
        "Stopped by app"
    );
    Ok(())
}

fn preflight(
    port: u16,
    directory: &Path,
    protected: bool,
    selection: &Selection,
) -> Result<Network> {
    valid_port(port)?;
    resources(directory, protected)?;
    assert_unused_uid(BROKER_UID)?;
    assert_unused_uid(ENGINE_UID)?;
    let _listener =
        TcpListener::bind((Ipv4Addr::LOCALHOST, port)).context("Proxy port is already occupied")?;
    let network = choose_network()?;
    // Pool ports are independently acquired by the broker; require some room,
    // not every port (recent stopped connections can still be in TIME_WAIT).
    let mut free = 0;
    for port in PORT_FIRST..=PORT_LAST {
        if TcpListener::bind((network.source, port)).is_ok()
            && UdpSocket::bind((network.source, port)).is_ok()
        {
            free += 1;
        }
    }
    ensure!(free >= 64, "Too few free source ports for the proxy");
    let mut args = selection.args(directory, false)?;
    args.push("--dry-run".into());
    checked(
        directory
            .join("utunws")
            .to_str()
            .context("Invalid engine path")?,
        &args.iter().map(String::as_str).collect::<Vec<_>>(),
        None,
    )?;
    Ok(network)
}

fn worker(port: u16, selection: Selection) -> Result<()> {
    root_required()?;
    signals();
    descriptor_limit()?;
    let _lock = lock_file(WORKER_LOCK)?;
    let directory = Path::new(INSTALL).join("engine");
    let network = preflight(port, &directory, true, &selection)?;
    let (unit, utun, local, peer) = choose_utun()?;
    let main = checked("/sbin/pfctl", &["-sr"], None)?;
    ensure!(
        main.contains("anchor \"com.apple/*\""),
        "The existing com.apple/* PF anchor is missing"
    );
    let (_, anchor, _) = run("/sbin/pfctl", &["-a", ANCHOR, "-sr"], None)?;
    ensure!(
        anchor.trim().is_empty(),
        "Application PF anchor is already occupied; refusing to replace it"
    );
    let stage = tempfile::Builder::new()
        .prefix("zapret-local-app-")
        .tempdir_in("/var/run")?;
    fs::set_permissions(stage.path(), fs::Permissions::from_mode(0o755))?;
    let mut runtime = Runtime::new();
    interrupted()?;
    let log = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(stage.path().join("engine.log"))?;
    let mut command = Command::new(directory.join("utunws"));
    command
        .args(selection.args(&directory, true)?)
        .env_clear()
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .env("ZAPRET_IFACE", &network.interface)
        .env("ZAPRET_GATEWAY_MAC", &network.mac)
        .env("ZAPRET_UTUN_UNIT", unit.to_string())
        .stdin(Stdio::null())
        .stdout(log.try_clone()?)
        .stderr(log);
    // Keep children in the launchd job's process group. If macOS eventually
    // force-stops the job, no detached packet engine/broker survives it.
    runtime.engine = Some(command.spawn()?);
    let mut present = false;
    for _ in 0..50 {
        interrupted()?;
        runtime.children_alive()?;
        if run("/sbin/ifconfig", &[&utun], None)?.0.success() {
            present = true;
            break;
        }
        thread::sleep(Duration::from_millis(100));
    }
    ensure!(present, "The engine did not create its private utun");
    checked(
        "/sbin/ifconfig",
        &[&utun, &local, &peer, "netmask", "255.255.255.255", "up"],
        None,
    )?;
    let pf = rules(network.source, &utun, &peer);
    checked("/sbin/pfctl", &["-a", ANCHOR, "-nf", "-"], Some(&pf))?;
    let enabled = checked("/sbin/pfctl", &["-E"], None)?;
    runtime.token = Some(
        Regex::new(r"Token\s*:\s*(\d+)")?
            .captures(&enabled)
            .context("PF did not return an owned enable token")?[1]
            .into(),
    );
    runtime.loaded = true;
    checked("/sbin/pfctl", &["-a", ANCHOR, "-f", "-"], Some(&pf))?;
    interrupted()?;
    let log = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(stage.path().join("broker.log"))?;
    let mut command = Command::new(Path::new(INSTALL).join("zapret-helper"));
    command
        .args([
            "--broker",
            "--interface",
            &network.interface,
            "--source-ip",
            &network.source.to_string(),
            "--port",
            &port.to_string(),
        ])
        .env_clear()
        .stdin(Stdio::null())
        .stdout(log.try_clone()?)
        .stderr(log);
    // Keep children in the launchd job's process group. If macOS eventually
    // force-stops the job, no detached packet engine/broker survives it.
    runtime.broker = Some(command.spawn()?);
    let mut ready = false;
    for _ in 0..50 {
        interrupted()?;
        runtime.children_alive()?;
        if let Ok(mut stream) =
            TcpStream::connect_timeout(&([127, 0, 0, 1], port).into(), Duration::from_millis(150))
        {
            stream.set_read_timeout(Some(Duration::from_millis(300)))?;
            stream.set_write_timeout(Some(Duration::from_millis(300)))?;
            let mut answer = [0; 2];
            if stream.write_all(&[5, 1, 0]).is_ok()
                && stream.read_exact(&mut answer).is_ok()
                && answer == [5, 0]
            {
                ready = true;
                break;
            }
        }
        thread::sleep(Duration::from_millis(100));
    }
    ensure!(ready, "Local SOCKS5 proxy failed its readiness check");
    println!(
        "{}",
        serde_json::to_string(&Response {
            running: true,
            ..Response::stopped(port)
        })?
    );
    std::io::stdout().flush()?;
    let mut network_check = Instant::now();
    while !STOP.load(Ordering::SeqCst) && parent_alive() {
        runtime.children_alive()?;
        if network_check.elapsed() >= Duration::from_secs(2) {
            ensure!(
                physical_network(&network.interface)? == network,
                "Physical network changed; proxy stopped"
            );
            network_check = Instant::now();
        }
        thread::sleep(Duration::from_millis(100));
    }
    runtime.cleanup()?;
    Ok(())
}

struct WorkerProcess {
    child: Child,
    lifetime: Option<ChildStdin>,
    output: BufReader<ChildStdout>,
}
impl WorkerProcess {
    fn start(port: u16, selection: &Selection) -> Result<Self> {
        let mut child = Command::new(Path::new(INSTALL).join("zapret-helper"))
            .args([
                "--worker",
                "--port",
                &port.to_string(),
                "--strategy",
                &selection.strategy,
                "--ipset",
                &selection.ipset,
            ])
            .env_clear()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let lifetime = child.stdin.take();
        let output = BufReader::new(child.stdout.take().context("Worker has no output")?);
        let mut own = Self {
            child,
            lifetime,
            output,
        };
        let deadline = Instant::now() + Duration::from_secs(40);
        loop {
            if STOP.load(Ordering::SeqCst) {
                bail!("Helper is stopping");
            }
            let mut pfd = libc::pollfd {
                fd: own.output.get_ref().as_raw_fd(),
                events: libc::POLLIN | libc::POLLHUP,
                revents: 0,
            };
            let available = unsafe { libc::poll(&mut pfd, 1, 100) };
            if available > 0 {
                let mut line = String::new();
                own.output.by_ref().take(8192).read_line(&mut line)?;
                let status: Response = serde_json::from_str(&line)
                    .context("Network helper stopped before becoming ready")?;
                ensure!(
                    status.ok && status.running,
                    "{}",
                    status
                        .error
                        .unwrap_or_else(|| "Network helper did not start".into())
                );
                return Ok(own);
            }
            ensure!(
                Instant::now() < deadline && own.child.try_wait()?.is_none(),
                "Network helper startup timed out"
            );
        }
    }
    fn stopped_error(&mut self) -> Option<String> {
        self.child.try_wait().ok().flatten()?;
        let mut rest = String::new();
        let _ = self.output.by_ref().take(8192).read_to_string(&mut rest);
        let error = rest
            .lines()
            .filter_map(|s| serde_json::from_str::<Response>(s).ok())
            .find_map(|r| r.error);
        Some(error.unwrap_or_else(|| "Network helper stopped".into()))
    }
}
impl WorkerProcess {
    fn finish(&mut self) -> Result<()> {
        self.lifetime.take();
        let deadline = Instant::now() + Duration::from_secs(45);
        let status = loop {
            if let Some(status) = self.child.try_wait()? {
                break status;
            }
            if Instant::now() >= deadline {
                stop_child(&mut self.child);
                bail!("Network helper exceeded its shutdown deadline; check its cleanup before restarting");
            }
            thread::sleep(Duration::from_millis(50));
        };
        let mut rest = String::new();
        self.output.by_ref().take(8192).read_to_string(&mut rest)?;
        if let Some(error) = rest
            .lines()
            .filter_map(|line| serde_json::from_str::<Response>(line).ok())
            .find_map(|r| r.error)
        {
            bail!("{error}");
        }
        ensure!(status.success(), "Network helper exited with {status}");
        Ok(())
    }
}
impl Drop for WorkerProcess {
    fn drop(&mut self) {
        let _ = self.finish();
    }
}
struct Controller {
    worker: Option<WorkerProcess>,
    owner: Option<u64>,
    status: Response,
}
impl Controller {
    fn new() -> Self {
        Self {
            worker: None,
            owner: None,
            status: Response::stopped(DEFAULT_PORT),
        }
    }
    fn refresh(&mut self) {
        if let Some(error) = self.worker.as_mut().and_then(WorkerProcess::stopped_error) {
            self.worker.take();
            self.owner = None;
            self.status = Response::failure(self.status.port, error);
        }
    }
    fn stop(&mut self) {
        let result = self.worker.take().map(|mut worker| worker.finish());
        self.owner = None;
        self.status = match result {
            Some(Err(error)) => Response::failure(self.status.port, format!("{error:#}")),
            _ => Response::stopped(self.status.port),
        };
    }
    fn reject(&self, error: impl ToString) -> Response {
        Response {
            ok: false,
            error: Some(error.to_string()),
            ..self.status.clone()
        }
    }
    fn request(&mut self, session: u64, req: Request) -> Response {
        self.refresh();
        if req.command == "status" {
            return self.status.clone();
        }
        if self.owner.is_some_and(|owner| owner != session) {
            return self.reject("Proxy is controlled by another app connection");
        }
        if req.command == "stop" {
            self.stop();
            return self.status.clone();
        }
        if req.command != "start" {
            return self.reject("Unknown command");
        }
        let selection = req.selection.unwrap_or_default();
        if let Err(e) = selection.validate() {
            return self.reject(e);
        }
        let port = req.port.unwrap_or(DEFAULT_PORT);
        if let Err(e) = valid_port(port) {
            return self.reject(e);
        }
        if self.worker.is_some() && self.status.port == port && self.status.selection == selection {
            return self.status.clone();
        }
        // Check a new port before stopping an existing listener.
        if (self.worker.is_none() || self.status.port != port)
            && TcpListener::bind((Ipv4Addr::LOCALHOST, port)).is_err()
        {
            return self.reject("Proxy port is already occupied");
        }
        self.stop();
        if !self.status.ok {
            return self.status.clone();
        }
        match WorkerProcess::start(port, &selection) {
            Ok(worker) => {
                self.worker = Some(worker);
                self.owner = Some(session);
                self.status = Response {
                    running: true,
                    selection,
                    ..Response::stopped(port)
                };
            }
            Err(error) => self.status = Response::failure(port, format!("{error:#}")),
        }
        self.status.clone()
    }
}

fn peer_uid(stream: &UnixStream) -> Result<u32> {
    let mut uid = 0;
    let mut gid = 0;
    ensure!(
        unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) } == 0,
        "Cannot authenticate app connection"
    );
    Ok(uid)
}
fn handle_client(
    mut stream: UnixStream,
    session: u64,
    shared: Arc<Mutex<Controller>>,
) -> Result<()> {
    // Darwin accept inherits O_NONBLOCK from the listener. SO_RCVTIMEO does
    // not make a nonblocking descriptor wait, so EAGAIN would busy-spin.
    stream.set_nonblocking(false)?;
    stream.set_read_timeout(Some(Duration::from_millis(250)))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    let mut pending = Vec::new();
    let mut buffer = [0u8; 1024];
    let result = (|| -> Result<()> {
        while !STOP.load(Ordering::SeqCst) {
            match stream.read(&mut buffer) {
                Ok(0) => break,
                Ok(n) => pending.extend_from_slice(&buffer[..n]),
                Err(e)
                    if matches!(
                        e.kind(),
                        std::io::ErrorKind::WouldBlock
                            | std::io::ErrorKind::TimedOut
                            | std::io::ErrorKind::Interrupted
                    ) =>
                {
                    continue
                }
                Err(e) => return Err(e.into()),
            }
            ensure!(pending.len() <= 4096, "IPC message too large");
            while let Some(index) = pending.iter().position(|b| *b == b'\n') {
                let line: Vec<_> = pending.drain(..=index).collect();
                let response = match serde_json::from_slice::<Request>(&line) {
                    Ok(req) => shared
                        .lock()
                        .map_err(|_| anyhow!("Helper lock poisoned"))?
                        .request(session, req),
                    Err(_) => Response::failure(DEFAULT_PORT, "Invalid request"),
                };
                serde_json::to_writer(&mut stream, &response)?;
                stream.write_all(b"\n")?;
            }
        }
        Ok(())
    })();
    if let Ok(mut state) = shared.lock() {
        if state.owner == Some(session) {
            state.stop();
        }
    }
    result
}
fn serve() -> Result<()> {
    root_required()?;
    signals();
    let _lock = lock_file(SERVICE_LOCK)?;
    protected_dir(Path::new(INSTALL))?;
    let owner: Owner = serde_json::from_slice(&read_regular(
        &Path::new(INSTALL).join("owner.json"),
        true,
        1024,
    )?)?;
    ensure!((501..60000).contains(&owner.uid), "Invalid installed owner");
    if let Ok(meta) = fs::symlink_metadata(SOCKET) {
        ensure!(
            meta.file_type().is_socket() && (meta.uid() == owner.uid || meta.uid() == 0),
            "Socket path is occupied by an unexpected object"
        );
        fs::remove_file(SOCKET)?;
    }
    let listener = UnixListener::bind(SOCKET)?;
    fs::set_permissions(SOCKET, fs::Permissions::from_mode(0o600))?;
    let socket_path = std::ffi::CString::new(SOCKET)?;
    ensure!(
        unsafe { libc::chown(socket_path.as_ptr(), owner.uid, libc::gid_t::MAX) } == 0,
        "Cannot assign app socket owner"
    );
    listener.set_nonblocking(true)?;
    let shared = Arc::new(Mutex::new(Controller::new()));
    let ids = AtomicU64::new(1);
    let mut clients = Vec::new();
    while !STOP.load(Ordering::SeqCst) {
        match listener.accept() {
            Ok((stream, _)) => {
                if peer_uid(&stream)? != owner.uid {
                    continue;
                }
                clients.retain(|t: &thread::JoinHandle<()>| !t.is_finished());
                if clients.len() >= 8 {
                    continue;
                }
                let state = shared.clone();
                let id = ids.fetch_add(1, Ordering::Relaxed);
                clients.push(thread::spawn(move || {
                    let _ = handle_client(stream, id, state);
                }));
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(100))
            }
            Err(e) => return Err(e.into()),
        }
        if let Ok(mut state) = shared.try_lock() {
            state.refresh();
        }
    }
    if let Ok(mut state) = shared.lock() {
        state.stop();
    }
    drop(listener);
    let _ = fs::remove_file(SOCKET);
    for client in clients {
        let _ = client.join();
    }
    Ok(())
}

fn broker(interface: String, source: Ipv4Addr, port: u16) -> Result<()> {
    root_required()?;
    valid_port(port)?;
    validate_interface(&interface)?;
    descriptor_limit()?;
    unsafe {
        ensure!(
            libc::setgroups(0, std::ptr::null()) == 0
                && libc::setgid(GROUP) == 0
                && libc::setuid(BROKER_UID) == 0,
            "Cannot drop broker privileges"
        );
    }
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    runtime.block_on(async {
        let (shutdown, rx) = tokio::sync::watch::channel(false);
        tokio::spawn(async move {
            let mut term =
                tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                    .expect("signal handler");
            let mut interrupt =
                tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())
                    .expect("signal handler");
            tokio::select! { _ = term.recv() => {}, _ = interrupt.recv() => {} }
            let _ = shutdown.send(true);
        });
        zapret_core::serve(
            zapret_core::Config {
                interface,
                source_ip: source,
                listen_port: port,
                port_start: PORT_FIRST,
                port_end: PORT_LAST,
            },
            rx,
        )
        .await
    })
}
fn value(args: &[String], key: &str) -> Result<Option<String>> {
    if let Some(index) = args.iter().position(|a| a == key) {
        return Ok(Some(
            args.get(index + 1)
                .filter(|s| !s.starts_with("--"))
                .context("Missing option value")?
                .clone(),
        ));
    }
    Ok(None)
}
fn bundled_resources() -> Result<PathBuf> {
    Ok(std::env::current_exe()?
        .parent()
        .context("Missing executable parent")?
        .join("../Resources/engine"))
}
fn main_inner() -> Result<()> {
    ensure!(cfg!(target_os = "macos"), "Zapret Local requires macOS");
    let args: Vec<String> = std::env::args().skip(1).collect();
    let port: u16 = value(&args, "--port")?
        .map(|v| v.parse())
        .transpose()?
        .unwrap_or(DEFAULT_PORT);
    let selection = Selection {
        strategy: value(&args, "--strategy")?.unwrap_or_else(|| "local".into()),
        ipset: value(&args, "--ipset")?.unwrap_or_else(|| "cloudflare".into()),
    };
    selection.validate()?;
    match args.first().map(String::as_str) {
        Some("--version") => println!("{}", env!("CARGO_PKG_VERSION")),
        Some("--install") => {
            let uid = value(&args, "--uid")?.context("Missing owner UID")?.parse()?;
            let resources = value(&args, "--resources")?.map(PathBuf::from).unwrap_or(bundled_resources()?);
            install(uid, &resources)?;
        }
        Some("--serve") => serve()?,
        Some("--uninstall") => uninstall()?,
        Some("--worker") => worker(port, selection.clone())?,
        Some("--broker") => broker(value(&args, "--interface")?.context("Missing interface")?, value(&args, "--source-ip")?.context("Missing source IP")?.parse()?, port)?,
        Some("--check") => {
            let resources = value(&args, "--resources")?.map(PathBuf::from).unwrap_or(bundled_resources()?);
            let net = preflight(port, &resources, false, &selection)?;
            let (_, tun, _, peer) = choose_utun()?;
            println!("{}", serde_json::json!({"ready":true,"port":port,"network":net,"anchor":ANCHOR,"rules":rules(net.source,&tun,&peer)}));
        }
        _ => bail!("Usage: zapret-helper --install --uid UID [--resources DIR] | --uninstall | --check [--port PORT] [--resources DIR] | --version"),
    }
    Ok(())
}
fn main() {
    if let Err(error) = main_inner() {
        let port = std::env::args()
            .collect::<Vec<_>>()
            .windows(2)
            .find(|v| v[0] == "--port")
            .and_then(|v| v[1].parse().ok())
            .unwrap_or(DEFAULT_PORT);
        println!(
            "{}",
            serde_json::to_string(&Response::failure(port, format!("{error:#}"))).unwrap()
        );
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn port_validation_preserves_source_pool_and_privileged_ports() {
        for p in [0, 80, 1023, PORT_FIRST, PORT_LAST] {
            assert!(valid_port(p).is_err());
        }
        for p in [1024, 49946, 65535] {
            assert!(valid_port(p).is_ok());
        }
    }
    #[test]
    fn pf_scope_is_only_the_dedicated_broker() {
        let r = rules("192.0.2.3".parse().unwrap(), "utun70", "10.254.71.2");
        assert!(r.contains("from 192.0.2.3 port 42600:43623 to any user 60004"));
        assert!(r.contains("route-to (utun70 10.254.71.2)"));
        assert!(!r.contains("60000"));
        assert!(!r.contains("60002"));
    }
    #[test]
    fn engine_profiles_keep_youtube_and_social_before_discord_fallback() {
        let args = engine_args(Path::new("/engine"), true);
        let yt = args
            .iter()
            .position(|s| s.starts_with("--hostlist-domains=youtube.com,"))
            .unwrap();
        let fallback = args
            .iter()
            .position(|s| s == "--filter-tcp=80,443,2053,2083,2087,2096,8443")
            .unwrap();
        assert!(yt < fallback);
        let x = args
            .iter()
            .position(|s| s == "--hostlist-domains=x.com")
            .unwrap();
        assert!(x < yt);
        assert_eq!(
            &args[x + 1..x + 4],
            &[
                "--dpi-desync=fake",
                "--dpi-desync-repeats=12",
                "--dpi-desync-fooling=ts"
            ]
        );
        let hosts = args[yt].strip_prefix("--hostlist-domains=").unwrap();
        let domains: Vec<_> = hosts.split(',').collect();
        for domain in [
            "youtube.com",
            "instagram.com",
            "cdninstagram.com",
            "fbcdn.net",
            "twimg.com",
        ] {
            assert!(domains.contains(&domain));
        }
        assert!(!domains.contains(&"x.com"));
        assert!(args.contains(&"--dpi-desync=multidisorder".into()));
        assert!(args.contains(&"--filter-l7=discord,stun".into()));
        assert_eq!(args[0], "--uid=60005:65534");
        assert!(!engine_args(Path::new("/engine"), false)
            .iter()
            .any(|a| a.starts_with("--uid=")));
    }
    #[test]
    fn interface_and_ipc_reject_unexpected_inputs() {
        for n in ["utun1", "en", "en0;anything", "en-1", "../en0"] {
            assert!(validate_interface(n).is_err());
        }
        assert!(validate_interface("en0").is_ok());
        assert!(serde_json::from_str::<Request>(
            r#"{"command":"start","port":49949,"program":"/bin/sh"}"#
        )
        .is_err());
        assert!(serde_json::from_str::<Request>(r#"{"command":"start","port":65536}"#).is_err());
    }
    #[test]
    fn resource_verification_rejects_symlinks_and_hash_changes() {
        let d = tempfile::tempdir().unwrap();
        let mut hashes = BTreeMap::new();
        for name in FILES {
            fs::write(d.path().join(name), b"test").unwrap();
            hashes.insert(name, format!("{:x}", Sha256::digest(b"test")));
        }
        fs::write(
            d.path().join("manifest.json"),
            serde_json::to_vec(&serde_json::json!({"commit":COMMIT,"sha256":hashes})).unwrap(),
        )
        .unwrap();
        assert!(resources(d.path(), false).is_ok());
        fs::write(d.path().join("utunws"), b"changed").unwrap();
        assert!(resources(d.path(), false).is_err());
        fs::remove_file(d.path().join("utunws")).unwrap();
        std::os::unix::fs::symlink(d.path().join(FILES[1]), d.path().join("utunws")).unwrap();
        assert!(resources(d.path(), false).is_err());
    }
    #[test]
    fn lifetime_pipe_detects_parent_death_without_a_process_lookup() {
        let (reader, writer) = UnixStream::pair().unwrap();
        assert!(lifetime_alive(reader.as_raw_fd()));
        drop(writer);
        // A concurrently spawning child can briefly hold a dup between fork
        // and exec. The worker polls repeatedly rather than relying on one tick.
        let deadline = Instant::now() + Duration::from_secs(2);
        while lifetime_alive(reader.as_raw_fd()) && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(10));
        }
        assert!(!lifetime_alive(reader.as_raw_fd()));
    }
    #[test]
    fn runtime_cleanup_reaps_only_its_owned_children() {
        let mut runtime = Runtime::new();
        runtime.engine = Some(Command::new("/bin/sleep").arg("60").spawn().unwrap());
        runtime.broker = Some(Command::new("/bin/sleep").arg("60").spawn().unwrap());
        let pids = [
            runtime.engine.as_ref().unwrap().id(),
            runtime.broker.as_ref().unwrap().id(),
        ];
        runtime.cleanup().unwrap();
        assert!(runtime.engine.is_none() && runtime.broker.is_none());
        for pid in pids {
            assert_eq!(unsafe { libc::kill(pid as i32, 0) }, -1);
        }
    }
    #[test]
    fn stop_surfaces_worker_cleanup_failure() {
        let message =
            serde_json::to_string(&Response::failure(DEFAULT_PORT, "PF cleanup failed")).unwrap();
        let mut child = Command::new("/usr/bin/printf")
            .args(["%s\n", &message])
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let output = BufReader::new(child.stdout.take().unwrap());
        let mut controller = Controller::new();
        controller.worker = Some(WorkerProcess {
            child,
            lifetime: None,
            output,
        });
        controller.owner = Some(1);
        controller.status.running = true;
        controller.stop();
        assert!(!controller.status.ok);
        assert!(!controller.status.running);
        assert!(controller
            .status
            .error
            .unwrap()
            .contains("PF cleanup failed"));
        assert!(controller.worker.is_none());
    }
    #[test]
    fn accepted_nonblocking_ipc_socket_is_reset_before_waiting() {
        let (mut client, server) = UnixStream::pair().unwrap();
        // Darwin accept inherits O_NONBLOCK from our nonblocking listener.
        server.set_nonblocking(true).unwrap();
        let observed = server.try_clone().unwrap();
        client
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let state = Arc::new(Mutex::new(Controller::new()));
        let handler = thread::spawn(move || handle_client(server, 77, state).unwrap());
        client.write_all(b"{\"command\":\"status\"}\n").unwrap();
        let mut response = String::new();
        BufReader::new(client.try_clone().unwrap())
            .read_line(&mut response)
            .unwrap();
        let flags = unsafe { libc::fcntl(observed.as_raw_fd(), libc::F_GETFL) };
        drop(client);
        handler.join().unwrap();
        assert!(flags >= 0);
        assert_eq!(
            flags & libc::O_NONBLOCK,
            0,
            "idle IPC reads must wait instead of spinning"
        );
    }

    #[test]
    fn another_connection_cannot_stop_or_release_the_owner() {
        let shared = Arc::new(Mutex::new(Controller::new()));
        {
            let mut state = shared.lock().unwrap();
            state.owner = Some(99);
            state.status.running = true;
        }
        let (mut client, server) = UnixStream::pair().unwrap();
        let state = shared.clone();
        let handler = thread::spawn(move || handle_client(server, 44, state).unwrap());
        client.write_all(b"{\"command\":\"stop\"}\n").unwrap();
        let mut response = String::new();
        BufReader::new(client.try_clone().unwrap())
            .read_line(&mut response)
            .unwrap();
        let response: Response = serde_json::from_str(&response).unwrap();
        assert!(!response.ok);
        assert!(response.running);
        drop(client);
        handler.join().unwrap();
        assert_eq!(shared.lock().unwrap().owner, Some(99));
        assert!(shared.lock().unwrap().status.running);
        let (mut client, server) = UnixStream::pair().unwrap();
        let state = shared.clone();
        let handler = thread::spawn(move || handle_client(server, 99, state).unwrap());
        client.write_all(b"{\"command\":\"status\"}\n").unwrap();
        let mut response = String::new();
        BufReader::new(client.try_clone().unwrap())
            .read_line(&mut response)
            .unwrap();
        drop(client);
        handler.join().unwrap();
        assert!(!shared.lock().unwrap().status.running);
        assert_eq!(shared.lock().unwrap().owner, None);
    }
}
