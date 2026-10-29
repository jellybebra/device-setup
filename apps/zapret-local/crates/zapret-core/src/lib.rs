//! Local SOCKS5 transport. All Internet sockets, including DNS, share the same
//! physical-interface binding and source-port pool. No implicit DNS/VPN fallback.
use anyhow::{bail, Context, Result};
use serde::Deserialize;
use socket2::{Domain, Protocol, Socket, Type};
use std::{
    collections::{HashMap, HashSet},
    ffi::CString,
    net::{IpAddr, Ipv4Addr, SocketAddr, SocketAddrV4},
    os::fd::AsRawFd,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncBufRead, AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWriteExt, BufReader},
    net::{TcpListener, TcpSocket, TcpStream, UdpSocket},
    sync::{mpsc, watch, Semaphore},
    task::{JoinHandle, JoinSet},
    time::timeout,
};
use tokio_rustls::{rustls, TlsConnector};

const MAX_BODY: usize = 65_536;
const MAX_HEADERS: usize = 16_384;
const MAX_UDP_PAYLOAD: usize = 65_507 - 10;
const MAX_PEERS: usize = 64;
const UDP_IDLE: Duration = Duration::from_secs(120);

#[derive(Debug, Clone)]
pub struct Config {
    pub interface: String,
    pub source_ip: Ipv4Addr,
    pub listen_port: u16,
    pub port_start: u16,
    pub port_end: u16,
}

#[derive(Default)]
struct Ports {
    busy: HashSet<u16>,
    next: u16,
}

struct Pool {
    config: Config,
    ports: Mutex<Ports>,
    interface_index: u32,
    test_loopback: bool,
}

struct Lease {
    pool: Arc<Pool>,
    port: u16,
}

impl Drop for Lease {
    fn drop(&mut self) {
        self.pool.ports.lock().unwrap().busy.remove(&self.port);
    }
}

impl Pool {
    fn new(config: Config, test_loopback: bool) -> Result<Arc<Self>> {
        if config.port_start == 0 || config.port_start > config.port_end {
            bail!("Invalid source-port range");
        }
        if !test_loopback && (config.listen_port == 0 || config.source_ip.is_unspecified()) {
            bail!("Invalid proxy address/port");
        }
        let interface_index = if test_loopback {
            0
        } else {
            if !cfg!(target_os = "macos") {
                bail!("Physical-interface binding requires macOS");
            }
            let name = CString::new(config.interface.as_str())?;
            let index = unsafe { libc::if_nametoindex(name.as_ptr()) };
            if index == 0 {
                bail!("Physical interface does not exist");
            }
            index
        };
        Ok(Arc::new(Self {
            ports: Mutex::new(Ports {
                next: config.port_start,
                ..Ports::default()
            }),
            config,
            interface_index,
            test_loopback,
        }))
    }

    fn socket(self: &Arc<Self>, udp: bool) -> Result<(Socket, Lease)> {
        let mut ports = self.ports.lock().unwrap();
        for _ in self.config.port_start..=self.config.port_end {
            let port = ports.next;
            ports.next = if port == self.config.port_end {
                self.config.port_start
            } else {
                port + 1
            };
            if ports.busy.contains(&port) {
                continue;
            }
            let socket = Socket::new(
                Domain::IPV4,
                if udp { Type::DGRAM } else { Type::STREAM },
                Some(if udp { Protocol::UDP } else { Protocol::TCP }),
            )?;
            if !self.test_loopback {
                // IP_BOUND_IF is 25 on Darwin; binding happens before connect.
                let result = unsafe {
                    libc::setsockopt(
                        socket.as_raw_fd(),
                        libc::IPPROTO_IP,
                        25,
                        (&self.interface_index as *const u32).cast(),
                        std::mem::size_of::<u32>() as libc::socklen_t,
                    )
                };
                if result != 0 {
                    return Err(std::io::Error::last_os_error().into());
                }
            }
            socket.set_nonblocking(true)?;
            if !udp {
                socket.set_tcp_nodelay(true)?;
            }
            if socket
                .bind(&SocketAddr::V4(SocketAddrV4::new(self.config.source_ip, port)).into())
                .is_err()
            {
                continue;
            }
            ports.busy.insert(port);
            return Ok((
                socket,
                Lease {
                    pool: self.clone(),
                    port,
                },
            ));
        }
        bail!("No usable source ports remain")
    }

    async fn tcp(self: &Arc<Self>, destination: SocketAddrV4) -> Result<(TcpStream, Lease)> {
        let (socket, lease) = self.socket(false)?;
        let stream: std::net::TcpStream = socket.into();
        let socket = TcpSocket::from_std_stream(stream);
        let stream = timeout(Duration::from_secs(10), socket.connect(destination.into())).await??;
        Ok((stream, lease))
    }

    async fn udp(self: &Arc<Self>, destination: SocketAddrV4) -> Result<(UdpSocket, Lease)> {
        let (socket, lease) = self.socket(true)?;
        let socket = UdpSocket::from_std(socket.into())?;
        socket.connect(destination).await?;
        Ok((socket, lease))
    }
}

fn public_ipv4(address: Ipv4Addr, test_loopback: bool) -> Result<Ipv4Addr> {
    if test_loopback && address.is_loopback() {
        return Ok(address);
    }
    let n = u32::from(address);
    let prohibited: &[(u32, u32)] = &[
        (0x00000000, 0xff000000),
        (0x0a000000, 0xff000000),
        (0x64400000, 0xffc00000),
        (0x7f000000, 0xff000000),
        (0xa9fe0000, 0xffff0000),
        (0xac100000, 0xfff00000),
        (0xc0000000, 0xffffff00),
        (0xc0000200, 0xffffff00),
        (0xc0586300, 0xffffff00),
        (0xc0a80000, 0xffff0000),
        (0xc6120000, 0xfffe0000),
        (0xc6336400, 0xffffff00),
        (0xcb007100, 0xffffff00),
        (0xe0000000, 0xf0000000),
        (0xf0000000, 0xf0000000),
    ];
    if prohibited.iter().any(|(base, mask)| n & mask == *base) {
        bail!("Only public IPv4 destinations are permitted");
    }
    Ok(address)
}

fn domain_name(raw: &[u8]) -> Result<String> {
    let name = std::str::from_utf8(raw)?
        .trim_end_matches('.')
        .to_ascii_lowercase();
    if name.is_empty()
        || name.len() > 253
        || !name.is_ascii()
        || name.split('.').any(|p| {
            p.is_empty()
                || p.len() > 63
                || !p
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        })
    {
        bail!("Invalid domain");
    }
    Ok(name)
}

#[derive(Debug, Clone)]
enum Host {
    Ip(Ipv4Addr),
    Domain(String),
}

async fn address(reader: &mut TcpStream, atyp: u8) -> Result<(Host, u16)> {
    let host = match atyp {
        1 => {
            let mut b = [0; 4];
            reader.read_exact(&mut b).await?;
            Host::Ip(b.into())
        }
        3 => {
            let len = reader.read_u8().await? as usize;
            let mut b = vec![0; len];
            reader.read_exact(&mut b).await?;
            Host::Domain(domain_name(&b)?)
        }
        _ => bail!("IPv4/domain address required"),
    };
    Ok((host, reader.read_u16().await?))
}

fn udp_decode(packet: &[u8]) -> Result<(Host, u16, &[u8])> {
    if packet.len() < 4 || packet[..3] != [0, 0, 0] {
        bail!("Malformed/fragmented UDP datagram");
    }
    let (host, offset) = match packet[3] {
        1 if packet.len() >= 10 => (
            Host::Ip(Ipv4Addr::new(packet[4], packet[5], packet[6], packet[7])),
            8,
        ),
        3 if packet.len() >= 5 && packet.len() >= 7 + packet[4] as usize => {
            let end = 5 + packet[4] as usize;
            (Host::Domain(domain_name(&packet[5..end])?), end)
        }
        _ => bail!("Malformed SOCKS UDP destination"),
    };
    let port = u16::from_be_bytes([packet[offset], packet[offset + 1]]);
    let payload = &packet[offset + 2..];
    if port == 0 || payload.len() > MAX_UDP_PAYLOAD {
        bail!("Invalid UDP port/payload");
    }
    Ok((host, port, payload))
}

fn udp_encode(address: SocketAddrV4, payload: &[u8]) -> Vec<u8> {
    let mut packet = Vec::with_capacity(payload.len() + 10);
    packet.extend_from_slice(&[0, 0, 0, 1]);
    packet.extend_from_slice(&address.ip().octets());
    packet.extend_from_slice(&address.port().to_be_bytes());
    packet.extend_from_slice(payload);
    packet
}

fn socks_reply(code: u8, address: SocketAddrV4) -> [u8; 10] {
    let mut reply = [5, code, 0, 1, 0, 0, 0, 0, 0, 0];
    reply[4..8].copy_from_slice(&address.ip().octets());
    reply[8..10].copy_from_slice(&address.port().to_be_bytes());
    reply
}

async fn bounded_line<R: AsyncBufRead + Unpin>(reader: &mut R, limit: usize) -> Result<Vec<u8>> {
    let mut result = Vec::new();
    loop {
        let data = reader.fill_buf().await?;
        if data.is_empty() {
            bail!("Unexpected HTTP EOF");
        }
        let count = data
            .iter()
            .position(|b| *b == b'\n')
            .map_or(data.len(), |n| n + 1);
        if result.len() + count > limit {
            bail!("HTTP line limit exceeded");
        }
        result.extend_from_slice(&data[..count]);
        reader.consume(count);
        if result.ends_with(b"\n") {
            if !result.ends_with(b"\r\n") {
                bail!("HTTP line must end in CRLF");
            }
            return Ok(result);
        }
    }
}

async fn http_body<R: AsyncRead + Unpin>(stream: R) -> Result<Vec<u8>> {
    let mut reader = BufReader::new(stream);
    let status = bounded_line(&mut reader, MAX_HEADERS).await?;
    let status_str = std::str::from_utf8(&status)?;
    if !(status_str.starts_with("HTTP/1.1 200 ") || status_str.starts_with("HTTP/1.0 200 ")) {
        bail!("DNS returned non-200 HTTP status");
    }
    let mut total = status.len();
    let mut headers: HashMap<String, Vec<String>> = HashMap::new();
    loop {
        let line = bounded_line(&mut reader, MAX_HEADERS.saturating_sub(total)).await?;
        total += line.len();
        if line == b"\r\n" {
            break;
        }
        let line = std::str::from_utf8(&line)?;
        let (key, value) = line
            .trim_end_matches("\r\n")
            .split_once(':')
            .context("Malformed HTTP header")?;
        if key.is_empty()
            || !key
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"!#$%&'*+.^_`|~-".contains(&b))
        {
            bail!("Malformed HTTP header name");
        }
        headers
            .entry(key.to_ascii_lowercase())
            .or_default()
            .push(value.trim().to_ascii_lowercase());
    }
    if let Some(enc) = headers.get("content-encoding") {
        if enc != &["identity"] {
            bail!("Unsupported HTTP content encoding");
        }
    }
    if let Some(transfer) = headers.get("transfer-encoding") {
        if transfer != &["chunked"] || headers.contains_key("content-length") {
            bail!("Ambiguous HTTP framing");
        }
        let mut body = Vec::new();
        loop {
            let line = bounded_line(&mut reader, 128).await?;
            let text = std::str::from_utf8(&line)?
                .trim_end_matches("\r\n")
                .split(';')
                .next()
                .unwrap();
            if text.is_empty() || !text.bytes().all(|b| b.is_ascii_hexdigit()) {
                bail!("Invalid HTTP chunk size");
            }
            let size = usize::from_str_radix(text, 16)?;
            if size == 0 {
                let mut total = 0;
                loop {
                    let trailer = bounded_line(&mut reader, MAX_HEADERS - total).await?;
                    total += trailer.len();
                    if trailer == b"\r\n" {
                        return Ok(body);
                    }
                }
            }
            if size > MAX_BODY - body.len() {
                bail!("DNS body too large");
            }
            let start = body.len();
            body.resize(start + size, 0);
            reader.read_exact(&mut body[start..]).await?;
            let mut crlf = [0; 2];
            reader.read_exact(&mut crlf).await?;
            if crlf != *b"\r\n" {
                bail!("Invalid HTTP chunk delimiter");
            }
        }
    }
    if let Some(lengths) = headers.get("content-length") {
        if lengths.iter().any(|s| s != &lengths[0])
            || !lengths[0].bytes().all(|b| b.is_ascii_digit())
        {
            bail!("Ambiguous HTTP length");
        }
        let size: usize = lengths[0].parse()?;
        if size > MAX_BODY {
            bail!("DNS body too large");
        }
        let mut body = vec![0; size];
        reader.read_exact(&mut body).await?;
        return Ok(body);
    }
    let mut body = Vec::new();
    reader
        .take((MAX_BODY + 1) as u64)
        .read_to_end(&mut body)
        .await?;
    if body.len() > MAX_BODY {
        bail!("DNS body too large");
    }
    Ok(body)
}

struct Resolver {
    pool: Arc<Pool>,
    cache: Mutex<HashMap<String, (Instant, Ipv4Addr)>>,
    slots: Semaphore,
    tls: TlsConnector,
}

impl Resolver {
    fn new(pool: Arc<Pool>) -> Self {
        let roots = rustls::RootCertStore {
            roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
        };
        let tls = rustls::ClientConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_root_certificates(roots)
        .with_no_client_auth();
        Self {
            pool,
            cache: Mutex::new(HashMap::new()),
            slots: Semaphore::new(8),
            tls: TlsConnector::from(Arc::new(tls)),
        }
    }

    async fn resolve(&self, host: Host) -> Result<Ipv4Addr> {
        let name = match host {
            Host::Ip(ip) => return public_ipv4(ip, self.pool.test_loopback),
            Host::Domain(name) => name,
        };
        if let Ok(ip) = name.parse() {
            return public_ipv4(ip, self.pool.test_loopback);
        }
        if let Some((until, ip)) = self.cache.lock().unwrap().get(&name) {
            if *until > Instant::now() {
                return Ok(*ip);
            }
        }
        timeout(Duration::from_secs(15), async {
            let _slot = self.slots.acquire().await?;
            let (stream, _lease) = self.pool.tcp(SocketAddrV4::new(Ipv4Addr::new(1, 1, 1, 1), 443)).await?;
            let server = rustls::pki_types::ServerName::try_from("cloudflare-dns.com")?;
            let mut tls = self.tls.connect(server, stream).await?;
            let request = format!("GET /dns-query?name={name}&type=A HTTP/1.1\r\nHost: cloudflare-dns.com\r\nAccept: application/dns-json\r\nConnection: close\r\n\r\n");
            tls.write_all(request.as_bytes()).await?;
            let body = http_body(tls).await?;
            #[derive(Deserialize)]
            struct Answer { #[serde(rename = "Status")] status: u32, #[serde(rename = "TC", default)] truncated: bool, #[serde(rename = "Answer", default)] answers: Vec<Record> }
            #[derive(Deserialize)]
            struct Record { #[serde(rename = "type")] kind: u32, data: String, #[serde(rename = "TTL", default)] ttl: u64 }
            let answer: Answer = serde_json::from_slice(&body)?;
            if answer.status != 0 || answer.truncated { bail!("DNS resolution failed"); }
            let record = answer.answers.iter().find(|r| r.kind == 1).context("DNS has no IPv4 answer")?;
            let ip = public_ipv4(record.data.parse()?, self.pool.test_loopback)?;
            let ttl = record.ttl.min(60);
            let mut cache = self.cache.lock().unwrap();
            if cache.len() >= 1024 { if let Some(key) = cache.keys().next().cloned() { cache.remove(&key); } }
            if ttl > 0 { cache.insert(name, (Instant::now() + Duration::from_secs(ttl), ip)); }
            Ok(ip)
        }).await?
    }
}

struct Peer {
    socket: Arc<UdpSocket>,
    _lease: Lease,
    receive: JoinHandle<()>,
    active: Instant,
}

impl Drop for Peer {
    fn drop(&mut self) {
        self.receive.abort();
    }
}

async fn udp_association(
    mut control: TcpStream,
    pool: Arc<Pool>,
    resolver: Arc<Resolver>,
    requested_port: u16,
) -> Result<()> {
    let udp = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).await?;
    let local = match udp.local_addr()? {
        SocketAddr::V4(a) => a,
        _ => unreachable!(),
    };
    control.write_all(&socks_reply(0, local)).await?;
    let mut client_port = requested_port;
    let mut peers: HashMap<SocketAddrV4, Peer> = HashMap::new();
    let (responses, mut received) = mpsc::channel::<(SocketAddrV4, Vec<u8>)>(128);
    let mut packet = vec![0; 65_536];
    let mut control_bytes = [0; 512];
    let mut sweep = tokio::time::interval(Duration::from_secs(5));
    loop {
        tokio::select! {
            read = control.read(&mut control_bytes) => { if read? == 0 { return Ok(()); } },
            datagram = udp.recv_from(&mut packet) => {
                let (len, sender) = datagram?;
                if sender.ip() != IpAddr::V4(Ipv4Addr::LOCALHOST) || (client_port != 0 && sender.port() != client_port) { continue; }
                let Ok((host, port, data)) = udp_decode(&packet[..len]) else { continue; };
                if client_port == 0 { client_port = sender.port(); }
                // A stalled DNS query must not extend a UDP association beyond
                // the lifetime of its TCP control connection.
                let ip = tokio::select! {
                    resolved = resolver.resolve(host) => { let Ok(ip) = resolved else { continue; }; ip },
                    read = control.read(&mut control_bytes) => { if read? == 0 { return Ok(()); } else { continue; } },
                };
                let target = SocketAddrV4::new(ip, port);
                if !peers.contains_key(&target) {
                    if peers.len() >= MAX_PEERS { continue; }
                    let Ok((socket, lease)) = pool.udp(target).await else { continue; };
                    let socket = Arc::new(socket);
                    let incoming = socket.clone(); let responses = responses.clone();
                    let receive = tokio::spawn(async move {
                        let mut data = vec![0; 65_536];
                        while let Ok(len) = incoming.recv(&mut data).await {
                            if len <= MAX_UDP_PAYLOAD && responses.send((target, data[..len].to_vec())).await.is_err() { break; }
                        }
                    });
                    peers.insert(target, Peer { socket, _lease: lease, receive, active: Instant::now() });
                }
                let peer = peers.get_mut(&target).unwrap();
                peer.active = Instant::now();
                let _ = peer.socket.send(data).await;
            },
            Some((target, payload)) = received.recv() => {
                if let Some(peer) = peers.get_mut(&target) {
                    peer.active = Instant::now();
                    let _ = udp.send_to(&udp_encode(target, &payload), (Ipv4Addr::LOCALHOST, client_port)).await;
                }
            },
            _ = sweep.tick() => { peers.retain(|_, peer| peer.active.elapsed() < UDP_IDLE && !peer.receive.is_finished()); },
        }
    }
}

async fn handle(mut client: TcpStream, pool: Arc<Pool>, resolver: Arc<Resolver>) -> Result<()> {
    let request = timeout(Duration::from_secs(10), async {
        let version = client.read_u8().await?;
        let count = client.read_u8().await? as usize;
        let mut methods = vec![0; count];
        client.read_exact(&mut methods).await?;
        if version != 5 || !methods.contains(&0) {
            client.write_all(&[5, 255]).await?;
            return Ok(None);
        }
        client.write_all(&[5, 0]).await?;
        let mut header = [0; 4];
        client.read_exact(&mut header).await?;
        if header[0] != 5 || header[2] != 0 {
            bail!("Invalid SOCKS request");
        }
        if !matches!(header[3], 1 | 3) {
            client
                .write_all(&socks_reply(8, SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0)))
                .await?;
            return Ok(None);
        }
        let (host, port) = address(&mut client, header[3]).await?;
        Ok::<_, anyhow::Error>(Some((header[1], host, port)))
    })
    .await;
    let (command, host, port) = match request {
        Ok(Ok(Some(request))) => request,
        Ok(Ok(None)) => return Ok(()),
        _ => {
            let _ = client
                .write_all(&socks_reply(1, SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0)))
                .await;
            return Ok(());
        }
    };
    match command {
        1 if port != 0 => {
            let remote = async {
                let address = resolver.resolve(host).await?;
                pool.tcp(SocketAddrV4::new(address, port)).await
            }
            .await;
            match remote {
                Ok((mut stream, _lease)) => {
                    let local = match stream.local_addr()? {
                        SocketAddr::V4(a) => a,
                        _ => unreachable!(),
                    };
                    client.write_all(&socks_reply(0, local)).await?;
                    tokio::io::copy_bidirectional(&mut client, &mut stream).await?;
                }
                Err(_) => {
                    client
                        .write_all(&socks_reply(4, SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0)))
                        .await?;
                }
            }
        }
        3 if matches!(host, Host::Ip(ip) if ip.is_unspecified() || ip.is_loopback() && ip == Ipv4Addr::LOCALHOST) =>
        {
            udp_association(client, pool, resolver, port).await?;
        }
        _ => {
            let code = if command == 3 {
                2
            } else if command == 1 {
                1
            } else {
                7
            };
            client
                .write_all(&socks_reply(
                    code,
                    SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0),
                ))
                .await?;
        }
    }
    Ok(())
}

/// Serve until shutdown becomes true or its sender disappears. Accepted TCP and
/// UDP associations are owned by a JoinSet and are cancelled on exit.
pub async fn serve(config: Config, shutdown: watch::Receiver<bool>) -> Result<()> {
    let pool = Pool::new(config, false)?;
    serve_pool(pool, shutdown).await
}

async fn serve_pool(pool: Arc<Pool>, shutdown: watch::Receiver<bool>) -> Result<()> {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, pool.config.listen_port)).await?;
    serve_listener(pool, shutdown, listener).await
}

async fn serve_listener(
    pool: Arc<Pool>,
    mut shutdown: watch::Receiver<bool>,
    listener: TcpListener,
) -> Result<()> {
    let resolver = Arc::new(Resolver::new(pool.clone()));
    let limit = Arc::new(Semaphore::new(256));
    let mut clients = JoinSet::new();
    loop {
        if *shutdown.borrow() {
            break;
        }
        tokio::select! {
            changed = shutdown.changed() => { if changed.is_err() || *shutdown.borrow() { break; } },
            accepted = listener.accept() => {
                let (client, address) = accepted?;
                if !address.ip().is_loopback() { continue; }
                let Ok(permit) = limit.clone().try_acquire_owned() else { continue; };
                let pool = pool.clone(); let resolver = resolver.clone();
                clients.spawn(async move { let _permit = permit; let _ = handle(client, pool, resolver).await; });
            },
            Some(_) = clients.join_next(), if !clients.is_empty() => {},
        }
    }
    drop(listener);
    clients.abort_all();
    while clients.join_next().await.is_some() {}
    Ok(())
}

#[cfg(test)]
mod tests;
