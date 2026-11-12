//! Generate the privileged runtime configuration from a narrow, data-only VLESS import.
mod readiness;
use super::*;
use serde_json::{json, Value};
use std::os::unix::process::CommandExt;

const CLOUDFLARE: &str = include_str!("../../../../../configs/cudy-tr3000/cloudflare-ipv4.txt");
const CLOUDFRONT: &str = include_str!("../../../resources/cloudfront-ipv4.txt");
pub(super) const MEDIA: &[&str] = &[
    "youtube.com",
    "youtu.be",
    "youtube-nocookie.com",
    "ggpht.com",
    "googlevideo.com",
    "ytimg.com",
    "youtubei.googleapis.com",
    "youtube.googleapis.com",
    "yt3.googleusercontent.com",
    "x.com",
    "twitter.com",
    "t.co",
    "twimg.com",
    "pscp.tv",
    "periscope.tv",
    "discord.com",
    "discord.gg",
    "discordapp.com",
    "discordapp.net",
    "discord.media",
    "discordcdn.com",
    "discordstatus.com",
    "discord.gift",
    "discord.new",
];
pub(super) const META: &[&str] = &[
    "instagram.com",
    "cdninstagram.com",
    "facebook.com",
    "fbcdn.net",
    "fbsbx.com",
    "ig.me",
];
const VPN: &[&str] = &[
    "telegram.org",
    "t.me",
    "telegram.me",
    "telegram.dog",
    "tdesktop.com",
    "telegra.ph",
    "telesco.pe",
    "telegram-cdn.org",
    "telegramdownload.com",
    "openai.com",
    "chatgpt.com",
    "oaistatic.com",
    "oaiusercontent.com",
    "auth0.com",
    "anthropic.com",
    "claude.ai",
    "cdn.openaimerge.com",
    "notion.com",
    "notion.so",
    "notion.site",
    "notionusercontent.com",
    "notion-static.com",
];
const TELEGRAM: &[&str] = &[
    "91.108.56.0/22",
    "91.108.4.0/22",
    "91.108.8.0/22",
    "91.108.16.0/22",
    "91.108.12.0/22",
    "149.154.160.0/20",
    "91.105.192.0/23",
    "91.108.20.0/22",
    "185.76.151.0/24",
];
pub(crate) const VERCEL: &str="64.29.17.0/24,64.239.109.0/24,64.239.123.0/24,66.33.60.0/24,76.76.21.0/24,143.13.0.0/16,155.121.0.0/16,198.169.1.0/24,198.169.2.0/24,216.150.1.0/24,216.150.16.0/24,216.198.79.0/24,216.230.84.0/24,216.230.86.0/24,76.223.126.88/32";

#[derive(Deserialize, Serialize)]
pub(crate) struct Node {
    host: String,
    port: u16,
    id: String,
    encryption: String,
    security: String,
    server_name: String,
    fingerprint: String,
    public_key: String,
    short_id: String,
    spider: String,
    alpn: Vec<String>,
    mldsa: String,
    ech_config: String,
    flow: String,
    #[serde(default)]
    fast_connect_retry: bool,
}

impl Node {
    fn text(v: &Value, k: &str) -> String {
        v[k].as_str().unwrap_or_default().to_owned()
    }
    pub fn import(o: &Value) -> Result<Self> {
        ensure!(o["protocol"] == "vless", "Нужен исходящий профиль VLESS");
        let stream = &o["streamSettings"];
        ensure!(
            matches!(stream["network"].as_str(), Some("raw" | "tcp")),
            "Поддерживается VLESS поверх TCP"
        );
        let security = Self::text(stream, "security");
        ensure!(
            matches!(security.as_str(), "tls" | "reality"),
            "Нужен VLESS с TLS или REALITY"
        );
        let tls = &stream[if security == "tls" {
            "tlsSettings"
        } else {
            "realitySettings"
        }];
        ensure!(
            tls["allowInsecure"] != true
                && tls.get("certificates").is_none()
                && tls.get("pinnedPeerCertSha256").is_none(),
            "Неподдерживаемые параметры проверки TLS"
        );
        let settings = &o["settings"];
        let (server, user) = if let Some(servers) = settings["vnext"].as_array() {
            ensure!(servers.len() == 1, "Нужен один узел VLESS");
            (&servers[0], &servers[0]["users"][0])
        } else {
            (settings, settings)
        };
        let host = Self::text(server, "address");
        ensure!(
            !host.is_empty()
                && host.len() <= 253
                && host
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-'),
            "Некорректный IPv4 адрес или имя VLESS"
        );
        let id = Self::text(user, "id");
        ensure!(!id.is_empty() && id.len() <= 128, "Неверный ID узла");
        let flow = match user["flow"].as_str().unwrap_or_default() {
            "xtls-rprx-vision" | "xtls-rprx-vision-udp443" => "xtls-rprx-vision-udp443",
            "" => "",
            _ => bail!("Неизвестный VLESS flow"),
        }
        .to_owned();
        let server_name = tls["serverName"]
            .as_str()
            .filter(|s| !s.is_empty())
            .unwrap_or(&host)
            .to_owned();
        let alpn = serde_json::from_value(tls.get("alpn").cloned().unwrap_or(json!([])))?;
        let port = u16::try_from(server["port"].as_u64().context("Неверный порт узла")?)?;
        ensure!(port != 0, "Неверный порт узла");
        let public_key = tls["publicKey"]
            .as_str()
            .or(tls["password"].as_str())
            .unwrap_or_default()
            .to_owned();
        ensure!(
            security != "reality" || !public_key.is_empty(),
            "Нет публичного ключа REALITY"
        );
        let ech_config = Self::text(tls, "echConfigList");
        ensure!(
            ech_config.len() <= 4096
                && ech_config
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"+/=".contains(&b)),
            "Поддерживаются только встроенные конфигурации ECH"
        );
        Ok(Self {
            host,
            port,
            id,
            encryption: user["encryption"].as_str().unwrap_or("none").to_owned(),
            security,
            server_name,
            fingerprint: Self::text(tls, "fingerprint"),
            public_key,
            short_id: Self::text(tls, "shortId"),
            spider: Self::text(tls, "spiderX"),
            alpn,
            mldsa: Self::text(tls, "mldsa65Verify"),
            ech_config,
            flow,
            fast_connect_retry: o["fastConnectRetry"].as_bool().unwrap_or(false),
        })
    }
    fn xray(&self, ip: Ipv4Addr, port: u16, interface: &str) -> Value {
        // Bound only the initial TCP SYN wait. Xray's existing dial retry then
        // opens a fresh socket/source port; established streams and TLS retain
        // their normal timeouts. Darwin TCP_CONNECTIONTIMEOUT is option 0x20
        // at IPPROTO_TCP (6), with its value expressed in seconds.
        let mut stream =
            json!({"network":"raw","security":self.security,"sockopt":{"interface":interface}});
        if self.fast_connect_retry {
            stream["sockopt"]["customSockopt"] = json!([{"system":"darwin","network":"tcp",
                "level":"6","opt":"32","value":"2","type":"int"}]);
        }
        if self.security == "reality" {
            stream["realitySettings"] = json!({"serverName":self.server_name,"fingerprint":self.fingerprint,"publicKey":self.public_key,"shortId":self.short_id,"spiderX":self.spider,"mldsa65Verify":self.mldsa});
        } else {
            stream["tlsSettings"] = json!({"serverName":self.server_name,"alpn":self.alpn,"fingerprint":self.fingerprint});
            if !self.ech_config.is_empty() {
                stream["tlsSettings"]["echConfigList"] = json!(self.ech_config);
            }
        }
        json!({"log":{"loglevel":"warning"},"inbounds":[{"listen":"127.0.0.1","port":port,"protocol":"socks","settings":{"udp":true}}],"outbounds":[{"protocol":"vless","settings":{"address":ip,"port":self.port,"id":self.id,"encryption":self.encryption,"flow":self.flow},"streamSettings":stream}]})
    }
}

struct Ports {
    vless: u16,
    doh: u16,
    resolver: u16,
}

impl Ports {
    fn available() -> Result<Self> {
        let bind = || TcpListener::bind((Ipv4Addr::LOCALHOST, 0));
        let vless = bind()?;
        let doh = bind()?;
        let resolver = bind()?;
        // Go clients such as cloudflared read resolv.conf, which cannot specify
        // a port. Prefer 53 when available, retaining the scoped macOS resolver
        // port on hosts where another local DNS service already owns 53.
        let resolver_port = if TcpListener::bind((Ipv4Addr::LOCALHOST, 53)).is_ok()
            && UdpSocket::bind((Ipv4Addr::LOCALHOST, 53)).is_ok()
        {
            53
        } else {
            resolver.local_addr()?.port()
        };
        UdpSocket::bind((Ipv4Addr::LOCALHOST, resolver_port))
            .context("Порт системного DNS занят")?;
        Ok(Self {
            vless: vless.local_addr()?.port(),
            doh: doh.local_addr()?.port(),
            resolver: resolver_port,
        })
    }
}

fn sing(
    interface: &str,
    source: Ipv4Addr,
    tun: &str,
    endpoint: Ipv4Addr,
    dpi: u16,
    ports: &Ports,
) -> Value {
    let cdn: Vec<_> = CLOUDFLARE
        .lines()
        .filter(|l| !l.trim().is_empty())
        .collect();
    let cloudfront: Vec<_> = CLOUDFRONT.lines().collect();
    let vercel: Vec<_> = VERCEL.split(',').collect();
    let media: Vec<_> = MEDIA.iter().chain(META).collect();
    // Match before sniffing when system DNS knows the name so the TUN can
    // immediately return ICMP unreachable. Also match the QUIC SNI when a
    // browser has its own cached DNS answer.
    let regional_fb = r"^(scontent|video)-[^.]+\.xx\.fbcdn\.net$";
    let instagram_udp = json!({"network":"udp","port":443,
        "domain_suffix":["instagram.com","cdninstagram.com"],"domain_regex":regional_fb,
        "action":"reject","no_drop":true});
    // Leave IPv4 route_address unset. sing-tun on Darwin supplies 1/8 through
    // 128/1 so no unscoped route has an all-zero destination. XNU uses that
    // destination to select its primary interface, irrespective of the netmask.
    json!({
      "log":{"level":"info"},
      "dns":{"servers":[{"type":"tcp","tag":"direct-doh","server":"127.0.0.1","server_port":ports.doh},
        {"type":"tcp","tag":"meta-vless","server":"8.8.8.8","server_port":53,"detour":"vless"}],
        "final":"direct-doh","strategy":"ipv4_only","reverse_mapping":true,
        "rules":[{"query_type":["AAAA","HTTPS","SVCB"],"action":"predefined","rcode":"NOERROR"},
        {"domain_suffix":META,"action":"route","server":"meta-vless","client_subnet":"8.8.8.0/24"},
        {"domain_suffix":"trycloudflare.com","action":"route","server":"direct-doh","disable_cache":true}]},
      "inbounds":[{"type":"tun","tag":"tun","interface_name":tun,"address":["198.18.61.1/30","fd73:72ab:cd01::1/126"],
        "auto_route":true,"mtu":1500,"dns_mode":"disabled",
        "route_address":["2000::/3"],
        "route_exclude_address":["0.0.0.0/8",format!("{endpoint}/32"),"1.1.1.1/32","8.8.8.8/32","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","224.0.0.0/4","127.0.0.0/8"]},
        {"type":"direct","tag":"system-dns","listen":"127.0.0.1","listen_port":ports.resolver}],
      "outbounds":[{"type":"direct","tag":"direct","bind_interface":interface,"inet4_bind_address":source},
        {"type":"socks","tag":"dpi","server":"127.0.0.1","server_port":dpi,"version":"5"},
        {"type":"socks","tag":"vless","server":"127.0.0.1","server_port":ports.vless,"version":"5"}],
      "route":{"default_domain_resolver":"direct-doh","final":"direct","rules":[
        {"inbound":"system-dns","action":"hijack-dns"},{"port":53,"action":"hijack-dns"},{"ip_version":6,"action":"reject"},
        instagram_udp,{"action":"sniff","timeout":"300ms"},instagram_udp,
        // Pass the image hostname to the SOCKS resolver even when the browser
        // connected to a cached CDN IP. The resolver selects X's Fastly edge.
        {"domain":"pbs.twimg.com","port":443,"outbound":"dpi","override_address":"pbs.twimg.com"},
        {"protocol":"tls","network":"tcp","port":443,"domain_suffix":["instagram.com","cdninstagram.com"],"domain_regex":regional_fb,
          "outbound":"dpi","override_address":zapret_core::INSTAGRAM_TLS_RELAY},
        {"ip_cidr":"216.150.1.1/32","network":"tcp","port":[80,443],"outbound":"dpi","override_address":"216.150.16.1"},
        {"ip_cidr":"216.150.1.1/32","network":"udp","port":443,"outbound":"dpi","override_address":"216.150.16.1"},
        {"port":7844,"outbound":"dpi"},
        {"ip_is_private":true,"outbound":"direct"},
        // GitHub assets must stay direct, including when CDN address ranges change.
        {"domain_suffix":"githubassets.com","outbound":"direct"},
        {"domain_suffix":VPN,"outbound":"vless"},{"ip_cidr":TELEGRAM,"outbound":"vless"},
        {"domain_suffix":["pinterest.com","pinimg.com","pin.it"],"outbound":"direct"},
        {"network":"udp","port_range":["19294:19344","50000:50100"],"outbound":"dpi"},
        {"domain_suffix":media,"outbound":"dpi"},
        {"domain_suffix":["trycloudflare.com","vercel.app","vercel.sh"],"outbound":"dpi"},
        {"ip_cidr":vercel,"outbound":"dpi"},
        {"ip_cidr":cdn,"network":"tcp","port":[80,443,8443],"outbound":"dpi"},
        {"ip_cidr":cdn,"network":"udp","port":443,"outbound":"dpi"},
        {"ip_cidr":cloudfront,"network":"udp","port":443,"outbound":"vless"},
        {"ip_cidr":cloudfront,"network":"tcp","port":[80,443],"outbound":"vless"}
      ]}
    })
}

fn apply_network_rules(config: &mut Value, rules: &[super::strategies::DomainRule]) -> Vec<usize> {
    let routes = config["route"]["rules"].as_array_mut().unwrap();
    let index = routes.iter().position(|r| r["action"] == "sniff").unwrap() + 1;
    // Keep private addresses direct before any user override. More specific
    // suffixes win, independently of the order in which the UI stored them.
    let mut overrides = rules.iter().collect::<Vec<_>>();
    overrides.sort_by_key(|r| std::cmp::Reverse(r.domain.len()));
    let mut entries = vec![json!({"ip_is_private":true,"outbound":"direct"})];
    entries.extend(
        overrides
            .into_iter()
            .map(|r| json!({"domain_suffix":r.domain,"outbound":r.route})),
    );
    routes.splice(index..index, entries.clone());
    // DNS reverse mapping can identify UDP before sniffing; honor its override too.
    let count = entries.len();
    routes.splice(3..3, entries);
    (4..3 + count)
        .chain(index + count + 1..index + 2 * count)
        .collect()
}

/// The inspector and the worker use the same policy builder. Only policy fields
/// leave the helper: no node credentials, endpoint, local address or ports.
pub(super) fn inspect_policy(rules: &[super::strategies::DomainRule]) -> Value {
    let mut config = sing(
        "interface",
        Ipv4Addr::UNSPECIFIED,
        "tun",
        Ipv4Addr::UNSPECIFIED,
        0,
        &Ports {
            vless: 0,
            doh: 0,
            resolver: 0,
        },
    );
    let profile_indices = apply_network_rules(&mut config, rules);
    let mut capture = config["inbounds"][0].clone();
    for key in ["interface_name", "address", "mtu", "type", "tag"] {
        capture.as_object_mut().unwrap().remove(key);
    }
    for address in capture["route_exclude_address"].as_array_mut().unwrap() {
        if *address == "0.0.0.0/32" {
            *address = json!("VLESS-сервер /32");
        }
    }
    for server in config["dns"]["servers"].as_array_mut().unwrap() {
        server.as_object_mut().unwrap().remove("server_port");
    }
    json!({"route":config["route"], "dns":config["dns"], "capture":capture, "profileIndices":profile_indices})
}

pub(super) fn check_custom(
    custom: &super::custom::CustomPolicy,
    binary: &Path,
    stage: &Path,
) -> Result<()> {
    let mut config = sing(
        "en0",
        "192.0.2.11".parse()?,
        "utun91",
        "192.0.2.10".parse()?,
        49956,
        &Ports {
            vless: 49957,
            doh: 49958,
            resolver: 49959,
        },
    );
    custom.apply(&mut config);
    let file = stage.join("check.json");
    atomic_write(&file, &serde_json::to_vec(&config)?, 0o600)?;
    checked(
        binary.to_str().context("Invalid binary path")?,
        &["check", "-c", file.to_str().unwrap()],
        None,
    )?;
    Ok(())
}

fn spawn(exe: &Path, args: &[&str], log: &File) -> Result<Child> {
    Ok(Command::new(exe)
        .args(args)
        .env_clear()
        .stdin(Stdio::null())
        .stdout(log.try_clone()?)
        .stderr(log.try_clone()?)
        .spawn()?)
}

fn wait_listener(port: u16, runtime: &mut Runtime) -> Result<()> {
    for _ in 0..50 {
        interrupted()?;
        runtime.children_alive()?;
        if TcpStream::connect((Ipv4Addr::LOCALHOST, port)).is_ok() {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(80));
    }
    bail!("Служба не открыла локальный порт {port}")
}

/// Validate a candidate before changing a running TUN. The UI launches this
/// as its own user. Only a temporary loopback Xray and a bound physical socket
/// are needed, so the current server continues to carry traffic.
pub fn probe_node(input: &[u8], bin: &Path) -> Result<u64> {
    let node = Node::import(&serde_json::from_slice(input)?)?;
    // An ordinary TCP socket only needs the physical interface. Unlike the
    // packet injector this probe does not need privileged ARP-table access.
    let route = checked("/sbin/route", &["-n", "get", "default"], None)?;
    let interface = route
        .lines()
        .find_map(|l| l.trim().strip_prefix("interface: "))
        .context("Нет интерфейса для проверки сервера")?;
    validate_interface(interface)?;
    let ip = match node.host.parse::<Ipv4Addr>() {
        Ok(ip) => ip,
        Err(_) => checked(
            bin.join("cudy-dns").to_str().context("DNS path")?,
            &["-interface", interface, "-resolve", &node.host],
            None,
        )?
        .trim()
        .parse()?,
    };
    let port = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))?
        .local_addr()?
        .port();
    let mut runtime = Runtime::new();
    runtime.xray = Some(
        Command::new(bin.join("xray"))
            .args(["run", "-c", "stdin:"])
            .env_clear()
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?,
    );
    let input = runtime
        .xray
        .as_mut()
        .and_then(|c| c.stdin.take())
        .context("Xray stdin")?;
    serde_json::to_writer(input, &node.xray(ip, port, interface))?;
    let mut ready = false;
    for _ in 0..50 {
        runtime.children_alive()?;
        if TcpStream::connect((Ipv4Addr::LOCALHOST, port)).is_ok() {
            ready = true;
            break;
        }
        thread::sleep(Duration::from_millis(80));
    }
    ensure!(ready, "Проверочный Xray не открыл порт");
    let (status, output, _) = run_bounded(
        "/usr/bin/curl",
        &[
            "--disable",
            "--noproxy",
            "",
            "--proxy",
            &format!("socks5h://127.0.0.1:{port}"),
            "--max-time",
            "12",
            "--silent",
            "--output",
            "/dev/null",
            "--write-out",
            "%{http_code} %{time_total}",
            "https://www.gstatic.com/generate_204",
        ],
        None,
        Duration::from_secs(14),
    )?;
    ensure!(status.success(), "Сервер не прошёл проверку HTTPS");
    probe_latency(&output)
}

fn probe_latency(output: &str) -> Result<u64> {
    let fields: Vec<_> = output.split_whitespace().collect();
    ensure!(
        fields.len() == 2 && fields[0] == "204",
        "Сервер не прошёл проверку HTTPS"
    );
    let seconds: f64 = fields[1].parse().context("Некорректное время проверки")?;
    ensure!(
        seconds.is_finite() && (0.0..=12.0).contains(&seconds),
        "Некорректное время проверки"
    );
    Ok((seconds * 1000.0).round().max(1.0) as u64)
}

fn check_dns(port: u16, tcp: bool) -> Result<()> {
    let (status, out, err) = run(
        "/usr/bin/dig",
        &[
            "@127.0.0.1",
            "-p",
            &port.to_string(),
            if tcp { "+tcp" } else { "+notcp" },
            "+tries=1",
            "+timeout=6",
            "+noall",
            "+comments",
            "+answer",
            "www.apple.com",
            "A",
        ],
        None,
    )?;
    let rcode = out
        .lines()
        .find_map(|l| {
            l.split_once("status: ")
                .map(|(_, r)| r.split(',').next().unwrap_or("unknown"))
        })
        .unwrap_or("нет ответа");
    ensure!(
        status.success()
            && rcode == "NOERROR"
            && out.lines().any(|l| l
                .split_whitespace()
                .last()
                .is_some_and(|v| v.parse::<Ipv4Addr>().is_ok())),
        "127.0.0.1:{port}: {rcode} {}",
        err.trim()
    );
    Ok(())
}

fn dns_failure_detail(stage: &Path, label: &str) -> String {
    // The selector reports only provider/transport errors, never queried names or credentials.
    let detail = fs::read_to_string(stage.join("network.log"))
        .ok()
        .and_then(|log| {
            log.lines()
                .rev()
                .find(|l| l.starts_with("DoH: "))
                .map(|s| s.chars().take(350).collect::<String>())
        });
    detail.map_or_else(|| label.to_owned(), |info| format!("{label} ({info})"))
}

fn primary_resolver_matches(resolvers: &str, port: u16) -> bool {
    let primary = resolvers.split("resolver #2").next().unwrap_or("");
    primary
        .lines()
        .any(|l| l.trim() == "nameserver[0] : 127.0.0.1")
        && primary
            .lines()
            .find_map(|l| {
                let (k, v) = l.split_once(':')?;
                (k.trim() == "port").then(|| v.trim().parse::<u16>().unwrap_or(0))
            })
            .unwrap_or(53)
            == port
}

pub fn check_tun() -> Result<()> {
    for addr in ["1.1.1.1", "8.8.8.8", "9.9.9.9"] {
        let route = checked("/sbin/route", &["-n", "get", addr], None)?;
        ensure!(
            !route
                .lines()
                .any(|s| s.trim().starts_with("interface: utun")),
            "Выключите активный TUN v2rayN или другой VPN"
        );
    }
    Ok(())
}

pub fn start(
    runtime: &mut Runtime,
    stage: &Path,
    net: &Network,
    dpi: u16,
    node: &Node,
    rules: &[super::strategies::DomainRule],
    custom: Option<&super::custom::CustomPolicy>,
) -> Result<()> {
    let bin = Path::new(INSTALL).join("network");
    let ports = Ports::available()?;
    let log = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(stage.join("network.log"))?;
    let dns_exe = bin.join("cudy-dns");
    let endpoint = if let Ok(ip) = node.host.parse::<Ipv4Addr>() {
        ip
    } else {
        let cache = Path::new(INSTALL).join("last-endpoint.json");
        let answer = checked(
            dns_exe.to_str().unwrap(),
            &["-interface", &net.interface, "-resolve", &node.host],
            None,
        );
        match answer.and_then(|s| Ok(s.trim().parse::<Ipv4Addr>()?)) {
            Ok(ip) => {
                atomic_write(&cache, &serde_json::to_vec(&(&node.host, ip))?, 0o600)?;
                ip
            }
            Err(e) => {
                let old = read_regular(&cache, true, 2048)
                    .ok()
                    .and_then(|v| serde_json::from_slice::<(String, Ipv4Addr)>(&v).ok())
                    .filter(|(host, _)| host == &node.host);
                old.context(e)?.1
            }
        }
    };
    runtime.dns = Some(spawn(
        &dns_exe,
        &[
            "-interface",
            &net.interface,
            "-port",
            &ports.doh.to_string(),
        ],
        &log,
    )?);
    wait_listener(ports.doh, runtime)?;
    check_dns(ports.doh, true)
        .with_context(|| dns_failure_detail(stage, "Прямой DoH до запуска TUN"))?;
    // Xray consumes a data-only config from a pipe and runs as nobody.
    let mut command = Command::new(bin.join("xray"));
    command
        .args(["run", "-c", "stdin:"])
        .env_clear()
        .stdin(Stdio::piped())
        .stdout(log.try_clone()?)
        .stderr(log.try_clone()?);
    unsafe {
        command.pre_exec(|| {
            if libc::setgroups(0, std::ptr::null()) != 0
                || libc::setgid(GROUP) != 0
                || libc::setuid(GROUP) != 0
            {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    runtime.xray = Some(command.spawn()?);
    serde_json::to_writer(
        runtime
            .xray
            .as_mut()
            .unwrap()
            .stdin
            .take()
            .context("Xray stdin")?,
        &node.xray(endpoint, ports.vless, &net.interface),
    )?;
    wait_listener(ports.vless, runtime)?;
    let capture = Capture {
        stage,
        net,
        endpoint,
        dpi,
        ports: &ports,
        log: &log,
        rules,
        custom,
    };
    let mut report = Vec::new();
    for stack in ["mixed", "gvisor"] {
        capture.start(runtime, stack)?;
        let failed = readiness::check(runtime, net, stage)?;
        if failed.is_empty() {
            return Ok(());
        }
        let retry = stack == "mixed" && readiness::physical_ok(&failed);
        let summary = readiness::summary(&failed);
        report.push(json!({"stack":stack,"probes":failed}));
        atomic_write(
            &Path::new(INSTALL).join("last-https-failure.json"),
            &serde_json::to_vec_pretty(&report)?,
            0o600,
        )?;
        if !retry {
            bail!("Проверка HTTPS ({stack}): {summary}")
        }
        // Keep the same local resolver registration across the stack retry. The new
        // listener uses the same port; releasing it to DHCP here would expose lookups.
        if let Some(mut child) = runtime.tun.take() {
            stop_child(&mut child);
        }
        interrupted()?;
    }
    unreachable!()
}

struct Capture<'a> {
    stage: &'a Path,
    net: &'a Network,
    endpoint: Ipv4Addr,
    dpi: u16,
    ports: &'a Ports,
    log: &'a File,
    rules: &'a [super::strategies::DomainRule],
    custom: Option<&'a super::custom::CustomPolicy>,
}

impl Capture<'_> {
    fn start(&self, runtime: &mut Runtime, stack: &str) -> Result<()> {
        let Self {
            stage,
            net,
            endpoint,
            dpi,
            ports,
            log,
            rules,
            custom,
        } = *self;
        let bin = Path::new(INSTALL).join("network");
        let (_, tun, _) = choose_utun()?;
        let config = stage.join("tun.json");
        let mut policy = sing(&net.interface, net.source, &tun, endpoint, dpi, ports);
        apply_network_rules(&mut policy, rules);
        if let Some(custom) = custom {
            custom.apply(&mut policy);
        }
        // Validate before launching or modifying system routing.
        let check = stage.join("check.json");
        atomic_write(&check, &serde_json::to_vec(&policy)?, 0o600)?;
        checked(
            bin.join("sing-box").to_str().unwrap(),
            &["check", "-c", check.to_str().unwrap()],
            None,
        )?;
        policy["inbounds"][0]["stack"] = json!(stack);
        atomic_write(&config, &serde_json::to_vec(&policy)?, 0o600)?;
        runtime.tun = Some(spawn(
            &bin.join("sing-box"),
            &["run", "-c", config.to_str().unwrap()],
            log,
        )?);
        let route_probe = if endpoint == Ipv4Addr::new(9, 9, 9, 9) {
            "208.67.222.222"
        } else {
            "9.9.9.9"
        };
        for _ in 0..60 {
            interrupted()?;
            if let Err(e) = runtime.children_alive() {
                let diagnostic = fs::read_to_string(stage.join("network.log")).unwrap_or_default();
                let reason = diagnostic
                    .lines()
                    .rev()
                    .find(|s| s.contains("FATAL") || s.contains("ERROR"))
                    .unwrap_or("");
                bail!("{e}: {reason}")
            }
            if checked("/sbin/route", &["-n", "get", route_probe], None)?
                .lines()
                .any(|l| l.trim() == format!("interface: {tun}"))
            {
                // Both routes must coexist: normal clients take the TUN while a socket
                // explicitly bound to the physical interface can still use its gateway.
                let physical = checked(
                    "/sbin/route",
                    &["-n", "get", "-ifscope", &net.interface, route_probe],
                    None,
                )
                .with_context(|| {
                    format!(
                        "Нет исходящего маршрута к {route_probe} через {}",
                        net.interface
                    )
                })?;
                ensure!(
                    physical
                        .lines()
                        .any(|line| line.trim() == format!("interface: {}", net.interface)),
                    "Исходящий маршрут к {route_probe} не использует {}",
                    net.interface
                );
                // Test the exact UDP listener that mDNSResponder will use before publishing it.
                check_dns(ports.resolver, false)
                    .with_context(|| dns_failure_detail(stage, "DNS после включения TUN"))?;
                let port = ports.resolver.to_string();
                if runtime.system_dns.is_none() {
                    runtime.system_dns = Some(spawn(&bin.join("system-dns"), &[&port], log)?);
                }
                for _ in 0..40 {
                    interrupted()?;
                    runtime.children_alive()?;
                    let resolvers = checked("/usr/sbin/scutil", &["--dns"], None)?;
                    if primary_resolver_matches(&resolvers, ports.resolver) {
                        return Ok(());
                    }
                    thread::sleep(Duration::from_millis(100));
                }
                bail!("macOS не активировала локальный DNS на порту {port}");
            }
            thread::sleep(Duration::from_millis(100));
        }
        bail!("TUN не установил маршрут")
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn probe_requires_successful_https_and_valid_timing() {
        assert_eq!(super::probe_latency("204 0.0424").unwrap(), 42);
        assert_eq!(super::probe_latency("204 0.00001").unwrap(), 1);
        for output in [
            "200 0.1",
            "503 0.1",
            "000 0",
            "204",
            "204 NaN",
            "204 inf",
            "204 -1",
            "204 13",
            "204 0.1 extra",
        ] {
            assert!(super::probe_latency(output).is_err(), "{output}");
        }
    }

    use super::*;
    #[test]
    fn import_limits_root_config_and_preserves_tls_hostname() {
        for tls in ["tls", "reality"] {
            let source = json!({"protocol":"vless","settings":{"address":"vpn.example.com","id":"11111111-1111-4111-8111-111111111111","flow":"xtls-rprx-vision","port":443},
                "streamSettings":{"network":"raw","security":tls,"sockopt":{"dialerProxy":"untrusted"},
                "realitySettings":{"publicKey":"example"}}});
            let node = Node::import(&source).unwrap();
            let cfg = node.xray("192.0.2.2".parse().unwrap(), 12345, "en0");
            let ob = &cfg["outbounds"][0];
            assert_eq!(ob["settings"]["flow"], "xtls-rprx-vision-udp443");
            assert_eq!(ob["settings"]["address"], "192.0.2.2");
            assert_eq!(
                ob["streamSettings"][format!("{tls}Settings")]["serverName"],
                "vpn.example.com"
            );
            let sockopt = &ob["streamSettings"]["sockopt"];
            assert_eq!(sockopt["interface"], "en0");
            assert!(sockopt.get("dialerProxy").is_none());
            assert!(
                sockopt.get("customSockopt").is_none(),
                "Existing profiles keep their original timeout"
            );
            let mut enabled = source.clone();
            enabled["fastConnectRetry"] = json!(true);
            let node = Node::import(&enabled).unwrap();
            let cfg = node.xray("192.0.2.2".parse().unwrap(), 12345, "en0");
            assert_eq!(
                cfg["outbounds"][0]["streamSettings"]["sockopt"]["customSockopt"],
                json!([{
                    "system":"darwin","network":"tcp","level":"6",
                    "opt":"32","value":"2","type":"int"
                }])
            );
        }
    }
    // Called only by tests/loopback.py with a freshly created, private temp directory.
    #[test]
    #[ignore]
    fn write_loopback_configs() -> Result<()> {
        let dir = PathBuf::from(std::env::var("ZAPRET_LOOPBACK_DIR")?);
        let case: Value = serde_json::from_slice(&fs::read(dir.join("case.json"))?)?;
        let node = Node::import(&case["node"])?;
        let port = |name: &str| -> Result<u16> {
            Ok(u16::try_from(case[name].as_u64().context("missing port")?)?)
        };
        let iface = case["interface"].as_str().context("missing interface")?;
        let ip = case["endpoint"]
            .as_str()
            .context("missing endpoint")?
            .parse()?;
        let mut config = sing(
            iface,
            checked("/usr/sbin/ipconfig", &["getifaddr", iface], None)?
                .trim()
                .parse()?,
            "unused",
            ip,
            port("dpi")?,
            &Ports {
                vless: port("vless")?,
                doh: port("dns")?,
                resolver: port("resolver")?,
            },
        );
        atomic_write(&dir.join("tun.json"), &serde_json::to_vec(&config)?, 0o600)?;
        config["inbounds"][0] =
            json!({"type":"mixed","tag":"probe","listen":"127.0.0.1","listen_port":port("proxy")?});
        atomic_write(&dir.join("sing.json"), &serde_json::to_vec(&config)?, 0o600)?;
        atomic_write(
            &dir.join("xray.json"),
            &serde_json::to_vec(&node.xray(ip, port("vless")?, iface))?,
            0o600,
        )
    }

    #[test]
    fn system_resolver_requires_the_owned_port_on_the_primary_entry() {
        let listing =
            "resolver #1\n  nameserver[0] : 127.0.0.1\n  port : 50001\nresolver #2\n  port : 50002";
        assert!(primary_resolver_matches(listing, 50001));
        assert!(!primary_resolver_matches(listing, 50002));
        assert!(!primary_resolver_matches(
            &listing.replace("127.0.0.1", "192.0.2.2"),
            50001
        ));
    }

    #[test]
    fn network_routes_override_services_and_are_specific_and_private_safe() {
        use super::super::strategies::{DomainRule, Route};
        let ports = Ports {
            vless: 49957,
            doh: 49958,
            resolver: 49959,
        };
        let mut config = sing(
            "en0",
            "192.0.2.11".parse().unwrap(),
            "utun91",
            "192.0.2.10".parse().unwrap(),
            49956,
            &ports,
        );
        let baseline = config.clone();
        apply_network_rules(
            &mut config,
            &[
                DomainRule {
                    domain: "githubassets.com".into(),
                    route: Route::Vless,
                },
                DomainRule {
                    domain: "specific.githubassets.com".into(),
                    route: Route::Direct,
                },
            ],
        );
        let rules = config["route"]["rules"].as_array().unwrap();
        assert_eq!(rules[3], json!({"ip_is_private":true,"outbound":"direct"}));
        assert_eq!(
            rules[4],
            json!({"domain_suffix":"specific.githubassets.com","outbound":"direct"})
        );
        assert_eq!(
            rules[5],
            json!({"domain_suffix":"githubassets.com","outbound":"vless"})
        );
        let sniff = rules.iter().position(|r| r["action"] == "sniff").unwrap();
        assert_eq!(rules[sniff + 1], rules[3]);
        assert_eq!(rules[sniff + 2], rules[4]);
        assert_eq!(rules[sniff + 3], rules[5]);
        assert!(!baseline["route"]["rules"]
            .as_array()
            .unwrap()
            .contains(&rules[5]));
    }

    #[test]
    fn check_policy_with_bundled_sing_box() {
        let config = sing(
            "en0",
            "192.0.2.11".parse().unwrap(),
            "utun91",
            "192.0.2.10".parse().unwrap(),
            49956,
            &Ports {
                vless: 49957,
                doh: 49958,
                resolver: 49959,
            },
        );
        assert_eq!(config["inbounds"][1]["listen"], "127.0.0.1");
        assert_eq!(config["inbounds"][1]["listen_port"], 49959);
        assert_eq!(
            config["route"]["rules"][0],
            json!({"inbound":"system-dns","action":"hijack-dns"})
        );
        assert_eq!(config["inbounds"][0]["auto_route"], true);
        assert_eq!(config["inbounds"][0]["route_address"], json!(["2000::/3"]));
        for address in [
            "0.0.0.0/8",
            "1.1.1.1/32",
            "8.8.8.8/32",
            "127.0.0.0/8",
            "192.0.2.10/32",
        ] {
            assert!(config["inbounds"][0]["route_exclude_address"]
                .as_array()
                .unwrap()
                .contains(&json!(address)));
        }
        let rules = config["route"]["rules"].as_array().unwrap();
        let cidrs = json!(CLOUDFLARE.lines().collect::<Vec<_>>());
        let cf: Vec<_> = rules
            .iter()
            .enumerate()
            .filter(|(_, r)| r["ip_cidr"] == cidrs)
            .collect();
        assert_eq!(cf.len(), 2);
        assert_eq!(
            *cf[0].1,
            json!({"ip_cidr":cidrs,"network":"tcp","port":[80,443,8443],"outbound":"dpi"})
        );
        assert_eq!(
            *cf[1].1,
            json!({"ip_cidr":cidrs,"network":"udp","port":443,"outbound":"dpi"})
        );
        let cloudfront = json!(CLOUDFRONT.lines().collect::<Vec<_>>());
        let after_cf = &rules[cf[1].0 + 1..];
        assert!(after_cf.contains(
            &json!({"ip_cidr":cloudfront,"network":"udp","port":443,"outbound":"vless"})
        ));
        assert!(after_cf.contains(
            &json!({"ip_cidr":cloudfront,"network":"tcp","port":[80,443],"outbound":"vless"})
        ));
        let before_cf = &rules[..cf[0].0];
        assert!(!VPN.contains(&"githubassets.com"));
        for exception in [
            json!({"domain_suffix":"githubassets.com","outbound":"direct"}),
            json!({"domain":"pbs.twimg.com","port":443,"outbound":"dpi","override_address":"pbs.twimg.com"}),
            json!({"port":7844,"outbound":"dpi"}),
            json!({"domain_suffix":VPN,"outbound":"vless"}),
            json!({"ip_cidr":TELEGRAM,"outbound":"vless"}),
            json!({"domain_suffix":["pinterest.com","pinimg.com","pin.it"],"outbound":"direct"}),
        ] {
            assert!(before_cf.contains(&exception));
        }
        assert_eq!(config["route"]["final"], "direct");
        assert_eq!(config["outbounds"][0]["bind_interface"], "en0");
        assert_eq!(config["outbounds"][0]["inet4_bind_address"], "192.0.2.11");
        assert_ne!(config["dns"]["rules"][1]["server"], config["dns"]["final"]);
        if let Some(binary) = std::env::var_os("ZAPRET_TEST_SING_BOX") {
            let mut file = tempfile::NamedTempFile::new().unwrap();
            serde_json::to_writer(&mut file, &config).unwrap();
            let output = Command::new(binary)
                .args(["check", "-c"])
                .arg(file.path())
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
        }
    }
}
