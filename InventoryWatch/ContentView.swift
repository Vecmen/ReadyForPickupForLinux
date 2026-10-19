//
//  ContentView.swift
//  InventoryWatch
//
//  Created by Worth Baker on 11/8/21.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: ViewModel

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showInspector = true
    @State private var searchPendingDeletion: SavedSearch?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            resultsAndInspector
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.addSearch() } label: { Image(systemName: "plus") }
                    .help("Add a search")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isLoading { ProgressView().controlSize(.small) }
                Button { Task { await model.fetchSelected() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh selected search")
                    .keyboardShortcut("r", modifiers: .command)
                Button(role: .destructive) { searchPendingDeletion = model.selectedSearch } label: { Image(systemName: "trash") }
                    .help("Delete selected search")
                    .disabled(model.selectedSearch == nil)
                Button { withAnimation { showInspector.toggle() } } label: { Image(systemName: "sidebar.trailing") }
                    .help("Toggle inspector")
            }
        }
        .confirmationDialog("Delete this search?",
                            isPresented: Binding(get: { searchPendingDeletion != nil },
                                                 set: { if $0 == false { searchPendingDeletion = nil } }),
                            titleVisibility: .visible,
                            presenting: searchPendingDeletion) { search in
            Button("Delete Search", role: .destructive) { model.deleteSearch(id: search.id) }
            Button("Cancel", role: .cancel) {}
        } message: { search in
            Text("This removes “\(search.productType.presentableName) at \(model.storeName(for: search))” and its preferences. This cannot be undone.")
        }
        .task {
            await model.loadStores()
            if let selected = model.selectedSearch {
                _ = await model.skuData(for: selected.productType)
            }
            await model.fetchAllSearches()
            model.restartAutoRefresh()
            NotificationManager.shared.requestNotificationPermissions()
        }
        .onDisappear {
            model.stopAutoRefresh()
        }
        .onChange(of: model.selectedSearchID) { _ in
            Task {
                await model.loadStores()
                if let selected = model.selectedSearch {
                    _ = await model.skuData(for: selected.productType)
                    if model.results[selected.id] == nil { await model.fetchSelected() }
                }
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $model.selectedSearchID) {
            Section("Searches") {
                ForEach(model.searches) { search in
                    HStack(spacing: 8) {
                        Image(systemName: iconName(for: search.productType))
                            .foregroundColor(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(search.productType.presentableName) at \(model.storeName(for: search))")
                                .lineLimit(1)
                            Text("at \(model.storeName(for: search))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        let count = model.availableCount(for: search)
                        if count > 0 {
                            Text("\(count)")
                                .font(.caption.bold())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.secondary.opacity(0.25)))
                        }
                    }
                    .contentShape(Rectangle())
                    // Acts on the clicked row, which may not be the selected one.
                    .contextMenu {
                        Button { Task { await model.refreshSearch(id: search.id) } } label: {
                            Label("Refresh Search", systemImage: "arrow.clockwise")
                        }
                        Button(role: .destructive) { searchPendingDeletion = search } label: {
                            Label("Delete Search…", systemImage: "trash")
                        }
                    }
                    .tag(search.id)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
    }

    private func iconName(for product: ProductType) -> String {
        switch product {
        case .iPhone16, .iPhone17, .iPhone17e, .iPhoneAir, .iPhoneDuo, .iPhonePro18, .iPhoneProMax18:
            return "iphone"
        case .MacBookNeo, .M5MacBookAir13, .M5MacBookAir15, .MacBookPro14, .MacBookPro16:
            return "laptopcomputer"
        case .iMac, .MacMini, .MacStudio:
            return "desktopcomputer"
        }
    }

    // MARK: - Center

    /// The inspector hangs off the results pane instead of being a third
    /// split-view column: NavigationSplitView can only collapse its leading
    /// columns, so toggling a detail-column inspector just blanked it.
    @ViewBuilder
    private var resultsAndInspector: some View {
        if #available(macOS 14.0, *) {
            centerPane
                .inspector(isPresented: $showInspector) {
                    inspector
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 360)
                }
        } else {
            // No .inspector on macOS 13: lay it out beside the results.
            HStack(spacing: 0) {
                centerPane
                if showInspector {
                    Divider()
                    inspector
                        .frame(width: 300)
                }
            }
        }
    }

    private var centerPane: some View {
        Group {
            if let search = model.selectedSearch {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(search.productType.presentableName) at \(model.storeName(for: search))")
                            .font(.title3.bold())
                        if let updated = model.lastUpdated[search.id] {
                            Text("Last updated at \(updated.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundColor(.secondary)
                        } else {
                            Text("Not yet updated").font(.caption).foregroundColor(.secondary)
                        }
                        if model.autoRefreshIntervalMinutes > 0, let next = model.nextAutoRefreshAt {
                            Text("Auto-refresh at \(next.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)

                    if let error = model.searchErrors[search.id] {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                            Text(error).font(.callout)
                            Spacer()
                            Button("Retry") { Task { await model.fetchSelected() } }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Color.orange.opacity(0.12))
                    }

                    let grouped = model.results[search.id] ?? []
                    if grouped.isEmpty {
                        VStack(spacing: 8) {
                            Spacer()
                            Image(systemName: "magnifyingglass").font(.largeTitle).foregroundColor(.secondary)
                            Text(model.isLoading ? "Checking inventory…" : "No models available in-store.")
                                .foregroundColor(.secondary)
                            if model.searchErrors[search.id] == nil && model.isLoading == false {
                                Text("Available models for this search will appear here, grouped by store.")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        List {
                            ForEach(grouped, id: \.0.storeNumber) { store, parts in
                                Section(store.storeName) {
                                    ForEach(parts.sorted(by: { $0.partName < $1.partName }), id: \.partNumber) { part in
                                        HStack {
                                            Text(part.partName)
                                            Spacer()
                                            if search.isPreferred(part) {
                                                Text("Preferred")
                                                    .font(.caption.bold()).foregroundColor(.white)
                                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                                    .background(Capsule().fill(Color.blue))
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .listStyle(.inset)
                    }
                }
            } else {
                Text("Add a search to get started.").foregroundColor(.secondary)
            }
        }
        .navigationSplitViewColumnWidth(min: 420, ideal: 560)
    }

    // MARK: - Inspector

    private var inspector: some View {
        Group {
            if let search = model.selectedSearch {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        banner(for: search)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Product Type").font(.headline)
                            Picker("", selection: productBinding) {
                                ForEach(ProductCategory.allCases) { category in
                                    Section(category.rawValue) {
                                        ForEach(category.products) { product in
                                            Text(product.presentableName).tag(product.rawValue)
                                        }
                                    }
                                }
                            }
                            .labelsHidden()
                        }

                        preferredModelsSection(for: search)
                        storeSection(for: search)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Custom SKU").font(.headline)
                            TextField("Part number (e.g. MHQJ4LL/A)", text: customSkuBinding)
                                .textFieldStyle(.roundedBorder)
                            TextField("Nickname", text: customNameBinding)
                                .textFieldStyle(.roundedBorder)
                            Text("A custom model is watched alongside the models above and counts as a preferred model for notifications.")
                                .font(.caption).foregroundColor(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Notifications").font(.headline)
                            Toggle("Send inventory notifications on this Mac", isOn: notifyBinding)
                            Toggle("Send Pushover notifications", isOn: pushoverBinding)
                            Text(model.pushoverConfigured
                                 ? "Notifications are sent when a preferred model is newly found. Pushover is configured in Settings."
                                 : "Pushover is not configured yet - add your keys in Settings (Cmd-,) to get phone notifications. Each user needs their own Pushover app token.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .padding(16)
                }
            } else {
                Text("No search selected.").foregroundColor(.secondary).padding()
            }
        }
    }

    private func banner(for search: SavedSearch) -> some View {
        // Only claim channels that are actually active for this search.
        let macOn = search.notifyOnThisMac
        let pushoverOn = search.notifyViaPushover && model.pushoverConfigured
        let channels: String = [macOn ? "on this Mac" : nil, pushoverOn ? "via Pushover" : nil]
            .compactMap { $0 }.joined(separator: " and ")
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: channels.isEmpty == false ? "checkmark.circle.fill" : "bell.badge")
                .foregroundColor(channels.isEmpty == false ? .green : .secondary)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(channels.isEmpty == false ? "Search configured successfully" : "Search saved")
                    .font(.headline)
                Text(channels.isEmpty == false
                     ? "You will receive notifications \(channels) when preferred models are found."
                     : "Turn on notifications on this Mac or via Pushover to be alerted when preferred models are found.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity((search.notifyOnThisMac || (search.notifyViaPushover && model.pushoverConfigured)) ? 0.10 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15)))
    }

    private func preferredModelsSection(for search: SavedSearch) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preferred Models").font(.headline)
            Text("Notifications are only sent when preferred models are found.")
                .font(.caption).foregroundColor(.secondary)

            if let skuData = model.skuDataByProduct[search.productType] {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(skuData.orderedSKUs, id: \.self) { sku in
                        Toggle(isOn: preferredBinding(search: search, sku: sku)) {
                            Text(skuData.productName(forSKU: sku) ?? sku).font(.callout)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
            } else {
                ProgressView().controlSize(.small)
            }

            Toggle("Only include results for preferred models", isOn: onlyPreferredBinding)
                .toggleStyle(.checkbox)
        }
    }

    private func storeSection(for search: SavedSearch) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preferred Store").font(.headline)
            Picker("", selection: storeBinding) {
                ForEach(model.stores, id: \.storeNumber) { store in
                    Text("\(store.name) — \(store.address.cityStateDisplay)").tag(store.storeNumber)
                }
            }
            .labelsHidden()
            Toggle("Include results from nearby stores", isOn: nearbyBinding)
                .toggleStyle(.checkbox)
        }
    }

    // MARK: - Bindings (all mutate the selected search + persist)

    private var productBinding: Binding<String> {
        Binding(get: { model.selectedSearch?.productTypeRaw ?? ProductType.iPhonePro18.rawValue },
                set: { newValue in
                    model.updateSelected { search in
                        search.productTypeRaw = newValue
                        search.preferredSKUs = []
                    }
                    Task {
                        if let selected = model.selectedSearch { _ = await model.skuData(for: selected.productType) }
                        await model.fetchSelected()
                    }
                })
    }

    private func preferredBinding(search: SavedSearch, sku: String) -> Binding<Bool> {
        Binding(get: { model.selectedSearch?.preferredSKUs.contains(sku) ?? false },
                set: { isOn in
                    model.updateSelected { s in
                        if isOn, s.preferredSKUs.contains(sku) == false { s.preferredSKUs.append(sku) }
                        if isOn == false { s.preferredSKUs.removeAll { $0 == sku } }
                    }
                })
    }

    private var onlyPreferredBinding: Binding<Bool> {
        Binding(get: { model.selectedSearch?.onlyPreferred ?? false },
                set: { value in model.updateSelected { $0.onlyPreferred = value }; Task { await model.fetchSelected() } })
    }

    private var storeBinding: Binding<String> {
        Binding(get: { model.selectedSearch?.storeNumber ?? "R032" },
                set: { value in model.updateSelected { $0.storeNumber = value }; Task { await model.fetchSelected() } })
    }

    private var nearbyBinding: Binding<Bool> {
        Binding(get: { model.selectedSearch?.includeNearby ?? true },
                set: { value in model.updateSelected { $0.includeNearby = value }; Task { await model.fetchSelected() } })
    }

    private var pushoverBinding: Binding<Bool> {
        Binding(get: { model.selectedSearch?.notifyViaPushover ?? true },
                set: { value in model.updateSelected { $0.notifyViaPushover = value } })
    }

    private var notifyBinding: Binding<Bool> {
        Binding(get: { model.selectedSearch?.notifyOnThisMac ?? true },
                set: { value in model.updateSelected { $0.notifyOnThisMac = value } })
    }

    private var customSkuBinding: Binding<String> {
        Binding(get: { model.selectedSearch?.customSku ?? "" },
                set: { value in model.updateSelected { $0.customSku = value } })
    }

    private var customNameBinding: Binding<String> {
        Binding(get: { model.selectedSearch?.customSkuNickname ?? "" },
                set: { value in model.updateSelected { $0.customSkuNickname = value } })
    }
}
