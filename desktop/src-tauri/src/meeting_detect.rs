use crate::app::App;
use crate::{meeting, shell};
use serde::Serialize;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri::async_runtime::{spawn, spawn_blocking};

// Automatic meeting detection for Windows and Linux.
//
// Polls active per-process audio streams every 2 s (WASAPI on Windows,
// PipeWire/PulseAudio via pactl on Linux). Only when a call app or browser
// actually has live audio does it read window titles (EnumWindows on Windows,
// EWMH via x11rb on Linux) so idle CPU usage stays near zero.

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DetectedMeeting {
    pub id: String,
    pub source: String,
    pub title: String,
    pub is_generic_title: bool,
    pub high_confidence: bool,
}

#[derive(Clone, Debug, Default)]
pub struct AppSnapshot {
    /// Lowercase executable stem (e.g. "chrome", "msedge", "zoom", "ms-teams", "slack").
    pub process_name: String,
    pub window_titles: Vec<String>,
    pub is_frontmost: bool,
    pub has_mic: bool,
    pub has_output: bool,
}

#[derive(Clone, Debug, Default)]
pub struct SystemSnapshot {
    pub apps: Vec<AppSnapshot>,
}

/* --------------------------------- matcher -------------------------------- */

const EXCLUDED_WEB_KEYWORDS: &[&str] = &[
    "chatgpt",
    "claude",
    "gemini",
    "perplexity",
    "grok",
    "notebooklm",
    "youtube",
    "spotify",
    "apple music",
    "soundcloud",
    "twitch",
    "netflix",
    "voice memos",
    "duolingo",
    "loom",
    "descript",
    "suno",
    "elevenlabs",
    "audacity",
    "soundtrap",
    "bandlab",
    "transcriptor",
    "dictation",
];

fn normalize_process_name(raw: &str) -> String {
    let trimmed = raw.trim().trim_matches('"');
    let base = trimmed.rsplit(['/', '\\']).next().unwrap_or(trimmed);
    let lower = base.to_ascii_lowercase();
    lower.strip_suffix(".exe").unwrap_or(&lower).to_string()
}

fn browser_label(process: &str) -> Option<&'static str> {
    match process {
        "chrome" | "google-chrome" | "google-chrome-stable" | "google-chrome-beta" | "google-chrome-unstable" | "chrome_proxy" => {
            Some("Google Chrome")
        }
        "msedge" | "microsoft-edge" | "microsoft-edge-stable" | "microsoft-edge-beta" => Some("Microsoft Edge"),
        "brave" | "brave-browser" => Some("Brave"),
        "firefox" | "firefox-bin" | "firefox-esr" | "firefox-developer-edition" | "firefox-nightly" => Some("Firefox"),
        "zen" | "zen-bin" | "zen-browser" => Some("Zen"),
        "arc" => Some("Arc"),
        "opera" | "opera_gx" => Some("Opera"),
        "vivaldi" | "vivaldi-bin" => Some("Vivaldi"),
        "chromium" | "chromium-browser" | "ungoogled-chromium" => Some("Chromium"),
        "floorp" => Some("Floorp"),
        "librewolf" => Some("LibreWolf"),
        "waterfox" => Some("Waterfox"),
        "comet" => Some("Comet"),
        "dia" => Some("Dia"),
        "helium" => Some("Helium"),
        _ => None,
    }
}

#[cfg_attr(not(any(target_os = "windows", target_os = "linux")), allow(dead_code))]
pub fn is_relevant_process(process: &str) -> bool {
    let p = normalize_process_name(process);
    if p == "transcriptor" {
        return false;
    }
    browser_label(&p).is_some()
        || matches!(
            p.as_str(),
            "zoom"
                | "cpthost"
                | "ms-teams"
                | "teams"
                | "teams-for-linux"
                | "slack"
                | "discord"
                | "discordptb"
                | "discordcanary"
                | "vesktop"
                | "armcord"
                | "legcord"
                | "ciscocollabhost"
                | "webex"
                | "atmgr"
                | "ptoneclk"
                | "ciscowebexstart"
                | "whatsapp"
                | "telegram"
                | "telegram-desktop"
                | "signal"
                | "signal-desktop"
                | "messenger"
                | "viber"
                | "lark"
                | "feishu"
                | "element"
                | "element-desktop"
                | "figma"
                | "figma-linux"
                | "tuple"
                | "gather"
                | "chime"
                | "ringcentral"
                | "glip"
                | "goto"
                | "g2mcomm"
                | "skype"
                | "skypeforlinux"
                | "around"
                | "tandem"
        )
}

pub struct MeetingMatcher;

impl MeetingMatcher {
    pub fn detect(snapshot: &SystemSnapshot) -> Option<DetectedMeeting> {
        let mut ordered: Vec<&AppSnapshot> = snapshot.apps.iter().collect();
        ordered.sort_by(|a, b| {
            b.has_mic
                .cmp(&a.has_mic)
                .then(b.is_frontmost.cmp(&a.is_frontmost))
                .then(b.has_output.cmp(&a.has_output))
        });

        for app in ordered {
            let proc_name = normalize_process_name(&app.process_name);
            if proc_name == "transcriptor" {
                continue;
            }
            if let Some(native) = Self::match_native(&proc_name, app) {
                return Some(native);
            }
            if let Some(browser) = browser_label(&proc_name) {
                if let Some(web) = Self::match_browser(browser, app) {
                    return Some(web);
                }
            }
        }
        None
    }

    fn match_native(proc_name: &str, app: &AppSnapshot) -> Option<DetectedMeeting> {
        let mic = app.has_mic;
        match proc_name {
            "zoom" | "cpthost" => {
                const LOBBY: &[&str] = &[
                    "zoom",
                    "zoom workplace",
                    "zoom cloud meetings",
                    "settings",
                    "zoom settings",
                    "team chat",
                    "chat",
                    "meeting chat",
                    "participants",
                    "polls",
                    "home",
                    "zoom share statusbar window",
                    "",
                ];
                let titles: Vec<String> = app.window_titles.iter().map(|t| strip_leading_badge(t)).collect();
                let meeting_window = titles.iter().find(|t| {
                    let l = t.to_lowercase();
                    l.contains("zoom meeting") || l.contains("zoom webinar")
                });
                let topic = titles.iter().find(|t| {
                    let l = t.to_lowercase();
                    !LOBBY.contains(&l.as_str()) && !l.starts_with("zoom meeting") && !l.starts_with("zoom webinar")
                });
                if !(mic || (app.has_output && meeting_window.is_some())) {
                    return None;
                }
                let title = topic.cloned().unwrap_or_else(|| {
                    if meeting_window.is_some_and(|w| w.to_lowercase().contains("webinar")) {
                        "Zoom Webinar".into()
                    } else {
                        "Zoom Meeting".into()
                    }
                });
                Some(DetectedMeeting {
                    id: format!("zoom:{}", title.to_lowercase()),
                    source: "Zoom".into(),
                    title,
                    is_generic_title: topic.is_none(),
                    high_confidence: mic || meeting_window.is_some(),
                })
            }

            "ms-teams" | "teams" | "teams-for-linux" => {
                const LOBBY: &[&str] = &[
                    "chat",
                    "activity",
                    "calendar",
                    "teams",
                    "calls",
                    "files",
                    "apps",
                    "microsoft teams",
                    "meeting compact view",
                    "meet",
                    "",
                ];
                let specific = app
                    .window_titles
                    .iter()
                    .map(|t| strip_leading_badge(t))
                    .filter_map(|t| strip_suffix(&t, &[" | Microsoft Teams", " - Microsoft Teams"]))
                    .find(|t| !LOBBY.contains(&t.to_lowercase().as_str()));
                if !(mic || (app.has_output && specific.is_some())) {
                    return None;
                }
                let title = specific.clone().unwrap_or_else(|| "Microsoft Teams".into());
                Some(DetectedMeeting {
                    id: format!("teams:{}", title.to_lowercase()),
                    source: "Microsoft Teams".into(),
                    title,
                    is_generic_title: specific.is_none(),
                    high_confidence: mic,
                })
            }

            "slack" => {
                let huddle_window = app.window_titles.iter().find(|t| t.to_lowercase().contains("huddle"));
                if !(mic || (app.has_output && huddle_window.is_some())) {
                    return None;
                }
                let cleaned = huddle_window.map(|w| clean_slack_title(w)).filter(|s| !s.is_empty());
                let title = cleaned.clone().unwrap_or_else(|| "Slack Huddle".into());
                Some(DetectedMeeting {
                    id: format!("slack:{}", title.to_lowercase()),
                    source: "Slack Huddle".into(),
                    title,
                    is_generic_title: cleaned.is_none(),
                    high_confidence: mic || huddle_window.is_some(),
                })
            }

            "discord" | "discordptb" | "discordcanary" | "vesktop" | "armcord" | "legcord" => {
                if !mic {
                    return None;
                }
                let specific = app
                    .window_titles
                    .iter()
                    .map(|t| strip_leading_badge(t))
                    .filter_map(|t| strip_suffix(&t, &[" - Discord", " - Vesktop"]))
                    .find(|t| !t.is_empty() && !t.eq_ignore_ascii_case("discord") && !t.eq_ignore_ascii_case("vesktop"));
                let title = specific.clone().unwrap_or_else(|| "Discord Call".into());
                Some(DetectedMeeting {
                    id: format!("discord:{}", title.to_lowercase()),
                    source: "Discord".into(),
                    title,
                    is_generic_title: specific.is_none(),
                    high_confidence: true,
                })
            }

            "ciscocollabhost" | "webex" | "atmgr" | "ptoneclk" | "ciscowebexstart" => {
                if !mic {
                    return None;
                }
                let specific = app
                    .window_titles
                    .iter()
                    .map(|t| strip_leading_badge(t))
                    .filter_map(|t| strip_suffix(&t, &[" - Webex", " | Webex"]))
                    .find(|t| !t.is_empty() && !t.eq_ignore_ascii_case("webex"));
                let title = specific.clone().unwrap_or_else(|| "Webex Meeting".into());
                Some(DetectedMeeting {
                    id: format!("webex:{}", title.to_lowercase()),
                    source: "Webex".into(),
                    title,
                    is_generic_title: specific.is_none(),
                    high_confidence: true,
                })
            }

            "whatsapp" => Self::generic_native_call(app, mic, "WhatsApp", "WhatsApp Call", &["whatsapp"]),
            "telegram" | "telegram-desktop" => Self::generic_native_call(app, mic, "Telegram", "Telegram Call", &["telegram"]),
            "signal" | "signal-desktop" => Self::generic_native_call(app, mic, "Signal", "Signal Call", &["signal"]),
            "messenger" => Self::generic_native_call(app, mic, "Messenger", "Messenger Call", &["messenger"]),
            "viber" => Self::generic_native_call(app, mic, "Viber", "Viber Call", &["viber"]),
            "lark" | "feishu" => Self::generic_native_call(app, mic, "Lark", "Lark Meeting", &["lark", "feishu"]),
            "element" | "element-desktop" => Self::generic_native_call(app, mic, "Element", "Element Call", &["element"]),
            "figma" | "figma-linux" => Self::generic_native_call(app, mic, "Figma Audio", "Figma Audio", &["figma"]),
            "tuple" => Self::generic_native_call(app, mic, "Tuple", "Tuple Call", &["tuple"]),
            "gather" => Self::generic_native_call(app, mic, "Gather", "Gather", &["gather"]),
            "chime" => Self::generic_native_call(app, mic, "Amazon Chime", "Amazon Chime", &["amazon chime", "chime"]),
            "ringcentral" | "glip" => Self::generic_native_call(app, mic, "RingCentral", "RingCentral Meeting", &["ringcentral"]),
            "goto" | "g2mcomm" => Self::generic_native_call(app, mic, "GoTo Meeting", "GoTo Meeting", &["goto", "gotomeeting"]),
            "skype" | "skypeforlinux" => Self::generic_native_call(app, mic, "Skype", "Skype Call", &["skype"]),
            "around" => Self::generic_native_call(app, mic, "Around", "Around Call", &["around"]),
            "tandem" => Self::generic_native_call(app, mic, "Tandem", "Tandem Call", &["tandem"]),
            _ => None,
        }
    }

    fn generic_native_call(
        app: &AppSnapshot,
        mic: bool,
        source: &str,
        fallback_title: &str,
        lobby: &[&str],
    ) -> Option<DetectedMeeting> {
        if !mic {
            return None;
        }
        let specific = app
            .window_titles
            .iter()
            .map(|t| strip_leading_badge(t))
            .find(|t| !t.is_empty() && !lobby.contains(&t.to_lowercase().as_str()));
        let title = specific.clone().unwrap_or_else(|| fallback_title.into());
        Some(DetectedMeeting {
            id: format!("{}:{}", source.to_lowercase(), title.to_lowercase()),
            source: source.into(),
            title,
            is_generic_title: specific.is_none(),
            high_confidence: true,
        })
    }

    fn match_browser(browser_name: &str, app: &AppSnapshot) -> Option<DetectedMeeting> {
        let mic = app.has_mic;
        if !mic && !app.has_output {
            return None;
        }

        // First: try explicit known web meeting platforms from any window title.
        for raw in &app.window_titles {
            let cleaned = clean_browser_title(raw);
            if cleaned.is_empty() {
                continue;
            }
            if let Some(known) = match_known_web_platform(&cleaned) {
                if !mic && !app.has_output {
                    continue;
                }
                return Some(known);
            }
        }

        // Second: universal WebRTC fallback when BOTH mic and speakers are active in the browser.
        if mic && app.has_output {
            // If window titles are readable (Windows / Linux X11 / XWayland), check exclusions first.
            let cleaned_titles: Vec<String> = app
                .window_titles
                .iter()
                .map(|t| clean_browser_title(t))
                .filter(|t| !t.is_empty())
                .collect();

            if !cleaned_titles.is_empty() {
                for cleaned in &cleaned_titles {
                    let lower = cleaned.to_lowercase();
                    if EXCLUDED_WEB_KEYWORDS.iter().any(|k| lower.contains(k)) {
                        return None;
                    }
                }
                let candidate = cleaned_titles[0].clone();
                return Some(DetectedMeeting {
                    id: format!("web:{}:{}", browser_name.to_lowercase(), candidate.to_lowercase()),
                    source: browser_name.into(),
                    title: candidate,
                    is_generic_title: false,
                    high_confidence: false,
                });
            }

            // Pure Wayland fallback: no X11 titles exposed, but browser has both mic + speakers live.
            return Some(DetectedMeeting {
                id: format!("web:{}:call", browser_name.to_lowercase()),
                source: browser_name.into(),
                title: format!("{browser_name} Meeting"),
                is_generic_title: true,
                high_confidence: false,
            });
        }

        None
    }
}

fn match_known_web_platform(title: &str) -> Option<DetectedMeeting> {
    let lower = title.to_lowercase();

    // 1. Google Meet: "Meet – abc-defg-hij" or "Meet - Weekly Standup"
    if let Some(rest) = strip_prefix_ci(title, &["meet – ", "meet - ", "meet — ", "google meet – ", "google meet - "]) {
        let trimmed = rest.trim();
        let is_code = is_google_meet_code(trimmed);
        let display = if is_code || trimmed.is_empty() { "Google Meet".to_string() } else { trimmed.to_string() };
        return Some(DetectedMeeting {
            id: format!("google-meet:{}", trimmed.to_lowercase()),
            source: "Google Meet".into(),
            title: display,
            is_generic_title: is_code || trimmed.is_empty(),
            high_confidence: true,
        });
    }
    if lower == "google meet" || lower.ends_with(" - google meet") || lower.ends_with(" | google meet") {
        let topic = strip_suffix(title, &[" - Google Meet", " | Google Meet", " – Google Meet"]).unwrap_or_default();
        let is_generic = topic.is_empty() || topic.eq_ignore_ascii_case("google meet") || is_google_meet_code(&topic);
        return Some(DetectedMeeting {
            id: format!("google-meet:{}", if is_generic { "call".into() } else { topic.to_lowercase() }),
            source: "Google Meet".into(),
            title: if is_generic { "Google Meet".into() } else { topic },
            is_generic_title: is_generic,
            high_confidence: true,
        });
    }

    // 2. Microsoft Teams (Web)
    if lower.contains("microsoft teams") {
        const LOBBY: &[&str] = &["chat", "activity", "calendar", "teams", "calls", "files", "microsoft teams", ""];
        let topic = strip_suffix(title, &[" | Microsoft Teams", " - Microsoft Teams"]).unwrap_or_default();
        let is_generic = topic.is_empty() || LOBBY.contains(&topic.to_lowercase().as_str());
        return Some(DetectedMeeting {
            id: format!("teams-web:{}", if is_generic { "call".into() } else { topic.to_lowercase() }),
            source: "Microsoft Teams".into(),
            title: if is_generic { "Microsoft Teams".into() } else { topic },
            is_generic_title: is_generic,
            high_confidence: true,
        });
    }

    // 3. Zoom (Web)
    if lower.contains("zoom meeting") || lower.contains("zoom webinar") || lower.ends_with(" - zoom") || lower.ends_with(" | zoom") {
        let topic = strip_suffix(title, &[" - Zoom", " | Zoom", " - Zoom Meeting"]).unwrap_or_default();
        let is_generic = topic.is_empty() || topic.to_lowercase().contains("zoom");
        return Some(DetectedMeeting {
            id: format!("zoom-web:{}", if is_generic { "call".into() } else { topic.to_lowercase() }),
            source: "Zoom".into(),
            title: if is_generic { "Zoom Meeting".into() } else { topic },
            is_generic_title: is_generic,
            high_confidence: true,
        });
    }

    // 4. Slack Huddle (Web)
    if lower.contains("huddle") && lower.contains("slack") {
        let cleaned = clean_slack_title(title);
        let is_generic = cleaned.is_empty();
        return Some(DetectedMeeting {
            id: format!("slack-web:{}", if is_generic { "huddle".into() } else { cleaned.to_lowercase() }),
            source: "Slack Huddle".into(),
            title: if is_generic { "Slack Huddle".into() } else { cleaned },
            is_generic_title: is_generic,
            high_confidence: true,
        });
    }

    // 5. Other known web meeting platforms
    const PLATFORMS: &[(&[&str], &str, &str)] = &[
        (&["whereby"], "Whereby", "Whereby"),
        (&["jitsi meet", "meet.jit.si"], "Jitsi Meet", "Jitsi Meet"),
        (&["discord"], "Discord", "Discord Call"),
        (&["webex"], "Webex", "Webex Meeting"),
        (&["riverside"], "Riverside", "Riverside"),
        (&["daily.co", " | daily"], "Daily", "Daily Call"),
        (&["gather.town", " | gather", " - gather"], "Gather", "Gather"),
        (&["streamyard"], "StreamYard", "StreamYard"),
        (&["cal.com", "cal video"], "Cal Video", "Cal Video"),
        (&["butter.us", " | butter", " - butter"], "Butter", "Butter"),
        (&["livestorm"], "Livestorm", "Livestorm"),
        (&["ringcentral"], "RingCentral", "RingCentral"),
        (&["gotomeeting", "goto meeting"], "GoTo Meeting", "GoTo Meeting"),
        (&["amazon chime"], "Amazon Chime", "Amazon Chime"),
        (&["livekit meet", "meet.livekit"], "LiveKit Meet", "LiveKit Meet"),
        (&["8x8 meet", "8x8.vc"], "8x8 Meet", "8x8 Meet"),
        (&["bigbluebutton"], "BigBlueButton", "BigBlueButton"),
        (&["nextcloud talk"], "Nextcloud Talk", "Nextcloud Talk"),
        (&["element call"], "Element Call", "Element Call"),
        (&["zoho meeting"], "Zoho Meeting", "Zoho Meeting"),
        (&["bluejeans"], "BlueJeans", "BlueJeans"),
        (&["whatsapp"], "WhatsApp", "WhatsApp Call"),
        (&["messenger"], "Messenger", "Messenger Call"),
        (&["telegram web"], "Telegram", "Telegram Call"),
    ];

    for (keywords, source, fallback) in PLATFORMS {
        if keywords.iter().any(|k| lower.contains(k)) {
            let topic = strip_platform_brand(title, source);
            let is_generic = topic.is_empty() || topic.eq_ignore_ascii_case(source);
            return Some(DetectedMeeting {
                id: format!(
                    "{}:{}",
                    source.to_lowercase(),
                    if is_generic { "call".into() } else { topic.to_lowercase() }
                ),
                source: (*source).into(),
                title: if is_generic { (*fallback).into() } else { topic },
                is_generic_title: is_generic,
                high_confidence: true,
            });
        }
    }

    None
}

/* ----------------------------- title cleaning ----------------------------- */

pub fn clean_browser_title(raw: &str) -> String {
    let mut s = strip_leading_badge(raw);

    const BROWSER_SUFFIXES: &[&str] = &[
        " - Google Chrome",
        " — Google Chrome",
        " – Google Chrome",
        " - Chromium",
        " - Brave",
        " — Brave",
        " - Microsoft Edge",
        " - Microsoft\u{200b} Edge",
        " — Mozilla Firefox",
        " - Mozilla Firefox",
        " - Firefox",
        " — Zen Browser",
        " - Zen Browser",
        " — Zen",
        " - Zen",
        " - Opera",
        " - Vivaldi",
        " - Arc",
        " - Floorp",
        " - LibreWolf",
        " - Waterfox",
        " - Comet",
        " - Dia",
        " - Helium",
    ];
    const MEDIA_SUFFIXES: &[&str] = &[
        " - Audio playing",
        " – Audio playing",
        " — Audio playing",
        " - Audio muted",
        " - Using microphone",
        " - Using camera",
        " - Sharing this tab",
        " - Sharing your screen",
        " - High memory usage",
        " - Memory Saver",
        " (Private Browsing)",
        " (Incognito)",
        " [InPrivate]",
    ];

    loop {
        let before = s.clone();
        // Strip Chrome/Edge profile suffix like " - Google Chrome - Work"
        for marker in [" - Google Chrome - ", " - Brave - ", " - Microsoft Edge - "] {
            if let Some(idx) = s.find(marker) {
                s = s[..idx].trim().to_string();
            }
        }
        // Strip Chrome memory badge like " - Memory usage - 142 MB"
        for marker in [" - Memory usage", " – Memory usage"] {
            if let Some(idx) = s.find(marker) {
                s = s[..idx].trim().to_string();
            }
        }
        for suffix in BROWSER_SUFFIXES.iter().chain(MEDIA_SUFFIXES.iter()) {
            if let Some(stripped) = strip_suffix(&s, &[suffix]) {
                s = stripped;
            }
        }
        if s == before {
            break;
        }
    }

    strip_leading_badge(&s)
}

fn strip_leading_badge(raw: &str) -> String {
    let mut s = raw.trim().to_string();
    for prefix in ["• ", "● ", "🔴 ", "🎙️ ", "🔊 ", "🔇 ", "🎥 "] {
        while let Some(rest) = s.strip_prefix(prefix) {
            s = rest.trim().to_string();
        }
    }
    if s.starts_with('(') {
        if let Some(close) = s.find(')') {
            let inside = &s[1..close];
            if !inside.is_empty() && inside.chars().all(|c| c.is_ascii_digit() || c == '+') {
                s = s[close + 1..].trim().to_string();
            }
        }
    }
    s
}

fn strip_suffix(s: &str, suffixes: &[&str]) -> Option<String> {
    let lower = s.to_lowercase();
    for suffix in suffixes {
        let sl = suffix.to_lowercase();
        if lower.ends_with(&sl) && s.len() >= suffix.len() {
            let cut = s.len() - suffix.len();
            if s.is_char_boundary(cut) {
                return Some(s[..cut].trim().to_string());
            }
        }
    }
    None
}

fn strip_prefix_ci<'a>(s: &'a str, prefixes: &[&str]) -> Option<&'a str> {
    let lower = s.to_lowercase();
    for prefix in prefixes {
        if lower.starts_with(prefix) && s.is_char_boundary(prefix.len()) {
            return Some(&s[prefix.len()..]);
        }
    }
    None
}

fn clean_slack_title(raw: &str) -> String {
    let mut s = strip_leading_badge(raw);
    for suffix in [" - Slack", " | Slack"] {
        if let Some(stripped) = strip_suffix(&s, &[suffix]) {
            s = stripped;
        }
    }
    if let Some(rest) = strip_prefix_ci(&s, &["huddle in ", "huddle with ", "huddle - ", "huddle – ", "huddle: "]) {
        s = rest.trim().to_string();
    }
    if s.eq_ignore_ascii_case("huddle") || s.eq_ignore_ascii_case("slack") {
        return String::new();
    }
    s
}

fn strip_platform_brand(title: &str, source: &str) -> String {
    let mut s = title.trim().to_string();
    for sep in [" | ", " - ", " – ", " — "] {
        let suffix = format!("{sep}{source}");
        if let Some(stripped) = strip_suffix(&s, &[&suffix]) {
            s = stripped;
        }
        let prefix = format!("{}{}", source.to_lowercase(), sep);
        if let Some(rest) = strip_prefix_ci(&s, &[&prefix]) {
            s = rest.trim().to_string();
        }
    }
    let trimmed = s.trim();
    if trimmed.eq_ignore_ascii_case("cal.com") {
        return String::new();
    }
    if let Some(stripped) = strip_suffix(trimmed, &[" | Cal.com", " - Cal.com"]) {
        return stripped;
    }
    trimmed.to_string()
}

/// Google Meet codes look like "abc-defg-hij" (3-4-3 lowercase ASCII letters).
pub fn is_google_meet_code(s: &str) -> bool {
    let parts: Vec<&str> = s.trim().split('-').collect();
    parts.len() == 3
        && parts[0].len() == 3
        && parts[1].len() == 4
        && parts[2].len() == 3
        && parts.iter().all(|p| p.chars().all(|c| c.is_ascii_lowercase()))
}

/* -------------------------------- tracker --------------------------------- */

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TrackerAction {
    None,
    Show(DetectedMeeting),
    Update(DetectedMeeting),
    Hide,
}

#[derive(Default)]
pub struct MeetingTracker {
    pub active: Option<DetectedMeeting>,
    pending_id: Option<String>,
    pending_polls: u32,
    dismissed: bool,
    consecutive_misses: u32,
}

impl MeetingTracker {
    pub fn step(&mut self, detected: Option<DetectedMeeting>, suppressed: bool) -> TrackerAction {
        let Some(detected) = detected else {
            self.pending_id = None;
            self.pending_polls = 0;
            self.consecutive_misses += 1;
            if self.consecutive_misses >= 3 {
                let was_active = self.active.is_some();
                self.active = None;
                self.dismissed = false;
                return if was_active { TrackerAction::Hide } else { TrackerAction::None };
            }
            return TrackerAction::None;
        };

        self.consecutive_misses = 0;

        if suppressed {
            let was_active = self.active.is_some();
            self.active = None;
            self.dismissed = true;
            return if was_active { TrackerAction::Hide } else { TrackerAction::None };
        }

        if self.dismissed {
            return TrackerAction::None;
        }

        if let Some(current) = &self.active {
            if current.title != detected.title || current.source != detected.source {
                self.active = Some(detected.clone());
                return TrackerAction::Update(detected);
            }
            return TrackerAction::None;
        }

        if detected.high_confidence {
            self.pending_id = None;
            self.pending_polls = 0;
            self.active = Some(detected.clone());
            return TrackerAction::Show(detected);
        }

        if self.pending_id.as_deref() == Some(detected.id.as_str()) {
            self.pending_polls += 1;
        } else {
            self.pending_id = Some(detected.id.clone());
            self.pending_polls = 1;
        }

        if self.pending_polls >= 2 {
            self.pending_id = None;
            self.pending_polls = 0;
            self.active = Some(detected.clone());
            return TrackerAction::Show(detected);
        }

        TrackerAction::None
    }

    pub fn dismiss(&mut self) {
        self.active = None;
        self.pending_id = None;
        self.pending_polls = 0;
        self.dismissed = true;
    }

    pub fn reset(&mut self) {
        self.active = None;
        self.pending_id = None;
        self.pending_polls = 0;
        self.dismissed = false;
        self.consecutive_misses = 0;
    }
}

/* ----------------------------- runtime state ------------------------------ */

#[derive(Default)]
pub struct MeetingDetectorState {
    tracker: Mutex<MeetingTracker>,
}

impl MeetingDetectorState {
    pub fn current(&self) -> Option<DetectedMeeting> {
        self.tracker.lock().unwrap().active.clone()
    }

    pub fn reset(&self) {
        self.tracker.lock().unwrap().reset();
    }

    pub fn dismiss(&self) {
        self.tracker.lock().unwrap().dismiss();
    }
}

pub fn start_monitor(app: Arc<App>) {
    spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(2));
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        // Let startup settle before first probe.
        interval.tick().await;
        loop {
            interval.tick().await;
            if !app.config().detect_meetings {
                let had_active = {
                    let mut tracker = app.meeting_detect.tracker.lock().unwrap();
                    let had = tracker.active.is_some();
                    tracker.reset();
                    had
                };
                if had_active {
                    shell::hide_meeting_banner(&app.handle);
                }
                continue;
            }

            let suppressed = app.meeting.lock().unwrap().is_active();
            let snapshot = spawn_blocking(probe_system).await.unwrap_or_default();
            let detected = MeetingMatcher::detect(&snapshot);
            let action = app.meeting_detect.tracker.lock().unwrap().step(detected, suppressed);
            match action {
                TrackerAction::Show(meeting) => shell::show_meeting_banner(&app.handle, &meeting),
                TrackerAction::Update(meeting) => shell::update_meeting_banner(&app.handle, &meeting),
                TrackerAction::Hide => shell::hide_meeting_banner(&app.handle),
                TrackerAction::None => {}
            }
        }
    });
}

pub fn apply_enabled(app: &Arc<App>) {
    if !app.config().detect_meetings {
        app.meeting_detect.reset();
        shell::hide_meeting_banner(&app.handle);
    }
}

pub fn dismiss_banner(app: &Arc<App>) {
    app.meeting_detect.dismiss();
    shell::hide_meeting_banner(&app.handle);
}

pub fn start_detected_meeting(app: &Arc<App>) {
    let title = app.meeting_detect.current().map(|m| m.title);
    app.meeting_detect.dismiss();
    shell::hide_meeting_banner(&app.handle);
    if !app.meeting.lock().unwrap().is_active() {
        meeting::reset(app);
        meeting::start_with_title(app, title);
    }
    shell::show_main(app, "meeting");
}

/* ----------------------------- Windows probe ------------------------------ */

#[cfg(target_os = "windows")]
fn probe_system() -> SystemSnapshot {
    use std::collections::{HashMap, HashSet};
    use windows::core::{BOOL, Interface, PWSTR};
    use windows::Win32::Foundation::{CloseHandle, HWND, LPARAM};
    use windows::Win32::Media::Audio::{
        eCapture, eCommunications, eConsole, eRender, AudioSessionStateActive, EDataFlow, ERole, IAudioSessionControl2,
        IAudioSessionManager2, IMMDeviceEnumerator, MMDeviceEnumerator,
    };
    use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_ALL, COINIT_MULTITHREADED};
    use windows::Win32::System::Threading::{
        OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        EnumWindows, GetForegroundWindow, GetWindowTextW, GetWindowThreadProcessId, IsWindowVisible,
    };

    struct ComGuard(bool);
    impl Drop for ComGuard {
        fn drop(&mut self) {
            if self.0 {
                unsafe { CoUninitialize() };
            }
        }
    }

    fn process_name_for_pid(pid: u32) -> Option<String> {
        if pid == 0 {
            return None;
        }
        unsafe {
            let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
            let mut buffer = [0u16; 1024];
            let mut length = buffer.len() as u32;
            let read = QueryFullProcessImageNameW(handle, PROCESS_NAME_WIN32, PWSTR(buffer.as_mut_ptr()), &mut length);
            let _ = CloseHandle(handle);
            read.ok()?;
            let path = String::from_utf16_lossy(&buffer[..length as usize]);
            Some(normalize_process_name(&path))
        }
    }

    fn active_pids(enumerator: &IMMDeviceEnumerator, flow: EDataFlow) -> HashSet<u32> {
        let mut pids = HashSet::new();
        for role in [eCommunications, eConsole] as [ERole; 2] {
            let Ok(device) = (unsafe { enumerator.GetDefaultAudioEndpoint(flow, role) }) else {
                continue;
            };
            let Ok(manager) = (unsafe { device.Activate::<IAudioSessionManager2>(CLSCTX_ALL, None) }) else {
                continue;
            };
            let Ok(sessions) = (unsafe { manager.GetSessionEnumerator() }) else {
                continue;
            };
            let count = unsafe { sessions.GetCount() }.unwrap_or(0);
            for i in 0..count {
                let Ok(control) = (unsafe { sessions.GetSession(i) }) else {
                    continue;
                };
                if unsafe { control.GetState() }.ok() != Some(AudioSessionStateActive) {
                    continue;
                }
                let Ok(control2) = control.cast::<IAudioSessionControl2>() else {
                    continue;
                };
                if let Ok(pid) = unsafe { control2.GetProcessId() } {
                    if pid != 0 {
                        pids.insert(pid);
                    }
                }
            }
        }
        pids
    }

    let self_pid = std::process::id();
    let com_ok = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }.is_ok();
    let _guard = ComGuard(com_ok);

    let Ok(enumerator) = (unsafe { CoCreateInstance::<_, IMMDeviceEnumerator>(&MMDeviceEnumerator, None, CLSCTX_ALL) }) else {
        return SystemSnapshot::default();
    };

    let mut apps_by_name: HashMap<String, AppSnapshot> = HashMap::new();
    let mut pid_cache: HashMap<u32, Option<String>> = HashMap::new();

    for (pids, is_mic) in [(active_pids(&enumerator, eCapture), true), (active_pids(&enumerator, eRender), false)] {
        for pid in pids {
            if pid == self_pid {
                continue;
            }
            let name = pid_cache.entry(pid).or_insert_with(|| process_name_for_pid(pid)).clone();
            let Some(name) = name else {
                continue;
            };
            if !is_relevant_process(&name) {
                continue;
            }
            let entry = apps_by_name.entry(name.clone()).or_insert_with(|| AppSnapshot {
                process_name: name,
                ..AppSnapshot::default()
            });
            if is_mic {
                entry.has_mic = true;
            } else {
                entry.has_output = true;
            }
        }
    }

    // Fast path: no relevant call app or browser has active audio.
    if apps_by_name.is_empty() {
        return SystemSnapshot::default();
    }

    struct EnumCtx<'a> {
        foreground: HWND,
        self_pid: u32,
        pid_cache: &'a mut HashMap<u32, Option<String>>,
        apps_by_name: &'a mut HashMap<String, AppSnapshot>,
    }

    unsafe extern "system" fn enum_proc(hwnd: HWND, lparam: LPARAM) -> BOOL {
        let ctx = &mut *(lparam.0 as *mut EnumCtx<'_>);
        if !IsWindowVisible(hwnd).as_bool() {
            return BOOL(1);
        }
        let mut pid = 0u32;
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
        if pid == 0 || pid == ctx.self_pid {
            return BOOL(1);
        }
        let name = ctx.pid_cache.entry(pid).or_insert_with(|| process_name_for_pid(pid)).clone();
        let Some(name) = name else {
            return BOOL(1);
        };
        let Some(app) = ctx.apps_by_name.get_mut(&name) else {
            return BOOL(1);
        };
        if hwnd == ctx.foreground {
            app.is_frontmost = true;
        }
        let mut buf = [0u16; 512];
        let len = GetWindowTextW(hwnd, &mut buf);
        if len > 0 {
            let title = String::from_utf16_lossy(&buf[..len as usize]).trim().to_string();
            if !title.is_empty() && !app.window_titles.contains(&title) {
                if hwnd == ctx.foreground {
                    app.window_titles.insert(0, title);
                } else {
                    app.window_titles.push(title);
                }
            }
        }
        BOOL(1)
    }

    let foreground = unsafe { GetForegroundWindow() };
    let mut ctx = EnumCtx {
        foreground,
        self_pid,
        pid_cache: &mut pid_cache,
        apps_by_name: &mut apps_by_name,
    };
    unsafe {
        let _ = EnumWindows(Some(enum_proc), LPARAM(&mut ctx as *mut _ as isize));
    }

    SystemSnapshot { apps: apps_by_name.into_values().collect() }
}

/* ------------------------------ Linux probe ------------------------------- */

#[derive(Clone, Debug, PartialEq, Eq)]
struct PactlStream {
    pid: Option<u32>,
    binary: String,
    media_name: Option<String>,
    corked: bool,
}

/// Parses `pactl list source-outputs` or `pactl list sink-inputs` output (both PulseAudio and PipeWire-Pulse).
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn parse_pactl_streams(output: &str) -> Vec<PactlStream> {
    let mut streams = Vec::new();
    let mut current: Option<PactlStream> = None;

    let flush = |streams: &mut Vec<PactlStream>, current: &mut Option<PactlStream>| {
        if let Some(stream) = current.take() {
            if !stream.corked && !stream.binary.is_empty() {
                streams.push(stream);
            }
        }
    };

    for raw_line in output.lines() {
        let line = raw_line.trim();
        if (raw_line.starts_with("Source Output #") || raw_line.starts_with("Sink Input #")) && !raw_line.starts_with(' ') {
            flush(&mut streams, &mut current);
            current = Some(PactlStream { pid: None, binary: String::new(), media_name: None, corked: false });
            continue;
        }
        let Some(stream) = current.as_mut() else {
            continue;
        };
        if let Some(val) = line.strip_prefix("Corked:") {
            stream.corked = val.trim().eq_ignore_ascii_case("yes");
        } else if let Some(val) = line.strip_prefix("application.process.id =") {
            stream.pid = val.trim().trim_matches('"').parse::<u32>().ok();
        } else if let Some(val) = line.strip_prefix("application.process.binary =") {
            stream.binary = normalize_process_name(val);
        } else if let Some(val) = line.strip_prefix("application.name =") {
            if stream.binary.is_empty() {
                stream.binary = normalize_process_name(val);
            }
        } else if let Some(val) = line.strip_prefix("media.name =") {
            let cleaned = val.trim().trim_matches('"').trim().to_string();
            if !cleaned.is_empty() {
                stream.media_name = Some(cleaned);
            }
        }
    }
    flush(&mut streams, &mut current);
    streams
}

#[cfg(target_os = "linux")]
fn probe_system() -> SystemSnapshot {
    use std::collections::HashMap;
    use std::process::{Command, Stdio};

    fn run_pactl(kind: &str) -> Vec<PactlStream> {
        let Ok(output) = Command::new("pactl")
            .args(["list", kind])
            .env("LC_ALL", "C")
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
        else {
            return Vec::new();
        };
        if !output.status.success() {
            return Vec::new();
        }
        parse_pactl_streams(&String::from_utf8_lossy(&output.stdout))
    }

    fn process_name_for_pid(pid: u32) -> Option<String> {
        if let Ok(exe) = std::fs::read_link(format!("/proc/{pid}/exe")) {
            if let Some(name) = exe.file_name().and_then(|n| n.to_str()) {
                return Some(normalize_process_name(name));
            }
        }
        std::fs::read_to_string(format!("/proc/{pid}/comm"))
            .ok()
            .map(|c| normalize_process_name(&c))
            .filter(|c| !c.is_empty())
    }

    let self_pid = std::process::id();
    let mut apps_by_name: HashMap<String, AppSnapshot> = HashMap::new();

    for (streams, is_mic) in [(run_pactl("source-outputs"), true), (run_pactl("sink-inputs"), false)] {
        for stream in streams {
            if stream.pid == Some(self_pid) {
                continue;
            }
            let name = if is_relevant_process(&stream.binary) {
                stream.binary
            } else if let Some(pid) = stream.pid {
                process_name_for_pid(pid).unwrap_or(stream.binary)
            } else {
                stream.binary
            };
            if !is_relevant_process(&name) {
                continue;
            }
            let entry = apps_by_name.entry(name.clone()).or_insert_with(|| AppSnapshot {
                process_name: name,
                ..AppSnapshot::default()
            });
            if is_mic {
                entry.has_mic = true;
            } else {
                entry.has_output = true;
            }
        }
    }

    if apps_by_name.is_empty() {
        return SystemSnapshot::default();
    }

    // Collect window titles over X11 / XWayland when DISPLAY is available.
    collect_x11_windows(&mut apps_by_name, self_pid, process_name_for_pid);

    SystemSnapshot { apps: apps_by_name.into_values().collect() }
}

#[cfg(target_os = "linux")]
fn collect_x11_windows(
    apps_by_name: &mut std::collections::HashMap<String, AppSnapshot>,
    self_pid: u32,
    process_name_for_pid: fn(u32) -> Option<String>,
) {
    use x11rb::connection::Connection;
    use x11rb::protocol::xproto::{AtomEnum, ConnectionExt};

    let Ok((conn, screen_num)) = x11rb::connect(None) else {
        return;
    };
    let root = conn.setup().roots[screen_num].root;

    let intern = |name: &[u8]| conn.intern_atom(false, name).ok().and_then(|c| c.reply().ok()).map(|r| r.atom);
    let Some(net_client_list) = intern(b"_NET_CLIENT_LIST") else { return };
    let Some(net_active_window) = intern(b"_NET_ACTIVE_WINDOW") else { return };
    let Some(net_wm_name) = intern(b"_NET_WM_NAME") else { return };
    let Some(net_wm_pid) = intern(b"_NET_WM_PID") else { return };
    let Some(utf8_string) = intern(b"UTF8_STRING") else { return };

    let active_win = conn
        .get_property(false, root, net_active_window, AtomEnum::WINDOW, 0, 1)
        .ok()
        .and_then(|c| c.reply().ok())
        .and_then(|r| r.value32()?.next());

    let Ok(list_cookie) = conn.get_property(false, root, net_client_list, AtomEnum::WINDOW, 0, 1024) else {
        return;
    };
    let Ok(list_reply) = list_cookie.reply() else {
        return;
    };
    let Some(windows) = list_reply.value32() else {
        return;
    };

    for win in windows {
        let Some(pid) = conn
            .get_property(false, win, net_wm_pid, AtomEnum::CARDINAL, 0, 1)
            .ok()
            .and_then(|c| c.reply().ok())
            .and_then(|r| r.value32()?.next())
        else {
            continue;
        };
        if pid == self_pid {
            continue;
        }
        let Some(name) = process_name_for_pid(pid) else {
            continue;
        };
        let Some(app) = apps_by_name.get_mut(&name) else {
            continue;
        };

        let is_active = active_win == Some(win);
        if is_active {
            app.is_frontmost = true;
        }

        let title = conn
            .get_property(false, win, net_wm_name, utf8_string, 0, 1024)
            .ok()
            .and_then(|c| c.reply().ok())
            .filter(|r| !r.value.is_empty())
            .map(|r| String::from_utf8_lossy(&r.value).trim().to_string())
            .or_else(|| {
                conn.get_property(false, win, AtomEnum::WM_NAME, AtomEnum::STRING, 0, 1024)
                    .ok()
                    .and_then(|c| c.reply().ok())
                    .filter(|r| !r.value.is_empty())
                    .map(|r| String::from_utf8_lossy(&r.value).trim().to_string())
            });

        if let Some(title) = title.filter(|t| !t.is_empty()) {
            if !app.window_titles.contains(&title) {
                if is_active {
                    app.window_titles.insert(0, title);
                } else {
                    app.window_titles.push(title);
                }
            }
        }
    }
}

#[cfg(not(any(target_os = "windows", target_os = "linux")))]
fn probe_system() -> SystemSnapshot {
    SystemSnapshot::default()
}

/* ---------------------------------- tests --------------------------------- */

#[cfg(test)]
mod tests {
    use super::*;

    fn snap(apps: Vec<AppSnapshot>) -> SystemSnapshot {
        SystemSnapshot { apps }
    }

    #[test]
    fn detects_google_meet_code_and_named_meeting_on_windows_and_linux() {
        let code_call = snap(vec![AppSnapshot {
            process_name: "chrome.exe".into(),
            window_titles: vec!["Meet – abc-defg-hij - Google Chrome".into()],
            is_frontmost: true,
            has_mic: true,
            has_output: true,
        }]);
        let m = MeetingMatcher::detect(&code_call).unwrap();
        assert_eq!(m.source, "Google Meet");
        assert_eq!(m.title, "Google Meet");
        assert!(m.is_generic_title);
        assert!(m.high_confidence);

        let named_call = snap(vec![AppSnapshot {
            process_name: "google-chrome".into(),
            window_titles: vec!["Meet - Q4 Product Review - Google Chrome - Work".into()],
            is_frontmost: false,
            has_mic: true,
            has_output: true,
        }]);
        let m = MeetingMatcher::detect(&named_call).unwrap();
        assert_eq!(m.source, "Google Meet");
        assert_eq!(m.title, "Q4 Product Review");
        assert!(!m.is_generic_title);
    }

    #[test]
    fn detects_native_call_apps_on_windows_and_linux() {
        let zoom = snap(vec![AppSnapshot {
            process_name: "Zoom.exe".into(),
            window_titles: vec!["Zoom Workplace".into(), "Weekly All-Hands".into()],
            is_frontmost: true,
            has_mic: true,
            has_output: true,
        }]);
        let m = MeetingMatcher::detect(&zoom).unwrap();
        assert_eq!(m.source, "Zoom");
        assert_eq!(m.title, "Weekly All-Hands");

        let teams = snap(vec![AppSnapshot {
            process_name: "ms-teams.exe".into(),
            window_titles: vec!["Sprint Planning | Microsoft Teams".into()],
            is_frontmost: false,
            has_mic: true,
            has_output: true,
        }]);
        let m = MeetingMatcher::detect(&teams).unwrap();
        assert_eq!(m.source, "Microsoft Teams");
        assert_eq!(m.title, "Sprint Planning");

        let slack = snap(vec![AppSnapshot {
            process_name: "slack".into(),
            window_titles: vec!["Huddle in #engineering - Slack".into()],
            is_frontmost: false,
            has_mic: true,
            has_output: true,
        }]);
        let m = MeetingMatcher::detect(&slack).unwrap();
        assert_eq!(m.source, "Slack Huddle");
        assert_eq!(m.title, "#engineering");

        let discord = snap(vec![AppSnapshot {
            process_name: "discord".into(),
            window_titles: vec!["#standup | Team - Discord".into()],
            is_frontmost: false,
            has_mic: true,
            has_output: true,
        }]);
        let m = MeetingMatcher::detect(&discord).unwrap();
        assert_eq!(m.source, "Discord");
        assert_eq!(m.title, "#standup | Team");
    }

    #[test]
    fn detects_known_web_platforms_across_browsers() {
        let cases = [
            ("msedge.exe", "Weekly Retro - Whereby - Microsoft Edge", "Whereby", "Weekly Retro"),
            ("firefox", "Design Sync | Jitsi Meet — Mozilla Firefox", "Jitsi Meet", "Design Sync"),
            ("brave-browser", "Podcast Ep 12 - Riverside - Brave", "Riverside", "Podcast Ep 12"),
            ("zen-bin", "Intro Call | Cal.com — Zen Browser", "Cal Video", "Intro Call"),
        ];
        for (proc_name, title, expected_source, expected_title) in cases {
            let s = snap(vec![AppSnapshot {
                process_name: proc_name.into(),
                window_titles: vec![title.into()],
                is_frontmost: true,
                has_mic: true,
                has_output: true,
            }]);
            let m = MeetingMatcher::detect(&s).unwrap();
            assert_eq!(m.source, expected_source);
            assert_eq!(m.title, expected_title);
        }
    }

    #[test]
    fn universal_webrtc_fallback_and_exclusions() {
        let custom = snap(vec![AppSnapshot {
            process_name: "chrome".into(),
            window_titles: vec!["Investor Call - AcmeMeet - Google Chrome".into()],
            is_frontmost: true,
            has_mic: true,
            has_output: true,
        }]);
        let m = MeetingMatcher::detect(&custom).unwrap();
        assert_eq!(m.source, "Google Chrome");
        assert_eq!(m.title, "Investor Call - AcmeMeet");
        assert!(!m.high_confidence);

        for excluded in ["ChatGPT - Google Chrome", "Claude - Brave", "YouTube - Music Mix - Firefox", "Loom Recording - Microsoft Edge"] {
            let s = snap(vec![AppSnapshot {
                process_name: "chrome".into(),
                window_titles: vec![excluded.into()],
                is_frontmost: true,
                has_mic: true,
                has_output: true,
            }]);
            assert!(MeetingMatcher::detect(&s).is_none(), "should exclude {excluded}");
        }
    }

    #[test]
    fn pure_wayland_browser_fallback_when_no_x11_titles() {
        let s = snap(vec![AppSnapshot {
            process_name: "firefox".into(),
            window_titles: vec![],
            is_frontmost: false,
            has_mic: true,
            has_output: true,
        }]);
        let m = MeetingMatcher::detect(&s).unwrap();
        assert_eq!(m.source, "Firefox");
        assert_eq!(m.title, "Firefox Meeting");
        assert!(m.is_generic_title);
        assert!(!m.high_confidence);
    }

    #[test]
    fn parses_pactl_pipewire_and_pulseaudio_streams() {
        let sample = r#"
Source Output #42
	Driver: PipeWire
	Owner Module: n/a
	Client: 38
	Source: 1
	Corked: no
	Properties:
		media.name = "RecordStream"
		application.name = "Google Chrome input"
		application.process.id = "12345"
		application.process.binary = "chrome"

Source Output #43
	Driver: PipeWire
	Corked: yes
	Properties:
		application.process.id = "9999"
		application.process.binary = "discord"
"#;
        let streams = parse_pactl_streams(sample);
        assert_eq!(streams.len(), 1);
        assert_eq!(streams[0].pid, Some(12345));
        assert_eq!(streams[0].binary, "chrome");
        assert!(!streams[0].corked);
    }

    #[test]
    fn tracker_debounce_update_dismiss_reset_and_suppression() {
        let mut tracker = MeetingTracker::default();
        let generic = DetectedMeeting {
            id: "google-meet:abc-defg-hij".into(),
            source: "Google Meet".into(),
            title: "Google Meet".into(),
            is_generic_title: true,
            high_confidence: true,
        };
        let named = DetectedMeeting {
            id: "google-meet:standup".into(),
            source: "Google Meet".into(),
            title: "Standup".into(),
            is_generic_title: false,
            high_confidence: true,
        };
        assert_eq!(tracker.step(Some(generic.clone()), false), TrackerAction::Show(generic.clone()));
        assert_eq!(tracker.step(Some(named.clone()), false), TrackerAction::Update(named.clone()));
        assert_eq!(tracker.step(None, false), TrackerAction::None);
        assert_eq!(tracker.step(None, false), TrackerAction::None);
        tracker.dismiss();
        assert_eq!(tracker.step(Some(named.clone()), false), TrackerAction::None);
        assert_eq!(tracker.step(None, false), TrackerAction::None);
        assert_eq!(tracker.step(None, false), TrackerAction::None);
        assert_eq!(tracker.step(None, false), TrackerAction::None);
        assert_eq!(tracker.step(Some(named.clone()), false), TrackerAction::Show(named.clone()));
        assert_eq!(tracker.step(Some(named.clone()), true), TrackerAction::Hide);
        assert_eq!(tracker.step(Some(named), false), TrackerAction::None);
    }

    #[test]
    fn tracker_requires_two_polls_for_low_confidence() {
        let mut tracker = MeetingTracker::default();
        let low = DetectedMeeting {
            id: "web:chrome:call".into(),
            source: "Google Chrome".into(),
            title: "Custom Call".into(),
            is_generic_title: false,
            high_confidence: false,
        };
        assert_eq!(tracker.step(Some(low.clone()), false), TrackerAction::None);
        assert_eq!(tracker.step(Some(low.clone()), false), TrackerAction::Show(low));
    }
}
