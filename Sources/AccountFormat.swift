import Foundation

// SWUFE's Mac instructions use @cm for China Mobile. A complete account is
// submitted as entered, and the selected format never changes the password.
func campusSubmittedAccount(_ account: String, realm: String) -> String {
    guard !account.isEmpty, !account.contains("@"), realm == "移动" else { return account }
    return account + "@cm"
}
