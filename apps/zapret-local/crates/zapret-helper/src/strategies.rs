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
        if self.strategy == "local" {
            return Ok(super::engine_args(directory, drop_root));
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
        let mut args = Vec::new();
        if drop_root {
            args.push(format!("--uid={}:{}", super::ENGINE_UID, super::GROUP));
        }
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
