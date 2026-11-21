import SwiftUI
import StoreKit
import UniformTypeIdentifiers
import UIKit
import GoogleSignInSwift

struct ProfileView: View {
    @ObservedObject var store: TravelStore
    @ObservedObject var cloudService: FirebaseTravelService
    @ObservedObject var subscription: SubscriptionStore

    @State private var displayName = ""
    @State private var friendCode = ""
    @State private var showingAccount = false
    @State private var showingSubscription = false
    @State private var showingTravellers = false
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var showingDeletion = false
    @State private var document = TravelArchiveDocument(data: Data())
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Traveller profile") {
                    HStack {
                        TextField("Your name", text: $displayName)
                            .textContentType(.name)
                            .onSubmit(saveProfile)
                        Button("Save", action: saveProfile)
                    }
                    Picker("List visibility", selection: visibilityBinding) {
                        ForEach(ProfileVisibility.allCases) { visibility in
                            Text(visibility.title).tag(visibility)
                        }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Traveller code")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(store.profile.shareCode)
                            .font(.headline.monospaced())
                            .textSelection(.enabled)
                        Text("Share this code so friends can find your public travel list.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ShareLink(
                        item: "\(displayName.isEmpty ? "Traveller" : displayName) · \(store.profile.shareCode)",
                        subject: Text("My travel list")
                    ) {
                        Label("Share my travel list", systemImage: "square.and.arrow.up")
                    }
                }

                Section("Friends and travellers") {
                    HStack {
                        TextField("Friend's traveller code", text: $friendCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        Button("Add") {
                            addFriend()
                        }
                        .disabled(friendCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if !store.profile.friendCodes.isEmpty {
                        ForEach(store.profile.friendCodes, id: \.self) { code in
                            Label(code, systemImage: "person.crop.circle.badge.checkmark")
                        }
                    }
                    Button {
                        showingTravellers = true
                    } label: {
                        Label("Browse travellers", systemImage: "magnifyingglass")
                    }
                    .disabled(!cloudService.isConfigured)
                }

                Section("Backup and sync") {
                    Button {
                        exportBackup()
                    } label: {
                        Label("Export local backup", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        showingImporter = true
                    } label: {
                        Label("Restore local backup", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        showingAccount = true
                    } label: {
                        Label(cloudService.email == nil ? "Cloud account" : cloudService.email ?? "Cloud account",
                              systemImage: "icloud")
                    }
                    Button {
                        showingSubscription = true
                    } label: {
                        Label(subscription.isActive ? "Automatic sync is on" : "Automatic cloud sync",
                              systemImage: "arrow.triangle.2.circlepath.icloud")
                    }
                    if let syncError = cloudService.lastError {
                        Text(syncError)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Button("Delete account and cloud data", role: .destructive) {
                        showingDeletion = true
                    }
                    .disabled(cloudService.email == nil || cloudService.isWorking)
                    Button("Delete local travel data", role: .destructive) {
                        do {
                            try store.clearLocalData()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                } footer: {
                    Text("Country tracking works offline and remains free. Cloud accounts and automatic sync are optional.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.travelBackground)
            .navigationTitle("Profile")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onAppear {
                displayName = store.profile.displayName
            }
            .sheet(isPresented: $showingAccount) {
                AccountCenterView(store: store, cloudService: cloudService)
            }
            .sheet(isPresented: $showingSubscription) {
                SubscriptionView(subscription: subscription)
            }
            .sheet(isPresented: $showingTravellers) {
                TravellerDirectoryView(store: store, cloudService: cloudService)
            }
            .sheet(isPresented: $showingDeletion, onDismiss: {
                displayName = store.profile.displayName
            }) {
                AccountDeletionView(store: store, cloudService: cloudService)
            }
            .fileExporter(
                isPresented: $showingExporter,
                document: document,
                contentType: .json,
                defaultFilename: "travelling-backup"
            ) { result in
                if case .failure(let error) = result {
                    errorMessage = error.localizedDescription
                }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    let hasAccess = url.startAccessingSecurityScopedResource()
                    defer {
                        if hasAccess { url.stopAccessingSecurityScopedResource() }
                    }
                    try store.restore(from: Data(contentsOf: url))
                    displayName = store.profile.displayName
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .alert("Something went wrong", isPresented: errorIsPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var visibilityBinding: Binding<ProfileVisibility> {
        Binding(
            get: { store.profile.visibility },
            set: { visibility in
                do {
                    try store.updateProfile(displayName: displayName, visibility: visibility)
                    publishProfile()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        )
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func saveProfile() {
        do {
            try store.updateProfile(displayName: displayName)
            publishProfile()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func publishProfile() {
        guard cloudService.email != nil else { return }
        Task {
            do {
                try await cloudService.publishProfile(store.profile, visitedCountryCount: store.visitedCount)
            } catch {
                cloudService.recordAutoSyncError(error)
            }
        }
    }

    private func addFriend() {
        let code = friendCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        Task {
            do {
                try await cloudService.addFriend(code: code, viewerCode: store.profile.shareCode)
                try store.addFriendCode(code)
                try await cloudService.publishProfile(store.profile, visitedCountryCount: store.visitedCount)
                friendCode = ""
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func exportBackup() {
        do {
            document = TravelArchiveDocument(data: try store.archiveData(includePhotos: true))
            showingExporter = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct AccountDeletionView: View {
    @ObservedObject var store: TravelStore
    @ObservedObject var cloudService: FirebaseTravelService

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @State private var showingConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This permanently removes your account, cloud backup, and local travel data.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Delete account and cloud data", role: .destructive) {
                        showingConfirmation = true
                    }
                    .disabled(cloudService.isWorking)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.travelBackground)
            .navigationTitle("Delete account?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if cloudService.isWorking {
                    ProgressView()
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .alert("Account deletion failed", isPresented: errorIsPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .confirmationDialog(
                "Delete your account?",
                isPresented: $showingConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete account and cloud data", role: .destructive) {
                    Task {
                        do {
                            try await cloudService.deleteAccount(store: store)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You’ll be asked to confirm your Google account before deletion.")
            }
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}

private struct AccountCenterView: View {
    @ObservedObject var store: TravelStore
    @ObservedObject var cloudService: FirebaseTravelService

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if let signedInEmail = cloudService.email {
                    Section("Signed in") {
                        Text(signedInEmail)
                        Button("Back up now") {
                            Task { await runCloudAction { try await cloudService.backup(store: store) } }
                        }
                        Button("Restore from cloud") {
                            Task { await runCloudAction { try await cloudService.restore(store: store) } }
                        }
                        Button("Sign out", role: .destructive) {
                            do {
                                try cloudService.signOut()
                                dismiss()
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                } else {
                    Section("Cloud account") {
                        Text("Sign in to back up or restore your travel list. Local tracking stays available without an account.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        GoogleSignInButton(scheme: .light, style: .wide) {
                            Task {
                                do {
                                    try await cloudService.signInWithGoogle()
                                    dismiss()
                                } catch {
                                    errorMessage = error.localizedDescription
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .disabled(!cloudService.isConfigured || cloudService.isWorking)
                    }
                }
                if !cloudService.isConfigured {
                    Section {
                        Text("Cloud services aren't configured for this build. Add the Firebase configuration in the app target to enable account features.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.travelBackground)
            .navigationTitle("Cloud account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay {
                if cloudService.isWorking {
                    ProgressView()
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .alert("Cloud action failed", isPresented: errorIsPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func runCloudAction(_ action: () async throws -> Void) async {
        do {
            try await action()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SubscriptionView: View {
    @ObservedObject var subscription: SubscriptionStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "icloud.and.arrow.up")
                    .font(.system(size: 42))
                    .foregroundStyle(.cyan)
                Text("Automatic cloud sync")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                Text("Country tracking, city visits, photos, and local backups are free. Subscribe to keep your signed-in travel list synced automatically.")
                    .foregroundStyle(.white.opacity(0.75))
                if subscription.isActive {
                    Label("Subscription active", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else if let product = subscription.product {
                    Button {
                        Task { await subscription.purchase() }
                    } label: {
                        Text("Subscribe · \(product.displayPrice)")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.cyan, in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(Color.travelBackground)
                    }
                    .disabled(subscription.isLoading)
                } else {
                    Text("Subscription isn't available in this store yet.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Button("Restore purchases") {
                    Task { await subscription.restorePurchases() }
                }
                .disabled(subscription.isLoading)
                Text("Subscriptions are billed through the App Store and renew automatically until cancelled in your Apple account settings.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.travelBackground.ignoresSafeArea())
            .navigationTitle("Cloud sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("StoreKit", isPresented: errorIsPresented) {
                Button("OK", role: .cancel) { subscription.clearError() }
            } message: {
                Text(subscription.errorMessage ?? "")
            }
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { subscription.errorMessage != nil },
            set: { if !$0 { subscription.clearError() } }
        )
    }
}

private struct TravellerDirectoryView: View {
    @ObservedObject var store: TravelStore
    @ObservedObject var cloudService: FirebaseTravelService

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var travellers: [TravellerDirectoryEntry] = []
    @State private var selectedTraveller: SharedTraveller?
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            List {
                if cloudService.email == nil {
                    ContentUnavailableView(
                        "Sign in to browse",
                        systemImage: "person.2",
                        description: Text("Sign in to search for travellers who have chosen to share their lists.")
                    )
                    .listRowBackground(Color.clear)
                } else if travellers.isEmpty && !isLoading {
                    ContentUnavailableView(
                        "No travellers found",
                        systemImage: "person.2",
                        description: Text("Try a different name. Only travellers who have made their lists visible appear here.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(travellers) { traveller in
                        Button {
                            openTraveller(traveller)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "person.crop.circle.fill")
                                    .font(.system(size: 38))
                                    .foregroundStyle(.cyan)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(traveller.displayName)
                                        .font(.headline)
                                        .foregroundStyle(.white)
                                    Text("\(traveller.visitedCountryCount) countries · \(traveller.shareCode)")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.65))
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                        }
                        .listRowBackground(Color.travelCard)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.travelBackground)
            .overlay {
                if isLoading { ProgressView().tint(.cyan) }
            }
            .searchable(text: $searchText, prompt: "Search travellers")
            .navigationTitle("Travellers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: searchText) {
                guard cloudService.email != nil else { return }
                do {
                    try await Task.sleep(for: .milliseconds(300))
                    isLoading = true
                    defer { isLoading = false }
                    travellers = try await cloudService.searchTravellers(
                        namePrefix: searchText,
                        viewerCode: store.profile.shareCode
                    )
                    errorMessage = nil
                } catch is CancellationError {
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .sheet(item: $selectedTraveller) { traveller in
                SharedTravellerView(traveller: traveller, cloudService: cloudService)
            }
            .alert("Couldn't load travellers", isPresented: errorIsPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func openTraveller(_ entry: TravellerDirectoryEntry) {
        Task {
            do {
                selectedTraveller = try await cloudService.sharedTraveller(
                    code: entry.shareCode,
                    viewerCode: store.profile.shareCode
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct SharedTravellerView: View {
    let traveller: SharedTraveller
    @ObservedObject var cloudService: FirebaseTravelService

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Countries visited", value: "\(traveller.countries.count)")
                } header: {
                    Text(traveller.displayName)
                }
                Section("Travel list") {
                    ForEach(traveller.countries) { item in
                        SharedCountryVisitRow(item: item, travellerID: traveller.id, cloudService: cloudService)
                    }
                }
            }
            .navigationTitle("Travel list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct SharedCountryVisitRow: View {
    let item: SharedCountryVisit
    let travellerID: String
    @ObservedObject var cloudService: FirebaseTravelService

    @State private var photoData: Data?
    @State private var photoError: String?
    @State private var isLoadingPhoto = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Text(item.country.flag)
                    .font(.title2)
                Text(item.country.name)
                    .font(.headline)
                Spacer()
                if let date = item.visit.visitedAt {
                    Text(date, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(item.visit.cities) { city in
                Label("\(city.name) · \(city.date.formatted(.dateTime.month(.abbreviated).year()))",
                      systemImage: "mappin")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if item.hasPhoto {
                if let photoData, let image = UIImage(data: photoData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 180)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("Shared photo from \(item.country.name)")
                } else if isLoadingPhoto {
                    ProgressView("Loading photo…")
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    Button("View country photo", systemImage: "photo") {
                        loadPhoto()
                    }
                    .font(.subheadline)
                    .disabled(cloudService.isWorking)
                }
                if let photoError {
                    Text(photoError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func loadPhoto() {
        isLoadingPhoto = true
        photoError = nil
        Task {
            defer { isLoadingPhoto = false }
            do {
                photoData = try await cloudService.sharedCountryPhoto(
                    travellerID: travellerID,
                    countryCode: item.country.code
                )
            } catch {
                photoError = error.localizedDescription
            }
        }
    }
}

private struct TravelArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
