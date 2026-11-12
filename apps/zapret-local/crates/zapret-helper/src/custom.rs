use super::*;
use serde_json::{json, Value};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct CustomPolicy {
    pub routing: Value,
    pub dns: Value,
    pub dpi_arguments: Vec<String>,
    pub lists: BTreeMap<String, String>,
}
impl CustomPolicy {
    pub fn validate(&self) -> Result<()> {
        ensure!(
            self.routing.is_object() && self.routing["rules"].is_array(),
            "routing.rules must be an array"
        );
        ensure!(
            self.dns.is_object() && self.dns["servers"].is_array() && self.dns["rules"].is_array(),
            "dns requires servers and rules"
        );
        ensure!(
            self.dpi_arguments.len() <= 1024 && self.lists.len() <= 64,
            "Configuration too large"
        );
        // No caller-selected files, executables, rule-set downloads or privileged engine controls.
        fn json_fields(v: &Value) -> Result<()> {
            match v {
                Value::Object(map) => {
                    for (k, v) in map {
                        ensure!(
                            !(k.ends_with("_path") && k != "process_path")
                                && ![
                                    "path",
                                    "rule_set",
                                    "rule_set_ip_cidr_match_source",
                                    "certificate_path",
                                    "key_path",
                                    "client_key_path",
                                    "client_certificate_path",
                                    "cache_file",
                                    "geosite",
                                    "geoip"
                                ]
                                .contains(&k.as_str()),
                            "Unsupported file-backed option: {k}"
                        );
                        json_fields(v)?;
                    }
                }
                Value::Array(a) => {
                    for v in a {
                        json_fields(v)?;
                    }
                }
                _ => {}
            }
            Ok(())
        }
        json_fields(&self.routing)?;
        json_fields(&self.dns)?;
        for name in self.lists.keys() {
            ensure!(
                name.ends_with(".txt")
                    && name.len() <= 80
                    && name
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
                    && !name.contains(".."),
                "Invalid list filename"
            );
        }
        for arg in &self.dpi_arguments {
            let option = arg.split('=').next().unwrap();
            ensure!(
                option == "--new"
                    || option.starts_with("--filter-")
                    || option.starts_with("--dpi-desync")
                    || option.starts_with("--orig-")
                    || option.starts_with("--dup")
                    || [
                        "--skip",
                        "--comment",
                        "--ctrack-timeouts",
                        "--ctrack-disable",
                        "--ipcache-lifetime",
                        "--ipcache-hostname",
                        "--wsize",
                        "--wssize",
                        "--wssize-cutoff",
                        "--wssize-forced-cutoff",
                        "--synack-split",
                        "--hostcase",
                        "--hostspell",
                        "--hostnospace",
                        "--domcase",
                        "--methodeol",
                        "--ip-id",
                        "--ipset-ip",
                        "--ipset-exclude-ip"
                    ]
                    .contains(&option)
                    || [
                        "--hostlist",
                        "--hostlist-domains",
                        "--hostlist-exclude",
                        "--hostlist-exclude-domains",
                        "--ipset",
                        "--ipset-exclude"
                    ]
                    .contains(&option),
                "Unsupported DPI option: {option}"
            );
            ensure!(
                !arg.contains('\0') && !arg.contains('\n'),
                "Invalid DPI argument"
            );
            if let Some((_, value)) = arg.split_once('=') {
                let file_option = [
                    "--hostlist",
                    "--hostlist-exclude",
                    "--ipset",
                    "--ipset-exclude",
                ]
                .contains(&option);
                let payload_option = [
                    "--dpi-desync-fake-http",
                    "--dpi-desync-fake-tls",
                    "--dpi-desync-fake-unknown",
                    "--dpi-desync-fake-syndata",
                    "--dpi-desync-fake-quic",
                    "--dpi-desync-fake-wireguard",
                    "--dpi-desync-fake-dht",
                    "--dpi-desync-fake-discord",
                    "--dpi-desync-fake-stun",
                    "--dpi-desync-fake-unknown-udp",
                    "--dpi-desync-split-seqovl-pattern",
                    "--dpi-desync-fakedsplit-pattern",
                    "--dpi-desync-udplen-pattern",
                ]
                .contains(&option);
                if file_option || payload_option {
                    if let Some((prefix, name)) = value.split_once("[списки]/") {
                        ensure!(
                            prefix.is_empty()
                                || prefix == "@"
                                || (prefix.starts_with('+')
                                    && prefix.ends_with('@')
                                    && prefix[1..prefix.len() - 1]
                                        .bytes()
                                        .all(|b| b.is_ascii_digit())),
                            "Invalid file offset"
                        );
                        ensure!(
                            !name.contains('/') && !name.contains('\\') && !name.contains(".."),
                            "Unsafe path"
                        );
                        ensure!(
                            FILES.contains(&name) || self.lists.contains_key(name),
                            "Unknown DPI file: {name}"
                        );
                    } else {
                        ensure!(
                            payload_option
                                && (value.starts_with("0x")
                                    || (option == "--dpi-desync-fake-tls"
                                        && value.starts_with('!'))),
                            "Use [списки]/filename or inline payload bytes"
                        );
                    }
                } else {
                    ensure!(
                        !value.contains('@') && !value.contains("[списки]"),
                        "File references are only allowed in file options"
                    );
                }
            }
        }
        ensure!(
            serde_json::to_vec(self)?.len() <= 1_000_000,
            "Configuration exceeds 1 MB"
        );
        Ok(())
    }
    pub fn args(&self, directory: &Path, drop_root: bool) -> Result<Vec<String>> {
        self.validate()?;
        let mut args = Vec::new();
        if drop_root {
            args.push(format!("--uid={ENGINE_UID}:{GROUP}"));
        }
        args.extend(
            self.dpi_arguments
                .iter()
                .map(|v| v.replace("[списки]", &directory.to_string_lossy())),
        );
        Ok(args)
    }
    pub fn prepare(&self, source: &Path, target: &Path) -> Result<()> {
        self.validate()?;
        fs::create_dir(target)?;
        fs::set_permissions(target, fs::Permissions::from_mode(0o755))?;
        for name in FILES {
            fs::copy(source.join(name), target.join(name))?;
        }
        for (name, contents) in &self.lists {
            atomic_write(&target.join(name), contents.as_bytes(), 0o644)?;
        }
        let mut hashes = BTreeMap::new();
        for name in FILES {
            hashes.insert(
                name,
                format!("{:x}", Sha256::digest(fs::read(target.join(name))?)),
            );
        }
        atomic_write(
            &target.join("manifest.json"),
            &serde_json::to_vec(&json!({"commit":COMMIT,"sha256":hashes}))?,
            0o644,
        )?;
        Ok(())
    }
    pub fn check_engines(&self, source: &Path, sing: &Path) -> Result<()> {
        let parent = if unsafe { libc::geteuid() } == 0 {
            PathBuf::from("/var/run")
        } else {
            std::env::temp_dir()
        };
        let stage = tempfile::Builder::new()
            .prefix("v2dpi-check-")
            .tempdir_in(parent)?;
        fs::set_permissions(stage.path(), fs::Permissions::from_mode(0o755))?;
        let directory = stage.path().join("engine");
        self.prepare(source, &directory)?;
        let mut args = self.args(&directory, false)?;
        args.push("--dry-run".into());
        checked(
            directory.join("utunws").to_str().unwrap(),
            &args.iter().map(String::as_str).collect::<Vec<_>>(),
            None,
        )?;
        network::check_custom(self, sing, stage.path())
    }
    pub fn apply(&self, config: &mut Value) {
        let local = config["dns"]["servers"]
            .as_array()
            .unwrap()
            .iter()
            .find(|v| v["tag"] == "direct-doh")
            .cloned();
        config["route"] = self.routing.clone();
        config["dns"] = self.dns.clone();
        // Resolve the application-owned local DNS endpoint at runtime.
        if let Some(local) = local {
            for server in config["dns"]["servers"].as_array_mut().unwrap() {
                if server["tag"] == "direct-doh"
                    && server["server"] == "127.0.0.1"
                    && server.get("server_port").is_none()
                {
                    if let Some(port) = local.get("server_port") {
                        server["server_port"] = port.clone();
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn policy() -> CustomPolicy {
        let snapshot = network::inspect_policy(&[]);
        CustomPolicy {
            routing: snapshot["route"].clone(),
            dns: snapshot["dns"].clone(),
            dpi_arguments: vec![
                "--filter-tcp=443".into(),
                "--dpi-desync=multidisorder".into(),
            ],
            lists: BTreeMap::new(),
        }
    }
    #[test]
    fn preserves_user_rules_dns_ports_and_inline_cidrs() {
        let mut custom = policy();
        custom.routing =
            json!({"rules":[{"domain_suffix":"example.com","outbound":"vless"}],"final":"dpi"});
        custom.dns["servers"][0]["server_port"] = json!(5353);
        custom.dpi_arguments.push("--ipset-ip=192.0.2.0/24".into());
        custom.validate().unwrap();
        let mut result = network::inspect_policy(&[]);
        custom.apply(&mut result);
        assert_eq!(result["route"], custom.routing);
        assert_eq!(result["dns"], custom.dns);
    }
    #[test]
    fn rejects_files_outside_configuration_and_privileged_controls() {
        for arg in [
            "--uid=0",
            "--debug=@/etc/passwd",
            "--dpi-desync-fake-unknown=passwd",
            "--dpi-desync-split-seqovl-pattern=@/etc/passwd",
            "--hostlist=[списки]/../passwd",
            "--hostlist=[списки]/absent.txt",
        ] {
            let mut custom = policy();
            custom.dpi_arguments.push(arg.into());
            assert!(custom.validate().is_err(), "{arg}");
        }
        let mut custom = policy();
        custom.dns["servers"][0]["tls"] = json!({"certificate_path":"/etc/passwd"});
        assert!(custom.validate().is_err());
        let mut custom = policy();
        custom.lists.insert("../secret.txt".into(), "".into());
        assert!(custom.validate().is_err());
    }
    #[test]
    fn editable_lists_reach_policy_and_real_engines() {
        let source = Path::new(INSTALL).join("engine");
        if !source.exists() {
            return;
        }
        let mut custom = policy();
        custom
            .lists
            .insert("my-domains.txt".into(), "example.com\n".into());
        custom
            .dpi_arguments
            .insert(1, "--hostlist=[списки]/my-domains.txt".into());
        custom
            .check_engines(&source, &Path::new(INSTALL).join("network/sing-box"))
            .unwrap();
        let selection = Selection {
            custom: Some(custom.clone()),
            ..Default::default()
        };
        let report = policy::inspect(&selection, None, &source).unwrap();
        assert!(report
            .entries
            .iter()
            .any(|e| e.title == "my-domains.txt" && e.details == "example.com\n"));
        custom.routing["rules"][0]["outbound"] = json!("missing-outbound");
        assert!(custom
            .check_engines(&source, &Path::new(INSTALL).join("network/sing-box"))
            .is_err());
    }
}
