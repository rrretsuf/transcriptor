import Testing
@testable import Transcriptor

struct MeetingDetectorTests {
    // MARK: - Google Meet & browser title cleanup

    @Test func detectsGoogleMeetWithCalendarTitleAndProfile() {
        let chrome = AppSnapshot(
            bundleID: "com.google.Chrome",
            name: "Google Chrome",
            windowTitles: ["Meet – Weekly Product Sync - Audio playing - Google Chrome - Filip"],
            hasMic: true,
            hasOutput: true
        )
        let match = MeetingMatcher.detect(in: SystemSnapshot(apps: [chrome]))
        #expect(match == DetectedMeeting(
            id: "google-meet:weekly product sync",
            source: "Google Meet",
            title: "Weekly Product Sync",
            isGenericTitle: false,
            highConfidence: true
        ))
    }

    @Test func detectsGoogleMeetCodeAsGenericTitle() {
        let chrome = AppSnapshot(
            bundleID: "com.google.Chrome",
            name: "Google Chrome",
            windowTitles: ["Meet - abc-defg-hij - Google Chrome"],
            hasMic: true
        )
        let match = MeetingMatcher.detect(in: SystemSnapshot(apps: [chrome]))
        #expect(match?.source == "Google Meet")
        #expect(match?.title == "Google Meet")
        #expect(match?.isGenericTitle == true)
        #expect(match?.highConfidence == true)
    }

    @Test func detectsGoogleMeetPWA() {
        let pwa = AppSnapshot(
            bundleID: "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan",
            name: "Google Meet",
            windowTitles: ["Meet – Design Critique"],
            hasMic: true,
            hasOutput: true
        )
        let match = MeetingMatcher.detect(in: SystemSnapshot(apps: [pwa]))
        #expect(match?.source == "Google Meet")
        #expect(match?.title == "Design Critique")
        #expect(match?.isGenericTitle == false)
    }

    @Test func ignoresStaleBackgroundMeetTabDuringYouTube() {
        let chrome = AppSnapshot(
            bundleID: "com.google.Chrome",
            name: "Google Chrome",
            windowTitles: ["Lo-fi Beats - YouTube - Google Chrome"],
            tabTitles: [
                "Lo-fi Beats - YouTube - Audio playing",
                "Meet – Morning Standup",
            ],
            hasMic: false,
            hasOutput: true
        )
        #expect(MeetingMatcher.detect(in: SystemSnapshot(apps: [chrome])) == nil)
    }

    @Test func detectsMutedUserInBackgroundMeetTabWithAudioBadge() {
        let chrome = AppSnapshot(
            bundleID: "com.google.Chrome",
            name: "Google Chrome",
            windowTitles: ["Pull Request #42 - GitHub - Google Chrome"],
            tabTitles: [
                "Meet – Old Call",
                "Meet – Architecture Review - Audio playing - Memory usage - 320 MB",
            ],
            hasMic: false,
            hasOutput: true
        )
        let match = MeetingMatcher.detect(in: SystemSnapshot(apps: [chrome]))
        #expect(match?.source == "Google Meet")
        #expect(match?.title == "Architecture Review")
        #expect(match?.highConfidence == false)
    }

    @Test func cleanBrowserTitleStripsSuffixesAndBadgesInAnyOrder() {
        #expect(
            MeetingMatcher.cleanBrowserTitle("(2) Meet – Sprint Planning - Camera or microphone recording - Google Chrome - Filip")
                == "Meet – Sprint Planning"
        )
        #expect(
            MeetingMatcher.cleanBrowserTitle("Meet – Demo Day - Google Chrome - Audio playing - Memory usage - 412 MB")
                == "Meet – Demo Day"
        )
        #expect(
            MeetingMatcher.cleanBrowserTitle("Team Sync | Microsoft Teams — Mozilla Firefox")
                == "Team Sync | Microsoft Teams"
        )
    }

    // MARK: - Native call apps

    @Test func detectsZoomWithTopicAndIgnoresLobbyAndLimitWindows() {
        let zoomWithTopic = AppSnapshot(
            bundleID: "us.zoom.xos",
            name: "zoom.us",
            windowTitles: ["Zoom Workplace", "Participants", "Q4 Roadmap Sync", "Zoom Meeting"],
            hasMic: true,
            hasOutput: true
        )
        let topicMatch = MeetingMatcher.detect(in: SystemSnapshot(apps: [zoomWithTopic]))
        #expect(topicMatch?.source == "Zoom")
        #expect(topicMatch?.title == "Q4 Roadmap Sync")
        #expect(topicMatch?.isGenericTitle == false)

        let zoomLimit = AppSnapshot(
            bundleID: "us.zoom.xos",
            name: "zoom.us",
            windowTitles: ["Zoom Workplace", "Zoom Meeting 40-Minute Limit"],
            hasMic: true
        )
        let limitMatch = MeetingMatcher.detect(in: SystemSnapshot(apps: [zoomLimit]))
        #expect(limitMatch?.source == "Zoom")
        #expect(limitMatch?.title == "Zoom Meeting")
        #expect(limitMatch?.isGenericTitle == true)
    }

    @Test func detectsTeamsNativeAndWeb() {
        let teamsNative = AppSnapshot(
            bundleID: "com.microsoft.teams2",
            name: "Microsoft Teams",
            windowTitles: ["Meeting compact view | Microsoft Teams", "(3) Client Kickoff | Microsoft Teams"],
            hasMic: true
        )
        let nativeMatch = MeetingMatcher.detect(in: SystemSnapshot(apps: [teamsNative]))
        #expect(nativeMatch?.source == "Microsoft Teams")
        #expect(nativeMatch?.title == "Client Kickoff")

        let teamsWeb = AppSnapshot(
            bundleID: "com.apple.Safari",
            name: "Safari",
            windowTitles: ["Board Review | Microsoft Teams - Safari"],
            hasMic: true
        )
        let webMatch = MeetingMatcher.detect(in: SystemSnapshot(apps: [teamsWeb]))
        #expect(webMatch?.source == "Microsoft Teams")
        #expect(webMatch?.title == "Board Review")
    }

    @Test func detectsSlackHuddleNativeAndWeb() {
        let slack = AppSnapshot(
            bundleID: "com.tinyspeck.slackmacgap",
            name: "Slack",
            windowTitles: ["Huddle: #engineering - Acme - Slack"],
            hasMic: true
        )
        let match = MeetingMatcher.detect(in: SystemSnapshot(apps: [slack]))
        #expect(match?.source == "Slack Huddle")
        #expect(match?.title == "Huddle: #engineering")
        #expect(match?.isGenericTitle == false)

        let embeddedSlack = AppSnapshot(
            bundleID: "com.tinyspeck.slackmacgap",
            name: "Slack",
            windowTitles: ["#general - Acme - Slack"],
            hasMic: true
        )
        let embeddedMatch = MeetingMatcher.detect(in: SystemSnapshot(apps: [embeddedSlack]))
        #expect(embeddedMatch?.source == "Slack Huddle")
        #expect(embeddedMatch?.title == "Slack Huddle")
        #expect(embeddedMatch?.isGenericTitle == true)
    }

    @Test func detectsFaceTimeViaDaemonAndReadsWindowTitle() {
        let daemon = AppSnapshot(bundleID: "com.apple.avconferenced", name: "FaceTime", hasMic: true, hasOutput: true)
        let app = AppSnapshot(bundleID: "com.apple.FaceTime", name: "FaceTime", windowTitles: ["FaceTime", "Jaka Novak"])
        let match = MeetingMatcher.detect(in: SystemSnapshot(apps: [daemon, app]))
        #expect(match?.source == "FaceTime")
        #expect(match?.title == "Jaka Novak")
        #expect(match?.isGenericTitle == false)
    }

    @Test(arguments: [
        ("com.hnc.Discord", "Discord", ["#standup | Team - Discord"], "Discord", "#standup | Team"),
        ("net.whatsapp.WhatsApp", "WhatsApp", ["Maja Horvat"], "WhatsApp", "Maja Horvat"),
        ("ru.keepcoder.Telegram", "Telegram", ["Telegram"], "Telegram", "Telegram Call"),
        ("org.whispersystems.signal-desktop", "Signal", ["Signal"], "Signal", "Signal Call"),
        ("Cisco-Systems.Spark", "Webex", ["Partner Sync - Webex"], "Webex", "Partner Sync"),
        ("com.figma.Desktop", "Figma", ["Design System"], "Figma Audio", "Design System"),
    ])
    func detectsOtherNativeCallApps(bundleID: String, name: String, windows: [String], expectedSource: String, expectedTitle: String) {
        let app = AppSnapshot(bundleID: bundleID, name: name, windowTitles: windows, hasMic: true)
        let match = MeetingMatcher.detect(in: SystemSnapshot(apps: [app]))
        #expect(match?.source == expectedSource)
        #expect(match?.title == expectedTitle)
    }

    // MARK: - Other web platforms & universal WebRTC fallback

    @Test(arguments: [
        ("Weekly Retro - Whereby", "Whereby", "Weekly Retro"),
        ("Design Sync | Jitsi Meet", "Jitsi Meet", "Design Sync"),
        ("Podcast Ep 12 - Riverside", "Riverside", "Podcast Ep 12"),
        ("Intro Call | Cal.com", "Cal Video", "Intro Call"),
        ("Discord | #voice-lobby", "Discord", "#voice-lobby"),
        ("Live Demo - StreamYard", "StreamYard", "Live Demo"),
        ("Boardroom | 8x8 Meet", "8x8 Meet", "Boardroom"),
    ])
    func detectsKnownWebPlatforms(tabTitle: String, expectedSource: String, expectedTitle: String) {
        let arc = AppSnapshot(
            bundleID: "company.thebrowser.Browser",
            name: "Arc",
            windowTitles: [tabTitle + " - Arc"],
            hasMic: true,
            hasOutput: true
        )
        let match = MeetingMatcher.detect(in: SystemSnapshot(apps: [arc]))
        #expect(match?.source == expectedSource)
        #expect(match?.title == expectedTitle)
    }

    @Test func detectsUnknownWebRTCCallViaTwoWayAudioFallback() {
        let chrome = AppSnapshot(
            bundleID: "com.google.Chrome",
            name: "Google Chrome",
            windowTitles: ["Interview with Ana — Custom Video Portal - Google Chrome"],
            hasMic: true,
            hasOutput: true
        )
        let match = MeetingMatcher.detect(in: SystemSnapshot(apps: [chrome]))
        #expect(match?.source == "Google Chrome")
        #expect(match?.title == "Interview with Ana — Custom Video Portal")
        #expect(match?.highConfidence == false)
    }

    @Test(arguments: [
        "ChatGPT - Google Chrome",
        "Claude - Google Chrome",
        "Gemini - Google Chrome",
        "YouTube - Music Mix - Google Chrome",
        "Spotify - Web Player - Google Chrome",
        "Loom Recording - Google Chrome",
    ])
    func excludesNonMeetingWebAppsEvenWithTwoWayAudio(windowTitle: String) {
        let chrome = AppSnapshot(
            bundleID: "com.google.Chrome",
            name: "Google Chrome",
            windowTitles: [windowTitle],
            hasMic: true,
            hasOutput: true
        )
        #expect(MeetingMatcher.detect(in: SystemSnapshot(apps: [chrome])) == nil)
    }

    @Test func macOS13FallbackPrefersExplicitWebMeetingOverIdleNativeApp() {
        let slack = AppSnapshot(
            bundleID: "com.tinyspeck.slackmacgap",
            name: "Slack",
            windowTitles: ["Slack - #general"],
            isFrontmost: false,
            hasMic: false,
            hasOutput: false
        )
        let chrome = AppSnapshot(
            bundleID: "com.google.Chrome",
            name: "Google Chrome",
            windowTitles: ["Meet – abc-defg-hij – Google Chrome"],
            isFrontmost: false,
            hasMic: false,
            hasOutput: false
        )
        let snapshot = SystemSnapshot(apps: [slack, chrome], globalMicActive: true, supportsPerProcessAudio: false)
        let detected = MeetingMatcher.detect(in: snapshot)
        #expect(detected?.source == "Google Meet")
        #expect(detected?.title == "Google Meet")
    }

    // MARK: - Tracker lifecycle & debounce

    @Test func trackerShowsUpdatesDismissesAndResetsAfterCallEnds() {
        var tracker = MeetingTracker()
        let generic = DetectedMeeting(id: "google-meet:abc-defg-hij", source: "Google Meet", title: "Google Meet", isGenericTitle: true, highConfidence: true)
        let titled = DetectedMeeting(id: "google-meet:weekly sync", source: "Google Meet", title: "Weekly Sync", isGenericTitle: false, highConfidence: true)

        // High-confidence appears immediately on poll 1.
        #expect(tracker.step(detected: generic, suppressed: false) == .show(generic))
        // Title arrives mid-call -> smooth update in-place.
        #expect(tracker.step(detected: titled, suppressed: false) == .update(titled))
        // Brief 2-poll audio gap does not prematurely dismiss.
        #expect(tracker.step(detected: nil, suppressed: false) == .none)
        #expect(tracker.step(detected: nil, suppressed: false) == .none)
        #expect(tracker.step(detected: titled, suppressed: false) == .none)

        // User dismisses -> stays silent for the rest of this call.
        tracker.dismiss()
        #expect(tracker.step(detected: titled, suppressed: false) == .none)
        #expect(tracker.step(detected: generic, suppressed: false) == .none)

        // 3 consecutive misses (~6s) mean the call genuinely ended -> resets for next call.
        #expect(tracker.step(detected: nil, suppressed: false) == .none)
        #expect(tracker.step(detected: nil, suppressed: false) == .none)
        #expect(tracker.step(detected: nil, suppressed: false) == .none)

        // Next call pops up again.
        #expect(tracker.step(detected: titled, suppressed: false) == .show(titled))
    }

    @Test func trackerRequiresTwoPollsForLowConfidence() {
        var tracker = MeetingTracker()
        let low = DetectedMeeting(id: "web:chrome:call", source: "Google Chrome", title: "Custom Call", isGenericTitle: false, highConfidence: false)
        #expect(tracker.step(detected: low, suppressed: false) == .none)
        #expect(tracker.step(detected: low, suppressed: false) == .show(low))
    }

    @Test func trackerSuppressesWhileRecordingAndHidesActiveBanner() {
        var tracker = MeetingTracker()
        let meet = DetectedMeeting(id: "zoom:standup", source: "Zoom", title: "Standup", isGenericTitle: false, highConfidence: true)
        #expect(tracker.step(detected: meet, suppressed: false) == .show(meet))
        #expect(tracker.step(detected: meet, suppressed: true) == .hide)
        // Ending recording while still in the same call does not re-pop the banner.
        #expect(tracker.step(detected: meet, suppressed: false) == .none)
    }
}
