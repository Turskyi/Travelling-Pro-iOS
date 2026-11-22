import SwiftUI

struct ContentView: View {
    @StateObject private var store = TravelStore()
    @StateObject private var cloudService = FirebaseTravelService()
    @StateObject private var subscription = SubscriptionStore()
    @State private var selectedTab = 0
    @State private var autoSyncTask: Task<Void, Never>?
    @State private var cloudSyncTask: Task<Void, Never>?
    @State private var hasStartedCloudSync = false

    var body: some View {
        TabView(selection: $selectedTab) {
            CountryListView(store: store)
                .tabItem {
                    Label("Countries", systemImage: "globe.europe.africa")
                }
                .tag(0)

            ProfileView(store: store, cloudService: cloudService, subscription: subscription)
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle")
                }
                .tag(1)
        }
        .tint(.cyan)
        .preferredColorScheme(.dark)
        .task {
            await subscription.refreshServerAccess()
            if cloudService.email != nil { startCloudSync() }
        }
        .onChange(of: store.visits) { _, _ in
            if !cloudService.isWorking { scheduleAutomaticSync() }
        }
        .onChange(of: cloudService.email) { _, email in
            guard email != nil else {
                hasStartedCloudSync = false
                cloudSyncTask?.cancel()
                autoSyncTask?.cancel()
                return
            }
            startCloudSync()
        }
        .onChange(of: subscription.hasAutomaticSyncAccess) { _, hasAccess in
            if hasAccess { scheduleAutomaticSync() }
        }
        .alert("Couldn't load travel data", isPresented: loadErrorIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.loadError ?? "")
        }
    }

    private var loadErrorIsPresented: Binding<Bool> {
        Binding(
            get: { store.loadError != nil },
            set: { if !$0 { store.clearLoadError() } }
        )
    }

    private func scheduleAutomaticSync() {
        autoSyncTask?.cancel()
        guard subscription.hasAutomaticSyncAccess, cloudService.email != nil else { return }
        autoSyncTask = Task {
            do {
                try await Task.sleep(for: .seconds(1))
                try await cloudService.backup(store: store)
            } catch is CancellationError {
            } catch {
                cloudService.recordAutoSyncError(error)
            }
        }
    }

    private func startCloudSync() {
        guard !hasStartedCloudSync, cloudService.email != nil else { return }
        hasStartedCloudSync = true
        cloudSyncTask = Task {
            await subscription.refreshServerAccess()
            guard !Task.isCancelled, cloudService.email != nil else { return }

            if subscription.hasAutomaticSyncAccess {
                do {
                    try await cloudService.synchronize(store: store)
                } catch {
                    cloudService.recordAutoSyncError(error)
                }
            }

            do {
                try await cloudService.publishProfile(store.profile, visitedCountryCount: store.visitedCount)
                if subscription.hasAutomaticSyncAccess { scheduleAutomaticSync() }
            } catch {
                cloudService.recordAutoSyncError(error)
            }
        }
    }
}

private struct CountryListView: View {
    @ObservedObject var store: TravelStore
    @Environment(\.locale) private var locale
    @State private var searchText = ""
    @State private var showingAllCountries: Bool?

    private var showingVisitedOnly: Bool {
        showingAllCountries.map { !$0 } ?? (store.visitedCount > 0)
    }

    private var countries: [Country] {
        Country.catalog(for: locale.identifier).filter { country in
            let visit = store.visit(for: country.code)
            let matchesVisited = !showingVisitedOnly || visit.visited
            let matchesSearch = searchText.isEmpty
                || country.name(in: locale.identifier).localizedCaseInsensitiveContains(searchText)
                || country.code.localizedCaseInsensitiveContains(searchText)
            return matchesVisited && matchesSearch
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    progressCard
                    HStack {
                        Text(showingVisitedOnly ? "Visited countries" : "Country list")
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                        Spacer()
                        Menu {
                            Button("All countries") { showingAllCountries = true }
                            Button("Visited only") { showingAllCountries = false }
                        } label: {
                            Label(showingVisitedOnly ? "Visited" : "All", systemImage: "line.3.horizontal.decrease.circle")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.cyan)
                        }
                        .accessibilityLabel("Filter countries")
                    }

                    if countries.isEmpty {
                        ContentUnavailableView(
                            showingVisitedOnly ? "No countries visited" : "No countries found",
                            systemImage: showingVisitedOnly ? "airplane" : "magnifyingglass",
                            description: Text(showingVisitedOnly
                                ? "Mark a country as visited to start your travel list."
                                : "Try another country name or code.")
                        )
                        .foregroundStyle(.white.opacity(0.8))
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(countries) { country in
                                NavigationLink(value: country) {
                                    countryRow(country)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 28)
            }
            .background(Color.travelBackground.ignoresSafeArea())
            .navigationTitle("Travelling")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .searchable(text: $searchText, prompt: "Search countries")
            .navigationDestination(for: Country.self) { country in
                CountryDetailView(store: store, country: country)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 3) {
                Text("TRAVELLING")
                    .font(.caption.weight(.bold))
                    .tracking(2.2)
                    .foregroundStyle(.cyan)
                Text("Your world, in one place")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private var progressCard: some View {
        let total = Country.catalog(for: locale.identifier).count
        let progress = total == 0 ? 0 : Double(store.visitedCount) / Double(total)

        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("YOUR TRAVEL MAP")
                        .font(.caption.weight(.bold))
                        .tracking(1.5)
                        .foregroundStyle(.white.opacity(0.68))
                    Text("\(store.visitedCount) of \(total) countries")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                }
                Spacer()
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.14), lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: min(progress, 1))
                        .stroke(.cyan, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "airplane")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.cyan)
                }
                .frame(width: 58, height: 58)
                .accessibilityLabel("\(Int(progress * 100)) percent of countries visited")
            }
            ProgressView(value: Double(store.visitedCount), total: Double(max(total, 1)))
                .tint(.cyan)
                .accessibilityLabel("Visited countries progress")
            Text("Every trip becomes part of your story.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.72))
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [Color(red: 0.08, green: 0.25, blue: 0.42), Color(red: 0.08, green: 0.15, blue: 0.28)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
    }

    private func countryRow(_ country: Country) -> some View {
        let visit = store.visit(for: country.code)

        return HStack(spacing: 14) {
            Text(country.flag)
                .font(.system(size: 30))
                .frame(width: 42, height: 42)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(country.name(in: locale.identifier))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                Text(visit.visited ? visitSummary(visit) : country.code)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.56))
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: visit.visited ? "checkmark.circle.fill" : "plus.circle")
                .font(.system(size: 25))
                .foregroundStyle(visit.visited ? .cyan : .white.opacity(0.55))
                .accessibilityHidden(true)
        }
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private func visitSummary(_ visit: CountryVisit) -> String {
        if let latestCity = visit.cities.first {
            return "\(latestCity.name) · \(latestCity.date.formatted(date: .abbreviated, time: .omitted))"
        }
        if let date = visit.visitedAt {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        return "Visited"
    }
}
