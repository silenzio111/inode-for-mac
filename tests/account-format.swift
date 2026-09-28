import Foundation

@main struct AccountFormatTests {
    static func main() {
        precondition(campusSubmittedAccount("synthetic-id", realm: "移动") == "synthetic-id@cm")
        precondition(campusSubmittedAccount("synthetic-id@cm", realm: "移动") == "synthetic-id@cm")
        precondition(campusSubmittedAccount("synthetic-id@custom", realm: "移动") == "synthetic-id@custom")
        precondition(campusSubmittedAccount("synthetic-id", realm: "") == "synthetic-id")
        precondition(campusSubmittedAccount("synthetic-id", realm: "电信") == "synthetic-id")
        precondition(campusSubmittedAccount("", realm: "移动").isEmpty)
        print("China Mobile account format and complete-account preservation passed")
    }
}
