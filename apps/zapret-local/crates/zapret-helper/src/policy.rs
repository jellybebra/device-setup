//! Read-only projection of the exact routing and engine policy builders.
use super::{network, strategies::Selection};
use anyhow::{ensure, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{collections::BTreeSet, fs, path::Path};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Policy {
    pub strategy: String,
    pub entries: Vec<Entry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Entry {
    pub id: String,
    pub section: String,
    pub title: String,
    pub outcome: String,
    pub source: String,
    pub summary: String,
    pub details: String,
}

fn value_text(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        Value::Array(items) => items.iter().map(value_text).collect::<Vec<_>>().join(", "),
        other => other.to_string(),
    }
}

fn outcome(rule: &Value) -> String {
    let value = rule["outbound"]
        .as_str()
        .or(rule["action"].as_str())
        .unwrap_or("direct");
    match value {
        "direct" => "Напрямую",
        "dpi" => "DPI",
        "vless" => "VLESS",
        "sniff" => "Определить протокол",
        "reject" => "Отклонить",
        "hijack-dns" => "Системный DNS",
        "predefined" => "Ответ DNS",
        "route" => return format!("DNS: {}", value_text(&rule["server"])),
        other => other,
    }
    .into()
}

fn conditions(rule: &Value) -> String {
    rule.as_object()
        .map(|map| {
            map.iter()
                .filter(|(k, _)| !["outbound", "action"].contains(&k.as_str()))
                .map(|(key, value)| {
                    let label = match key.as_str() {
                        "domain_suffix" => "Домены и поддомены",
                        "domain" => "Точный домен",
                        "domain_regex" => "Шаблон домена",
                        "ip_cidr" => "IP-сети",
                        "network" => "Транспорт",
                        "protocol" => "Протокол",
                        "port" => "Порт",
                        "port_range" => "Диапазоны портов",
                        "ip_is_private" => "Частный адрес",
                        "ip_version" => "Версия IP",
                        "override_address" => "Адрес назначения",
                        "inbound" => "Вход",
                        "query_type" => "Тип DNS-запроса",
                        other => other,
                    };
                    format!("{label}: {}", value_text(value))
                })
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default()
}

pub fn inspect(selection: &Selection, key: Option<&str>, directory: &Path) -> Result<Policy> {
    selection.validate()?;
    if let Some(key) = key {
        ensure!(
            selection.profile(key).is_some(),
            "Network profile not found"
        );
    }
    let profile = key.and_then(|key| selection.profile(key));
    let effective = selection.for_network(key.unwrap_or(""));
    let overrides = profile.map(|p| p.rules.as_slice()).unwrap_or(&[]);
    let mut config = network::inspect_policy(overrides);
    if let Some(custom) = &effective.custom {
        custom.apply(&mut config);
        config["profileIndices"] = json!([]);
    }
    let mut entries = Vec::new();
    for (section, rules) in [
        ("Маршрутизация", &config["route"]["rules"]),
        ("DNS", &config["dns"]["rules"]),
    ] {
        for (i, rule) in rules.as_array().unwrap().iter().enumerate() {
            let from_profile = section == "Маршрутизация"
                && config["profileIndices"]
                    .as_array()
                    .unwrap()
                    .contains(&json!(i));
            let summary = conditions(rule);
            entries.push(Entry {
                id: format!("{section}-{i}"),
                section: section.into(),
                title: format!("Правило {}", i + 1),
                outcome: outcome(rule),
                source: if from_profile {
                    "Профиль сети"
                } else {
                    "Встроенное правило"
                }
                .into(),
                summary: if summary.is_empty() {
                    "Все соединения на этом этапе".into()
                } else {
                    summary
                },
                details: serde_json::to_string_pretty(rule)?,
            });
        }
    }
    for (id, section, title, value) in [
        (
            "route-final",
            "Маршрутизация",
            "Маршрут по умолчанию",
            json!({"outbound":config["route"]["final"]}),
        ),
        (
            "dns-default",
            "DNS",
            "Резолверы и настройки DNS",
            {
                let mut dns = config["dns"].clone();
                dns.as_object_mut().unwrap().remove("rules");
                dns
            },
        ),
        (
            "capture",
            "Захват трафика",
            "TUN и исключения",
            config["capture"].clone(),
        ),
    ] {
        entries.push(Entry {
            id: id.into(),
            section: section.into(),
            title: title.into(),
            outcome: if id == "route-final" {
                "Напрямую"
            } else {
                "Система"
            }
            .into(),
            source: "Встроенное правило".into(),
            summary: if id == "route-final" {
                "Если ни одно правило маршрутизации выше не совпало".into()
            } else {
                conditions(&value)
            },
            details: serde_json::to_string_pretty(&value)?,
        });
    }
    let args = effective.args(directory, false)?;
    let mut files = BTreeSet::new();
    for (i, group) in args
        .split(|arg| arg == "--new")
        .filter(|g| !g.is_empty())
        .enumerate()
    {
        let mut readable = Vec::new();
        for arg in group {
            // Only known packaged files referenced by generated arguments may be read.
            for name in super::FILES {
                if name.ends_with(".txt")
                    && arg.ends_with(&format!("={}", directory.join(name).display()))
                {
                    files.insert(name.to_string());
                }
            }
            readable.push(arg.replace(&directory.to_string_lossy().to_string(), "[списки]"));
        }
        let action = group
            .iter()
            .find_map(|s| s.strip_prefix("--dpi-desync="))
            .unwrap_or("Без модификации");
        let summary = readable
            .iter()
            .filter(|s| {
                s.starts_with("--filter-")
                    || s.starts_with("--hostlist")
                    || s.starts_with("--ipset")
            })
            .cloned()
            .collect::<Vec<_>>()
            .join("\n");
        entries.push(Entry {
            id: format!("dpi-{i}"),
            section: "DPI".into(),
            title: format!("DPI-профиль {}", i + 1),
            outcome: action.into(),
            source: format!("Стратегия: {}", effective.strategy),
            summary: if summary.is_empty() {
                "Все соединения, дошедшие до этого DPI-профиля".into()
            } else {
                summary
            },
            details: readable.join("\n"),
        });
    }
    if let Some(custom) = &effective.custom {
        files.extend(custom.lists.keys().cloned());
    }
    for name in files {
        let path = directory.join(&name);
        let text = if let Some(text) = effective.custom.as_ref().and_then(|c| c.lists.get(&name)) {
            text.clone()
        } else {
            ensure!(
                fs::metadata(&path)?.len() <= 1_048_576,
                "Policy list too large"
            );
            fs::read_to_string(&path).with_context(|| format!("Cannot read {name}"))?
        };
        let count = text
            .lines()
            .filter(|l| !l.trim().is_empty() && !l.trim_start().starts_with('#'))
            .count();
        entries.push(Entry {
            id: format!("list-{name}"),
            section: "Списки DPI".into(),
            title: name,
            outcome: format!("{count} записей"),
            source: "Файл установленного движка".into(),
            summary: "Полный список, используемый выбранной стратегией".into(),
            details: text,
        });
    }
    let policy = Policy {
        strategy: effective.strategy,
        entries,
    };
    ensure!(
        serde_json::to_vec(&policy)?.len() < 3_000_000,
        "Policy report too large"
    );
    Ok(policy)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::strategies::{DomainRule, NetworkProfile, Route};

    #[test]
    fn report_uses_real_policy_order_and_keeps_network_overrides_scoped() {
        let directory =
            std::env::temp_dir().join(format!("v2dpi-policy-test-{}", std::process::id()));
        fs::create_dir_all(&directory).unwrap();
        for name in super::super::FILES {
            if name.ends_with(".txt") {
                fs::write(directory.join(name), "example.com\n").unwrap();
            }
        }
        let key = "a".repeat(64);
        let selection = Selection {
            network_profiles: vec![NetworkProfile {
                key: key.clone(),
                name: "Office".into(),
                strategy: "general-exp".into(),
                ipset: "cloudflare".into(),
                rules: vec![DomainRule {
                    domain: "githubassets.com".into(),
                    route: Route::Vless,
                }],
            }],
            ..Default::default()
        };
        let base = inspect(&selection, None, &directory).unwrap();
        assert!(!base.entries.iter().any(|e| e.source == "Профиль сети"));
        let report = inspect(&selection, Some(&key), &directory).unwrap();
        let route = network::inspect_policy(&selection.network_profiles[0].rules);
        let rendered: Vec<Value> = report
            .entries
            .iter()
            .filter(|e| e.section == "Маршрутизация" && e.id != "route-final")
            .map(|e| serde_json::from_str(&e.details).unwrap())
            .collect();
        assert_eq!(json!(rendered), route["route"]["rules"]);
        assert_eq!(
            report
                .entries
                .iter()
                .filter(|e| e.source == "Профиль сети")
                .count(),
            2
        );
        assert!(report
            .entries
            .iter()
            .any(|e| e.section == "DPI" && e.details.contains("multidisorder")));
        assert!(report
            .entries
            .iter()
            .any(|e| e.section == "Списки DPI" && e.details == "example.com\n"));
        let serialized = serde_json::to_string(&report).unwrap();
        for secret in ["password", "private_key", "server_port", "192.0.2."] {
            assert!(!serialized.contains(secret));
        }
        assert!(inspect(&selection, Some(&"b".repeat(64)), &directory).is_err());
        fs::remove_dir_all(directory).unwrap();
    }
}
