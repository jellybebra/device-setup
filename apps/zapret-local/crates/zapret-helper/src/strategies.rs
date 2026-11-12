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
#[serde(default, deny_unknown_fields)]
pub struct Selection {
    pub strategy: String,
    pub ipset: String,
}

impl Default for Selection {
    fn default() -> Self {
        Self {
            strategy: "local".into(),
            ipset: "cloudflare".into(),
        }
    }
}

impl Selection {
    pub fn validate(&self) -> Result<()> {
        ensure!(
            self.strategy == "local" || catalog().iter().any(|p| p.id == self.strategy),
            "Unknown strategy"
        );
        ensure!(
            ["none", "cloudflare", "loaded", "any"].contains(&self.ipset.as_str()),
            "Unknown IPSet mode"
        );
        Ok(())
    }

    pub fn args(&self, directory: &Path, drop_root: bool) -> Result<Vec<String>> {
        self.validate()?;
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
