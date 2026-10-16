// EDIDentity: give one of two identical monitors a distinct EDID serial so macOS can tell them apart.
// Apple Silicon only. The EDID is applied as a volatile override through IOAVServiceSetVirtualEDIDMode,
// so nothing is written to the monitor. The override is lost on reconnect; `watch` re-applies it.
import Foundation
import IOKit
import CoreGraphics

@_silgen_name("IOAVServiceCreateWithService")
func IOAVServiceCreateWithService(_ alloc: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceCopyEDID")
func IOAVServiceCopyEDID(_ svc: CFTypeRef, _ edid: UnsafeMutablePointer<Unmanaged<CFData>?>) -> IOReturn
// mode pointing to 1 applies `edid`; (nil, nil) restores the factory EDID.
@_silgen_name("IOAVServiceSetVirtualEDIDMode")
func IOAVServiceSetVirtualEDIDMode(_ svc: CFTypeRef, _ mode: UnsafePointer<UInt32>?, _ edid: CFData?) -> IOReturn

let usage = """
usage: edidentity list
       edidentity apply --target <alphanumeric serial> [--serial <n>]
       edidentity reset --target <alphanumeric serial>
       edidentity watch --target <alphanumeric serial> [--serial <n>]

  list    show external displays with their EDID serials
  apply   override the target display's numeric serial once
  reset   restore the target display's factory EDID
  watch   stay running and re-apply whenever displays are reconnected

  --serial defaults to a value derived from the alphanumeric serial.
"""

func log(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("[\(ts)] \(s)")
    fflush(stdout)
}

func fail(_ s: String) -> Never {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    exit(1)
}

struct Display {
    let service: CFTypeRef
    let edid: [UInt8]
    var alnum: String? { alnumSerial(edid) }
    var serial: UInt32 { UInt32(edid[12]) | UInt32(edid[13]) << 8 | UInt32(edid[14]) << 16 | UInt32(edid[15]) << 24 }
    var name: String? { descriptor(edid, tag: 0xFC) }
}

func descriptor(_ b: [UInt8], tag: UInt8) -> String? {
    for o in [54, 72, 90, 108] where b.count >= o + 18 {
        if b[o] == 0, b[o+1] == 0, b[o+2] == 0, b[o+3] == tag {
            let s = String(decoding: b[(o+5)..<(o+18)], as: UTF8.self)
            return s.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }
    return nil
}

func alnumSerial(_ b: [UInt8]) -> String? { descriptor(b, tag: 0xFF) }

// FNV-1a, so the same alphanumeric serial always maps to the same numeric serial.
func derivedSerial(_ s: String) -> UInt32 {
    var h: UInt32 = 2166136261
    for c in s.utf8 { h = (h ^ UInt32(c)) &* 16777619 }
    return h
}

func patched(_ b: [UInt8], serial: UInt32) -> [UInt8] {
    var p = b
    for i in 0..<4 { p[12 + i] = UInt8((serial >> (8 * UInt32(i))) & 0xFF) }
    let sum = p[0..<127].reduce(0) { ($0 + Int($1)) & 0xFF }
    p[127] = UInt8((256 - sum) & 0xFF)
    return p
}

// External displays as seen by their AV services. CopyEDID returns the override while one is active.
func externalDisplays() -> [Display] {
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &it) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(it) }
    var result: [Display] = []
    while case let svc = IOIteratorNext(it), svc != 0 {
        defer { IOObjectRelease(svc) }
        let loc = IORegistryEntryCreateCFProperty(svc, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        guard loc == "External", let av = IOAVServiceCreateWithService(kCFAllocatorDefault, svc)?.takeRetainedValue() else { continue }
        var out: Unmanaged<CFData>?
        guard IOAVServiceCopyEDID(av, &out) == kIOReturnSuccess, let data = out?.takeRetainedValue() else { continue }
        let b = [UInt8](data as Data)
        if b.count >= 128 { result.append(Display(service: av, edid: b)) }
    }
    return result
}

func findTarget(_ alnum: String) -> Display? {
    externalDisplays().first { $0.alnum == alnum }
}

func apply(_ d: Display, serial: UInt32) -> IOReturn {
    var mode: UInt32 = 1
    return IOAVServiceSetVirtualEDIDMode(d.service, &mode, Data(patched(d.edid, serial: serial)) as CFData)
}

func hex(_ r: IOReturn) -> String { "0x" + String(UInt32(bitPattern: r), radix: 16) }

// Watch mode: apply when the target is connected with a different serial, but never more than
// 3 times in 2 minutes so a display that rejects the override cannot cause a flicker loop.
var recentApplies: [Date] = []
func check(_ alnum: String, _ serial: UInt32) {
    guard let d = findTarget(alnum), d.serial != serial else { return }
    recentApplies = recentApplies.filter { Date().timeIntervalSince($0) < 120 }
    guard recentApplies.count < 3 else { log("skip: applied 3 times in 2 minutes"); return }
    recentApplies.append(Date())
    log("apply \(alnum): serial \(d.serial) -> \(serial): \(hex(apply(d, serial: serial)))")
}

var pending = false
var watchTarget = ""
var watchSerial: UInt32 = 0
func schedule() {
    guard !pending else { return }
    pending = true
    // Give the AV service a moment to come up after reconfiguration.
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { pending = false; check(watchTarget, watchSerial) }
}

// MARK: - CLI

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let target = option("--target")
let serialArg: UInt32? = option("--serial").map {
    guard let n = UInt32($0) else { fail("--serial must be a 32-bit unsigned integer") }
    return n
}

func requireTarget() -> String {
    guard let t = target else { fail("--target is required\n\n" + usage) }
    return t
}

switch command {
case "list":
    var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &n)
    print("macOS serials: \(ids.prefix(Int(n)).map { CGDisplaySerialNumber($0) })")
    for d in externalDisplays() {
        print("\(d.name ?? "?")  alphanumeric=\(d.alnum ?? "-")  serial=\(d.serial)")
    }

case "apply":
    let t = requireTarget()
    guard let d = findTarget(t) else { fail("display \(t) not found") }
    let s = serialArg ?? derivedSerial(t)
    print("apply \(t): serial \(d.serial) -> \(s): \(hex(apply(d, serial: s)))")

case "reset":
    let t = requireTarget()
    guard let d = findTarget(t) else { fail("display \(t) not found") }
    print("reset \(t): \(hex(IOAVServiceSetVirtualEDIDMode(d.service, nil, nil)))")

case "watch":
    watchTarget = requireTarget()
    watchSerial = serialArg ?? derivedSerial(watchTarget)
    log("watch \(watchTarget) -> serial \(watchSerial)")
    _ = CGMainDisplayID()   // connect to WindowServer so reconfiguration callbacks arrive
    CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
        if !flags.contains(.beginConfigurationFlag) { DispatchQueue.main.async { schedule() } }
    }, nil)
    // Fallback in case a callback is missed; it is only an IORegistry lookup.
    Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in check(watchTarget, watchSerial) }
    check(watchTarget, watchSerial)
    RunLoop.main.run()

default:
    print(usage)
    exit(command == "-h" || command == "--help" ? 0 : 1)
}
