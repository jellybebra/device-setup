//! Shorten the player's first silent request to a regional YouTube cache.
//! The browser owns the fallback URL. Never replay a request or terminate TLS.
use super::Host;
use socket2::SockRef;
use std::{
    collections::HashMap,
    future::Future,
    io,
    pin::Pin,
    sync::Mutex,
    task::{Context, Poll},
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncWrite, ReadBuf},
    net::TcpStream,
    time::{Instant, Sleep},
};
use tokio_rustls::rustls::server::Acceptor;

const STARTUP: Duration = Duration::from_secs(8);
const SILENCE: Duration = Duration::from_millis(1200);
const STREAMING: usize = 16 * 1024;

fn regional(name: &str) -> bool {
    let Some((rr, group)) = name.split_once("---sn-") else {
        return false;
    };
    rr.strip_prefix("rr")
        .is_some_and(|n| !n.is_empty() && n.len() <= 2 && n.bytes().all(|c| c.is_ascii_digit()))
        && matches!(
            group,
            "gvnuxaxjvh-3gg6.googlevideo.com"
                | "gvnuxaxjvh-3ggl.googlevideo.com"
                | "gvnuxaxjvh-3ggz.googlevideo.com"
                | "hxb54vo-3gg6.googlevideo.com"
        )
}

pub(super) fn candidate(host: &Host) -> bool {
    match host {
        Host::Domain(name) => regional(name) || name.parse::<std::net::Ipv4Addr>().is_ok(),
        Host::Ip(_) => true,
    }
}

#[derive(Default)]
pub(super) struct Retries(Mutex<HashMap<String, Instant>>);
impl Retries {
    fn allow(&self, name: &str, now: Instant) -> bool {
        let mut recent = self.0.lock().unwrap();
        recent.retain(|_, expiry| *expiry > now);
        if recent.contains_key(name) {
            return false;
        }
        recent.insert(name.to_owned(), now + STARTUP);
        true
    }
}

// Inspect record lengths across partial TCP writes. No payload is retained.
#[derive(Default)]
struct Records {
    header: [u8; 5],
    used: usize,
    remaining: usize,
}
impl Records {
    fn written(&mut self, mut data: &[u8]) -> bool {
        let mut request = false;
        while !data.is_empty() {
            if self.used < 5 {
                let n = (5 - self.used).min(data.len());
                self.header[self.used..self.used + n].copy_from_slice(&data[..n]);
                self.used += n;
                data = &data[n..];
                if self.used < 5 {
                    break;
                }
                self.remaining = u16::from_be_bytes([self.header[3], self.header[4]]) as usize;
            }
            let n = self.remaining.min(data.len());
            data = &data[n..];
            self.remaining -= n;
            if self.remaining == 0 {
                request |= self.header[0] == 23
                    && self.header[1] == 3
                    && u16::from_be_bytes([self.header[3], self.header[4]]) >= 300;
                self.used = 0;
            }
        }
        request
    }
}

struct Startup<'a> {
    remote: &'a mut TcpStream,
    retries: &'a Retries,
    until: Instant,
    name: Option<String>,
    hello: Option<Acceptor>,
    inspected: usize,
    records: Records,
    heard_server: bool,
    response_bytes: Option<usize>,
    alarm: Option<Pin<Box<Sleep>>>,
    aborted: bool,
}

impl Startup<'_> {
    fn done(&mut self) {
        self.name = None;
        self.hello = None;
        self.alarm = None;
    }
    fn written(&mut self, data: &[u8], cx: &Context<'_>) {
        if self.name.is_none() && self.hello.is_none() {
            return;
        }
        if Instant::now() >= self.until {
            self.done();
            return;
        }
        if let Some(parser) = self.hello.as_mut() {
            self.inspected += data.len();
            if self.inspected > 65536 {
                self.done();
                return;
            }
            let mut input = data;
            while !input.is_empty() {
                if !matches!(parser.read_tls(&mut input),Ok(n) if n>0) {
                    self.done();
                    return;
                }
                match parser.accept() {
                    Ok(Some(hello)) => {
                        self.name = hello
                            .client_hello()
                            .server_name()
                            .filter(|s| regional(s))
                            .map(str::to_owned);
                        self.hello = None;
                        break;
                    }
                    Ok(None) => {}
                    Err(_) => {
                        self.done();
                        return;
                    }
                }
            }
        }
        let request = self.records.written(data);
        if request && self.name.is_some() && self.heard_server && self.alarm.is_none() {
            let deadline = Instant::now() + SILENCE;
            if deadline >= self.until {
                self.done();
                return;
            }
            self.response_bytes.get_or_insert(0);
            self.alarm = Some(Box::pin(tokio::time::sleep_until(deadline)));
            cx.waker().wake_by_ref();
        }
    }
}

impl AsyncRead for Startup<'_> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let before = buf.filled().len();
        let result = Pin::new(&mut *self.remote).poll_read(cx, buf);
        if let Poll::Ready(Ok(())) = result {
            self.heard_server = true;
            self.alarm = None;
            if let Some(bytes) = self.response_bytes.as_mut() {
                *bytes = bytes.saturating_add(buf.filled().len() - before);
                if *bytes >= STREAMING {
                    self.done();
                    self.response_bytes = None;
                }
            }
        } else if result.is_pending()
            && self
                .alarm
                .as_mut()
                .is_some_and(|alarm| alarm.as_mut().poll(cx).is_ready())
        {
            let now = Instant::now();
            self.aborted = now < self.until
                && self
                    .name
                    .as_deref()
                    .is_some_and(|n| self.retries.allow(n, now));
            if self.aborted {
                eprintln!(
                    "YouTube startup retry: {}",
                    self.name.as_deref().unwrap_or_default()
                );
            }
            self.done();
            if self.aborted {
                return Poll::Ready(Err(io::ErrorKind::TimedOut.into()));
            }
        }
        result
    }
}
impl AsyncWrite for Startup<'_> {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        let result = Pin::new(&mut *self.remote).poll_write(cx, buf);
        if let Poll::Ready(Ok(n)) = result {
            self.written(&buf[..n], cx);
        }
        result
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut *self.remote).poll_flush(cx)
    }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut *self.remote).poll_shutdown(cx)
    }
}

pub(super) async fn relay(
    client: &mut TcpStream,
    remote: &mut TcpStream,
    host: &Host,
    retries: &Retries,
) -> io::Result<()> {
    let name = match host {
        Host::Domain(n) if regional(n) => Some(n.clone()),
        _ => None,
    };
    let mut startup = Startup {
        remote,
        retries,
        until: Instant::now() + STARTUP,
        hello: name.is_none().then(Acceptor::default),
        name,
        inspected: 0,
        records: Default::default(),
        heard_server: false,
        response_bytes: None,
        alarm: None,
        aborted: false,
    };
    let result = tokio::io::copy_bidirectional(client, &mut startup).await;
    if startup.aborted {
        SockRef::from(&*startup.remote).set_linger(Some(Duration::ZERO))?;
        SockRef::from(&*client).set_linger(Some(Duration::ZERO))?;
    }
    result.map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::TcpListener,
    };
    const EDGE: &str = "rr2---sn-gvnuxaxjvh-3gg6.googlevideo.com";

    #[test]
    fn matches_only_tested_cache_groups() {
        assert!(regional(EDGE));
        for name in [
            "www.youtube.com",
            "rr4---sn-f5fz7n7s.googlevideo.com",
            "rr2---sn-gvnuxaxjvh-3gg6.googlevideo.com.example.com",
            "rr---sn-gvnuxaxjvh-3gg6.googlevideo.com",
        ] {
            assert!(!regional(name));
        }
        let mut records = Records::default();
        assert!(!records.written(&[23, 3]));
        assert!(!records.written(&[3, 1, 44]));
        assert!(!records.written(&[0; 299]));
        assert!(records.written(&[0]));
    }

    async fn sockets() -> (TcpStream, TcpStream) {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let (out, inc) = tokio::join!(
            TcpStream::connect(listener.local_addr().unwrap()),
            listener.accept()
        );
        (out.unwrap(), inc.unwrap().0)
    }

    fn hello(name: &str) -> Vec<u8> {
        use tokio_rustls::rustls::{self, ClientConnection};
        let config = rustls::ClientConfig::builder_with_provider(std::sync::Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_root_certificates(rustls::RootCertStore::empty())
        .with_no_client_auth();
        let mut client =
            ClientConnection::new(config.into(), name.to_owned().try_into().unwrap()).unwrap();
        let mut bytes = Vec::new();
        client.write_tls(&mut bytes).unwrap();
        bytes
    }

    // Exercise the actual TCP relay on random loopback ports, including IP-only
    // SOCKS requests, a fragmented ClientHello, the retry and a streaming flow.
    #[tokio::test]
    async fn startup_only_resets_the_first_silent_edge_request() {
        let retries = Retries::default();
        for (name, streaming, expect_reset) in [
            (EDGE, false, true),
            (EDGE, false, false),
            ("rr5---sn-gvnuxaxjvh-3ggz.googlevideo.com", true, false),
            ("rr4---sn-f5fz7n7s.googlevideo.com", false, false),
        ] {
            let (mut browser, mut client) = sockets().await;
            let (mut remote, mut edge) = sockets().await;
            let host = Host::Ip(std::net::Ipv4Addr::LOCALHOST);
            let forward = relay(&mut client, &mut remote, &host, &retries);
            let exchange = async {
                let wire = hello(name);
                for part in wire.chunks(7) {
                    browser.write_all(part).await.unwrap();
                }
                let mut copy = vec![0; wire.len()];
                edge.read_exact(&mut copy).await.unwrap();
                assert_eq!(copy, wire);
                edge.write_u8(1).await.unwrap();
                assert_eq!(browser.read_u8().await.unwrap(), 1);
                let mut request = vec![0; 325];
                request[..5].copy_from_slice(&[23, 3, 3, 1, 64]);
                browser.write_all(&request).await.unwrap();
                edge.read_exact(&mut vec![0; 325]).await.unwrap();
                if streaming {
                    edge.write_all(&vec![1; STREAMING]).await.unwrap();
                    browser.read_exact(&mut vec![0; STREAMING]).await.unwrap();
                    browser.write_all(&request).await.unwrap();
                    edge.read_exact(&mut vec![0; 325]).await.unwrap();
                }
                tokio::time::sleep(SILENCE + Duration::from_millis(150)).await;
                if !expect_reset {
                    edge.write_u8(2).await.unwrap();
                    assert_eq!(browser.read_u8().await.unwrap(), 2);
                }
                drop(edge);
                drop(browser);
            };
            let (result, ()) = tokio::time::timeout(Duration::from_secs(4), async {
                tokio::join!(forward, exchange)
            })
            .await
            .unwrap();
            if expect_reset {
                assert_eq!(result.unwrap_err().kind(), io::ErrorKind::TimedOut)
            } else {
                result.unwrap()
            }
        }
    }
}
