import SwiftUI

struct DevicePickerView: View {
    @EnvironmentObject private var cast: CastController
    @Environment(\.dismiss) private var dismiss
    @State private var manualIP = ""
    @State private var adding = false
    @State private var addError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if cast.renderers.isEmpty {
                        Text(cast.isScanning ? "Looking for TVs…" : "No TVs found yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(cast.renderers) { tv in
                        Button {
                            cast.select(tv)
                            dismiss()
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "tv").font(.title2).foregroundStyle(.tint).frame(width: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tv.name).foregroundStyle(.primary)
                                    Text([tv.model, tv.host].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if cast.selected?.id == tv.id {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("TVs on your Wi-Fi")
                        Spacer()
                        if cast.isScanning { ProgressView().controlSize(.small) }
                    }
                }

                Section {
                    HStack {
                        TextField("e.g. 192.168.1.42", text: $manualIP)
                            .keyboardType(.decimalPad)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if adding {
                            ProgressView()
                        } else {
                            Button("Add") {
                                adding = true
                                Task {
                                    if await cast.addTV(ip: manualIP) {
                                        dismiss()
                                    } else {
                                        addError = cast.errorMessage
                                        cast.errorMessage = nil
                                    }
                                    adding = false
                                }
                            }
                            .disabled(manualIP.isEmpty)
                        }
                    }
                } header: {
                    Text("Add by IP address")
                } footer: {
                    Text("On the TV: Menu › Network › Network Status shows its IP address.")
                }

                Section("Can't find your TV?") {
                    Label("Turn the TV on and connect it to the same Wi-Fi as this iPhone.", systemImage: "wifi")
                    Label("Allow Local Network access: Settings › NazCast › Local Network.", systemImage: "lock.open")
                    Label("If the TV asks whether to allow a new device, choose Allow. On older models check Menu › Network › AllShare Settings.", systemImage: "checkmark.shield")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                if cast.selected != nil {
                    Section {
                        Button("Disconnect", role: .destructive) {
                            cast.select(nil)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Choose a TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .refreshable { await cast.scan() }
            .alert("Couldn't add TV", isPresented: Binding(
                get: { addError != nil },
                set: { if !$0 { addError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(addError ?? "")
            }
            .task {
                // Keep looking while the sheet is open. The first scan can come back empty
                // while iOS is still showing the Local Network permission prompt.
                while !Task.isCancelled {
                    await cast.scan()
                    try? await Task.sleep(for: .seconds(cast.renderers.isEmpty ? 3 : 10))
                }
            }
        }
    }
}
