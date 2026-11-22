import AppKit
import Contacts
import SwiftUI
import TabMapCore

// MARK: - Settings section

struct AutofillSettingsSection: View {
    @AppStorage(AutofillStore.addressesEnabledKey) private var addresses = true
    @AppStorage(AutofillStore.useMeCardKey) private var useMeCard = true
    @AppStorage(AutofillStore.cardsEnabledKey) private var cards = true
    @AppStorage(AutofillStore.offerSaveKey) private var offerSave = true
    @ObservedObject private var store = AutofillStore.shared
    @State private var managingAddresses = false
    @State private var managingCards = false

    var body: some View {
        Section {
            Toggle("Fill addresses in forms", isOn: $addresses)
            Toggle("Include the addresses on my card in Contacts", isOn: $useMeCard)
                .disabled(!addresses)
                .onChange(of: useMeCard) { on in
                    if on && store.contactsStatus == .notDetermined { store.requestContactsAccess() } else { store.reloadMeCard() }
                }
            if useMeCard && addresses { contactsStatusRow }
            Toggle("Fill credit cards (asks for Touch ID each time)", isOn: $cards)
            Toggle("Offer to save new addresses and cards after a form is sent", isOn: $offerSave)
            HStack {
                Button("Addresses…") { managingAddresses = true }
                Button("Cards…") { managingCards = true }
            }
            Text("Card numbers are kept in your Mac's login keychain and are only read after Touch ID or your Mac's password. Security codes are never saved: after a card is filled, the cursor waits in the security code field.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $managingAddresses) { SavedAddressesView() }
        .sheet(isPresented: $managingCards) { SavedCardsView() }
        .onAppear { store.reloadMeCard() }
    }

    @ViewBuilder private var contactsStatusRow: some View {
        switch store.contactsStatus {
        case .authorized:
            Text(store.meCardAddresses.isEmpty
                 ? "Your card in Contacts has no details to fill. Pick your card in Contacts with Card > Make This My Card."
                 : "Using \(store.meCardAddresses.count == 1 ? "1 address" : "\(store.meCardAddresses.count) addresses") from your card in Contacts.")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .notDetermined:
            Button("Allow Access to Contacts…") { store.requestContactsAccess() }
        default:
            HStack {
                Text("Tabmap isn't allowed to read Contacts.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Button("Open Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

// MARK: - Addresses

struct SavedAddressesView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = AutofillStore.shared
    @State private var editing: AutofillAddress?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Addresses").font(.headline)
                Spacer()
                Button { editing = AutofillAddress(label: "Home") } label: { Label("Add Address", systemImage: "plus") }
            }
            List {
                if !store.meCardAddresses.isEmpty {
                    Section("From your card in Contacts") {
                        ForEach(store.meCardAddresses) { address in
                            row(address) {
                                Button("Edit in Contacts") { openContacts() }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
                Section(store.meCardAddresses.isEmpty ? "" : "Saved in Tabmap") {
                    if store.savedAddresses.isEmpty {
                        Text("No saved addresses yet. Add one here, or fill in a form and Tabmap will offer to save it.")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    ForEach(store.savedAddresses) { address in
                        row(address) {
                            Button { editing = address } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless).help("Edit")
                            Button { store.deleteAddress(address) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help("Delete")
                        }
                    }
                }
            }
            .frame(minHeight: 280)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560, height: 440)
        .sheet(item: $editing) { address in
            AddressEditor(address: address) { store.saveAddress($0) }
        }
    }

    private func row<Buttons: View>(_ address: AutofillAddress, @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(address.label.isEmpty ? address.fullName : address.label)
                Text(detailLine(address))
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            buttons()
        }
    }

    private func detailLine(_ a: AutofillAddress) -> String {
        let place = (a.streetLines + [a.city, a.region, a.postalCode, a.country]).filter { !$0.isEmpty }.joined(separator: ", ")
        return [a.fullName, place, a.email, a.phone].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func openContacts() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.AddressBook") {
            NSWorkspace.shared.open(app)
        }
    }
}

struct AddressEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var address: AutofillAddress
    let onSave: (AutofillAddress) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Address").font(.headline)
            Form {
                TextField("Label", text: $address.label, prompt: Text("Home, Work…"))
                TextField("First name", text: $address.givenName)
                TextField("Last name", text: $address.familyName)
                TextField("Company", text: $address.organization)
                TextField("Street", text: $address.street, prompt: Text("One line per line"), axis: .vertical)
                    .lineLimit(1...3)
                TextField("City", text: $address.city)
                TextField("State or region", text: $address.region)
                TextField("Postal code", text: $address.postalCode)
                TextField("Country", text: $address.country)
                    .onChange(of: address.country) { name in
                        address.countryCode = AutofillPlaces.code(forCountry: name) ?? ""
                    }
                TextField("Email", text: $address.email)
                TextField("Phone", text: $address.phone)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(address)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(address.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}

// MARK: - Cards

struct SavedCardsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = AutofillStore.shared
    @State private var editing: CardDraft?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Cards").font(.headline)
                Spacer()
                Button { editing = CardDraft() } label: { Label("Add Card", systemImage: "plus") }
            }
            List {
                if store.cards.isEmpty {
                    Text("No saved cards yet. Add one here, or pay on a site and Tabmap will offer to save the card.")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                ForEach(store.cards) { card in
                    HStack {
                        Image(systemName: "creditcard")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.nickname.isEmpty ? card.masked : "\(card.nickname) · \(card.masked)")
                            Text("\(card.holder.isEmpty ? "No name" : card.holder) · expires \(String(format: "%02d/%d", card.expMonth, card.expYear))")
                                .font(.system(size: 11))
                                .foregroundColor(card.isExpired() ? .red : .secondary)
                        }
                        Spacer()
                        Button { editing = CardDraft(card) } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless).help("Edit")
                        Button { remove(card) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Delete")
                    }
                }
            }
            .frame(minHeight: 260)
            if let error { Text(error).font(.system(size: 11)).foregroundColor(.red) }
            HStack {
                Text("Numbers stay in your login keychain. Security codes are never saved.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 540, height: 420)
        .onAppear { store.reloadCards() }
        .sheet(item: $editing) { draft in CardEditor(draft: draft) }
    }

    private func remove(_ card: CardSummary) {
        do { try store.deleteCard(card) } catch { self.error = error.localizedDescription }
    }
}

struct CardDraft: Identifiable {
    var id = UUID()
    /// The saved card being edited; nil for a new one.
    var existing: CardSummary?
    var number = ""
    var holder = ""
    var nickname = ""
    var expMonth = Calendar.current.component(.month, from: Date())
    var expYear = Calendar.current.component(.year, from: Date()) + 3

    init() {}

    init(_ card: CardSummary) {
        existing = card
        holder = card.holder
        nickname = card.nickname
        expMonth = card.expMonth
        expYear = card.expYear
    }
}

struct CardEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: CardDraft
    @State private var error: String?

    private var numberOK: Bool {
        draft.number.isEmpty ? draft.existing != nil : CardNumber.isValid(draft.number)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.existing == nil ? "Add Card" : "Edit \(draft.existing!.masked)").font(.headline)
            Form {
                TextField("Card number", text: $draft.number,
                          prompt: Text(draft.existing == nil ? "1234 5678 9012 3456" : "Leave empty to keep •••• \(draft.existing!.last4)"))
                if !draft.number.isEmpty {
                    Text(CardNumber.isValid(draft.number) ? CardNumber.brand(draft.number).displayName : "That number doesn't look right")
                        .font(.system(size: 11))
                        .foregroundColor(CardNumber.isValid(draft.number) ? .secondary : .red)
                }
                TextField("Name on card", text: $draft.holder)
                Picker("Expires", selection: $draft.expMonth) {
                    ForEach(1...12, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }
                Picker("Year", selection: $draft.expYear) {
                    let now = Calendar.current.component(.year, from: Date())
                    ForEach(Array(Set((now - 2)...(now + 15)).union([draft.expYear])).sorted(), id: \.self) { Text(String($0)).tag($0) }
                }
                TextField("Nickname", text: $draft.nickname, prompt: Text("Optional, e.g. Work card"))
            }
            if let error { Text(error).font(.system(size: 11)).foregroundColor(.red) }
            HStack {
                Text("No security code needed: it is never saved.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!numberOK)
            }
        }
        .padding(16)
        .frame(width: 440)
    }

    private func save() {
        let details = CardDetails(number: draft.number, holder: draft.holder.trimmingCharacters(in: .whitespaces),
                                  expMonth: draft.expMonth, expYear: draft.expYear)
        do {
            try AutofillStore.shared.saveCard(details, nickname: draft.nickname.trimmingCharacters(in: .whitespaces),
                                              replacing: draft.existing?.id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
