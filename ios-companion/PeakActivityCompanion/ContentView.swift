import FamilyControls
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: CompanionStore
    @State private var durationMinutes = "25"
    @State private var note = ""

    private var today: LocalReportSummary { store.report() }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Limited iOS companion")
                        .font(.title2.bold())
                    Text("This app does not track desktop-style app names, window titles, or websites.")
                        .foregroundStyle(.secondary)

                    GroupBox("Screen Time selection") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Apple's picker keeps selected app and site names hidden. PeakActivity stores only the encrypted opaque selection token; automatic Screen Time reports are not enabled in this prototype.")
                            Button("Set up Screen Time selection") {
                                store.beginFamilyControlFlow()
                            }
                            .accessibilityHint("Requests Family Controls only after you start this flow")
                            Text(store.screenTimeStatus)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Manual entry") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Duration in minutes", text: $durationMinutes)
                                .keyboardType(.numberPad)
                                .accessibilityLabel("Manual entry duration in minutes")
                            TextField("Optional private note", text: $note, axis: .vertical)
                                .lineLimit(2...5)
                                .accessibilityLabel("Optional local manual entry note")
                            Button("Save on this device") {
                                guard let minutes = Int(durationMinutes), store.addManualEntry(durationMinutes: minutes, note: note) else {
                                    return
                                }
                                note = ""
                            }
                            .disabled(!store.canWrite || Int(durationMinutes) == nil)
                            Text(store.storageStatus)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Today's local report") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(today.entryCount) manual entries · \(today.totalDurationSeconds / 60) minutes")
                                .font(.headline)
                            ForEach(store.entries) { entry in
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.startedAt, style: .time)
                                            .font(.subheadline)
                                        Text("\(entry.durationSeconds / 60) minutes")
                                            .font(.caption)
                                        if !entry.note.isEmpty {
                                            Text(entry.note).font(.footnote)
                                        }
                                    }
                                    Spacer()
                                    Button("Delete") { _ = store.deleteManualEntry(entry.id) }
                                        .accessibilityLabel("Delete manual entry")
                                }
                                .padding(.vertical, 4)
                            }
                            Text("Only manual entries are included in this report.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    NavigationLink("Sync and devices") {
                        CompanionSyncView(store: store.sync)
                    }

                    GroupBox("AI status") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(store.aiStatus)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("PeakActivity")
        }
        .familyActivityPicker(isPresented: $store.familyPickerPresented, selection: $store.familySelection)
        .onChange(of: store.familySelection) { selection in
            store.persistFamilySelection(selection)
        }
    }
}
