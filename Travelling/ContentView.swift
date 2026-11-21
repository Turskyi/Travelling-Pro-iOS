//
//  ContentView.swift
//  Travelling
//
//  Created by Dmytro on 2026-11-16.
//

import SwiftUI

struct ContentView: View {
    @AppStorage("visitedCountryCodes") private var savedVisitedCodes = ""
    @State private var searchText = ""
    @State private var showingVisitedOnly = false

    private let countries = Country.catalog

    private var visitedCodes: Set<String> {
        Set(savedVisitedCodes.split(separator: ",").map(String.init))
    }

    private var visibleCountries: [Country] {
        countries.filter { country in
            let matchesFilter = !showingVisitedOnly || visitedCodes.contains(country.code)
            let matchesSearch = searchText.isEmpty
                || country.name.localizedCaseInsensitiveContains(searchText)
                || country.code.localizedCaseInsensitiveContains(searchText)
            return matchesFilter && matchesSearch
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.035, green: 0.075, blue: 0.15)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header
                        progressCard
                        countrySection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 32)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 3) {
                Text("TRAVELLING")
                    .font(.caption.weight(.bold))
                    .tracking(2.2)
                    .foregroundStyle(.cyan)
                Text("Your world, in one place")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("YOUR TRAVEL MAP")
                        .font(.caption.weight(.bold))
                        .tracking(1.5)
                        .foregroundStyle(.white.opacity(0.65))
                    Text("\(visitedCodes.count) of \(countries.count) countries")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                }

                Spacer()

                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.14), lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            Color.cyan,
                            style: StrokeStyle(lineWidth: 7, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "airplane")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.cyan)
                }
                .frame(width: 58, height: 58)
                .accessibilityLabel("\(Int(progress * 100)) percent of countries visited")
            }

            ProgressView(value: Double(visitedCodes.count), total: Double(countries.count))
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

    private var countrySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(showingVisitedOnly ? "Visited" : "Countries")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    showingVisitedOnly.toggle()
                } label: {
                    Text(showingVisitedOnly ? "Show all" : "Visited only")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.cyan)
                }
                .accessibilityHint(showingVisitedOnly ? "Shows every country" : "Shows countries marked as visited")
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.white.opacity(0.55))
                TextField("Search countries", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(.white)
                    .accessibilityLabel("Search countries")
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

            if visibleCountries.isEmpty {
                ContentUnavailableView(
                    showingVisitedOnly ? "No countries yet" : "No countries found",
                    systemImage: showingVisitedOnly ? "airplane" : "magnifyingglass",
                    description: Text(showingVisitedOnly
                        ? "Mark a country as visited to start your travel list."
                        : "Try another country name or code.")
                )
                .foregroundStyle(.white)
                .padding(.top, 12)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(visibleCountries) { country in
                        countryRow(country)
                    }
                }
            }
        }
    }

    private func countryRow(_ country: Country) -> some View {
        let isVisited = visitedCodes.contains(country.code)

        return HStack(spacing: 14) {
            Text(country.flag)
                .font(.system(size: 30))
                .frame(width: 42, height: 42)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(country.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                Text(country.code)
                    .font(.caption.weight(.medium))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.55))
            }

            Spacer()

            Button {
                toggleVisited(country)
            } label: {
                Image(systemName: isVisited ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 26))
                    .foregroundStyle(isVisited ? .cyan : .white.opacity(0.55))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isVisited ? "Remove \(country.name) from visited" : "Mark \(country.name) as visited")
        }
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }

    private var progress: Double {
        guard !countries.isEmpty else { return 0 }
        return min(Double(visitedCodes.count) / Double(countries.count), 1)
    }

    private func toggleVisited(_ country: Country) {
        var updatedCodes = visitedCodes
        if updatedCodes.contains(country.code) {
            updatedCodes.remove(country.code)
        } else {
            updatedCodes.insert(country.code)
        }
        savedVisitedCodes = updatedCodes.sorted().joined(separator: ",")
    }
}

private struct Country: Identifiable {
    let code: String
    let name: String
    let flag: String

    var id: String { code }

    static var catalog: [Country] {
        Locale.Region.isoRegions.compactMap { region in
            let code = region.identifier.uppercased()
            guard code.count == 2,
                  code.unicodeScalars.allSatisfy({ (65...90).contains($0.value) }),
                  let name = Locale.current.localizedString(forRegionCode: code)
            else {
                return nil
            }

            let flagScalars = code.unicodeScalars.compactMap { scalar -> UnicodeScalar? in
                guard (65...90).contains(scalar.value) else { return nil }
                return UnicodeScalar(127397 + scalar.value)
            }
            return Country(code: code, name: name, flag: String(String.UnicodeScalarView(flagScalars)))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

#Preview {
    ContentView()
}
