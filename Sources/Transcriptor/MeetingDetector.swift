import AppKit
import ApplicationServices
import CoreAudio
import Darwin
import Foundation

// Watches for active meetings across native call apps and browsers without
// requiring AppleScript or Screen Recording permissions. CoreAudio tells us
// which process is actually using the microphone or speakers; Accessibility
// (which Transcriptor already holds) gives us window and browser tab titles
// so we know what the meeting is called and can carry the title straight into
// the transcription.

struct DetectedMeeting: Equatable, Sendable {
    /// Stable identity for this meeting (used to remember dismissals).
    let id: String
    /// Platform name shown in the banner (e.g. "Google Meet", "Zoom", "Slack Huddle").
    let source: String
    /// Extracted meeting title, ready to edit or save with the transcript.
    let title: String
    /// True when the title is just a generic fallback like "Google Meet".
    let isGenericTitle: Bool
    /// High-confidence detections (explicit meeting + active mic) appear immediately.
    let highConfidence: Bool
}

struct AppSnapshot: Equatable, Sendable {
    let bundleID: String
    let name: String
    let windowTitles: [String]
    let tabTitles: [String]
    let isFrontmost: Bool
    let hasMic: Bool
    let hasOutput: Bool

    init(bundleID: String, name: String, windowTitles: [String] = [], tabTitles: [String] = [],
         isFrontmost: Bool = false, hasMic: Bool = false, hasOutput: Bool = false) {
        self.bundleID = bundleID
        self.name = name
        self.windowTitles = windowTitles
        self.tabTitles = tabTitles
        self.isFrontmost = isFrontmost
        self.hasMic = hasMic
        self.hasOutput = hasOutput
    }
}

struct SystemSnapshot: Equatable, Sendable {
    let apps: [AppSnapshot]
    /// Fallback for macOS 13–14.1 where per-process CoreAudio status is unavailable.
    let globalMicActive: Bool
    let supportsPerProcessAudio: Bool

    init(apps: [AppSnapshot], globalMicActive: Bool = false, supportsPerProcessAudio: Bool = true) {
        self.apps = apps
        self.globalMicActive = globalMicActive
        self.supportsPerProcessAudio = supportsPerProcessAudio
    }
}

// MARK: - Pure classification & title extraction

enum MeetingMatcher {
    static let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta", "com.google.Chrome.dev",
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "company.thebrowser.Browser", "company.thebrowser.dia",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly", "app.zen-browser.zen",
        "com.operasoftware.Opera", "com.operasoftware.OperaGX",
        "com.vivaldi.Vivaldi", "com.kagi.kagimacOS", "org.chromium.Chromium",
        "com.openai.atlas", "ai.perplexity.comet", "net.imput.helium", "com.sigmaos.sigmaos.macos",
    ]

    private static let webAppBundlePrefixes: [String] = [
        "com.google.Chrome.app.",
        "com.apple.Safari.WebApp.",
        "com.brave.Browser.app.",
        "com.microsoft.edgemac.app.",
        "company.thebrowser.Browser.app.",
    ]

    static func isBrowserBundleID(_ bundleID: String) -> Bool {
        browserBundleIDs.contains(bundleID)
            || webAppBundlePrefixes.contains { bundleID.hasPrefix($0) }
    }

    static let nativeCallBundleIDs: Set<String> = [
        "us.zoom.xos", "us.zoom.videomeetings",
        "com.microsoft.teams2", "com.microsoft.teams",
        "com.tinyspeck.slackmacgap",
        "com.apple.FaceTime", "com.apple.avconferenced", "com.apple.TelephonyUtilities",
        "com.hnc.Discord", "com.hnc.DiscordPTB", "com.hnc.DiscordCanary",
        "Cisco-Systems.Spark", "com.cisco.webexmeetingsapp", "com.webex.meetingmanager",
        "net.whatsapp.WhatsApp", "desktop.WhatsApp",
        "ru.keepcoder.Telegram", "org.telegram.desktop",
        "org.whispersystems.signal-desktop",
        "com.facebook.archon", "com.facebook.Messenger", "com.viber.osx",
        "com.larksuite.Lark", "com.electron.lark", "im.riot.app",
        "com.figma.Desktop",
        "app.tuple.app", "com.gather.GatherV2", "com.amazon.Amazon-Chime",
        "com.ringcentral.glip", "com.ringcentral.rcapp",
        "com.logmein.goto", "com.logmein.GoToMeeting",
        "com.skype.skype", "co.around.Around", "chat.tandem.Tandem", "com.pop.pop.app",
    ]

    /// Apps/sites that often use the mic or speakers but are not meetings.
    private static let excludedWebKeywords: [String] = [
        "chatgpt", "claude", "gemini", "perplexity", "grok", "notebooklm",
        "youtube", "spotify", "apple music", "soundcloud", "twitch", "netflix",
        "voice memos", "duolingo", "loom", "descript", "suno", "elevenlabs",
        "audacity", "soundtrap", "bandlab", "transcriptor", "dictation",
    ]

    static func detect(in snapshot: SystemSnapshot) -> DetectedMeeting? {
        // 1. FaceTime / Continuity calls run audio inside avconferenced or TelephonyUtilities.
        if let facetime = matchFaceTime(in: snapshot, requireDaemon: !snapshot.supportsPerProcessAudio) {
            return facetime
        }

        // 2. Prefer apps with active mic input first, then known meeting apps with output.
        let ordered = snapshot.apps.sorted { a, b in
            if a.hasMic != b.hasMic { return a.hasMic }
            if a.isFrontmost != b.isFrontmost { return a.isFrontmost }
            return a.hasOutput && !b.hasOutput
        }

        // On macOS 14.2+ per-process audio tells us the exact app using the mic.
        if snapshot.supportsPerProcessAudio {
            for app in ordered {
                if app.bundleID == "com.transcriptor.app" { continue }
                if let native = matchNative(app, snapshot: snapshot) { return native }
                if isBrowserBundleID(app.bundleID),
                   let web = matchBrowser(app, snapshot: snapshot) { return web }
            }
            return nil
        }

        // On macOS 13–14.1 we only know a mic is globally active, so prefer apps
        // with an explicit meeting window/tab before falling back to an idle native app.
        var best: (rank: Int, meeting: DetectedMeeting)?
        func consider(_ meeting: DetectedMeeting, app: AppSnapshot, explicitWeb: Bool) {
            let rank = (explicitWeb || !meeting.isGenericTitle ? 4 : 0)
                + (app.isFrontmost ? 2 : 0)
                + (meeting.highConfidence ? 1 : 0)
            if best == nil || rank > best!.rank {
                best = (rank, meeting)
            }
        }

        if let ft = matchFaceTime(in: snapshot, requireDaemon: false),
           let ftApp = snapshot.apps.first(where: { $0.bundleID == "com.apple.FaceTime" }) {
            consider(ft, app: ftApp, explicitWeb: false)
        }
        for app in ordered {
            if app.bundleID == "com.transcriptor.app" { continue }
            if let native = matchNative(app, snapshot: snapshot) {
                consider(native, app: app, explicitWeb: false)
            } else if isBrowserBundleID(app.bundleID),
                      let web = matchBrowser(app, snapshot: snapshot) {
                consider(web, app: app, explicitWeb: web.highConfidence)
            }
        }
        return best?.meeting
    }

    // MARK: Native apps

    private static func matchFaceTime(in snapshot: SystemSnapshot, requireDaemon: Bool = false) -> DetectedMeeting? {
        let daemonActive = snapshot.apps.contains {
            ($0.bundleID == "com.apple.avconferenced" || $0.bundleID == "com.apple.TelephonyUtilities") && $0.hasMic
        }
        let app = snapshot.apps.first { $0.bundleID == "com.apple.FaceTime" }
        let appActive = !requireDaemon && ((app?.hasMic ?? false) || (!snapshot.supportsPerProcessAudio && snapshot.globalMicActive && app != nil))
        guard daemonActive || appActive else { return nil }

        let specific = app?.windowTitles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0.caseInsensitiveCompare("FaceTime") != .orderedSame }
        let title = specific ?? "FaceTime"
        return DetectedMeeting(
            id: "facetime:\(title.lowercased())",
            source: "FaceTime",
            title: title,
            isGenericTitle: specific == nil,
            highConfidence: true
        )
    }

    private static func matchNative(_ app: AppSnapshot, snapshot: SystemSnapshot) -> DetectedMeeting? {
        let mic = app.hasMic || (!snapshot.supportsPerProcessAudio && snapshot.globalMicActive)

        switch app.bundleID {
        case "us.zoom.xos", "us.zoom.videomeetings":
            let lobby: Set<String> = [
                "zoom", "zoom workplace", "zoom cloud meetings", "settings", "zoom settings",
                "team chat", "chat", "meeting chat", "participants", "polls", "home",
                "zoom share statusbar window", "",
            ]
            let titles = app.windowTitles.map { stripLeadingBadge($0) }
            let meetingWindow = titles.first { lower in
                let l = lower.lowercased()
                return l.contains("zoom meeting") || l.contains("zoom webinar")
            }
            let topic = titles.first { t in
                let l = t.lowercased()
                return !lobby.contains(l) && !l.hasPrefix("zoom meeting") && !l.hasPrefix("zoom webinar")
            }
            guard mic || (app.hasOutput && meetingWindow != nil) else { return nil }
            if !mic && !app.hasOutput { return nil }
            let title = topic ?? (meetingWindow?.lowercased().contains("webinar") == true ? "Zoom Webinar" : "Zoom Meeting")
            return DetectedMeeting(
                id: "zoom:\(title.lowercased())",
                source: "Zoom",
                title: title,
                isGenericTitle: topic == nil,
                highConfidence: mic || meetingWindow != nil
            )

        case "com.microsoft.teams2", "com.microsoft.teams":
            let lobby: Set<String> = [
                "chat", "activity", "calendar", "teams", "calls", "files", "apps",
                "microsoft teams", "meeting compact view", "meet", "",
            ]
            let candidates = app.windowTitles
                .map { stripLeadingBadge($0) }
                .compactMap { stripSuffix($0, suffixes: [" | Microsoft Teams", " - Microsoft Teams"]) }
            let specific = candidates.first { !lobby.contains($0.lowercased()) }
            guard mic || (app.hasOutput && specific != nil) else { return nil }
            let title = specific ?? "Microsoft Teams"
            return DetectedMeeting(
                id: "teams:\(title.lowercased())",
                source: "Microsoft Teams",
                title: title,
                isGenericTitle: specific == nil,
                highConfidence: mic
            )

        case "com.tinyspeck.slackmacgap":
            let huddleWindow = app.windowTitles.first { $0.localizedCaseInsensitiveContains("huddle") }
            guard mic || (app.hasOutput && huddleWindow != nil) else { return nil }
            let cleaned = huddleWindow.map { cleanSlackTitle($0) }
            let title = (cleaned?.isEmpty == false) ? cleaned! : "Slack Huddle"
            return DetectedMeeting(
                id: "slack:\(title.lowercased())",
                source: "Slack Huddle",
                title: title,
                isGenericTitle: cleaned == nil,
                highConfidence: mic || huddleWindow != nil
            )

        case "com.hnc.Discord", "com.hnc.DiscordPTB", "com.hnc.DiscordCanary":
            guard mic else { return nil }
            let specific = app.windowTitles
                .map { stripLeadingBadge($0) }
                .compactMap { stripSuffix($0, suffixes: [" - Discord"]) }
                .first { !$0.isEmpty && $0.caseInsensitiveCompare("Discord") != .orderedSame }
            let title = specific ?? "Discord Call"
            return DetectedMeeting(
                id: "discord:\(title.lowercased())",
                source: "Discord",
                title: title,
                isGenericTitle: specific == nil,
                highConfidence: true
            )

        case "Cisco-Systems.Spark", "com.cisco.webexmeetingsapp", "com.webex.meetingmanager":
            let meetingWindow = app.windowTitles.first { $0.localizedCaseInsensitiveContains("meeting") }
            guard mic || (app.hasOutput && meetingWindow != nil) else { return nil }
            let specific = app.windowTitles
                .map { stripLeadingBadge($0) }
                .compactMap { stripSuffix($0, suffixes: [" - Cisco Webex Meetings", " - Webex", " | Webex"]) }
                .first { !$0.isEmpty && $0.caseInsensitiveCompare("Webex") != .orderedSame }
            let title = specific ?? "Webex Meeting"
            return DetectedMeeting(
                id: "webex:\(title.lowercased())",
                source: "Webex",
                title: title,
                isGenericTitle: specific == nil,
                highConfidence: mic
            )

        case "net.whatsapp.WhatsApp", "desktop.WhatsApp":
            guard mic else { return nil }
            return simpleNative(id: "whatsapp", source: "WhatsApp", fallback: "WhatsApp Call", titles: app.windowTitles, ignore: ["WhatsApp"])

        case "ru.keepcoder.Telegram", "org.telegram.desktop":
            guard mic else { return nil }
            return simpleNative(id: "telegram", source: "Telegram", fallback: "Telegram Call", titles: app.windowTitles, ignore: ["Telegram"])

        case "org.whispersystems.signal-desktop":
            guard mic else { return nil }
            return simpleNative(id: "signal", source: "Signal", fallback: "Signal Call", titles: app.windowTitles, ignore: ["Signal"])

        case "com.facebook.archon", "com.facebook.Messenger":
            guard mic else { return nil }
            return simpleNative(id: "messenger", source: "Messenger", fallback: "Messenger Call", titles: app.windowTitles, ignore: ["Messenger"])

        case "com.viber.osx":
            guard mic else { return nil }
            return simpleNative(id: "viber", source: "Viber", fallback: "Viber Call", titles: app.windowTitles, ignore: ["Viber"])

        case "com.larksuite.Lark", "com.electron.lark":
            guard mic else { return nil }
            return simpleNative(id: "lark", source: "Lark", fallback: "Lark Meeting", titles: app.windowTitles, ignore: ["Lark", "Feishu"])

        case "im.riot.app":
            guard mic else { return nil }
            return simpleNative(id: "element", source: "Element", fallback: "Element Call", titles: app.windowTitles, ignore: ["Element"])

        case "com.figma.Desktop":
            guard mic else { return nil }
            return simpleNative(id: "figma", source: "Figma Audio", fallback: "Figma Audio", titles: app.windowTitles, ignore: ["Figma"])

        case "app.tuple.app":
            guard mic else { return nil }
            return simpleNative(id: "tuple", source: "Tuple", fallback: "Tuple Call", titles: app.windowTitles, ignore: ["Tuple"])

        case "com.gather.GatherV2":
            guard mic else { return nil }
            return simpleNative(id: "gather", source: "Gather", fallback: "Gather", titles: app.windowTitles, ignore: ["Gather"])

        case "com.amazon.Amazon-Chime":
            guard mic else { return nil }
            return simpleNative(id: "chime", source: "Amazon Chime", fallback: "Amazon Chime", titles: app.windowTitles, ignore: ["Amazon Chime"])

        case "com.ringcentral.glip", "com.ringcentral.rcapp":
            guard mic else { return nil }
            return simpleNative(id: "ringcentral", source: "RingCentral", fallback: "RingCentral", titles: app.windowTitles, ignore: ["RingCentral"])

        case "com.logmein.goto", "com.logmein.GoToMeeting":
            guard mic else { return nil }
            return simpleNative(id: "goto", source: "GoTo Meeting", fallback: "GoTo Meeting", titles: app.windowTitles, ignore: ["GoTo", "GoTo Meeting"])

        case "com.skype.skype":
            guard mic else { return nil }
            return simpleNative(id: "skype", source: "Skype", fallback: "Skype Call", titles: app.windowTitles, ignore: ["Skype"])

        case "co.around.Around":
            guard mic else { return nil }
            return simpleNative(id: "around", source: "Around", fallback: "Around", titles: app.windowTitles, ignore: ["Around"])

        case "chat.tandem.Tandem":
            guard mic else { return nil }
            return simpleNative(id: "tandem", source: "Tandem", fallback: "Tandem", titles: app.windowTitles, ignore: ["Tandem"])

        case "com.pop.pop.app":
            guard mic else { return nil }
            return simpleNative(id: "pop", source: "Pop", fallback: "Pop Call", titles: app.windowTitles, ignore: ["Pop"])

        default:
            return nil
        }
    }

    private static func simpleNative(id: String, source: String, fallback: String,
                                     titles: [String], ignore: [String]) -> DetectedMeeting {
        let ignored = Set(ignore.map { $0.lowercased() })
        let specific = titles
            .map { stripLeadingBadge($0) }
            .first { !$0.isEmpty && !ignored.contains($0.lowercased()) }
        let title = specific ?? fallback
        return DetectedMeeting(
            id: "\(id):\(title.lowercased())",
            source: source,
            title: title,
            isGenericTitle: specific == nil,
            highConfidence: true
        )
    }

    // MARK: Browsers

    private static func matchBrowser(_ app: AppSnapshot, snapshot: SystemSnapshot) -> DetectedMeeting? {
        let mic = app.hasMic || (!snapshot.supportsPerProcessAudio && snapshot.globalMicActive)
        let activeAudio = mic || app.hasOutput
        guard activeAudio else { return nil }

        // Check active window titles first, then background tabs with a live media badge,
        // then remaining background tabs (only when mic is active so a stale silent tab
        // cannot trigger while YouTube plays).
        let activeCandidates = app.windowTitles.map { (raw: $0, isActiveWindow: true) }
        let badgedTabs = app.tabTitles
            .filter { hasBrowserMediaBadge($0) }
            .map { (raw: $0, isActiveWindow: false) }
        let otherTabs = app.tabTitles
            .filter { !hasBrowserMediaBadge($0) }
            .map { (raw: $0, isActiveWindow: false) }

        for candidate in activeCandidates + badgedTabs + otherTabs {
            let tabHasMediaBadge = hasBrowserMediaBadge(candidate.raw)
            if !mic && !candidate.isActiveWindow && !tabHasMediaBadge { continue }
            let cleaned = cleanBrowserTitle(candidate.raw)
            if let match = matchWebService(cleaned, micActive: mic) {
                return match
            }
        }

        // Universal fallback: two-way audio (both mic AND output) in a browser catches
        // every other WebRTC meeting tool (Cal.com, LiveKit, custom corporate calls, etc.).
        if app.hasMic && app.hasOutput {
            let preferred = app.tabTitles.first(where: { hasBrowserMediaBadge($0) })
                ?? app.windowTitles.first
            if let raw = preferred {
                let cleaned = cleanBrowserTitle(raw)
                if !cleaned.isEmpty && !isExcludedWebTitle(cleaned) {
                    return DetectedMeeting(
                        id: "web:\(app.bundleID):\(cleaned.lowercased())",
                        source: app.name,
                        title: cleaned,
                        isGenericTitle: false,
                        highConfidence: false
                    )
                }
            }
        }
        return nil
    }

    static func matchWebService(_ title: String, micActive: Bool) -> DetectedMeeting? {
        guard !title.isEmpty else { return nil }
        let lower = title.lowercased()

        // Google Meet: "Meet – Weekly Sync", "Meet - abc-defg-hij", "Google Meet – Standup"
        for prefix in ["Meet – ", "Meet - ", "Meet — ", "Google Meet – ", "Google Meet - ", "Google Meet — "] {
            if let range = title.range(of: prefix, options: [.anchored, .caseInsensitive]) {
                let rest = String(title[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rest.isEmpty else { continue }
                let isCode = isGoogleMeetCode(rest)
                return DetectedMeeting(
                    id: "google-meet:\(rest.lowercased())",
                    source: "Google Meet",
                    title: isCode ? "Google Meet" : rest,
                    isGenericTitle: isCode,
                    highConfidence: micActive
                )
            }
        }

        // Microsoft Teams Web
        if let base = stripSuffix(title, suffixes: [" | Microsoft Teams", " - Microsoft Teams"]) {
            let lobby: Set<String> = ["chat", "activity", "calendar", "teams", "calls", "files", "sign in", "microsoft teams", ""]
            if !lobby.contains(base.lowercased()) {
                return DetectedMeeting(
                    id: "teams-web:\(base.lowercased())",
                    source: "Microsoft Teams",
                    title: base,
                    isGenericTitle: false,
                    highConfidence: micActive
                )
            }
        }

        // Zoom Web
        if lower == "zoom meeting" || lower == "zoom webinar" {
            return DetectedMeeting(
                id: "zoom-web:\(lower)",
                source: "Zoom",
                title: lower == "zoom webinar" ? "Zoom Webinar" : "Zoom Meeting",
                isGenericTitle: true,
                highConfidence: micActive
            )
        }
        if let base = stripSuffix(title, suffixes: [" - Zoom", " | Zoom"]) {
            let ignored = ["sign in", "my account", "download center", "plans & pricing", "meetings", "join a meeting", "zoom"]
            if !base.isEmpty && !ignored.contains(where: { base.lowercased().contains($0) }) && micActive {
                return DetectedMeeting(
                    id: "zoom-web:\(base.lowercased())",
                    source: "Zoom",
                    title: base,
                    isGenericTitle: false,
                    highConfidence: true
                )
            }
        }

        // Slack Huddle Web
        if lower.contains("huddle") && lower.contains("slack") {
            let cleaned = cleanSlackTitle(title)
            let name = cleaned.isEmpty ? "Slack Huddle" : cleaned
            return DetectedMeeting(
                id: "slack-web:\(name.lowercased())",
                source: "Slack Huddle",
                title: name,
                isGenericTitle: cleaned.isEmpty,
                highConfidence: micActive
            )
        }

        // Whereby
        if let base = stripSuffix(title, suffixes: [" - Whereby", " | Whereby"]), !base.isEmpty {
            let ignored = ["pricing", "sign in", "login", "video calls"]
            if !ignored.contains(where: { base.lowercased().contains($0) }) {
                return DetectedMeeting(
                    id: "whereby:\(base.lowercased())",
                    source: "Whereby",
                    title: base,
                    isGenericTitle: false,
                    highConfidence: micActive
                )
            }
        }

        // Jitsi Meet
        if lower == "jitsi meet" || lower.hasSuffix(" | jitsi meet") || lower.hasSuffix(" - jitsi meet") {
            let base = stripSuffix(title, suffixes: [" | Jitsi Meet", " - Jitsi Meet"])
            let name = (base?.isEmpty == false && base?.lowercased() != "jitsi meet") ? base! : "Jitsi Meet"
            return DetectedMeeting(
                id: "jitsi:\(name.lowercased())",
                source: "Jitsi Meet",
                title: name,
                isGenericTitle: name == "Jitsi Meet",
                highConfidence: micActive
            )
        }

        // Mic-confirmed web meeting platforms (prevents matching docs/marketing pages).
        guard micActive else { return nil }

        // Standalone Google Meet PWA or PiP window while mic is live.
        if lower == "google meet" || lower == "meet" {
            return DetectedMeeting(
                id: "google-meet:generic",
                source: "Google Meet",
                title: "Google Meet",
                isGenericTitle: true,
                highConfidence: true
            )
        }

        let micServices: [(suffixes: [String], source: String, idPrefix: String)] = [
            ([" - Discord", " | Discord"], "Discord", "discord-web"),
            ([" - Webex", " | Webex", " - Cisco Webex"], "Webex", "webex-web"),
            ([" - Riverside", " | Riverside", " - Riverside.fm"], "Riverside", "riverside"),
            ([" - Daily", " | Daily"], "Daily", "daily"),
            ([" | Gather", " - Gather"], "Gather", "gather-web"),
            ([" - StreamYard", " | StreamYard"], "StreamYard", "streamyard"),
            ([" | Cal.com", " - Cal.com", " | Cal Video"], "Cal Video", "cal-video"),
            ([" - Butter", " | Butter"], "Butter", "butter"),
            ([" - Livestorm", " | Livestorm"], "Livestorm", "livestorm"),
            ([" - RingCentral", " | RingCentral"], "RingCentral", "ringcentral-web"),
            ([" - GoTo Meeting", " | GoTo"], "GoTo Meeting", "goto-web"),
            ([" - Amazon Chime", " | Amazon Chime"], "Amazon Chime", "chime-web"),
            ([" - LiveKit Meet", " | LiveKit"], "LiveKit", "livekit"),
            ([" | 8x8 Meet", " - 8x8 Meet", " - 8x8.vc"], "8x8 Meet", "8x8"),
            ([" - BigBlueButton", " | BigBlueButton"], "BigBlueButton", "bbb"),
            ([" - Nextcloud Talk", " | Nextcloud Talk"], "Nextcloud Talk", "nextcloud"),
            ([" - Element Call", " | Element Call"], "Element Call", "element-web"),
            ([" - Zoho Meeting", " | Zoho Meeting"], "Zoho Meeting", "zoho"),
            ([" - BlueJeans", " | BlueJeans"], "BlueJeans", "bluejeans"),
        ]

        for service in micServices {
            if let base = stripSuffix(title, suffixes: service.suffixes) {
                let name = base.isEmpty ? service.source : base
                return DetectedMeeting(
                    id: "\(service.idPrefix):\(name.lowercased())",
                    source: service.source,
                    title: name,
                    isGenericTitle: base.isEmpty,
                    highConfidence: true
                )
            }
        }

        if lower.hasPrefix("discord | ") {
            let rest = String(title.dropFirst("Discord | ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            let name = rest.isEmpty ? "Discord Call" : rest
            return DetectedMeeting(
                id: "discord-web:\(name.lowercased())",
                source: "Discord",
                title: name,
                isGenericTitle: rest.isEmpty,
                highConfidence: true
            )
        }

        if lower == "whatsapp" || lower == "whatsapp web" {
            return DetectedMeeting(id: "whatsapp-web:call", source: "WhatsApp", title: "WhatsApp Call", isGenericTitle: true, highConfidence: true)
        }
        if lower == "messenger" || lower.hasSuffix(" | messenger") {
            let base = stripSuffix(title, suffixes: [" | Messenger"])
            let name = (base?.isEmpty == false) ? base! : "Messenger Call"
            return DetectedMeeting(id: "messenger-web:\(name.lowercased())", source: "Messenger", title: name, isGenericTitle: base == nil, highConfidence: true)
        }
        if lower == "telegram" || lower == "telegram web" {
            return DetectedMeeting(id: "telegram-web:call", source: "Telegram", title: "Telegram Call", isGenericTitle: true, highConfidence: true)
        }

        return nil
    }

    // MARK: Title normalization helpers

    static func cleanBrowserTitle(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        let tabBadges = [
            " - High memory usage",
            " - Audio playing",
            " - Audio muted",
            " - Camera or microphone recording",
            " - Microphone recording",
            " - Camera recording",
            " - Sharing this tab",
            " - Sharing this window",
            " - Sharing your screen",
            " - Tab is using microphone",
            " - Tab is using camera",
        ]
        let profileBrowsers = ["Google Chrome", "Brave", "Microsoft Edge", "Chromium", "Vivaldi", "Opera", "Arc", "Dia"]
        let simpleBrowsers = [
            " — Mozilla Firefox", " - Mozilla Firefox", " — Firefox", " - Firefox",
            " - Safari", " - Orion", " - Zen Browser", " — Zen Browser",
            " - ChatGPT Atlas", " - Comet", " - Helium",
        ]

        // Strip browser suffixes, memory usage, and tab indicators in any order.
        var changed = true
        while changed {
            changed = false
            for browser in profileBrowsers {
                let pattern = #"\s+[-–—]\s+\#(NSRegularExpression.escapedPattern(for: browser))(?:\s+[-–—]\s+[^-–—]+)?$"#
                if let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                    text.removeSubrange(range)
                    changed = true
                    break
                }
            }
            if let stripped = stripSuffix(text, suffixes: simpleBrowsers) {
                text = stripped
                changed = true
            }
            if let range = text.range(of: #"\s+-\s+Memory usage\s+-\s+[\d.,]+\s*[KMGT]?B$"#, options: [.regularExpression, .caseInsensitive]) {
                text.removeSubrange(range)
                changed = true
            }
            for badge in tabBadges {
                if let stripped = stripSuffix(text, suffixes: [badge]) {
                    text = stripped
                    changed = true
                }
            }
        }

        return stripLeadingBadge(text)
    }

    private static func stripLeadingBadge(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: #"^(?:\(\d+\)|\[\d+\]|•)\s+"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func hasBrowserMediaBadge(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        return lower.contains("audio playing")
            || lower.contains("camera or microphone recording")
            || lower.contains("microphone recording")
            || lower.contains("sharing this tab")
            || lower.contains("sharing your screen")
    }

    static func isGoogleMeetCode(_ text: String) -> Bool {
        text.range(of: #"^[a-z]{3}-[a-z]{4}-[a-z]{3}$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isExcludedWebTitle(_ title: String) -> Bool {
        let lower = title.lowercased()
        return excludedWebKeywords.contains { lower.contains($0) }
    }

    private static func cleanSlackTitle(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let stripped = stripSuffix(text, suffixes: [" - Slack", " | Slack"]) { text = stripped }
        if text.lowercased().hasPrefix("slack | ") {
            text = String(text.dropFirst("Slack | ".count))
        }
        // "Huddle: #engineering - Acme" -> "Huddle: #engineering"
        if text.lowercased().hasPrefix("huddle"), let dash = text.range(of: " - ") {
            text = String(text[..<dash.lowerBound])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripSuffix(_ text: String, suffixes: [String]) -> String? {
        for suffix in suffixes {
            if text.count >= suffix.count,
               let range = text.range(of: suffix, options: [.anchored, .backwards, .caseInsensitive]) {
                return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}

// MARK: - Debounce, dismissal and lifecycle state machine

struct MeetingTracker: Sendable {
    private(set) var active: DetectedMeeting?
    private var pending: DetectedMeeting?
    private var confirmCount = 0
    private var missCount = 0
    private var dismissedInCurrentCall = false
    private var dismissedIDs: Set<String> = []

    enum Event: Equatable, Sendable {
        case none
        case show(DetectedMeeting)
        case update(DetectedMeeting)
        case hide
    }

    /// Feed one poll result. `suppressed` is true while Transcriptor is already recording.
    mutating func step(detected: DetectedMeeting?, suppressed: Bool) -> Event {
        if suppressed {
            if let detected { dismissedIDs.insert(detected.id) }
            if active != nil {
                active = nil
                pending = nil
                confirmCount = 0
                missCount = 0
                dismissedInCurrentCall = true
                return .hide
            }
            dismissedInCurrentCall = detected != nil
            return .none
        }

        guard let detected else {
            pending = nil
            confirmCount = 0
            guard active != nil || dismissedInCurrentCall else { return .none }
            missCount += 1
            // 3 consecutive misses (~6s) means the meeting genuinely ended.
            guard missCount >= 3 else { return .none }
            let wasVisible = active != nil
            active = nil
            dismissedInCurrentCall = false
            dismissedIDs.removeAll()
            missCount = 0
            return wasVisible ? .hide : .none
        }

        missCount = 0

        // Already dismissed for this continuous call or specific meeting ID.
        if dismissedInCurrentCall || dismissedIDs.contains(detected.id) {
            return .none
        }

        if let current = active {
            if current != detected {
                active = detected
                return .update(detected)
            }
            return .none
        }

        // Confirm high-confidence detections immediately; lower-confidence require 2 consecutive polls.
        let required = detected.highConfidence ? 1 : 2
        if pending?.id == detected.id {
            confirmCount += 1
        } else {
            pending = detected
            confirmCount = 1
        }
        guard confirmCount >= required else { return .none }

        active = detected
        pending = nil
        confirmCount = 0
        return .show(detected)
    }

    mutating func dismiss() {
        if let active { dismissedIDs.insert(active.id) }
        active = nil
        pending = nil
        confirmCount = 0
        dismissedInCurrentCall = true
    }
}

// MARK: - Live macOS probe & monitor

@MainActor
final class MeetingDetector {
    var onShow: ((DetectedMeeting) -> Void)?
    var onUpdate: ((DetectedMeeting) -> Void)?
    var onHide: (() -> Void)?
    var isSuppressed: () -> Bool = { false }

    private var tracker = MeetingTracker()
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            // Short initial settle so launch stays instant.
            try? await Task.sleep(for: .seconds(1))
            while !Task.isCancelled {
                let snapshot = await SystemProbe.capture()
                guard !Task.isCancelled, let self else { break }
                self.consume(snapshot)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if tracker.active != nil {
            tracker = MeetingTracker()
            onHide?()
        }
    }

    func dismissCurrent() {
        tracker.dismiss()
        onHide?()
    }

    /// Call immediately when Transcriptor begins a meeting or dictation.
    func suppressNow() {
        if tracker.step(detected: tracker.active, suppressed: true) == .hide {
            onHide?()
        }
    }

    private func consume(_ snapshot: SystemSnapshot) {
        let detected = MeetingMatcher.detect(in: snapshot)
        switch tracker.step(detected: detected, suppressed: isSuppressed()) {
        case .none: break
        case .show(let meeting): onShow?(meeting)
        case .update(let meeting): onUpdate?(meeting)
        case .hide: onHide?()
        }
    }
}

// MARK: - Off-main-thread system probe

private enum SystemProbe {
    struct AppMeta: Sendable {
        let pid: pid_t
        let bundleID: String
        let name: String
        let isFrontmost: Bool
    }

    @MainActor
    private static func runningAppMeta() -> [AppMeta] {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { return nil }
            guard bundleID != "com.transcriptor.app" else { return nil }
            let isRelevant = MeetingMatcher.isBrowserBundleID(bundleID)
                || MeetingMatcher.nativeCallBundleIDs.contains(bundleID)
            guard isRelevant else { return nil }
            return AppMeta(
                pid: app.processIdentifier,
                bundleID: bundleID,
                name: app.localizedName ?? bundleID,
                isFrontmost: app.processIdentifier == frontPID
            )
        }
    }

    static func capture() async -> SystemSnapshot {
        let metas = await runningAppMeta()
        return await probeOffMain(metas: metas)
    }

    @concurrent
    private static func probeOffMain(metas: [AppMeta]) async -> SystemSnapshot {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let pidToBundle = Dictionary(uniqueKeysWithValues: metas.map { ($0.pid, $0.bundleID) })
        let runningBundles = Set(metas.map(\.bundleID))

        var inputBundles: Set<String> = []
        var outputBundles: Set<String> = []
        let supportsPerProcess: Bool
        let globalMic: Bool

        if #available(macOS 14.2, *) {
            supportsPerProcess = true
            globalMic = false
            for proc in coreAudioProcesses() where proc.pid != selfPID {
                guard proc.isRunningInput || proc.isRunningOutput else { continue }
                let owner = resolveOwnerBundle(pid: proc.pid, bundleID: proc.bundleID,
                                               pidToBundle: pidToBundle, runningBundles: runningBundles)
                guard let owner else { continue }
                if proc.isRunningInput { inputBundles.insert(owner) }
                if proc.isRunningOutput { outputBundles.insert(owner) }
            }
        } else {
            supportsPerProcess = false
            globalMic = defaultInputRunning()
        }

        // Fast path: when no relevant app has active audio (and no macOS 13 global mic),
        // skip Accessibility completely so idle CPU usage stays near zero.
        let activeBundles = inputBundles.union(outputBundles)
        if supportsPerProcess && activeBundles.isEmpty {
            return SystemSnapshot(apps: [], globalMicActive: false, supportsPerProcessAudio: true)
        }

        let axTrusted = AXIsProcessTrusted()
        let faceTimeDaemonActive = inputBundles.contains("com.apple.avconferenced")
            || inputBundles.contains("com.apple.TelephonyUtilities")
        var snapshots: [AppSnapshot] = []
        snapshots.reserveCapacity(metas.count)

        for meta in metas {
            let hasMic = inputBundles.contains(meta.bundleID)
            let hasOutput = outputBundles.contains(meta.bundleID)
            let needsFaceTimeTitle = meta.bundleID == "com.apple.FaceTime" && faceTimeDaemonActive
            let needsWindows = hasMic || hasOutput || needsFaceTimeTitle || (!supportsPerProcess && globalMic)
            guard needsWindows else { continue }

            var windows: [String] = []
            var tabs: [String] = []
            if axTrusted {
                let isBrowser = MeetingMatcher.isBrowserBundleID(meta.bundleID)
                let ax = inspectAX(pid: meta.pid, includeTabs: isBrowser)
                windows = ax.windows
                tabs = ax.tabs
            }
            if windows.isEmpty {
                windows = cgWindowTitles(for: meta.pid)
            }
            snapshots.append(AppSnapshot(
                bundleID: meta.bundleID,
                name: meta.name,
                windowTitles: windows,
                tabTitles: tabs,
                isFrontmost: meta.isFrontmost,
                hasMic: hasMic,
                hasOutput: hasOutput
            ))
        }

        // Also surface system call daemons (avconferenced / TelephonyUtilities) that aren't in NSRunningApplication.
        for daemon in ["com.apple.avconferenced", "com.apple.TelephonyUtilities"] {
            if inputBundles.contains(daemon), !snapshots.contains(where: { $0.bundleID == daemon }) {
                snapshots.append(AppSnapshot(bundleID: daemon, name: "FaceTime", hasMic: true, hasOutput: outputBundles.contains(daemon)))
            }
        }

        return SystemSnapshot(apps: snapshots, globalMicActive: globalMic, supportsPerProcessAudio: supportsPerProcess)
    }

    // MARK: CoreAudio

    private struct AudioProcess {
        let pid: pid_t
        let bundleID: String
        let isRunningInput: Bool
        let isRunningOutput: Bool
    }

    @available(macOS 14.2, *)
    private static func coreAudioProcesses() -> [AudioProcess] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = Array(repeating: AudioObjectID(0), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }

        var result: [AudioProcess] = []
        result.reserveCapacity(ids.count)
        for id in ids {
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &pidAddr, 0, nil, &pidSize, &pid) == noErr, pid > 0 else { continue }

            let input = audioFlag(id, selector: kAudioProcessPropertyIsRunningInput)
            let output = audioFlag(id, selector: kAudioProcessPropertyIsRunningOutput)
            guard input || output else { continue }

            var rawBundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<CFString?>.size)
            var bundleAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                        mScope: kAudioObjectPropertyScopeGlobal,
                                                        mElement: kAudioObjectPropertyElementMain)
            let status = AudioObjectGetPropertyData(id, &bundleAddr, 0, nil, &bundleSize, &rawBundle)
            let bundle = (status == noErr) ? (rawBundle?.takeRetainedValue() as String? ?? "") : ""
            result.append(AudioProcess(pid: pid, bundleID: bundle, isRunningInput: input, isRunningOutput: output))
        }
        return result
    }

    private static func audioFlag(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> Bool {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func defaultInputRunning() -> Bool {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return false }
        return audioFlag(device, selector: kAudioDevicePropertyDeviceIsRunningSomewhere)
    }

    /// Maps helper processes (e.g. `com.google.Chrome.helper`, `com.apple.WebKit.GPU`,
    /// `us.zoom.CptHost`) back to the owning app bundle ID.
    private static func resolveOwnerBundle(pid: pid_t, bundleID: String,
                                           pidToBundle: [pid_t: String],
                                           runningBundles: Set<String>) -> String? {
        if bundleID == "com.apple.avconferenced" || bundleID == "com.apple.TelephonyUtilities" {
            return bundleID
        }
        if let direct = pidToBundle[pid] { return direct }
        if runningBundles.contains(bundleID) { return bundleID }

        // Known helper-to-parent mappings.
        if bundleID.hasPrefix("com.apple.WebKit") {
            if runningBundles.contains("com.apple.Safari") { return "com.apple.Safari" }
            if runningBundles.contains("com.apple.SafariTechnologyPreview") { return "com.apple.SafariTechnologyPreview" }
        }
        if bundleID.hasPrefix("us.zoom."), runningBundles.contains("us.zoom.xos") {
            return "us.zoom.xos"
        }
        if !bundleID.isEmpty {
            for candidate in runningBundles where bundleID.hasPrefix(candidate + ".") {
                return candidate
            }
        }

        // Universal fallback: walk parent PIDs up to 4 levels for any Chromium/Electron helper.
        var current = pid
        for _ in 0..<4 {
            let parent = parentPID(of: current)
            guard parent > 1, parent != current else { break }
            if let owner = pidToBundle[parent] { return owner }
            current = parent
        }
        return nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return 0 }
        return pid_t(info.pbi_ppid)
    }

    // MARK: Accessibility & window titles

    private static func inspectAX(pid: pid_t, includeTabs: Bool) -> (windows: [String], tabs: [String]) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        let axWindows: [AXUIElement] = axAttribute(app, kAXWindowsAttribute) ?? []
        var windowTitles: [String] = []
        var tabTitles: [String] = []

        for window in axWindows.prefix(6) {
            if let title: String = axAttribute(window, kAXTitleAttribute), !title.isEmpty {
                windowTitles.append(title)
            }
            if includeTabs {
                collectTabTitles(window, depth: 0, into: &tabTitles)
            }
        }
        return (windowTitles, tabTitles)
    }

    private static func collectTabTitles(_ element: AXUIElement, depth: Int, into out: inout [String]) {
        guard depth < 14, out.count < 80 else { return }
        let role: String = axAttribute(element, kAXRoleAttribute) ?? ""
        if role == "AXTabGroup" {
            let tabs: [AXUIElement] = axAttribute(element, "AXTabs") ?? axAttribute(element, kAXChildrenAttribute) ?? []
            collectTabItems(tabs, depth: 0, into: &out)
            return
        }
        // Skip deep web content areas so traversal only touches browser chrome.
        if role == "AXWebArea" || role == "AXScrollArea" { return }
        let children: [AXUIElement] = axAttribute(element, kAXChildrenAttribute) ?? []
        for child in children.prefix(35) {
            collectTabTitles(child, depth: depth + 1, into: &out)
        }
    }

    private static func collectTabItems(_ elements: [AXUIElement], depth: Int, into out: inout [String]) {
        guard depth < 3, out.count < 80 else { return }
        for item in elements {
            let role: String = axAttribute(item, kAXRoleAttribute) ?? ""
            let subrole: String = axAttribute(item, kAXSubroleAttribute) ?? ""
            if role == "AXRadioButton" || subrole == "AXTabButton" {
                let title: String = axAttribute(item, kAXTitleAttribute) ?? ""
                let desc: String = axAttribute(item, kAXDescriptionAttribute) ?? ""
                if !title.isEmpty {
                    if !desc.isEmpty && MeetingMatcher.hasBrowserMediaBadge(desc) && !MeetingMatcher.hasBrowserMediaBadge(title) {
                        out.append("\(title) - \(desc)")
                    } else {
                        out.append(title)
                    }
                } else if !desc.isEmpty {
                    out.append(desc)
                }
            } else if role == "AXGroup" {
                // Chrome Tab Groups nest AXTabButton items one level inside an AXGroup.
                let nested: [AXUIElement] = axAttribute(item, kAXChildrenAttribute) ?? []
                collectTabItems(nested, depth: depth + 1, into: &out)
            }
        }
    }

    private static func axAttribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func cgWindowTitles(for pid: pid_t) -> [String] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { entry in
            guard (entry[kCGWindowOwnerPID as String] as? Int32) == pid else { return nil }
            guard (entry[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            guard let name = entry[kCGWindowName as String] as? String, !name.isEmpty else { return nil }
            return name
        }
    }
}
