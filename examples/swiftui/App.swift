// Plain SwiftUI app (no simflick-specific code) used to test simflick against native UI.
import Charts
import SwiftUI

@main
struct DemoApp: App {
  var body: some Scene { WindowGroup { RootView() } }
}

struct RootView: View {
  var body: some View {
    TabView {
      HomeView().tabItem { Label("Home", systemImage: "house") }
      SettingsView().tabItem { Label("Settings", systemImage: "gear") }
      StatusView().tabItem { Label("Status", systemImage: "chart.bar") }
    }
  }
}

struct HomeView: View {
  @State private var query = ""
  @State private var showingAdd = false
  @State private var items = (1...60).map { "Item \($0)" }
  let cities = ["Lisbon", "Berlin", "Tokyo", "Lima", "Oslo", "Cairo", "Seoul", "Quito", "Perth", "Riga"]

  var body: some View {
    NavigationStack {
      List {
        Section("Featured") {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
              ForEach(cities, id: \.self) { city in
                VStack(alignment: .leading, spacing: 8) {
                  Text(city).font(.headline)
                  NavigationLink("Visit") { Text("Welcome to \(city)").font(.largeTitle).navigationTitle(city) }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("visit-\(city.lowercased())")
                }
                .padding().frame(width: 160, height: 100, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
              }
            }
          }
        }
        Section("All items") {
          ForEach(items.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }, id: \.self) { item in
            NavigationLink(item) { Text("Details for \(item)").navigationTitle(item) }
          }
        }
      }
      .searchable(text: $query, prompt: "Search items")
      .navigationTitle("Demo")
      .toolbar { Button("Add") { showingAdd = true }.accessibilityIdentifier("add-btn") }
      .sheet(isPresented: $showingAdd) {
        AddItemView { name in items.insert(name, at: 0) }
      }
    }
  }
}

struct AddItemView: View {
  var onSave: (String) -> Void
  @State private var name = ""
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      Form { TextField("Name", text: $name).accessibilityIdentifier("name-field") }
        .navigationTitle("New item")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) { Button("Save") { onSave(name); dismiss() }.disabled(name.isEmpty) }
        }
    }
  }
}

struct SettingsView: View {
  @State private var notifications = true
  @State private var volume = 0.5
  var body: some View {
    NavigationStack {
      Form {
        Toggle("Notifications", isOn: $notifications)
        Slider(value: $volume) { Text("Volume") }
        Button("Reset", role: .destructive) { notifications = true; volume = 0.5 }
      }
      .navigationTitle("Settings")
    }
  }
}

// A spinner, a progress bar and a chart: content a reader must not mistake for controls or a settled screen.
struct StatusView: View {
  let days = [("Mon", 3), ("Tue", 5), ("Wed", 2), ("Thu", 6)]
  var body: some View {
    NavigationStack {
      VStack(spacing: 24) {
        ProgressView()
        ProgressView(value: 0.4) { Text("Upload") }
        Chart(days, id: \.0) { BarMark(x: .value("Day", $0.0), y: .value("Cards", $0.1)) }.frame(height: 160)
        Button("Refresh") {}
      }
      .padding()
      .navigationTitle("Status")
    }
  }
}
