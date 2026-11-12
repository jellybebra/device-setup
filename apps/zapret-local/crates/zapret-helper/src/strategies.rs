use anyhow::{ensure, Result};
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Deserialize)]
pub struct Preset {
    pub id: String,
    pub args: Vec<String>,
}

pub fn catalog() -> Vec<Preset> {
    serde_json::from_str(include_str!("../../../resources/strategies.json"))
        .expect("bundled strategy catalog")
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Route {
    Direct,
    Dpi,
    Vless,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DomainRule {
    pub domain: String,
    pub route: Route,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NetworkProfile {
    pub key: String,
    pub name: String,
    pub strategy: String,
    pub ipset: String,
    pub rules: Vec<DomainRule>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Selection {
    pub strategy: String,
    pub ipset: String,
    pub custom: Option<super::custom::CustomPolicy>,
    #[serde(rename = "networkProfiles", default)]
    pub network_profiles: Vec<NetworkProfile>,
    #[serde(skip)]
    pub(super) extra_dpi_domains: Vec<String>,
}

impl Default for Selection {
    fn default() -> Self {
        Self {
            strategy: "local".into(),
            ipset: "cloudflare".into(),
            custom: None,
            network_profiles: Vec::new(),
            extra_dpi_domains: Vec::new(),
        }
    }
}

impl Selection {
    pub fn validate(&self) -> Result<()> {
        if let Some(custom) = &self.custom {
            custom.validate()?;
        }
        ensure!(
            self.strategy == "local" || catalog().iter().any(|p| p.id == self.strategy),
            "Unknown strategy"
        );
        ensure!(
            ["none", "cloudflare", "loaded", "any"].contains(&self.ipset.as_str()),
            "Unknown IPSet mode"
        );
        ensure!(
            self.network_profiles.len() <= 16,
            "Too many network profiles"
        );
        let mut keys = std::collections::HashSet::new();
        for profile in &self.network_profiles {
            ensure!(
                profile.key.len() == 64 && profile.key.bytes().all(|b| b.is_ascii_hexdigit()),
                "Invalid network key"
            );
            ensure!(keys.insert(&profile.key), "Duplicate network profile");
            ensure!(
                !profile.name.trim().is_empty() && profile.name.len() <= 160,
                "Invalid profile name"
            );
            ensure!(profile.rules.len() <= 32, "Too many domain rules");
            Selection {
                strategy: profile.strategy.clone(),
                ipset: profile.ipset.clone(),
                ..Default::default()
            }
            .validate()?;
            let mut domains = std::collections::HashSet::new();
            for rule in &profile.rules {
                let domain = &rule.domain;
                ensure!(
                    domain.len() <= 253
                        && domain.contains('.')
                        && domain.split('.').all(|label| {
                            !label.is_empty()
                                && label.len() <= 63
                                && !label.starts_with('-')
                                && !label.ends_with('-')
                                && label.bytes().all(|b| {
                                    b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-'
                                })
                        })
                        && domain.parse::<std::net::IpAddr>().is_err(),
                    "Invalid rule domain"
                );
                ensure!(domains.insert(domain), "Duplicate rule domain");
            }
        }
        ensure!(
            serde_json::to_vec(self)?.len() <= 1_100_000,
            "Network profiles exceed the settings limit"
        );
        Ok(())
    }

    pub fn profile(&self, key: &str) -> Option<&NetworkProfile> {
        self.network_profiles.iter().find(|p| p.key == key)
    }

    pub fn for_network(&self, key: &str) -> Self {
        let mut selected = self.clone();
        if let Some(profile) = self.profile(key) {
            selected.strategy = profile.strategy.clone();
            selected.ipset = profile.ipset.clone();
            selected.extra_dpi_domains = profile
                .rules
                .iter()
                .filter(|r| r.route == Route::Dpi)
                .map(|r| r.domain.clone())
                .collect();
        }
        selected.network_profiles.clear();
        selected
    }

    pub fn args(&self, directory: &Path, drop_root: bool) -> Result<Vec<String>> {
        self.validate()?;
        if let Some(custom) = &self.custom {
            return custom.args(directory, drop_root);
        }
        let mut args = Vec::new();
        if drop_root {
            args.push(format!("--uid={}:{}", super::ENGINE_UID, super::GROUP));
        }
        // These sessions reach the broker only after the Cudy policy selected DPI.
        let cf = format!(
            "--ipset={}",
            directory.join("cloudflare-ipv4.txt").display()
        );
        for (filter, matcher, proto) in [
            (
                "--filter-tcp=443",
                "--hostlist-domains=trycloudflare.com".into(),
                "tls",
            ),
            ("--filter-tcp=443,7844,8443", cf.clone(), "tls"),
            ("--filter-udp=443,7844", cf.clone(), "quic"),
            (
                "--filter-tcp=443",
                format!("--ipset-ip={}", super::network::VERCEL),
                "tls",
            ),
            (
                "--filter-udp=443",
                format!("--ipset-ip={}", super::network::VERCEL),
                "quic",
            ),
        ] {
            args.extend([filter.into(), matcher, "--dpi-desync=fake".into()]);
            if proto == "tls" {
                args.extend([
                    "--dpi-desync-repeats=12".into(),
                    "--dpi-desync-fooling=ts".into(),
                    "--dpi-desync-ts-increment=-600000".into(),
                    format!(
                        "--dpi-desync-fake-tls={}",
                        directory.join(super::FILES[3]).display()
                    ),
                ]);
            } else {
                args.extend([
                    "--filter-l7=quic".into(),
                    "--dpi-desync-repeats=6".into(),
                    format!(
                        "--dpi-desync-fake-quic={}",
                        directory.join(super::FILES[2]).display()
                    ),
                ]);
            }
            args.push("--new".into());
        }
        let media = super::network::MEDIA
            .iter()
            .chain(super::network::META)
            .copied()
            .collect::<Vec<_>>()
            .join(",");
        // ALT9's remaining Cloudflare web profile is HTTP on port 80.
        // Leave named social sites to their existing hostname profiles on that port.
        args.extend([
            "--filter-tcp=80".into(),
            cf,
            format!("--hostlist-exclude-domains={media}"),
            "--dpi-desync=hostfakesplit".into(),
            "--dpi-desync-hostfakesplit-mod=host=ozon.ru".into(),
            "--dpi-desync-repeats=4".into(),
            "--dpi-desync-fooling=ts".into(),
            "--dpi-desync-ts-increment=-600000".into(),
            "--new".into(),
        ]);
        // X media needs its own TCP profile even when a general preset is
        // selected. The preset's fake/overlap profile intermittently stalls
        // the TLS handshake on Fastly; plain multidisorder preserves it.
        args.extend([
            "--filter-tcp=443".into(),
            "--hostlist-domains=twimg.com".into(),
            "--dpi-desync=multidisorder".into(),
            "--dpi-desync-split-pos=1,midsld".into(),
            "--new".into(),
        ]);
        if self.strategy == "local" {
            args.extend(super::engine_args(directory, false));
            return Ok(args);
        }
        let preset = catalog()
            .into_iter()
            .find(|p| p.id == self.strategy)
            .unwrap();
        let ipset = directory.join(match self.ipset.as_str() {
            "loaded" => "ipset-all.txt",
            "any" => "ipset-any.txt",
            "cloudflare" => "cloudflare-ipv4.txt",
            _ => "ipset-none.txt",
        });
        args.extend([
            "--filter-udp=443".into(),
            "--filter-l7=quic".into(),
            format!("--hostlist-domains={media}"),
            "--dpi-desync=fake".into(),
            "--dpi-desync-repeats=6".into(),
            format!(
                "--dpi-desync-fake-quic={}",
                directory.join(super::FILES[2]).display()
            ),
            "--new".into(),
        ]);
        for arg in preset.args {
            if arg == "--hostlist=@LISTS@/list-general-user.txt"
                && !self.extra_dpi_domains.is_empty()
            {
                args.push(format!(
                    "--hostlist-domains={}",
                    self.extra_dpi_domains.join(",")
                ));
            }
            // Only compiled-in presets are accepted. No shell and no caller-
            // supplied paths/engine options cross the privileged IPC boundary.
            args.push(
                arg.replace("@BASE@/bin", &directory.to_string_lossy())
                    .replace("@LISTS@", &directory.to_string_lossy())
                    .replace("@IPSET@", &ipset.to_string_lossy()),
            );
        }
        Ok(args)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn profiles_are_isolated_and_custom_dpi_domains_reach_presets() {
        let key = "a".repeat(64);
        let selection = Selection {
            strategy: "local".into(),
            network_profiles: vec![NetworkProfile {
                key: key.clone(),
                name: "Office Wi-Fi".into(),
                strategy: "general-exp".into(),
                ipset: "none".into(),
                rules: vec![DomainRule {
                    domain: "example.com".into(),
                    route: Route::Dpi,
                }],
            }],
            ..Default::default()
        };
        selection.validate().unwrap();
        assert_eq!(selection.for_network(&key).strategy, "general-exp");
        assert_eq!(selection.for_network(&key).ipset, "none");
        assert!(selection
            .for_network(&key)
            .args(Path::new("/engine"), false)
            .unwrap()
            .contains(&"--hostlist-domains=example.com".into()));
        assert_eq!(selection.for_network(&"b".repeat(64)).strategy, "local");
        assert!(selection.profile(&"b".repeat(64)).is_none());
        for domain in [
            "https://example.com",
            "*.example.com",
            "example.com/path",
            "127.0.0.1",
            "-bad.example",
            "a..example",
        ] {
            let mut bad = selection.clone();
            bad.network_profiles[0].rules[0].domain = domain.into();
            assert!(bad.validate().is_err(), "{domain}");
        }
        let mut bad = selection.clone();
        bad.network_profiles.push(bad.network_profiles[0].clone());
        assert!(bad.validate().is_err());
    }

    #[test]
    fn selection_rejects_arguments_paths_and_unknown_modes() {
        for id in [
            "../general",
            "--uid=0",
            "general;touch /tmp/x",
            "",
            "general-unknown",
        ] {
            assert!(Selection {
                strategy: id.into(),
                ..Selection::default()
            }
            .validate()
            .is_err());
        }
        assert!(Selection {
            ipset: "/tmp/custom.txt".into(),
            ..Selection::default()
        }
        .validate()
        .is_err());
    }
    #[test]
    fn x_media_profile_precedes_each_general_preset() {
        for strategy in
            std::iter::once("local".to_owned()).chain(catalog().into_iter().map(|p| p.id))
        {
            let args = Selection {
                strategy,
                ..Selection::default()
            }
            .args(Path::new("/engine"), false)
            .unwrap();
            let profiles: Vec<_> = args.split(|arg| arg == "--new").collect();
            let index = profiles
                .iter()
                .position(|profile| {
                    profile
                        .iter()
                        .any(|arg| arg == "--hostlist-domains=twimg.com")
                })
                .unwrap();
            assert!(profiles[index].iter().any(|arg| arg == "--filter-tcp=443"));
            assert!(profiles[index]
                .iter()
                .any(|arg| arg == "--dpi-desync=multidisorder"));
            assert!(profiles[index]
                .iter()
                .any(|arg| arg == "--dpi-desync-split-pos=1,midsld"));
            // A catch-all or list-based preset before this profile would
            // silently make the targeted strategy unreachable again.
            assert!(profiles[..index].iter().all(|profile| !profile
                .iter()
                .any(|arg| { arg.starts_with("--hostlist=") || arg == "--filter-tcp=80,443" })));
        }
    }

    #[test]
    fn every_preset_has_only_bundled_paths_and_preserves_profile_order() {
        let presets = catalog();
        assert_eq!(presets.len(), 21);
        for preset in presets {
            for mode in ["none", "cloudflare", "loaded", "any"] {
                let args = Selection {
                    strategy: preset.id.clone(),
                    ipset: mode.into(),
                    ..Default::default()
                }
                .args(Path::new("/engine"), true)
                .unwrap();
                assert_eq!(
                    args[0],
                    format!("--uid={}:{}", super::super::ENGINE_UID, super::super::GROUP)
                );
                assert!(args.iter().any(|a| a == "--new"));
                assert!(args
                    .iter()
                    .all(|a| a.starts_with("--") && !a.contains('@') && !a.contains('"')));
                for arg in &args {
                    if let Some((_, value)) = arg.split_once('=') {
                        if value.starts_with('/') {
                            let name = value.strip_prefix("/engine/").unwrap();
                            assert!(super::super::FILES.contains(&name), "{arg}");
                        }
                    }
                }
            }
        }
    }
}
