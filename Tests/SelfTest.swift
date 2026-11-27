// Logic tests. Run with Tests/run.sh (compiled together with the app sources, minus the app bootstrap).
import AppKit
import CoreImage

var failures = 0
func check(_ cond: Bool, _ name: String) {
    print(cond ? "  ok   \(name)" : "  FAIL \(name)")
    if !cond { failures += 1 }
}

print("names / routes / hooks")
check(isValidName("wg-dev") && isValidName("a.b_c=d+e-f"), "valid names")
check(!isValidName("corporate-vpn-prd") && !isValidName("../x") && !isValidName("a b") && !isValidName(""), "invalid names rejected")
check(cidrOverlap("10.0.7.0/24", "10.0.0.0/16") && !cidrOverlap("10.1.0.0/16", "10.0.0.0/16"), "CIDR overlap")
check(!cidrOverlap("garbage", "10.0.0.0/8") && cidrOverlap("0.0.0.0/0", "172.16.0.0/16") && !cidrOverlap("10.0.0.0/99", "10.0.0.1/32"), "CIDR edge cases")
check(hookLines("  postup=x\nPreDown = y\n# PostUp = z\nPostUpX = w").count == 2, "hook detection")

let conf = """
[Interface]
PrivateKey = AAAA
Address = 10.10.3.10/32, fd00::10/128
DNS = 10.0.0.53,10.0.0.54, corp, lab.example
MTU = 1380

[Peer]
PublicKey = BBBB
AllowedIPs = 10.0.0.0/16, 10.100.0.0/16, fd00::/64
"""
check(allowedIPs(conf) == ["10.0.0.0/16", "10.100.0.0/16", "fd00::/64"], "AllowedIPs (IPv4 and IPv6)")
check(cidrOverlap("fd00::/64", "fd00::1/128") && !cidrOverlap("fd00::/64", "fd01::/64"), "IPv6 overlap")
check(cidrOverlap("::/0", "2001:db8::/32") && !cidrOverlap("::/0", "0.0.0.0/0"), "IPv6 default route, families never mix")
check(parseCIDR("10.0.0.0/33") == nil && parseCIDR("10.0.0.0/x") == nil && parseCIDR("fd00::/129") == nil && parseCIDR("10.0.0") == nil, "invalid CIDRs rejected")
check(parseCIDR("0.0.0.0/0")?.bits == 0 && parseCIDR("10.1.2.3")?.bits == 32, "prefix lengths")
check(resolverDomains("PostUp = printf 'x' > /etc/resolver/Corp\nPostDown = rm -f /etc/resolver/corp\nPostUp = echo /etc/resolver/lab.example") == ["corp", "lab.example"], "resolver domains from hooks")
let tmp = NSTemporaryDirectory() + "wgtest-\(UUID().uuidString).conf"
try! conf.write(toFile: tmp, atomically: true, encoding: .utf8)
check(tunnelAddress(tmp) == "10.10.3.10", "tunnel address")
try? FileManager.default.removeItem(atPath: tmp)

print("split DNS")
let plan = SplitDNS.plan(conf)!
check(plan.servers == ["10.0.0.53", "10.0.0.54"] && plan.domains == ["corp", "lab.example"], "plan servers/domains")
let converted = SplitDNS.convert(conf, plan: plan)
check(confValues(converted, key: "dns").isEmpty, "DNS line removed")
check(hookLines(converted).count == 4, "2 PostUp + 2 PostDown")
check(converted.contains("printf 'nameserver 10.0.0.53\\nnameserver 10.0.0.54\\n' > /etc/resolver/corp"), "resolver hook content")
check(converted.contains("[Peer]") && converted.contains("MTU = 1380"), "rest of config kept")
let ipOnly = "[Interface]\nPrivateKey = A\nDNS = 1.1.1.1\n[Peer]\nPublicKey = B\n"
let p2 = SplitDNS.plan(ipOnly)!
check(p2.domains.isEmpty && hookLines(SplitDNS.convert(ipOnly, plan: p2)).isEmpty && confValues(SplitDNS.convert(ipOnly, plan: p2), key: "dns").isEmpty, "IP-only DNS: line removed, no hooks")
check(SplitDNS.plan("[Interface]\nPrivateKey = A\n") == nil, "no DNS line -> no plan")
let evil = "[Interface]\nDNS = 10.0.0.1, x;rm -rf /, a$(id)\n"
check(SplitDNS.plan(evil)!.domains.isEmpty, "shell metacharacters never become domains")

print("cli")
check(CLI.run(["bogus"]) == 2 && CLI.run(["up"]) == 2 && CLI.run(["up", "no-such-tunnel"]) == 2, "cli rejects bad input")

print("updates")
check(Updates.isNewer("1.3.0", than: "1.2") && Updates.isNewer("1.10", than: "1.9.9"), "newer")
check(!Updates.isNewer("1.2.0", than: "1.2") && !Updates.isNewer("1.2", than: "1.2.1"), "not newer")

print("QR")
let qrText = conf
let filter = CIFilter(name: "CIQRCodeGenerator")!
filter.setValue(Data(qrText.utf8), forKey: "inputMessage")
let ci = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
let rep = NSCIImageRep(ciImage: ci)
let img = NSImage(size: rep.size); img.addRepresentation(rep)
check(QRImport.decode(img) == qrText, "QR round trip")

print("stats")
let table = interfaceTable()
check(!table.isEmpty && table.keys.allSatisfy { $0.hasPrefix("utun") }, "utun interface table (\(table.count) entries)")
check(formatBytes(1536).hasSuffix("KB") && formatBytes(3 * 1024 * 1024).hasSuffix("MB"), "byte formatting: \(formatBytes(1536)), \(formatBytes(3 * 1024 * 1024))")

print("helper scripts")
func bashN(_ text: String) -> Bool {
    let f = NSTemporaryDirectory() + "wgtest-\(UUID().uuidString).sh"
    try! text.write(toFile: f, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: f) }
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = ["-n", f]
    try! p.run(); p.waitUntilExit(); return p.terminationStatus == 0
}
func runHelper(_ args: [String]) -> Int32 {
    let f = NSTemporaryDirectory() + "wgtest-helper-\(UUID().uuidString).sh"
    try! Helper.script.write(toFile: f, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: f) }
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = [f] + args
    p.standardError = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice
    try! p.run(); p.waitUntilExit(); return p.terminationStatus
}
check(bashN(Helper.script), "helper script syntax")
check(bashN(Helper.installer(user: "tester", moveFrom: ["/tmp/a b.conf"])), "installer script syntax")
check(Helper.installer(user: "tester", moveFrom: ["/tmp/a b.conf"]).contains("'/tmp/a b.conf'"), "installer quotes paths")
check(runHelper(["up", "../../tmp/x"]) == 2, "helper rejects path traversal")
check(runHelper(["up", "corporate-vpn-prd"]) == 2, "helper rejects long names")
check(runHelper(["up", "x;id"]) == 2, "helper rejects shell metacharacters")
check(runHelper(["up", "nosuchtunnel"]) == 2, "helper rejects missing config")
check(runHelper(["up", "a", "extra"]) == 2, "helper rejects extra args")
check(runHelper(["rm", "-rf"]) == 2, "helper rejects unknown command")

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
