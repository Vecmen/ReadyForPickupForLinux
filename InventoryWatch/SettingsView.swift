//
//  SettingsView.swift
//  InventoryWatch
//
//  Created by Worth Baker on 11/9/21.
//

import SwiftUI

/// Per-search settings now live in the main window's inspector
/// (2.0-style layout). This scene keeps only app-wide preferences.
struct SettingsView: View {
    @EnvironmentObject var model: ViewModel
    @AppStorage("preferredCountry") private var preferredCountry = "US"
    @AppStorage("useLargeText") private var useLargeText: Bool = false
    @AppStorage("preferredUpdateInterval") private var preferredUpdateInterval: Int = 5

    var body: some View {
        Form {
            Text("Searches, products, stores and notifications are configured per search in the main window's right-hand inspector.")
                .foregroundColor(.secondary)

            Picker("Country (store list)", selection: $preferredCountry) {
                ForEach(OrderedCountries, id: \.self) { code in
                    Text(Countries[code]?.name ?? code).tag(code)
                }
            }

            Picker("Auto-refresh every", selection: $preferredUpdateInterval) {
                Text("Off").tag(0)
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
            Text("Searches refresh automatically while the app is running, one after another. Use the toolbar refresh button (or Cmd-R) to re-check now - that also resets the schedule.")
                .font(.caption).foregroundColor(.secondary)

            Toggle("Use larger text sizes", isOn: $useLargeText)
        }
        .padding(20)
        .frame(width: 420)
    }
}
