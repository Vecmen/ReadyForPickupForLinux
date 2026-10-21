//
//  SettingsView.swift
//  ReadyForPickup
//
//  Created by Worth Baker on 11/9/21.
//

import SwiftUI

/// Per-search settings now live in the main window's inspector
/// (2.0-style layout). This scene keeps only app-wide preferences.
struct SettingsView: View {
    @EnvironmentObject var model: ViewModel
    @EnvironmentObject var updater: UpdaterViewModel
    @AppStorage("preferredCountry") private var preferredCountry = "US"
    @AppStorage("preferredUpdateInterval") private var preferredUpdateInterval: Int = 5
    // Read by LaunchHours.stored.
    @AppStorage(LaunchHours.enabledKey) private var launchHoursEnabled = false
    @AppStorage(LaunchHours.startKey) private var launchHoursStart = LaunchHours.defaultStart
    @AppStorage(LaunchHours.endKey) private var launchHoursEnd = LaunchHours.defaultEnd
    // Read by PushoverSettings.highPriorityAlerts.
    @AppStorage("pushoverHighPriority") private var pushoverHighPriority = false
    @State private var pushoverUserKey: String = PushoverSettings.userKey
    @State private var pushoverApiToken: String = PushoverSettings.apiToken
    @State private var isSendingTest = false

    var body: some View {
        Form {
            Text("Searches, countries, products, stores and notifications are configured per search in the main window's right-hand inspector.")
                .foregroundColor(.secondary)

            // Stored under the old app-wide setting's key (see DefaultsVendor).
            Picker("Default country", selection: $preferredCountry) {
                ForEach(Country.all) { country in
                    Text(country.name).tag(country.code)
                }
            }
            Text("New searches start in this country, at a store there. Each search's own country is set in the inspector.")
                .font(.caption).foregroundColor(.secondary)

            Picker("Auto-refresh every", selection: $preferredUpdateInterval) {
                Text("Off").tag(0)
                Text("2 minutes").tag(2)
                Text("5 minutes").tag(5)
                Text("10 minutes").tag(10)
                Text("15 minutes").tag(15)
                Text("30 minutes").tag(30)
            }
            .onChange(of: preferredUpdateInterval) { newValue in
                // Takes effect immediately; no relaunch needed. The
                // scheduler doubles this wait (up to 60 min) while
                // Apple is throttling requests.
                model.restartAutoRefresh(withMinutes: newValue)
            }
            Text("Searches refresh automatically, one after another, while the app is running - even with its window closed. To re-check now, use the toolbar refresh button or File > Refresh Selected Search (Cmd-R), or File > Refresh All Searches (Shift-Cmd-R); either also resets the schedule. If Apple starts refusing requests, the app waits longer between refreshes, up to an hour, until Apple answers again.")
                .font(.caption).foregroundColor(.secondary)
            // On 2026-10-21 the app alone, every 2 minutes, got 31 answers
            // and then 20-30 minutes of refusals, four times in a row; it was
            // never refused at 12 an hour.
            if requestsPerHour >= 20 {
                Text("That's about \(requestsPerHour) requests an hour, one per search per refresh. Apple answers about 31 in an hour and a half, then refuses every device on your network for up to half an hour, so the app will miss stretches. Under 20 an hour, such as one search every 5 minutes, it keeps answering.")
                    .font(.caption).foregroundColor(.orange)
            }

            Toggle("Check more often during launch hours", isOn: $launchHoursEnabled)
                .onChange(of: launchHoursSetting) { _ in
                    // Takes effect immediately, like the interval above.
                    model.restartAutoRefresh()
                }
            Group {
                DatePicker("From", selection: timeOfDay($launchHoursStart), displayedComponents: .hourAndMinute)
                DatePicker("To", selection: timeOfDay($launchHoursEnd), displayedComponents: .hourAndMinute)
            }
            .environment(\.timeZone, Self.utc)
            .disabled(launchHoursEnabled == false)
            Text(launchHoursCaption)
                .font(.caption).foregroundColor(.secondary)
            if launchHoursEnabled, let warning = launchHoursWarning {
                Text(warning)
                    .font(.caption).foregroundColor(.orange)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Software Updates").font(.headline)
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
                CheckForUpdatesView(updater: updater)
                Text("Updates are downloaded from GitHub via Sparkle. Version 0.3.2 and earlier can't install updates: download 0.3.3 or later once from the Releases page.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Mac notifications").font(.headline)
                // On only when macOS allows them too; turning it on asks
                // macOS, or opens System Settings if the user said no there.
                Toggle("Enable Mac notifications", isOn: Binding(
                    get: { model.macNotificationsActive },
                    set: { on in Task { await model.setMacNotificationsEnabled(on) } }))
                Text(macNotificationsCaption)
                    .font(.caption).foregroundColor(.secondary)
                HStack {
                    if model.macNotificationsEnabled, model.macNotificationStatus == .denied {
                        Button("Open Notification Settings…") { NotificationManager.openSystemSettings() }
                    }
                    Button("Send test notification") {
                        Task { await model.sendTestMacNotification() }
                    }
                    .disabled(model.macNotificationsActive == false)
                }
                if let feedback = model.macNotificationFeedback {
                    Text(feedback).font(.caption)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Pushover (push to your phone)").font(.headline)
                Text("Pushover requires your own account and app token: install Pushover on your iPhone, register an application at pushover.net/apps, then paste your User Key and that app's API Token below. Keys are stored in your Mac's Keychain, never in the app.")
                    .font(.caption).foregroundColor(.secondary)

                Toggle("Enable Pushover notifications", isOn: Binding(
                    get: { model.pushoverEnabled },
                    set: { model.setPushoverEnabled($0) }))

                SecureField("Pushover User Key", text: $pushoverUserKey)
                    .onChange(of: pushoverUserKey) { PushoverSettings.userKey = $0; model.refreshPushoverState() }
                SecureField("Application API Token", text: $pushoverApiToken)
                    .onChange(of: pushoverApiToken) { PushoverSettings.apiToken = $0; model.refreshPushoverState() }

                Toggle("Send stock alerts at high priority", isOn: $pushoverHighPriority)
                Text("High-priority alerts get through your Pushover quiet hours, always with sound, and show in red. Test notifications stay at normal priority.")
                    .font(.caption).foregroundColor(.secondary)

                HStack {
                    Button("Send test notification") {
                        isSendingTest = true
                        Task { await model.sendTestPushover(); isSendingTest = false }
                    }
                    .disabled(isSendingTest || pushoverUserKey.isEmpty || pushoverApiToken.isEmpty)
                    if isSendingTest { ProgressView().controlSize(.small) }
                }
                if pushoverUserKey.isEmpty || pushoverApiToken.isEmpty {
                    Text("Enter both keys to enable the test button. With invalid keys, Pushover's own error is shown here.")
                        .font(.caption).foregroundColor(.secondary)
                }
                if let feedback = model.pushoverFeedback {
                    Text(feedback).font(.caption)
                        .foregroundColor(feedback.hasPrefix("Test sent") ? .green : .red)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .task { await model.refreshMacNotificationStatus() }
        // Picks up a change made in System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshMacNotificationStatus() }
        }
    }

    /// Auto-refresh's pickup requests an hour: one per search per refresh
    /// (two for a search watching more than 20 models).
    private var requestsPerHour: Int {
        preferredUpdateInterval > 0 ? model.requestsPerSweep * 60 / preferredUpdateInterval : 0
    }

    private var launchHoursSetting: LaunchHours {
        LaunchHours(isEnabled: launchHoursEnabled, start: launchHoursStart, end: launchHoursEnd)
    }

    private var launchHoursCaption: String {
        let hours = launchHoursSetting
        let interval = LaunchHours.intervalMinutes(requestsPerSweep: model.requestsPerSweep)
        let pace = "as often as the app can while sending at most \(LaunchHours.maxRequestsPerHour) requests an hour, one per search per refresh"
        guard hours.isEnabled else {
            return "Turn this on to refresh searches every \(interval) minutes in a daily window, such as the hours stock drops at a launch: \(pace)."
        }
        guard hours.minutes > 0 else {
            return "From and To are the same time, so launch hours never start."
        }
        let end = time(hours.end) + (hours.end < hours.start ? " the next day" : "")
        var caption = "Every day from \(time(hours.start)) to \(end), searches refresh every \(interval) minutes: \(pace). At other times they follow Auto-refresh above, which can be Off."
        if preferredUpdateInterval > 0, preferredUpdateInterval < interval {
            caption += " That's slower than Auto-refresh above, which Apple will refuse at times."
        }
        return caption
    }

    /// Shown when one day's window would send more than Apple answers
    /// before refusing (LaunchHours.requestsAppleAnswers).
    private var launchHoursWarning: String? {
        let requests = launchHoursSetting.requestsPerWindow(requestsPerSweep: model.requestsPerSweep)
        guard requests >= LaunchHours.requestsAppleAnswers else { return nil }
        return "This window sends up to \(requests) requests. Apple answers about \(LaunchHours.requestsAppleAnswers) in an hour and a half, then refuses every device on your network for up to half an hour, so the app may be refused before the window ends. A shorter window avoids that."
    }

    // Launch hours' times are minutes after midnight on the Mac's clock,
    // not dates. The pickers show them as that time on 2001-01-01 in UTC,
    // which never skips or repeats an hour, so any time can be picked and
    // reads back as picked.
    private static let utc = TimeZone(secondsFromGMT: 0)!
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }()

    private func timeOfDay(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(get: { Date(timeIntervalSinceReferenceDate: TimeInterval(minutes.wrappedValue * 60)) },
                set: { date in
                    let parts = Self.utcCalendar.dateComponents([.hour, .minute], from: date)
                    minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                })
    }

    private func time(_ minutes: Int) -> String {
        Date(timeIntervalSinceReferenceDate: TimeInterval(minutes * 60))
            .formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: Self.utc))
    }

    private var macNotificationsCaption: String {
        if model.macNotificationsActive {
            return "On. Banners, sounds and Focus follow System Settings > Notifications > ReadyForPickup. Each search can also turn them off in the inspector."
        }
        if model.macNotificationsEnabled == false {
            return "Off: ReadyForPickup sends no Mac notifications."
        }
        switch model.macNotificationStatus {
        case .denied:
            return "macOS has notifications turned off for ReadyForPickup, and only System Settings can turn them back on: turn on Allow notifications there, then come back."
        default:
            return "Turn this on and macOS will ask whether ReadyForPickup may send notifications."
        }
    }
}
