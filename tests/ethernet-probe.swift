import Foundation

@main struct EthernetProbeTests {
    static func main() {
        let reply = """
        {"Status":0,"Answer":[
          {"type":5,"data":"www.wshifen.com."},
          {"type":1,"data":"198.18.0.11"},
          {"type":1,"data":"198.19.0.11"},
          {"type":1,"data":"127.0.0.1"},
          {"type":1,"data":"10.53.241.37"},
          {"type":1,"data":"103.235.47.188"},
          {"type":1,"data":"103.235.47.189"}
        ]}
        """
        precondition(publicIPv4Answers(from: Data(reply.utf8)) == ["103.235.47.188", "103.235.47.189"])
        precondition(publicIPv4Answers(from: Data(#"{"Status":2,"Answer":[{"type":1,"data":"103.235.47.188"}]}"#.utf8)).isEmpty)
        precondition(publicIPv4Answers(from: Data("not JSON".utf8)).isEmpty)
        print("Proxy fake DNS addresses are excluded from Ethernet HTTPS targets")
    }
}
