//! Compare the system path with a physical connection to the exact same HTTPS peer.
use super::*;

const TARGETS: [&str; 2] = [
    "www.apple.com/library/test/success.html",
    "www.gstatic.com/generate_204",
];

#[derive(Serialize)]
pub(super) struct Probe {
    target: &'static str,
    ip: Option<Ipv4Addr>,
    port: Option<u16>,
    error: String,
    physical: Option<String>,
    trace: Vec<String>,
}

fn https(target: &'static str, control: Option<(&Network, Ipv4Addr)>) -> Result<Probe> {
    let url = format!("https://{target}");
    let mut args = vec![
        "--disable",
        "--noproxy",
        "*",
        "--ipv4",
        "--silent",
        "--show-error",
        "--fail",
        "--max-time",
        "4",
        "--output",
        "/dev/null",
        "--write-out",
        "%{remote_ip} %{local_port}",
    ];
    let resolution;
    if let Some((net, ip)) = control {
        let host = target.split('/').next().unwrap();
        resolution = format!("{host}:443:{ip}");
        args.extend(["--interface", &net.interface, "--resolve", &resolution]);
    }
    args.push(&url);
    let (status, meta, error) = run("/usr/bin/curl", &args, None)?;
    let (ip, port) = meta.split_once(' ').unwrap_or(("", ""));
    Ok(Probe {
        target,
        ip: ip.parse().ok(),
        port: port.trim().parse().ok().filter(|p| *p != 0),
        error: if status.success() {
            String::new()
        } else {
            format!("curl {}: {}", status.code().unwrap_or(-1), error.trim())
        },
        physical: None,
        trace: Vec::new(),
    })
}

// Keep only messages associated with the probe socket. Other users' requests may be present in the log.
fn connection_trace(log: &str, port: u16) -> Vec<String> {
    let source = format!(":{port}");
    let id = log
        .lines()
        .rev()
        .find(|line| line.contains("inbound connection from ") && line.ends_with(&source))
        .and_then(|line| {
            Regex::new(r"\[(\d+) [^\]]+\]")
                .ok()?
                .captures(line)
                .map(|c| format!("[{} ", &c[1]))
        });
    let Some(id) = id else { return vec![] };
    log.lines()
        .filter(|l| l.contains(&id))
        .take(12)
        .map(|l| l.chars().take(400).collect())
        .collect()
}

pub(super) fn check(runtime: &mut Runtime, net: &Network, stage: &Path) -> Result<Vec<Probe>> {
    let mut failed = Vec::new();
    for pass in 0..2 {
        if pass != 0 {
            thread::sleep(Duration::from_millis(500));
        }
        failed.clear();
        for target in TARGETS {
            interrupted()?;
            runtime.children_alive()?;
            let probe = https(target, None)?;
            if probe.error.is_empty() {
                return Ok(vec![]);
            }
            failed.push(probe);
        }
    }
    let mut log = File::open(stage.join("network.log"))?;
    let tail = log.metadata()?.len().saturating_sub(256 * 1024);
    log.seek(SeekFrom::Start(tail))?;
    let mut bytes = Vec::new();
    log.take(256 * 1024).read_to_end(&mut bytes)?;
    let clean = Regex::new(r"\x1b\[[0-9;]*m")?
        .replace_all(&String::from_utf8_lossy(&bytes), "")
        .into_owned();
    for probe in &mut failed {
        if let Some(port) = probe.port {
            probe.trace = connection_trace(&clean, port);
        }
        if let Some(ip) = probe.ip {
            interrupted()?;
            let physical = https(probe.target, Some((net, ip)))?;
            probe.physical = Some(if physical.error.is_empty() {
                "ok".into()
            } else {
                physical.error
            });
        }
    }
    Ok(failed)
}

pub(super) fn physical_ok(probes: &[Probe]) -> bool {
    probes.iter().any(|p| p.physical.as_deref() == Some("ok"))
}

pub(super) fn summary(probes: &[Probe]) -> String {
    probes
        .iter()
        .map(|p| {
            format!(
                "{}: {}; напрямую: {}",
                p.target.split('/').next().unwrap(),
                p.error,
                p.physical.as_deref().unwrap_or("адрес не получен")
            )
        })
        .collect::<Vec<_>>()
        .join(" / ")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn retry_requires_the_same_peer_to_work_on_the_physical_interface() {
        let mut failed = Probe {
            target: TARGETS[0],
            ip: Some(Ipv4Addr::new(192, 0, 2, 1)),
            port: Some(51000),
            error: "TLS reset".into(),
            physical: None,
            trace: vec![],
        };
        assert!(!physical_ok(std::slice::from_ref(&failed)));
        failed.physical = Some("TLS reset".into());
        assert!(!physical_ok(std::slice::from_ref(&failed)));
        failed.physical = Some("ok".into());
        assert!(physical_ok(&[failed]));
    }

    #[test]
    fn report_includes_only_the_probe_connection() {
        let input="[11 0ms] inbound connection from 192.0.2.1:51400\n[42 0ms] inbound connection from 192.0.2.1:51401\n[11 1ms] error: reset\n[42 1ms] another host";
        assert_eq!(connection_trace(input, 51400).len(), 2);
        assert!(connection_trace(input, 51400)
            .iter()
            .all(|l| l.contains("[11 ")));
        assert!(connection_trace(input, 51500).is_empty());
    }
}
