import XCTest
@testable import TabMapCore

final class FormAutofillTests: XCTestCase {

    private func field(_ index: Int, tag: String = "input", type: String = "text", ac: String = "",
                       name: String = "", id: String = "", label: String = "", placeholder: String = "",
                       maxLength: Int = -1, options: [SelectOption]? = nil, value: String? = nil,
                       selectedText: String? = nil) -> FormField {
        FormField(index: index, tag: tag, type: type, autocomplete: ac, name: name, id: id, label: label,
                  placeholder: placeholder, maxLength: maxLength, options: options, value: value, selectedText: selectedText)
    }

    // MARK: What a field asks for

    func testAutocompleteAttributeWins() {
        XCTAssertEqual(FieldClassifier.classify(field(0, ac: "shipping address-line1", name: "zip")), .addressLine1)
        XCTAssertEqual(FieldClassifier.classify(field(0, ac: "section-a billing postal-code")), .postalCode)
        XCTAssertEqual(FieldClassifier.classify(field(0, ac: "home tel")), .phone)
        XCTAssertEqual(FieldClassifier.classify(field(0, ac: "cc-exp")), .cardExpiry)
        XCTAssertEqual(FieldClassifier.classify(field(0, ac: "address-level1")), .region)
        XCTAssertEqual(FieldClassifier.classify(field(0, ac: "address-level2")), .city)
        XCTAssertNil(FieldClassifier.classify(field(0, ac: "username", name: "email")))
        XCTAssertNil(FieldClassifier.classify(field(0, type: "password", name: "card_number")))
    }

    func testNamesIdsAndLabels() {
        XCTAssertEqual(FieldClassifier.classify(field(0, name: "billingZip")), .postalCode)
        XCTAssertEqual(FieldClassifier.classify(field(0, name: "billing_zip")), .postalCode)
        XCTAssertEqual(FieldClassifier.classify(field(0, label: "First name")), .givenName)
        XCTAssertEqual(FieldClassifier.classify(field(0, id: "lastName")), .familyName)
        XCTAssertEqual(FieldClassifier.classify(field(0, label: "Street address")), .addressLine1)
        XCTAssertEqual(FieldClassifier.classify(field(0, label: "Apt, suite, etc. (optional)")), .addressLine2)
        XCTAssertEqual(FieldClassifier.classify(field(0, name: "address2")), .addressLine2)
        XCTAssertEqual(FieldClassifier.classify(field(0, label: "City")), .city)
        XCTAssertEqual(FieldClassifier.classify(field(0, tag: "select", label: "State")), .region)
        XCTAssertEqual(FieldClassifier.classify(field(0, label: "Email address")), .email)
        XCTAssertEqual(FieldClassifier.classify(field(0, type: "tel", name: "x1")), .phone)
        XCTAssertEqual(FieldClassifier.classify(field(0, label: "Company name")), .organization)
        XCTAssertEqual(FieldClassifier.classify(field(0, name: "cardnumber")), .cardNumber)
        XCTAssertEqual(FieldClassifier.classify(field(0, name: "exp-date", placeholder: "MM / YY")), .cardExpiry)
        XCTAssertEqual(FieldClassifier.classify(field(0, name: "cvc")), .cardSecurityCode)
        XCTAssertEqual(FieldClassifier.classify(field(0, label: "Name on card")), .cardName)
        XCTAssertEqual(FieldClassifier.classify(field(0, tag: "select", name: "expiry_month")), .cardExpMonth)
        XCTAssertEqual(FieldClassifier.classify(field(0, tag: "select", name: "expiry_year")), .cardExpYear)
        XCTAssertEqual(FieldClassifier.classify(field(0, tag: "textarea", label: "Address")), .streetAddress)
    }

    func testFieldsThatAreNotForAutofill() {
        XCTAssertNil(FieldClassifier.classify(field(0, name: "q", placeholder: "Search")))
        XCTAssertNil(FieldClassifier.classify(field(0, label: "Promo code")))
        XCTAssertNil(FieldClassifier.classify(field(0, label: "Username")))
        XCTAssertNil(FieldClassifier.classify(field(0, type: "hidden", name: "address1")))
        XCTAssertNil(FieldClassifier.classify(field(0, name: "quantity")))
    }

    func testLoneNameInCardFormIsCardholder() {
        let fields = [field(0, label: "Name"), field(1, name: "cardnumber"), field(2, name: "cvc")]
        let kinds = FieldClassifier.classify(fields)
        XCTAssertEqual(kinds[0], .cardName)
        XCTAssertEqual(kinds[1], .cardNumber)
    }

    // MARK: Cards

    func testLuhnAndBrands() {
        XCTAssertTrue(CardNumber.isValid("4242 4242 4242 4242"))
        XCTAssertTrue(CardNumber.isValid("5555-5555-5555-4444"))
        XCTAssertTrue(CardNumber.isValid("378282246310005"))
        XCTAssertFalse(CardNumber.isValid("4242 4242 4242 4241"))
        XCTAssertFalse(CardNumber.isValid("4242"))
        XCTAssertFalse(CardNumber.isValid("4242a4242424242"))
        XCTAssertEqual(CardNumber.brand("4242424242424242"), .visa)
        XCTAssertEqual(CardNumber.brand("5555555555554444"), .mastercard)
        XCTAssertEqual(CardNumber.brand("2223003122003222"), .mastercard)
        XCTAssertEqual(CardNumber.brand("378282246310005"), .amex)
        XCTAssertEqual(CardNumber.brand("6011111111111117"), .discover)
        XCTAssertEqual(CardNumber.brand("3530111333300000"), .jcb)
        XCTAssertEqual(CardNumber.last4("4242 4242 4242 4242"), "4242")
        XCTAssertEqual(CardNumber.masked(brand: .visa, last4: "4242"), "Visa •••• 4242")
    }

    func testExpiryParsing() {
        XCTAssertEqual(CardExpiry.parse("08/27")?.month, 8)
        XCTAssertEqual(CardExpiry.parse("08/27")?.year, 2027)
        XCTAssertEqual(CardExpiry.parse("8 / 2031")?.year, 2031)
        XCTAssertEqual(CardExpiry.parse("0827")?.month, 8)
        XCTAssertNil(CardExpiry.parse("13/27"))
        XCTAssertNil(CardExpiry.parse("hello"))
    }

    func testExpiredCard() {
        let card = CardSummary(holder: "A", brand: .visa, last4: "4242", expMonth: 1, expYear: 2020)
        XCTAssertTrue(card.isExpired())
        let fresh = CardSummary(holder: "A", brand: .visa, last4: "4242", expMonth: 12, expYear: 2099)
        XCTAssertFalse(fresh.isExpired())
    }

    private let card = CardDetails(number: "4242 4242 4242 4242", holder: "Ada Lovelace", expMonth: 8, expYear: 2027)

    func testCardValuesForTextFields() {
        let fields = [field(0, ac: "cc-name"), field(1, ac: "cc-number"),
                      field(2, ac: "cc-exp", placeholder: "MM / YY"), field(3, ac: "cc-csc")]
        let v = AutofillPlanner.values(for: card, fields: fields, kinds: FieldClassifier.classify(fields))
        XCTAssertEqual(v[0], "Ada Lovelace")
        XCTAssertEqual(v[1], "4242424242424242")
        XCTAssertEqual(v[2], "08 / 27")
        XCTAssertNil(v[3], "the security code is never filled")
    }

    func testCardValuesForSelects() {
        let months = (1...12).map { SelectOption(value: String($0), text: String(format: "%02d - %@", $0, DateFormatter().monthSymbols[$0 - 1])) }
        let years = (2025...2035).map { SelectOption(value: String($0), text: String($0)) }
        let types = [SelectOption(value: "", text: "Choose"), SelectOption(value: "MC", text: "MasterCard"), SelectOption(value: "VI", text: "Visa")]
        let fields = [field(0, tag: "select", ac: "cc-exp-month", options: months),
                      field(1, tag: "select", ac: "cc-exp-year", options: years),
                      field(2, tag: "select", ac: "cc-type", options: types),
                      field(3, ac: "cc-exp-year", maxLength: 2)]
        let v = AutofillPlanner.values(for: card, fields: fields, kinds: FieldClassifier.classify(fields))
        XCTAssertEqual(v[0], "8")
        XCTAssertEqual(v[1], "2027")
        XCTAssertEqual(v[2], "VI")
        XCTAssertEqual(v[3], "27")
    }

    func testReadingASentCardForm() {
        let fields = [field(0, ac: "cc-number", value: "4242 4242 4242 4242"), field(1, ac: "cc-exp", value: "08/27"),
                      field(2, ac: "cc-name", value: "Ada Lovelace"), field(3, ac: "cc-csc", value: "123")]
        let read = AutofillPlanner.card(from: fields, kinds: FieldClassifier.classify(fields))
        XCTAssertEqual(read, card.withDigitsOnly)
        let bad = [field(0, ac: "cc-number", value: "4242 4242 4242 4241"), field(1, ac: "cc-exp", value: "08/27")]
        XCTAssertNil(AutofillPlanner.card(from: bad, kinds: FieldClassifier.classify(bad)))
    }

    // MARK: Addresses

    private let home = AutofillAddress(label: "Home", givenName: "Ada", familyName: "Lovelace",
                                       street: "1 Infinite Loop\nBuilding 2", city: "Cupertino", region: "CA",
                                       postalCode: "95014", country: "United States", countryCode: "US",
                                       email: "ada@example.com", phone: "+1 408 555 0100")

    func testAddressValuesSplitNamesAndLines() {
        let fields = [field(0, ac: "given-name"), field(1, ac: "family-name"), field(2, ac: "address-line1"),
                      field(3, ac: "address-line2"), field(4, ac: "address-level2"), field(5, ac: "postal-code"),
                      field(6, ac: "email"), field(7, ac: "tel")]
        let v = AutofillPlanner.values(for: home, fields: fields, kinds: FieldClassifier.classify(fields))
        XCTAssertEqual(v[0], "Ada")
        XCTAssertEqual(v[1], "Lovelace")
        XCTAssertEqual(v[2], "1 Infinite Loop")
        XCTAssertEqual(v[3], "Building 2")
        XCTAssertEqual(v[4], "Cupertino")
        XCTAssertEqual(v[5], "95014")
        XCTAssertEqual(v[6], "ada@example.com")
        XCTAssertEqual(v[7], "+1 408 555 0100")
    }

    func testAddressValuesJoinWhenTheFormHasFewerFields() {
        let fields = [field(0, ac: "name"), field(1, ac: "address-line1"), field(2, tag: "textarea", ac: "street-address")]
        let v = AutofillPlanner.values(for: home, fields: fields, kinds: FieldClassifier.classify(fields))
        XCTAssertEqual(v[0], "Ada Lovelace")
        XCTAssertEqual(v[1], "1 Infinite Loop, Building 2")
        XCTAssertEqual(v[2], "1 Infinite Loop\nBuilding 2")
    }

    func testRegionAndCountrySelects() {
        let states = [SelectOption(value: "", text: "Select"), SelectOption(value: "AZ", text: "Arizona"),
                      SelectOption(value: "CA", text: "California")]
        let statesByName = [SelectOption(value: "12", text: "Arizona"), SelectOption(value: "13", text: "California")]
        let countries = [SelectOption(value: "CA", text: "Canada"), SelectOption(value: "USA", text: "United States of America")]
        let fields = [field(0, tag: "select", ac: "address-level1", options: states),
                      field(1, tag: "select", label: "State", options: statesByName),
                      field(2, tag: "select", ac: "country", options: countries),
                      field(3, ac: "address-level1", maxLength: 2)]
        let full = AutofillAddress(region: "California", country: "United States", countryCode: "US")
        let v = AutofillPlanner.values(for: full, fields: fields, kinds: FieldClassifier.classify(fields))
        XCTAssertEqual(v[0], "CA")
        XCTAssertEqual(v[1], "13")
        XCTAssertEqual(v[2], "USA", "the country is not confused with Canada's code")
        XCTAssertEqual(v[3], "CA")
    }

    func testReadingASentAddressForm() {
        let fields = [field(0, ac: "name", value: "Ada King Lovelace"), field(1, ac: "address-line1", value: "1 Infinite Loop"),
                      field(2, ac: "address-level2", value: "Cupertino"), field(3, ac: "postal-code", value: "95014"),
                      field(4, tag: "select", ac: "country", value: "US", selectedText: "United States")]
        let a = AutofillPlanner.address(from: fields, kinds: FieldClassifier.classify(fields))
        XCTAssertEqual(a?.givenName, "Ada")
        XCTAssertEqual(a?.familyName, "King Lovelace")
        XCTAssertEqual(a?.country, "United States")
        XCTAssertEqual(a?.countryCode, "US")
        XCTAssertTrue(a?.samePlace(as: home) ?? false)
        let thin = [field(0, ac: "email", value: "a@b.c"), field(1, ac: "name", value: "Ada")]
        XCTAssertNil(AutofillPlanner.address(from: thin, kinds: FieldClassifier.classify(thin)))
    }

    // MARK: What to offer

    func testOffers() {
        let checkout = FieldClassifier.classify([field(0, ac: "name"), field(1, ac: "address-line1"), field(2, ac: "cc-number"), field(3, ac: "cc-csc")])
        XCTAssertEqual(AutofillOffer.forFocus(0, kinds: checkout), .address)
        XCTAssertEqual(AutofillOffer.forFocus(2, kinds: checkout), .card)
        XCTAssertEqual(AutofillOffer.forFocus(3, kinds: checkout), .none)
        let newsletter = FieldClassifier.classify([field(0, type: "email", name: "email")])
        XCTAssertEqual(AutofillOffer.forFocus(0, kinds: newsletter), .none)
    }

    func testOptionMatcherNumbersAndWords() {
        let options = [SelectOption(value: "", text: "Month"), SelectOption(value: "1", text: "01"), SelectOption(value: "10", text: "10")]
        XCTAssertEqual(OptionMatcher.best(["01", "1"], in: options)?.value, "1")
        XCTAssertNil(OptionMatcher.best(["zzz"], in: options))
    }
}

private extension CardDetails {
    var withDigitsOnly: CardDetails {
        CardDetails(number: CardNumber.digits(number) ?? number, holder: holder, expMonth: expMonth, expYear: expYear)
    }
}
