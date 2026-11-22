import Contacts
import Foundation
import LocalAuthentication
import Security
import TabMapCore

/// Saved addresses and cards for form autofill.
///
/// Addresses: kept in ~/Library/Application Support/Tabmap/addresses.json (readable only by this
/// Mac user), plus, when that setting is on, the addresses on the "Me" card in Contacts, read
/// fresh each time so edits there show up. Tabmap never writes to Contacts.
///
/// Cards: one generic-password item per card in the login keychain. The number is the item's
/// secret and is only read after Touch ID or the Mac's password, every time. The cardholder,
/// brand, last four digits and expiry sit in the item's attributes so menus can show them without
/// unlocking. The security code is never stored anywhere.
@MainActor
final class AutofillStore: ObservableObject {
    static let shared = AutofillStore()

    static let addressesEnabledKey = "autofillAddresses"
    static let cardsEnabledKey = "autofillCards"
    static let useMeCardKey = "autofillUseMeCard"
    static let offerSaveKey = "autofillOfferSave"
    private static let cardService = "Tabmap Credit Card"

    enum StoreError: LocalizedError {
        case keychain(OSStatus)
        case cancelled
        case invalidCard
        var errorDescription: String? {
            switch self {
            case .keychain(let status):
                return (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
            case .cancelled: return "Cancelled"
            case .invalidCard: return "That card number doesn't look right"
            }
        }
    }

    /// Addresses typed in Settings or saved from forms.
    @Published private(set) var savedAddresses: [AutofillAddress] = []
    /// Addresses from the "Me" card in Contacts (empty when the setting is off or access was refused).
    @Published private(set) var meCardAddresses: [AutofillAddress] = []
    @Published private(set) var contactsStatus: CNAuthorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
    /// Saved cards, without numbers.
    @Published private(set) var cards: [CardSummary] = []

    private let fileURL: URL
    private let contacts = CNContactStore()
    private var contactsObserver: NSObjectProtocol?

    private init() {
        UserDefaults.standard.register(defaults: [
            Self.addressesEnabledKey: true,
            Self.cardsEnabledKey: true,
            Self.useMeCardKey: true,
            Self.offerSaveKey: true,
        ])
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let root = base.appendingPathComponent("Tabmap", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        fileURL = root.appendingPathComponent("addresses.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([AutofillAddress].self, from: data) {
            savedAddresses = saved
        }
        reloadCards()
        reloadMeCard()
        contactsObserver = NotificationCenter.default.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reloadMeCard() }
        }
    }

    var addressesEnabled: Bool { UserDefaults.standard.bool(forKey: Self.addressesEnabledKey) }
    var cardsEnabled: Bool { UserDefaults.standard.bool(forKey: Self.cardsEnabledKey) }
    var useMeCard: Bool { UserDefaults.standard.bool(forKey: Self.useMeCardKey) }
    var offerSaveEnabled: Bool { UserDefaults.standard.bool(forKey: Self.offerSaveKey) }

    /// Everything to offer in an address form: the Me card first, then saved addresses.
    var addresses: [AutofillAddress] {
        meCardAddresses + savedAddresses.filter { saved in !meCardAddresses.contains { $0.samePlace(as: saved) && !$0.streetLines.isEmpty } }
    }

    // MARK: Addresses

    func saveAddress(_ address: AutofillAddress) {
        guard !address.fromContacts else { return }
        if let i = savedAddresses.firstIndex(where: { $0.id == address.id }) {
            savedAddresses[i] = address
        } else {
            savedAddresses.append(address)
        }
        writeAddresses()
    }

    func deleteAddress(_ address: AutofillAddress) {
        savedAddresses.removeAll { $0.id == address.id }
        writeAddresses()
    }

    /// True when `address` is already saved or on the Me card.
    func knows(_ address: AutofillAddress) -> Bool {
        addresses.contains { $0.samePlace(as: address) }
    }

    private func writeAddresses() {
        guard let data = try? JSONEncoder().encode(savedAddresses) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    // MARK: The Me card

    /// Asks for Contacts access if it has not been asked yet, then reads the Me card.
    func requestContactsAccess() {
        contacts.requestAccess(for: .contacts) { _, _ in
            Task { @MainActor in
                self.contactsStatus = CNContactStore.authorizationStatus(for: .contacts)
                self.reloadMeCard()
            }
        }
    }

    func reloadMeCard() {
        contactsStatus = CNContactStore.authorizationStatus(for: .contacts)
        guard useMeCard, contactsStatus == .authorized else {
            meCardAddresses = []
            return
        }
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey, CNContactMiddleNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
            CNContactPostalAddressesKey, CNContactEmailAddressesKey, CNContactPhoneNumbersKey,
        ].map { $0 as CNKeyDescriptor }
        let store = contacts
        Task.detached {
            let me = try? store.unifiedMeContactWithKeys(toFetch: keys)
            let found = me.map(Self.addresses(from:)) ?? []
            await MainActor.run { self.meCardAddresses = found }
        }
    }

    /// One address per postal address on the card (or one with just the name, email and phone
    /// when it has none).
    nonisolated static func addresses(from contact: CNContact) -> [AutofillAddress] {
        let email = contact.emailAddresses.first.map { String($0.value) } ?? ""
        let phone = contact.phoneNumbers.first?.value.stringValue ?? ""
        func base(label: String) -> AutofillAddress {
            AutofillAddress(id: UUID(), label: label, givenName: contact.givenName, additionalName: contact.middleName,
                            familyName: contact.familyName, organization: contact.organizationName,
                            email: email, phone: phone, fromContacts: true)
        }
        guard !contact.postalAddresses.isEmpty else {
            let only = base(label: "My Card")
            return only.isEmpty ? [] : [only]
        }
        return contact.postalAddresses.map { labeled in
            let p = labeled.value
            var a = base(label: labeled.label.map { CNLabeledValue<CNPostalAddress>.localizedString(forLabel: $0).capitalized } ?? "My Card")
            a.street = p.street
            a.city = p.city
            a.region = p.state
            a.postalCode = p.postalCode
            a.country = p.country
            a.countryCode = p.isoCountryCode.uppercased()
            if a.countryCode.isEmpty, let code = AutofillPlaces.code(forCountry: p.country) { a.countryCode = code }
            return a
        }
    }

    // MARK: Cards

    private struct CardAttributes: Codable {
        var nickname: String
        var holder: String
        var brand: CardBrand
        var last4: String
        var expMonth: Int
        var expYear: Int
    }

    func reloadCards() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.cardService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else {
            cards = []
            return
        }
        cards = items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String, let id = UUID(uuidString: account),
                  let data = item[kSecAttrGeneric as String] as? Data,
                  let a = try? JSONDecoder().decode(CardAttributes.self, from: data) else { return nil }
            return CardSummary(id: id, nickname: a.nickname, holder: a.holder, brand: a.brand, last4: a.last4,
                               expMonth: a.expMonth, expYear: a.expYear)
        }
        .sorted { ($0.isExpired() ? 1 : 0, $0.nickname, $0.last4) < ($1.isExpired() ? 1 : 0, $1.nickname, $1.last4) }
    }

    /// The saved card with the same brand and last four digits, if any.
    func matchingCard(_ details: CardDetails) -> CardSummary? {
        let last4 = CardNumber.last4(details.number)
        return cards.first { $0.last4 == last4 && $0.brand == CardNumber.brand(details.number) }
    }

    /// Adds a card, or replaces the saved card with id `id`. Pass an empty `number` when editing
    /// to keep the stored number.
    @discardableResult
    func saveCard(_ details: CardDetails, nickname: String = "", replacing id: UUID? = nil) throws -> CardSummary {
        let keepNumber = details.number.isEmpty && id != nil
        let summary: CardSummary
        if keepNumber, let old = cards.first(where: { $0.id == id }) {
            summary = CardSummary(id: old.id, nickname: nickname, holder: details.holder, brand: old.brand,
                                  last4: old.last4, expMonth: details.expMonth, expYear: details.expYear)
        } else {
            guard let digits = CardNumber.digits(details.number), CardNumber.isValid(digits) else { throw StoreError.invalidCard }
            summary = CardDetails(number: digits, holder: details.holder, expMonth: details.expMonth, expYear: details.expYear)
                .summary(id: id ?? UUID(), nickname: nickname)
        }
        let attributes = CardAttributes(nickname: summary.nickname, holder: summary.holder, brand: summary.brand,
                                        last4: summary.last4, expMonth: summary.expMonth, expYear: summary.expYear)
        let generic = try JSONEncoder().encode(attributes)
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.cardService,
            kSecAttrAccount as String: summary.id.uuidString,
        ]
        var update: [String: Any] = [
            kSecAttrGeneric as String: generic,
            kSecAttrLabel as String: "Tabmap card \(summary.masked)",
        ]
        if !keepNumber { update[kSecValueData as String] = Data((CardNumber.digits(details.number) ?? "").utf8) }

        var status = SecItemUpdate(match as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            guard !keepNumber else { throw StoreError.keychain(status) }
            var add = match
            add.merge(update) { $1 }
            add[kSecAttrDescription as String] = "credit card"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        reloadCards()
        return summary
    }

    func deleteCard(_ card: CardSummary) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.cardService,
            kSecAttrAccount as String: card.id.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError.keychain(status) }
        reloadCards()
    }

    /// The card's full details, after Touch ID, an Apple Watch or the Mac's password. Asked every
    /// time, as Safari does for cards. Throws `.cancelled` if the person declines.
    func details(for card: CardSummary, reason: String) async throws -> CardDetails {
        try await unlock(reason: reason)
        let account = card.id.uuidString
        let service = Self.cardService
        let data: Data = try await Task.detached {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecReturnData as String: true,
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecUserCanceled || status == errSecAuthFailed { throw StoreError.cancelled }
            guard status == errSecSuccess, let data = result as? Data else { throw StoreError.keychain(status) }
            return data
        }.value
        return CardDetails(number: String(decoding: data, as: UTF8.self), holder: card.holder,
                           expMonth: card.expMonth, expYear: card.expYear)
    }

    private func unlock(reason: String) async throws {
        let context = LAContext()
        var error: NSError?
        // No password on this Mac: nothing to ask for.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            throw StoreError.cancelled
        }
    }
}
