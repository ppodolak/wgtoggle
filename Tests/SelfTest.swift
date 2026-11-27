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

print("conflicts")
let a = "[Interface]\nPostUp = printf x > /etc/resolver/corp\n[Peer]\nAllowedIPs = 10.0.0.0/16, ::/0, 10.0.0.0/40\n"
let b = "[Interface]\nPostUp = printf y > /etc/resolver/corp\n[Peer]\nAllowedIPs = 10.0.5.0/24\n"
let found = conflicts(name: "a", conf: a, others: [(name: "b", conf: b)])
check(found.contains { $0.contains("10.0.0.0/16 overlaps b: 10.0.5.0/24") }, "route overlap reported")
check(found.contains { $0.contains("::/0 sends ALL IPv6") }, "IPv6 default route reported")
check(found.contains { $0.contains("10.0.0.0/40 is not a valid network") }, "invalid entry reported")
check(found.contains { $0.contains("split DNS for corp") }, "shared resolver domain reported")
check(conflicts(name: "b", conf: b, others: []).isEmpty, "clean config has no conflicts")

print("restart backoff")
let now = Date()
check(restartDelay(previous: [], now: now) == 10, "first restart after 10s")
check(restartDelay(previous: [now.addingTimeInterval(-60), now.addingTimeInterval(-30)], now: now) == 40, "third restart after 40s")
check(restartDelay(previous: [now, now, now].map { $0.addingTimeInterval(-60) }, now: now) == nil, "gives up after 3 in 15 min")
check(restartDelay(previous: [now, now, now].map { $0.addingTimeInterval(-16 * 60) }, now: now) == 10, "resets after 15 min")

print("cli")
check(CLI.run(["bogus"]) == 2 && CLI.run(["up"]) == 2 && CLI.run(["up", "no-such-tunnel"]) == 2, "cli rejects bad input")

print("shared split DNS")
do {
    let base = NSTemporaryDirectory() + "wgdns-\(UUID().uuidString.prefix(8))"
    let R = base + "/resolver", M = base + "/markers", W = base + "/run"
    try! FileManager.default.createDirectory(atPath: W, withIntermediateDirectories: true)
    let hooks = SplitDNS.hooks(domain: "corp", nameservers: "nameserver 10.0.0.53\\n", resolverDir: R, markerDir: M, runDir: W)
    func hook(_ prefix: String, _ iface: String) {
        let cmd = hooks.first { $0.hasPrefix(prefix) }!.split(separator: "=", maxSplits: 1)[1]
            .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%i", with: iface)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = ["-c", "(eval \"$1\")", "_", cmd]
        try! p.run(); p.waitUntilExit()
    }
    var socks: [String: Int32] = [:]
    func sock(_ iface: String, alive: Bool) {   // stands in for wireguard-go's control socket
        let path = "\(W)/\(iface).sock"
        if alive {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &addr.sun_path) { buf in _ = path.utf8CString.withUnsafeBytes { buf.copyMemory(from: $0) } }
            _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            socks[iface] = fd
        } else {
            if let fd = socks[iface] { close(fd) }
            unlink(path)
        }
    }
    let resolver = R + "/corp"
    let fm = FileManager.default
    hook("PostUp", "utun10"); sock("utun10", alive: true)
    hook("PostUp", "utun11"); sock("utun11", alive: true)
    check(fm.fileExists(atPath: resolver), "resolver created")
    sock("utun11", alive: false); hook("PostDown", "utun11")
    check(fm.fileExists(atPath: resolver), "second tunnel down: resolver kept for the first")
    sock("utun10", alive: false); hook("PostDown", "utun10")
    check(!fm.fileExists(atPath: resolver), "last tunnel down: resolver removed")
    hook("PostUp", "utun10"); sock("utun10", alive: true)
    hook("PostUp", "utun11"); sock("utun11", alive: false)   // utun11 crashed, its marker is stale
    sock("utun10", alive: false); hook("PostDown", "utun10")
    check(!fm.fileExists(atPath: resolver), "stale marker of a dead tunnel doesn't keep the resolver")
    let x = "[Interface]\n" + hooks.joined(separator: "\n").replacingOccurrences(of: M, with: SplitDNS.markerDir)
    check(conflicts(name: "a", conf: x, others: [(name: "b", conf: x)]).isEmpty, "no shared-DNS warning when both coordinate")
    try? fm.removeItem(atPath: base)
}

print("operation lock")
let l1 = OpLock.acquire(wait: 0)
check(l1 != nil, "lock acquired")
check(OpLock.acquire(wait: 0.3) == nil, "second holder blocked")
OpLock.release(l1!)
let l2 = OpLock.acquire(wait: 0)
check(l2 != nil, "lock free again after release")
OpLock.release(l2!)

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
check(runHelper(["meta", "../../etc/passwd"]) == 2 && runHelper(["meta", "nosuchtunnel"]) == 2, "helper meta validates names")
check(runHelper(["version"]) == 0, "helper version command")
let metaGrep = Helper.script.split(separator: "\n").first { $0.contains("grep -iE") && $0.contains("AllowedIPs") } ?? ""
check(!metaGrep.isEmpty && !metaGrep.contains("Key"), "helper meta only selects key-free lines")
check(Helper.script.contains("[[ -S \"/var/run/wireguard/$i.sock\" ]] || continue"), "helper status skips stale name files")

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
