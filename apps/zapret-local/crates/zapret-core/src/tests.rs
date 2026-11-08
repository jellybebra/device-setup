use super::*;

#[tokio::test]
async fn unreachable_dns_answer_is_evicted_and_releases_source_port() {
    let pool = test_pool();
    let resolver = Resolver::new(pool.clone());
    let host = Host::Domain("unreachable.example".into());
    resolver.cache.lock().unwrap().insert(
        "unreachable.example".into(),
        (
            Instant::now() + Duration::from_secs(60),
            Ipv4Addr::LOCALHOST,
        ),
    );
    assert!(resolver.connect(host, free_port(), false).await.is_err());
    assert!(!resolver
        .cache
        .lock()
        .unwrap()
        .contains_key("unreachable.example"));
    assert!(pool.ports.lock().unwrap().busy.is_empty());
}

#[tokio::test]
async fn reachable_dns_answer_remains_cached() {
    let resolver = Resolver::new(test_pool());
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
    resolver.cache.lock().unwrap().insert(
        "reachable.example".into(),
        (
            Instant::now() + Duration::from_secs(60),
            Ipv4Addr::LOCALHOST,
        ),
    );
    let connection = resolver
        .connect(
            Host::Domain("reachable.example".into()),
            listener.local_addr().unwrap().port(),
            false,
        )
        .await
        .unwrap();
    assert!(resolver
        .cache
        .lock()
        .unwrap()
        .contains_key("reachable.example"));
    drop(connection);
}

#[test]
fn failed_connection_does_not_evict_a_newer_dns_address() {
    let resolver = Resolver::new(test_pool());
    let newer = Ipv4Addr::new(104, 21, 77, 110);
    resolver.cache.lock().unwrap().insert(
        "cdn.example".into(),
        (Instant::now() + Duration::from_secs(60), newer),
    );
    resolver.discard_failed_address(
        &Host::Domain("cdn.example".into()),
        Ipv4Addr::new(188, 114, 96, 3),
    );
    assert_eq!(resolver.cache.lock().unwrap()["cdn.example"].1, newer);
}

#[test]
fn cdn_resolution_preserves_unrelated_names_and_meta_fallback() {
    for alternate in [false, true] {
        for name in ["abs.twimg.com", "pbs.twimg.com"] {
            assert_eq!(
                dns_query_name(name, alternate),
                "twimg.twitter.map.fastly.net"
            );
        }
        assert_eq!(
            dns_query_name("video.twimg.com", alternate),
            "dualstack.video.twitter.map.fastly.net"
        );
        for name in [
            "x.com",
            "api.x.com",
            "twimg.com",
            "abs.twimg.com.example.org",
            "other.twimg.com",
        ] {
            assert_eq!(dns_query_name(name, alternate), name);
        }
    }
    assert_eq!(
        dns_query_name("scontent-arn2-1.cdninstagram.com", false),
        "scontent-arn2-1.cdninstagram.com"
    );
    assert_eq!(
        dns_query_name("scontent-arn2-1.cdninstagram.com", true),
        "scontent.cdninstagram.com"
    );
}

#[test]
fn media_fallback_is_limited_to_regional_meta_edges() {
    assert_eq!(
        media_fallback_name("scontent-arn2-1.cdninstagram.com"),
        "scontent.cdninstagram.com"
    );
    assert_eq!(
        media_fallback_name("scontent-hel3-1.xx.fbcdn.net"),
        "scontent.xx.fbcdn.net"
    );
    assert_eq!(
        media_fallback_name("video-hel3-1.xx.fbcdn.net"),
        "scontent.xx.fbcdn.net"
    );
    for name in [
        "scontent.cdninstagram.com",
        "pbs.twimg.com",
        "example.com",
        "scontent-a.cdninstagram.com.example.com",
        "scontent-a.foo.cdninstagram.com",
    ] {
        assert_eq!(media_fallback_name(name), name);
    }
}

fn free_port() -> u16 {
    std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

fn test_pool() -> Arc<Pool> {
    let start = loop {
        let candidate = free_port();
        if candidate > 65_000 {
            continue;
        }
        let mut tcp = Vec::new();
        let mut udp = Vec::new();
        let mut free = true;
        for port in candidate..candidate + 64 {
            let Ok(t) = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, port)) else {
                free = false;
                break;
            };
            let Ok(u) = std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, port)) else {
                free = false;
                break;
            };
            tcp.push(t);
            udp.push(u);
        }
        if free {
            break candidate;
        }
    };
    Pool::new(
        Config {
            interface: "test-only".into(),
            source_ip: Ipv4Addr::LOCALHOST,
            listen_port: free_port(),
            port_start: start,
            port_end: start + 63,
        },
        true,
    )
    .unwrap()
}

async fn start(pool: Arc<Pool>) -> (watch::Sender<bool>, JoinHandle<Result<()>>, u16) {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (stop, rx) = watch::channel(false);
    let task = tokio::spawn(serve_listener(pool, rx, listener));
    (stop, task, port)
}

async fn request(port: u16, command: u8, destination: SocketAddrV4) -> (TcpStream, [u8; 10]) {
    let mut client = TcpStream::connect((Ipv4Addr::LOCALHOST, port))
        .await
        .unwrap();
    client.write_all(&[5, 1, 0]).await.unwrap();
    let mut auth = [0; 2];
    client.read_exact(&mut auth).await.unwrap();
    assert_eq!(auth, [5, 0]);
    let mut packet = vec![5, command, 0, 1];
    packet.extend_from_slice(&destination.ip().octets());
    packet.extend_from_slice(&destination.port().to_be_bytes());
    client.write_all(&packet).await.unwrap();
    let mut reply = [0; 10];
    client.read_exact(&mut reply).await.unwrap();
    (client, reply)
}

#[tokio::test]
async fn tcp_relay_large_payload_half_close_and_shutdown() {
    let echo = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
    let echo_addr = match echo.local_addr().unwrap() {
        SocketAddr::V4(a) => a,
        _ => unreachable!(),
    };
    let echo_task = tokio::spawn(async move {
        let (mut socket, peer) = echo.accept().await.unwrap();
        let (mut r, mut w) = socket.split();
        tokio::io::copy(&mut r, &mut w).await.unwrap();
        peer.port()
    });
    let pool = test_pool();
    let (stop, server, port) = start(pool.clone()).await;
    let (client, reply) = request(port, 1, echo_addr).await;
    assert_eq!(reply[1], 0);
    let (mut read, mut write) = client.into_split();
    let payload = vec![0x6b; 1_048_576];
    let output = timeout(Duration::from_secs(5), async {
        let writing = async {
            write.write_all(&payload).await.unwrap();
            write.shutdown().await.unwrap();
        };
        let reading = async {
            let mut received = Vec::new();
            read.read_to_end(&mut received).await.unwrap();
            received
        };
        let (_, received) = tokio::join!(writing, reading);
        received
    })
    .await
    .unwrap();
    assert_eq!(output, payload);
    let source_port = echo_task.await.unwrap();
    assert!((pool.config.port_start..=pool.config.port_end).contains(&source_port));
    stop.send(true).unwrap();
    server.await.unwrap().unwrap();
    assert!(pool.ports.lock().unwrap().busy.is_empty());
    assert!(TcpStream::connect((Ipv4Addr::LOCALHOST, port))
        .await
        .is_err());
}

#[tokio::test]
async fn udp_association_pins_sender_and_closes_with_tcp_control() {
    let echo = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
    let target = match echo.local_addr().unwrap() {
        SocketAddr::V4(a) => a,
        _ => unreachable!(),
    };
    let echo_task = tokio::spawn(async move {
        let mut buffer = [0; 4096];
        loop {
            let (n, source) = echo.recv_from(&mut buffer).await.unwrap();
            echo.send_to(&buffer[..n], source).await.unwrap();
        }
    });
    let pool = test_pool();
    let (stop, server, port) = start(pool.clone()).await;
    let (control, reply) = request(port, 3, SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0)).await;
    assert_eq!(reply[1], 0);
    let relay = SocketAddrV4::new(
        Ipv4Addr::new(reply[4], reply[5], reply[6], reply[7]),
        u16::from_be_bytes([reply[8], reply[9]]),
    );
    let client = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
    let stranger = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
    let packet = udp_encode(target, b"voice-test\0bytes");
    let mut fragmented = packet.clone();
    fragmented[2] = 1;
    stranger.send_to(&fragmented, relay).await.unwrap();
    client.send_to(&packet, relay).await.unwrap();
    let mut received = [0; 4096];
    let (len, _) = timeout(Duration::from_secs(2), client.recv_from(&mut received))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(&received[..len], packet);
    stranger.send_to(&packet, relay).await.unwrap();
    assert!(timeout(
        Duration::from_millis(100),
        stranger.recv_from(&mut received)
    )
    .await
    .is_err());
    drop(control);
    for _ in 0..50 {
        if pool.ports.lock().unwrap().busy.is_empty() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(pool.ports.lock().unwrap().busy.is_empty());
    client.send_to(&packet, relay).await.unwrap();
    assert!(
        timeout(Duration::from_millis(100), client.recv_from(&mut received))
            .await
            .is_err()
    );
    stop.send(true).unwrap();
    server.await.unwrap().unwrap();
    echo_task.abort();
}

#[tokio::test]
async fn stop_cancels_idle_udp_control_and_releases_all_leases() {
    let pool = test_pool();
    let (stop, server, port) = start(pool.clone()).await;
    let (mut control, reply) = request(port, 3, SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0)).await;
    assert_eq!(reply[1], 0);
    stop.send(true).unwrap();
    timeout(Duration::from_secs(2), server)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(control.read(&mut [0; 1]).await.unwrap(), 0);
    assert!(pool.ports.lock().unwrap().busy.is_empty());
}

#[tokio::test]
async fn denied_private_destination_does_not_allocate_egress_socket() {
    let pool = test_pool();
    let (stop, server, port) = start(pool.clone()).await;
    let (_client, reply) =
        request(port, 1, SocketAddrV4::new(Ipv4Addr::new(10, 1, 2, 3), 80)).await;
    assert_eq!(reply[1], 4);
    assert!(pool.ports.lock().unwrap().busy.is_empty());
    stop.send(true).unwrap();
    server.await.unwrap().unwrap();
}

#[tokio::test]
async fn unsupported_auth_is_rejected_without_a_second_response() {
    let pool = test_pool();
    let (stop, server, port) = start(pool.clone()).await;
    let mut client = TcpStream::connect((Ipv4Addr::LOCALHOST, port))
        .await
        .unwrap();
    client.write_all(&[5, 1, 2]).await.unwrap();
    let mut bytes = Vec::new();
    timeout(Duration::from_secs(2), client.read_to_end(&mut bytes))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(bytes, [5, 255]);
    assert!(pool.ports.lock().unwrap().busy.is_empty());
    stop.send(true).unwrap();
    server.await.unwrap().unwrap();
}

#[test]
fn source_port_pool_is_shared_across_tcp_and_udp() {
    let mut config = test_pool().config.clone();
    config.port_end = config.port_start;
    let pool = Pool::new(config, true).unwrap();
    let (socket, lease) = pool.socket(false).unwrap();
    assert!(pool.socket(true).is_err());
    drop(socket);
    drop(lease);
    let (_socket, _lease) = pool.socket(true).unwrap();
}

#[test]
fn destination_and_udp_frame_validation() {
    for s in [
        "0.0.0.0",
        "10.2.3.4",
        "127.0.0.1",
        "100.64.0.1",
        "169.254.1.2",
        "172.16.3.4",
        "192.168.1.1",
        "192.0.2.1",
        "198.18.0.1",
        "198.51.100.1",
        "203.0.113.1",
        "224.0.0.1",
        "255.255.255.255",
    ] {
        assert!(public_ipv4(s.parse().unwrap(), false).is_err(), "{s}");
    }
    assert!(public_ipv4("1.1.1.1".parse().unwrap(), false).is_ok());
    let address = SocketAddrV4::new(Ipv4Addr::new(1, 1, 1, 1), 3478);
    let frame = udp_encode(address, b"hello");
    let (host, port, data) = udp_decode(&frame).unwrap();
    assert!(matches!(host,Host::Ip(ip) if ip==*address.ip()));
    assert_eq!(port, 3478);
    assert_eq!(data, b"hello");
    for packet in [
        vec![],
        vec![0, 0, 1, 1],
        vec![0, 0, 0, 4],
        vec![0, 0, 0, 3, 255],
    ] {
        assert!(udp_decode(&packet).is_err());
    }
    assert!(domain_name(b"a&name=evil.com").is_err());
    assert!(domain_name(b"a..com").is_err());
    assert_eq!(domain_name(b"WWW.Example.COM.").unwrap(), "www.example.com");
}

#[tokio::test]
async fn bounded_http_framing() {
    for bytes in [
        b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".as_slice(),
        b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n",
        b"HTTP/1.0 200 OK\r\n\r\n{}",
    ] {
        assert_eq!(http_body(bytes).await.unwrap(), b"{}");
    }
    for bytes in [
        b"HTTP/1.1 302 Found\r\nContent-Length: 0\r\n\r\n".as_slice(),
        b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n{}",
        b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 2\r\n\r\n{}",
        b"HTTP/1.1 200 OK\r\nContent-Length: 999999\r\n\r\n",
        b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n10001\r\n",
    ] {
        assert!(http_body(bytes).await.is_err());
    }
    let giant = [
        b"HTTP/1.1 200 OK\r\nHeader: ".as_slice(),
        &vec![b'x'; MAX_HEADERS + 1],
        b"\r\n\r\n",
    ]
    .concat();
    assert!(http_body(giant.as_slice()).await.is_err());
}
