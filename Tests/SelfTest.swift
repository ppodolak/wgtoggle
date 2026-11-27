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
try! "[Interface]\nAddress = fd00:0:0::0010/128\n".write(toFile: tmp, atomically: true, encoding: .utf8)
check(tunnelAddress(tmp) == "fd00::10", "IPv6-only tunnel address, canonical form")
try? FileManager.default.removeItem(atPath: tmp)

print("split DNS")
let plan = SplitDNS.plan(conf)!
check(plan.servers == ["10.0.0.53", "10.0.0.54"] && plan.domains == ["corp", "lab.example"], "plan servers/domains")
let converted = SplitDNS.convert(conf, plan: plan)
check(confValues(converted, key: "dns").isEmpty, "DNS line removed")
check(hookLines(converted).count == 8, "4 hook lines per domain")
check(converted.contains("printf 'nameserver 10.0.0.53\\nnameserver 10.0.0.54\\n' > '/var/db/wgtoggle-dns/corp.if.%i@%I' && cp '/var/db/wgtoggle-dns/corp.if.%i@%I' /etc/resolver/corp"), "resolver hook content")
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

print("per-peer health")
let st0 = Helper.parseStatus("""
office utun7 1764200000 900 5000
peer office AAAAkeyA= 1764200000 800 2500
peer office BBBBkeyB= 0 100 2500
home utun8 1764100000 10 20
garbage line
""")
check(Helper.parseStatus("a utun1 0 1 2\nend 1\n", strict: true)?["a"] != nil, "strict status with end marker parses")
check(Helper.parseStatus("a utun1 0 1 2\n", strict: true) == nil, "strict status without end marker = unknown")
check(Helper.parseStatus("a utun1 0 1 2\nGARBAGE here\nend 1\n", strict: true) == nil, "strict status with a garbled line = unknown")
let st = st0!
check(st["office"]?.iface == "utun7" && st["office"]?.peers.count == 2 && st["home"]?.peers.isEmpty == true, "status parser: tunnels and peers")
check(st["office"]?.peers[1].handshake == nil && st["office"]?.peers[0].tx == 2500, "status parser: peer fields")
let t0 = Date()
check(peerIsStale(txDelta: 5_000, handshake: nil, now: t0), "peer with traffic and no handshake is stale")
check(peerIsStale(txDelta: 5_000, handshake: t0.addingTimeInterval(-300), now: t0), "peer with old handshake is stale")
check(!peerIsStale(txDelta: 5_000, handshake: t0.addingTimeInterval(-30), now: t0), "peer with fresh handshake is fine")
check(!peerIsStale(txDelta: 0, handshake: nil, now: t0), "idle peer isn't stale")
check(peerIsStale(txDelta: 148, handshake: nil, now: t0), "unreachable peer sending only handshake attempts is stale")

print("log redaction")
let key = "yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk="
let red = Log.redact("PrivateKey = \(key)\npresharedkey=\(key)\npeer \(key) handshake")
check(!red.contains(key) && !red.contains("lXXJte14"), "keys never appear in the log")
check(red.contains("PrivateKey = <redacted>") && red.contains("presharedkey=<redacted>") && red.contains("peer yAnz… handshake"), "redacted form is readable")
check(Log.redact("wg-quick up wg-dev ok, 10.0.0.0/16") == "wg-quick up wg-dev ok, 10.0.0.0/16", "normal text untouched")

print("installer transaction (as user, paths redirected to a temp dir)")
if findBinary("wg-quick") == nil {
    print("  skip (wireguard-tools not installed)")
} else {
    let T = NSTemporaryDirectory() + "wginst-\(UUID().uuidString.prefix(8))"
    let fm = FileManager.default
    try! fm.createDirectory(atPath: T + "/src", withIntermediateDirectories: true)
    try! "[Interface]\nPrivateKey = A\n".write(toFile: T + "/src/a.conf", atomically: true, encoding: .utf8)
    try! "[Interface]\nPrivateKey = B\n".write(toFile: T + "/src/b.conf", atomically: true, encoding: .utf8)
    func script(breakCheck: Bool = false) -> String {
        var x = Helper.installer(user: NSUserName(), moveFrom: [T + "/src/a.conf", T + "/src/b.conf"])
        for (a, b) in [("/Library/PrivilegedHelperTools/wgtoggle", T + "/H"), ("/etc/sudoers.d/wgtoggle", T + "/sudoers"),
                       ("/etc/wireguard", T + "/etcwg"), ("mkdir -p /Library/PrivilegedHelperTools", "mkdir -p " + T),
                       ("chown -R root:wheel", ": chown"), ("chown root:wheel", ": chown"),
                       ("install -o root -g wheel", "install")] { x = x.replacingOccurrences(of: a, with: b) }
        if breakCheck { x = x.replacingOccurrences(of: "== \(Helper.currentVersion) ]]", with: "== 999 ]]") }
        return x
    }
    func run(_ text: String) -> Int32 {
        let f = T + "/install.sh"
        try! text.write(toFile: f, atomically: true, encoding: .utf8)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = [f]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try! p.run(); p.waitUntilExit(); return p.terminationStatus
    }
    let ex = { fm.fileExists(atPath: T + $0) }
    // 1. first install fails at the final check: nothing may be left behind
    check(run(script(breakCheck: true)) != 0 && !ex("/H") && !ex("/sudoers") && !ex("/etcwg/a.conf"), "failed first install leaves nothing")
    // 2. first install succeeds
    check(run(script()) == 0 && ex("/H/wgtoggle-helper") && ex("/sudoers") && ex("/etcwg/a.conf") && !ex("/H.old") && !ex("/sudoers.old"), "install succeeds, no backups left")
    // 3. reinstall fails: previous helper, rule and configs restored exactly
    try! "marker".write(toFile: T + "/H/previous", atomically: true, encoding: .utf8)
    try! "old rule".write(toFile: T + "/sudoers", atomically: true, encoding: .utf8)
    try! "[Interface]\nPrivateKey = OLD\n".write(toFile: T + "/etcwg/a.conf", atomically: true, encoding: .utf8)
    try? fm.removeItem(atPath: T + "/etcwg/b.conf")
    check(run(script(breakCheck: true)) != 0, "broken reinstall fails")
    check(ex("/H/previous") && !ex("/H.old"), "previous helper restored")
    check((try? String(contentsOfFile: T + "/sudoers", encoding: .utf8)) == "old rule", "previous sudo rule restored")
    check((try? String(contentsOfFile: T + "/etcwg/a.conf", encoding: .utf8))?.contains("OLD") == true && !ex("/etcwg/b.conf"), "overwritten config restored, new config removed")
    // 4. an install was killed half-way (leftover .old / .wgtoggle-bak); the next attempt recovers first,
    //    and if that attempt fails too, the original state is what comes back
    try? fm.removeItem(atPath: T + "/H.old"); try! fm.moveItem(atPath: T + "/H", toPath: T + "/H.old")
    try! fm.createDirectory(atPath: T + "/H", withIntermediateDirectories: true)   // half-installed junk
    try! "old rule".write(toFile: T + "/sudoers.old", atomically: true, encoding: .utf8)
    try! "junk rule".write(toFile: T + "/sudoers", atomically: true, encoding: .utf8)
    try! fm.moveItem(atPath: T + "/etcwg/a.conf", toPath: T + "/etcwg/a.conf.wgtoggle-bak")
    try! "junk".write(toFile: T + "/etcwg/a.conf", atomically: true, encoding: .utf8)
    check(run(script(breakCheck: true)) != 0, "install after an interrupted one fails as injected")
    check(ex("/H/previous") && !ex("/H.old") && (try? String(contentsOfFile: T + "/sudoers", encoding: .utf8)) == "old rule"
          && (try? String(contentsOfFile: T + "/etcwg/a.conf", encoding: .utf8))?.contains("OLD") == true && !ex("/etcwg/a.conf.wgtoggle-bak"),
          "interrupted install recovered to the original state")
    check(run(script()) == 0 && ex("/H/wgtoggle-helper") && !ex("/H/previous"), "next install then succeeds")
    try? fm.removeItem(atPath: T)
}

print("privileged commands")
let wq = wgQuick("up", "/tmp/a b.conf")
check(wq.hasPrefix("'/") && wq.contains("/bash' '") && wq.hasSuffix("/wg-quick' up '/tmp/a b.conf'"), "wg-quick runs by absolute path with its own bash")

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
    func hooks(_ ns: String) -> [String] { SplitDNS.hooks(domain: "corp", nameservers: "nameserver \(ns)\\n", resolverDir: R, markerDir: M, runDir: W) }
    var names: [String: String] = ["utun10": "dev", "utun11": "prod"]
    func run(_ hs: [String], _ prefix: String, _ iface: String) {
        for h in hs where h.hasPrefix(prefix) {   // wg-quick runs each hook line in its own subshell
            let cmd = h.split(separator: "=", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "%i", with: iface).replacingOccurrences(of: "%I", with: names[iface]!)
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = ["-c", "(eval \"$1\")", "_", cmd]
            try! p.run(); p.waitUntilExit()
        }
    }
    var socks: [String: Int32] = [:]
    func sock(_ iface: String, alive: Bool) {   // stands in for wireguard-go's socket + wg-quick's name file
        let path = "\(W)/\(iface).sock"
        let nameFile = "\(W)/\(names[iface]!).name"
        if alive { try! "\(iface)\n".write(toFile: nameFile, atomically: true, encoding: .utf8) } else { unlink(nameFile) }
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
    func content() -> String { (try? String(contentsOfFile: resolver, encoding: .utf8)) ?? "" }
    let dev = hooks("10.10.0.53"), prod = hooks("10.20.0.53")
    func up(_ h: [String], _ i: String) { run(h, "PostUp", i); sock(i, alive: true); Thread.sleep(forTimeInterval: 1.1) }  // ls -t has 1s resolution
    func down(_ h: [String], _ i: String) { sock(i, alive: false); run(h, "PostDown", i) }   // wg-quick removes the socket first

    up(dev, "utun10"); up(prod, "utun11")
    check(content().contains("10.20.0.53"), "newest tunnel's nameserver is used")
    down(prod, "utun11")
    check(content().contains("10.10.0.53") && !content().contains("10.20.0.53"), "after prod disconnects, dev's nameserver is back")
    down(dev, "utun10")
    check(!fm.fileExists(atPath: resolver), "last tunnel down: resolver removed")

    up(dev, "utun10"); run(prod, "PostUp", "utun11")   // utun11 starts, then crashes (no socket)
    down(dev, "utun10")
    check(!fm.fileExists(atPath: resolver), "stale marker of a crashed tunnel doesn't keep the resolver")

    try! "nameserver 192.0.2.1\n".write(toFile: resolver, atomically: true, encoding: .utf8)   // made by someone else
    up(dev, "utun10"); up(prod, "utun11")
    down(dev, "utun10"); down(prod, "utun11")
    check(content() == "nameserver 192.0.2.1\n", "pre-existing resolver file restored afterwards")
    // crash/reboot: resolver of a tunnel that's no longer running gets cleaned up by repair
    up(dev, "utun10"); sock("utun10", alive: false)   // utun10 dies without running PostDown
    func repair() { let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", SplitDNS.repairScript(resolverDir: R, markerDir: M, runDir: W)]
        p.standardOutput = FileHandle.nullDevice; try! p.run(); p.waitUntilExit() }
    repair()
    check(content() == "nameserver 192.0.2.1\n", "repair: dead tunnel's resolver replaced by the saved original")
    up(dev, "utun10"); up(prod, "utun11"); sock("utun11", alive: false)
    repair()
    check(content().contains("10.10.0.53"), "repair: resolver rebuilt from the tunnel still running")
    down(dev, "utun10")
    repair(); let once = content(); repair()
    check(content() == once, "repair twice changes nothing")

    // reboot: everything in /var/run is gone, the persistent prod marker for utun11 survives.
    // Then a different VPN ("lab") gets utun11. Its socket must not keep prod's resolver alive.
    try? fm.removeItem(atPath: resolver)
    up(prod, "utun11")
    sock("utun11", alive: false)                       // "reboot"
    names["utun11"] = "lab"; sock("utun11", alive: true)  // another tunnel reuses utun11
    repair()
    check(!fm.fileExists(atPath: resolver), "reused utun name doesn't keep a dead tunnel's resolver")
    sock("utun11", alive: false); names["utun11"] = "prod"
    let hooks = dev
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
check(Updates.isNewer("1.7.0", than: "1.7.0-beta.2") && !Updates.isNewer("1.7.0-beta.2", than: "1.7.0"), "release beats its prerelease")
check(Updates.isNewer("1.7.0-beta.10", than: "1.7.0-beta.9") && Updates.isNewer("1.7.0-beta.1", than: "1.6.9"), "prerelease ordering")

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
let counters = exactCounters()
check(counters["lo0"] != nil && counters.count > 3, "exact counters parse every interface (\(counters.count))")
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
let toolsOnly = Helper.installer(user: "tester", moveFrom: [], sudoers: false)
check(bashN(toolsOnly) && !toolsOnly.contains("visudo") && toolsOnly.contains("rm -f /etc/sudoers.d/wgtoggle"), "tools-only installer: no sudo rule")
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
