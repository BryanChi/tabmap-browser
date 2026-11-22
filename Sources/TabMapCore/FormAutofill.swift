import Foundation

// Pure rules behind address and card autofill: what each form field asks for, what to put in it,
// how card numbers are checked and shown, and what to offer to save after a form is sent.
// The page script, the keychain and Contacts live in the app.

/// What a form field asks for.
public enum AutofillFieldKind: String, Codable, CaseIterable, Sendable {
    case fullName, givenName, additionalName, familyName, organization
    case streetAddress, addressLine1, addressLine2, addressLine3
    case city, region, postalCode, country
    case email, phone
    case cardName, cardNumber, cardExpiry, cardExpMonth, cardExpYear, cardSecurityCode, cardType

    public var isCard: Bool {
        switch self {
        case .cardName, .cardNumber, .cardExpiry, .cardExpMonth, .cardExpYear, .cardSecurityCode, .cardType: return true
        default: return false
        }
    }

    public var isAddress: Bool { !isCard }
}

/// One option of a `<select>`.
public struct SelectOption: Codable, Hashable, Sendable {
    public var value: String
    public var text: String
    public init(value: String, text: String) {
        self.value = value
        self.text = text
    }
}

/// A form field as the page script describes it.
public struct FormField: Codable, Hashable, Sendable {
    public var index: Int
    /// "input", "select" or "textarea".
    public var tag: String
    public var type: String
    public var autocomplete: String
    public var name: String
    public var id: String
    public var label: String
    public var placeholder: String
    /// -1 when the page sets none.
    public var maxLength: Int
    public var options: [SelectOption]?
    /// The current value, only sent when a form is submitted. For a select, the chosen option's value.
    public var value: String?
    /// For a select, the chosen option's text.
    public var selectedText: String?

    public init(index: Int, tag: String = "input", type: String = "text", autocomplete: String = "",
                name: String = "", id: String = "", label: String = "", placeholder: String = "",
                maxLength: Int = -1, options: [SelectOption]? = nil, value: String? = nil, selectedText: String? = nil) {
        self.index = index
        self.tag = tag
        self.type = type
        self.autocomplete = autocomplete
        self.name = name
        self.id = id
        self.label = label
        self.placeholder = placeholder
        self.maxLength = maxLength
        self.options = options
        self.value = value
        self.selectedText = selectedText
    }

    public var isSelect: Bool { tag.lowercased() == "select" }
    public var isTextArea: Bool { tag.lowercased() == "textarea" }
}

// MARK: - What a field asks for

public enum FieldClassifier {
    /// What `field` asks for, or nil when it is not something autofill fills. The page's
    /// `autocomplete` attribute wins when it names a field; otherwise the field's name, id, label
    /// and placeholder are read.
    public static func classify(_ field: FormField) -> AutofillFieldKind? {
        let type = field.type.lowercased()
        if ["password", "hidden", "submit", "button", "checkbox", "radio", "file", "image", "reset",
            "search", "range", "color", "date", "datetime-local", "time", "week"].contains(type) {
            return nil
        }
        let ac = field.autocomplete.lowercased()
        // Sign-in fields belong to password autofill. "off" is ignored, as browsers do for addresses.
        if ac.split(separator: " ").contains(where: { $0 == "username" || $0.hasSuffix("password") || $0 == "one-time-code" }) {
            return nil
        }
        if let kind = fromAutocomplete(ac) { return kind }
        return fromHints(field)
    }

    /// Kinds for every field, by field index.
    public static func classify(_ fields: [FormField]) -> [Int: AutofillFieldKind] {
        var out: [Int: AutofillFieldKind] = [:]
        for field in fields {
            if let kind = classify(field) { out[field.index] = kind }
        }
        return refine(out, fields: fields)
    }

    /// The last token of an autocomplete attribute is the field name; "shipping", "billing",
    /// "section-…", "home", "work" and "mobile" come before it.
    static func fromAutocomplete(_ ac: String) -> AutofillFieldKind? {
        guard let token = ac.split(separator: " ").last.map(String.init) else { return nil }
        switch token {
        case "name": return .fullName
        case "given-name": return .givenName
        case "additional-name": return .additionalName
        case "family-name": return .familyName
        case "organization": return .organization
        case "street-address": return .streetAddress
        case "address-line1": return .addressLine1
        case "address-line2": return .addressLine2
        case "address-line3": return .addressLine3
        case "address-level2": return .city
        case "address-level1": return .region
        case "postal-code": return .postalCode
        case "country", "country-name": return .country
        case "email": return .email
        case "tel", "tel-national": return .phone
        case "cc-name", "cc-given-name", "cc-family-name": return .cardName
        case "cc-number": return .cardNumber
        case "cc-exp": return .cardExpiry
        case "cc-exp-month": return .cardExpMonth
        case "cc-exp-year": return .cardExpYear
        case "cc-csc": return .cardSecurityCode
        case "cc-type": return .cardType
        default: return nil
        }
    }

    /// Rules over the field's name, id, label and placeholder, in order; the first that matches wins.
    private static let rules: [(AutofillFieldKind, String)] = [
        (.cardSecurityCode, #"cvc|cvv|csc|cvn|security.?code|card.?verif|card.?code|\bcid\b"#),
        (.cardNumber, #"card.?num|cc.?num|cardno|card.?no\b|credit.?card|debit.?card|acct.?num|\bpan\b|card.?#|numero.?de.?tarjeta|kartennummer"#),
        (.cardName, #"name.?on.?card|card.?holder|cardholder|cc.?name|holder.?name|name.?on.?the.?card|card.?name"#),
        (.cardExpMonth, #"(exp|expir|valid).*(month|\bmm\b)|cc.?month|card.?month|\bexp.?mm\b|ccmonth"#),
        (.cardExpYear, #"(exp|expir|valid).*(year|\byy|yyyy)|cc.?year|card.?year|\bexp.?yy|ccyear"#),
        (.cardExpiry, #"expir|\bexp\b|exp.?date|mm.?/.?yy|valid.?thr|valid.?until|ablauf"#),
        (.email, #"e.?mail"#),
        (.organization, #"company|organi[sz]ation|business.?name|firm"#),
        (.postalCode, #"\bzip|postal|post.?code|postcode|\bpin.?code|plz\b"#),
        (.country, #"country|\bnation"#),
        (.region, #"\bstate\b|province|region|county|prefecture|address.?level.?1|\bstate.?code|\bstate_|_state\b|^state"#),
        (.city, #"city|town|locality|suburb|address.?level.?2|\bort\b"#),
        (.addressLine3, #"address.?(line)?.?3|addr.?3|line.?3"#),
        (.addressLine2, #"address.?(line)?.?2|addr.?2|\bline.?2|apt|apartment|suite|\bunit\b|\bflat\b|building|floor"#),
        (.addressLine1, #"address.?(line)?.?1|addr.?1|\bline.?1|street|address|\baddr\b|strasse|straße"#),
        (.phone, #"phone|mobile|\btel\b|telephone|cell"#),
        (.givenName, #"first.?name|given.?name|\bfname|forename|vorname|first$"#),
        (.familyName, #"last.?name|family.?name|surname|\blname|nachname|last$"#),
        (.additionalName, #"middle.?name|\bmname|middle.?initial"#),
        (.fullName, #"full.?name|your.?name|^name$|\bname\b|recipient|contact.?name"#),
    ]

    /// Fields that look like address fields but are something else.
    private static let notAutofill = #"search|coupon|promo|voucher|gift|captcha|username|user.?name|login|discount|referr|comment|message|subject|quantity|qty|otp|verification.?code"#

    static func fromHints(_ field: FormField) -> AutofillFieldKind? {
        let hints = [field.name, field.id, field.label, field.placeholder]
            .map(normalizeHint)
            .filter { !$0.isEmpty }
        guard !hints.isEmpty else { return field.type.lowercased() == "email" ? .email : nil }
        let joined = hints.joined(separator: " | ")
        if matches(joined, notAutofill) { return nil }
        let type = field.type.lowercased()
        if type == "email" { return .email }
        // Each hint on its own first, so "Name" in a label is not beaten by "card" in another hint's id.
        for hint in hints {
            for (kind, pattern) in rules where matches(hint, pattern) {
                return adjust(kind, field: field)
            }
        }
        if type == "tel" { return .phone }
        return nil
    }

    /// "billingZip", "billing_zip" and "billing-zip" all become "billing zip", so word rules match.
    static func normalizeHint(_ raw: String) -> String {
        var out = ""
        var previous: Character?
        for ch in raw {
            if ch.isUppercase, let p = previous, p.isLowercase { out.append(" ") }
            out.append(ch)
            previous = ch
        }
        out = out.lowercased()
        out = out.replacingOccurrences(of: #"[_\-\.\[\]():*#]+"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func adjust(_ kind: AutofillFieldKind, field: FormField) -> AutofillFieldKind {
        // A textarea asking for an address takes every line.
        if field.isTextArea, kind == .addressLine1 { return .streetAddress }
        return kind
    }

    /// Fixes that need the whole form: a lone "name" in a card form is the cardholder.
    static func refine(_ kinds: [Int: AutofillFieldKind], fields: [FormField]) -> [Int: AutofillFieldKind] {
        var out = kinds
        let values = Set(kinds.values)
        let hasCard = values.contains(.cardNumber)
        let hasAddress = values.contains { [.addressLine1, .streetAddress, .postalCode, .city].contains($0) }
        if hasCard && !hasAddress {
            for (index, kind) in kinds where kind == .fullName { out[index] = .cardName }
        }
        return out
    }

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

// MARK: - Addresses

/// A saved address with the name, email and phone that go with it.
public struct AutofillAddress: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// "Home", "Work", or what the person typed.
    public var label: String
    public var givenName: String
    public var additionalName: String
    public var familyName: String
    public var organization: String
    /// One line per line of the street address.
    public var street: String
    public var city: String
    public var region: String
    public var postalCode: String
    /// The country as written ("United States").
    public var country: String
    /// ISO 3166 two-letter code when known ("US").
    public var countryCode: String
    public var email: String
    public var phone: String
    /// True for an address read from the "Me" card in Contacts; those are not saved by Tabmap.
    public var fromContacts: Bool

    public init(id: UUID = UUID(), label: String = "", givenName: String = "", additionalName: String = "",
                familyName: String = "", organization: String = "", street: String = "", city: String = "",
                region: String = "", postalCode: String = "", country: String = "", countryCode: String = "",
                email: String = "", phone: String = "", fromContacts: Bool = false) {
        self.id = id
        self.label = label
        self.givenName = givenName
        self.additionalName = additionalName
        self.familyName = familyName
        self.organization = organization
        self.street = street
        self.city = city
        self.region = region
        self.postalCode = postalCode
        self.country = country
        self.countryCode = countryCode
        self.email = email
        self.phone = phone
        self.fromContacts = fromContacts
    }

    public var fullName: String {
        [givenName, additionalName, familyName].filter { !$0.isEmpty }.joined(separator: " ")
    }

    public var streetLines: [String] {
        street.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// One line for menus: "Home · 1 Infinite Loop, Cupertino".
    public var summary: String {
        let place = [streetLines.first ?? "", city].filter { !$0.isEmpty }.joined(separator: ", ")
        let lead = label.isEmpty ? fullName : label
        return [lead, place.isEmpty ? (email.isEmpty ? phone : email) : place]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    public var isEmpty: Bool {
        fullName.isEmpty && organization.isEmpty && street.isEmpty && city.isEmpty && postalCode.isEmpty
            && email.isEmpty && phone.isEmpty
    }

    /// Whether two addresses are the same place (first street line and postal code), ignoring case,
    /// spacing and punctuation.
    public func samePlace(as other: AutofillAddress) -> Bool {
        func key(_ s: String) -> String { AutofillText.fold(s) }
        return key(streetLines.first ?? "") == key(other.streetLines.first ?? "")
            && key(postalCode) == key(other.postalCode)
    }
}

// MARK: - Cards

public enum CardBrand: String, Codable, CaseIterable, Sendable {
    case visa, mastercard, amex, discover, dinersClub, jcb, unionPay, maestro, other

    public var displayName: String {
        switch self {
        case .visa: return "Visa"
        case .mastercard: return "Mastercard"
        case .amex: return "American Express"
        case .discover: return "Discover"
        case .dinersClub: return "Diners Club"
        case .jcb: return "JCB"
        case .unionPay: return "UnionPay"
        case .maestro: return "Maestro"
        case .other: return "Card"
        }
    }

    /// Words a card-type select uses for this brand.
    var aliases: [String] {
        switch self {
        case .visa: return ["visa"]
        case .mastercard: return ["mastercard", "master card", "mc", "master"]
        case .amex: return ["american express", "amex", "americanexpress", "ax"]
        case .discover: return ["discover", "di"]
        case .dinersClub: return ["diners club", "diners", "dinersclub", "dc"]
        case .jcb: return ["jcb"]
        case .unionPay: return ["unionpay", "union pay", "cup"]
        case .maestro: return ["maestro"]
        case .other: return []
        }
    }
}

public enum CardNumber {
    /// The digits of `text`, ignoring spaces and dashes. Nil if anything else is in it.
    public static func digits(_ text: String) -> String? {
        var out = ""
        for ch in text {
            if ch.isASCII, ch.isNumber { out.append(ch) }
            else if ch == " " || ch == "-" || ch == "\u{00A0}" { continue }
            else { return nil }
        }
        return out.isEmpty ? nil : out
    }

    /// The Luhn check every card number passes.
    public static func passesLuhn(_ digits: String) -> Bool {
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            guard var d = ch.wholeNumberValue else { return false }
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }

    /// A plausible card number: 12 to 19 digits that pass Luhn.
    public static func isValid(_ text: String) -> Bool {
        guard let d = digits(text), (12...19).contains(d.count) else { return false }
        return passesLuhn(d)
    }

    public static func brand(_ text: String) -> CardBrand {
        guard let d = digits(text) else { return .other }
        func prefix(_ n: Int) -> Int { Int(d.prefix(n)) ?? -1 }
        if d.hasPrefix("4") { return .visa }
        if (51...55).contains(prefix(2)) || (2221...2720).contains(prefix(4)) { return .mastercard }
        if d.hasPrefix("34") || d.hasPrefix("37") { return .amex }
        if d.hasPrefix("6011") || d.hasPrefix("65") || (644...649).contains(prefix(3)) { return .discover }
        if d.hasPrefix("36") || d.hasPrefix("38") || (300...305).contains(prefix(3)) { return .dinersClub }
        if (3528...3589).contains(prefix(4)) { return .jcb }
        if d.hasPrefix("62") { return .unionPay }
        if ["50", "56", "57", "58", "63", "67"].contains(String(d.prefix(2))) { return .maestro }
        return .other
    }

    public static func last4(_ text: String) -> String {
        String((digits(text) ?? "").suffix(4))
    }

    /// "Visa •••• 4242".
    public static func masked(brand: CardBrand, last4: String) -> String {
        "\(brand.displayName) •••• \(last4)"
    }
}

/// What Tabmap keeps about a card outside the keychain's secret: never the number or the
/// security code. The number lives in the keychain item, read after Touch ID.
public struct CardSummary: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var nickname: String
    public var holder: String
    public var brand: CardBrand
    public var last4: String
    public var expMonth: Int
    /// Four digits.
    public var expYear: Int

    public init(id: UUID = UUID(), nickname: String = "", holder: String, brand: CardBrand, last4: String,
                expMonth: Int, expYear: Int) {
        self.id = id
        self.nickname = nickname
        self.holder = holder
        self.brand = brand
        self.last4 = last4
        self.expMonth = expMonth
        self.expYear = expYear
    }

    public var masked: String { CardNumber.masked(brand: brand, last4: last4) }

    /// "Visa •••• 4242 · 08/27", or the nickname first when there is one.
    public var summary: String {
        let exp = String(format: "%02d/%02d", expMonth, expYear % 100)
        return [nickname, masked, exp].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    public func isExpired(now: Date = Date(), calendar: Calendar = Calendar(identifier: .gregorian)) -> Bool {
        let c = calendar.dateComponents([.year, .month], from: now)
        guard let y = c.year, let m = c.month else { return false }
        return expYear < y || (expYear == y && expMonth < m)
    }
}

/// A card as read from a form or typed in Settings, number included. Only ever held briefly.
public struct CardDetails: Hashable, Sendable {
    public var number: String
    public var holder: String
    public var expMonth: Int
    public var expYear: Int

    public init(number: String, holder: String, expMonth: Int, expYear: Int) {
        self.number = number
        self.holder = holder
        self.expMonth = expMonth
        self.expYear = expYear
    }

    public func summary(id: UUID = UUID(), nickname: String = "") -> CardSummary {
        CardSummary(id: id, nickname: nickname, holder: holder, brand: CardNumber.brand(number),
                    last4: CardNumber.last4(number), expMonth: expMonth, expYear: expYear)
    }
}

/// Reads an expiry date the way people and forms write it.
public enum CardExpiry {
    /// "08/27", "8/2027", "08 / 27", "0827" → (8, 2027). Nil when it is not a date.
    public static func parse(_ text: String) -> (month: Int, year: Int)? {
        let parts = text.split(whereSeparator: { !$0.isNumber }).map(String.init)
        var m: Int?, y: Int?
        if parts.count >= 2 {
            m = Int(parts[0]); y = Int(parts[1])
        } else if let only = parts.first, only.count == 4 || only.count == 6 {
            m = Int(only.prefix(2)); y = Int(only.dropFirst(2))
        }
        guard let month = m, let year = y.map(fullYear), (1...12).contains(month) else { return nil }
        return (month, year)
    }

    public static func fullYear(_ y: Int) -> Int { y < 100 ? 2000 + y : y }
}

// MARK: - Shared text helpers

public enum AutofillText {
    /// Lower case, no accents, letters and digits only.
    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Lower case, no accents, words separated by single spaces.
    static func words(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return folded.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).joined(separator: " ")
    }
}

// MARK: - Choosing a select option

public enum OptionMatcher {
    /// The option that best matches any of `candidates`, which are tried in order. Exact matches on
    /// the option's value or text come first, then options whose text starts with or holds the
    /// candidate as a whole word. Numbers match numbers ("8" matches "08").
    public static func best(_ candidates: [String], in options: [SelectOption]) -> SelectOption? {
        let wanted = candidates.map(AutofillText.words).filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return nil }
        let usable = options.filter { !AutofillText.words($0.text + $0.value).isEmpty }
        func same(_ a: String, _ b: String) -> Bool {
            if a == b { return true }
            if let x = Int(a), let y = Int(b), a.allSatisfy(\.isNumber), b.allSatisfy(\.isNumber) { return x == y }
            return false
        }
        for w in wanted {
            if let o = usable.first(where: { same(AutofillText.words($0.value), w) || same(AutofillText.words($0.text), w) }) {
                return o
            }
        }
        for w in wanted where w.count >= 2 {
            if let o = usable.first(where: {
                let t = AutofillText.words($0.text)
                let first = t.split(separator: " ").first.map(String.init) ?? ""
                return same(first, w) || t.hasPrefix(w + " ") || (w.count >= 4 && (" " + t + " ").contains(" " + w + " "))
            }) {
                return o
            }
        }
        return nil
    }
}

// MARK: - Regions and countries

public enum AutofillPlaces {
    /// US states and territories, and Canadian provinces: code → name.
    public static let regions: [String: String] = [
        "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas", "CA": "California", "CO": "Colorado",
        "CT": "Connecticut", "DE": "Delaware", "DC": "District of Columbia", "FL": "Florida", "GA": "Georgia",
        "HI": "Hawaii", "ID": "Idaho", "IL": "Illinois", "IN": "Indiana", "IA": "Iowa", "KS": "Kansas",
        "KY": "Kentucky", "LA": "Louisiana", "ME": "Maine", "MD": "Maryland", "MA": "Massachusetts",
        "MI": "Michigan", "MN": "Minnesota", "MS": "Mississippi", "MO": "Missouri", "MT": "Montana",
        "NE": "Nebraska", "NV": "Nevada", "NH": "New Hampshire", "NJ": "New Jersey", "NM": "New Mexico",
        "NY": "New York", "NC": "North Carolina", "ND": "North Dakota", "OH": "Ohio", "OK": "Oklahoma",
        "OR": "Oregon", "PA": "Pennsylvania", "RI": "Rhode Island", "SC": "South Carolina", "SD": "South Dakota",
        "TN": "Tennessee", "TX": "Texas", "UT": "Utah", "VT": "Vermont", "VA": "Virginia", "WA": "Washington",
        "WV": "West Virginia", "WI": "Wisconsin", "WY": "Wyoming", "PR": "Puerto Rico", "GU": "Guam",
        "VI": "U.S. Virgin Islands", "AS": "American Samoa", "MP": "Northern Mariana Islands",
        "AB": "Alberta", "BC": "British Columbia", "MB": "Manitoba", "NB": "New Brunswick",
        "NL": "Newfoundland and Labrador", "NS": "Nova Scotia", "NT": "Northwest Territories", "NU": "Nunavut",
        "ON": "Ontario", "PE": "Prince Edward Island", "QC": "Quebec", "SK": "Saskatchewan", "YT": "Yukon",
    ]

    /// Ways to write `region` that a select may use: as written, then its code or full name.
    static func regionCandidates(_ region: String) -> [String] {
        let trimmed = region.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        var out = [trimmed]
        if let name = regions[trimmed.uppercased()] { out.append(name) }
        if let code = regions.first(where: { AutofillText.fold($0.value) == AutofillText.fold(trimmed) })?.key { out.append(code) }
        return out
    }

    /// Ways to write a country: code, name as written, the English name, and common short forms.
    static func countryCandidates(name: String, code: String) -> [String] {
        var out: [String] = []
        let c = code.uppercased()
        if !c.isEmpty { out.append(c) }
        if !name.isEmpty { out.append(name) }
        if !c.isEmpty, let english = Locale(identifier: "en_US").localizedString(forRegionCode: c) { out.append(english) }
        switch c {
        case "US": out += ["United States of America", "USA", "U.S.A.", "U.S."]
        case "GB": out += ["United Kingdom", "UK", "Great Britain"]
        case "KR": out += ["South Korea", "Korea, Republic of"]
        case "RU": out += ["Russian Federation"]
        case "AE": out += ["UAE"]
        default: break
        }
        if c.isEmpty, !name.isEmpty, let found = Self.code(forCountry: name) { out.append(found) }
        return out
    }

    /// The ISO code for a country name in English or the current language.
    public static func code(forCountry name: String) -> String? {
        let key = AutofillText.fold(name)
        guard !key.isEmpty else { return nil }
        if key.count == 2 { return key.uppercased() }
        let aliases = ["usa": "US", "unitedstatesofamerica": "US", "uk": "GB", "greatbritain": "GB", "england": "GB"]
        if let a = aliases[key] { return a }
        for locale in [Locale(identifier: "en_US"), Locale.current] {
            for c in Locale.Region.isoRegions.map(\.identifier) where c.count == 2 {
                if let n = locale.localizedString(forRegionCode: c), AutofillText.fold(n) == key { return c }
            }
        }
        return nil
    }
}

// MARK: - What to put in each field

public enum AutofillPlanner {
    /// Values to fill, by field index. For a select, the value of the option to choose. The page
    /// script leaves fields that already hold text alone, except the one being filled from.
    public static func values(for address: AutofillAddress, fields: [FormField],
                              kinds: [Int: AutofillFieldKind]) -> [Int: String] {
        let present = Set(kinds.values)
        let lines = address.streetLines
        var out: [Int: String] = [:]
        for field in fields {
            guard let kind = kinds[field.index], kind.isAddress else { continue }
            var value: String
            switch kind {
            case .fullName:
                value = address.fullName
            case .givenName:
                // With no last-name field, the first-name field takes the whole name.
                value = present.contains(.familyName) ? address.givenName : address.fullName
            case .additionalName: value = address.additionalName
            case .familyName: value = address.familyName
            case .organization: value = address.organization
            case .streetAddress:
                value = field.isTextArea ? lines.joined(separator: "\n") : lines.joined(separator: ", ")
            case .addressLine1:
                value = present.contains(.addressLine2) ? (lines.first ?? "") : lines.joined(separator: ", ")
            case .addressLine2:
                let rest = Array(lines.dropFirst())
                value = present.contains(.addressLine3) ? (rest.first ?? "") : rest.joined(separator: ", ")
            case .addressLine3:
                value = lines.dropFirst(2).joined(separator: ", ")
            case .city: value = address.city
            case .region: value = address.region
            case .postalCode: value = address.postalCode
            case .country: value = address.country.isEmpty ? address.countryCode : address.country
            case .email: value = address.email
            case .phone: value = phone(address.phone, field: field)
            default: continue
            }
            if field.isSelect {
                let candidates: [String]
                switch kind {
                case .region: candidates = AutofillPlaces.regionCandidates(address.region)
                case .country: candidates = AutofillPlaces.countryCandidates(name: address.country, code: address.countryCode)
                default: candidates = [value]
                }
                guard let option = OptionMatcher.best(candidates, in: field.options ?? []) else { continue }
                value = option.value
            } else if field.maxLength > 0, value.count > field.maxLength {
                if kind == .region, let code = AutofillPlaces.regionCandidates(address.region).first(where: { $0.count <= field.maxLength }) {
                    value = code
                } else if kind == .country, address.countryCode.count <= field.maxLength, !address.countryCode.isEmpty {
                    value = address.countryCode
                } else {
                    value = String(value.prefix(field.maxLength))
                }
            }
            if !value.isEmpty { out[field.index] = value }
        }
        return out
    }

    /// Values for a card form. The security code is never filled: it is never stored.
    public static func values(for card: CardDetails, fields: [FormField],
                              kinds: [Int: AutofillFieldKind]) -> [Int: String] {
        var out: [Int: String] = [:]
        let digits = CardNumber.digits(card.number) ?? card.number
        let mm = String(format: "%02d", card.expMonth)
        let yyyy = String(card.expYear)
        let yy = String(format: "%02d", card.expYear % 100)
        for field in fields {
            guard let kind = kinds[field.index], kind.isCard else { continue }
            var value: String
            var candidates: [String] = []
            switch kind {
            case .cardName: value = card.holder
            case .cardNumber: value = digits
            case .cardExpiry:
                let hint = (field.placeholder + " " + field.label).lowercased()
                let long = hint.contains("yyyy")
                value = mm + "/" + (long ? yyyy : yy)
                if hint.contains(" / ") { value = mm + " / " + (long ? yyyy : yy) }
                candidates = [mm + "/" + yy, mm + "/" + yyyy, mm + yy]
            case .cardExpMonth:
                value = field.maxLength == 1 ? String(card.expMonth) : mm
                candidates = [mm, String(card.expMonth)] + monthNames(card.expMonth)
            case .cardExpYear:
                value = field.maxLength == 2 ? yy : yyyy
                candidates = [yyyy, yy]
            case .cardType:
                let brand = CardNumber.brand(digits)
                value = brand.displayName
                candidates = [brand.displayName] + brand.aliases
            default: continue
            }
            if field.isSelect {
                guard let option = OptionMatcher.best(candidates.isEmpty ? [value] : candidates, in: field.options ?? []) else { continue }
                value = option.value
            }
            if !value.isEmpty { out[field.index] = value }
        }
        return out
    }

    static func monthNames(_ month: Int) -> [String] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        guard (1...12).contains(month) else { return [] }
        return [f.monthSymbols[month - 1], f.shortMonthSymbols[month - 1]]
    }

    /// Phone fields that only take digits get digits; the rest get the number as saved.
    static func phone(_ phone: String, field: FormField) -> String {
        let digits = phone.filter(\.isNumber)
        if field.maxLength > 0, phone.count > field.maxLength {
            // A national number, without the country code, when the field is short.
            if phone.hasPrefix("+1"), digits.count == 11, field.maxLength >= 10 { return String(digits.dropFirst()) }
            return String(digits.suffix(field.maxLength))
        }
        return phone
    }

    // MARK: Reading a sent form

    /// The address a sent form holds, or nil when there is not enough of one to be worth saving
    /// (a street line and either a city or a postal code).
    public static func address(from fields: [FormField], kinds: [Int: AutofillFieldKind]) -> AutofillAddress? {
        var a = AutofillAddress()
        var line1 = "", line2 = "", line3 = "", street = "", full = ""
        for field in fields {
            guard let kind = kinds[field.index], kind.isAddress else { continue }
            let raw = (field.isSelect ? (field.selectedText ?? field.value) : field.value) ?? ""
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            switch kind {
            case .fullName: full = value
            case .givenName: a.givenName = value
            case .additionalName: a.additionalName = value
            case .familyName: a.familyName = value
            case .organization: a.organization = value
            case .streetAddress: street = value
            case .addressLine1: line1 = value
            case .addressLine2: line2 = value
            case .addressLine3: line3 = value
            case .city: a.city = value
            case .region: a.region = value
            case .postalCode: a.postalCode = value
            case .country:
                a.country = value
                a.countryCode = AutofillPlaces.code(forCountry: value)
                    ?? (field.value.map { $0.count == 2 ? $0.uppercased() : "" } ?? "")
            case .email: a.email = value
            case .phone: a.phone = value
            default: break
            }
        }
        if !full.isEmpty, a.givenName.isEmpty, a.familyName.isEmpty {
            let parts = full.split(separator: " ").map(String.init)
            a.givenName = parts.first ?? ""
            a.familyName = parts.count > 1 ? parts.dropFirst().joined(separator: " ") : ""
        }
        a.street = street.isEmpty ? [line1, line2, line3].filter { !$0.isEmpty }.joined(separator: "\n") : street
        guard !a.streetLines.isEmpty, !a.city.isEmpty || !a.postalCode.isEmpty else { return nil }
        return a
    }

    /// The card a sent form holds, or nil without a valid number and expiry. The security code is
    /// never read.
    public static func card(from fields: [FormField], kinds: [Int: AutofillFieldKind]) -> CardDetails? {
        var number: String?, holder = "", month: Int?, year: Int?
        for field in fields {
            guard let kind = kinds[field.index] else { continue }
            let value = (field.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let text = (field.selectedText ?? value).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            switch kind {
            case .cardNumber: number = CardNumber.digits(value)
            case .cardName: holder = value
            case .cardExpiry:
                if let e = CardExpiry.parse(value) { month = e.month; year = e.year }
            case .cardExpMonth:
                month = Int(value) ?? leadingNumber(text) ?? monthNumber(text)
            case .cardExpYear:
                year = (Int(value) ?? Int(text)).map(CardExpiry.fullYear)
            default: break
            }
        }
        guard let n = number, CardNumber.isValid(n), let m = month, (1...12).contains(m), let y = year else { return nil }
        return CardDetails(number: n, holder: holder, expMonth: m, expYear: y)
    }

    static func leadingNumber(_ text: String) -> Int? {
        let digits = text.prefix(while: { $0.isNumber || $0 == " " }).filter(\.isNumber)
        return digits.isEmpty ? nil : Int(digits)
    }

    static func monthNumber(_ text: String) -> Int? {
        let key = AutofillText.fold(text)
        guard key.count >= 3 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.monthSymbols.firstIndex { AutofillText.fold($0).hasPrefix(key) || key.hasPrefix(AutofillText.fold($0)) }.map { $0 + 1 }
    }
}

// MARK: - What to offer

public enum AutofillOffer: Equatable, Sendable {
    case none
    case address
    case card

    /// What to offer when `focused` gets focus in a form whose fields are `kinds`. Address fill
    /// needs at least two address fields in the form, or one street, city or postal code field,
    /// so a lone "email" box in a newsletter sign-up does not get an offer.
    public static func forFocus(_ focused: Int, kinds: [Int: AutofillFieldKind]) -> AutofillOffer {
        guard let kind = kinds[focused] else { return .none }
        if kind.isCard {
            return kind == .cardSecurityCode ? .none : .card
        }
        let addressKinds = Set(kinds.values.filter(\.isAddress))
        let strong: Set<AutofillFieldKind> = [.streetAddress, .addressLine1, .city, .postalCode]
        if addressKinds.count >= 2 || !addressKinds.isDisjoint(with: strong) { return .address }
        return .none
    }
}
