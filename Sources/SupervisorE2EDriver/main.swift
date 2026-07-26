// SupervisorE2EDriver — Accessibility-API driver for the true-new-user E2E
// harness (Scripts/e2e/).
//
// Drives an ISOLATED Supervisor instance's UI (onboarding fields, buttons,
// hover panel) from a shell script, by pid. AX-by-pid — not OCR+click, not
// frontmost-window CGEvent posts — because the harness runs on a machine
// where a LIVE Supervisor is also on screen: everything here is scoped to
// the target pid's AX tree, so it physically cannot press a button in the
// wrong app. (Precedent: the AX walking in
// Sources/SupervisorCore/Intervention/Injector.swift and
// spikes/cgevent_inject_spike.swift.)
//
// Foundation + ApplicationServices only — deliberately NOT SupervisorCore:
// the driver must stay independent of the code under test, and a leaf
// executable keeps the harness usable even when SupervisorCore is broken.
//
// Usage:
//   SupervisorE2EDriver --pid <n> tree
//       Dump the app's full AX tree as JSON to stdout: role, title, value,
//       position, size, enabled, children. Scripts jq-assert against this.
//   SupervisorE2EDriver --pid <n> windows
//       List the app's windows (title, position, size) as JSON.
//   SupervisorE2EDriver --pid <n> press --title <t>
//       Find a pressable element by title and AXPress it. Exact match wins;
//       falls back to case-insensitive substring so SwiftUI's decorated
//       labels still hit.
//   SupervisorE2EDriver --pid <n> set --title <t> --value <v>
//       Find a text field by title / placeholder / description / identifier
//       and set kAXValueAttribute. Focuses the field first so SwiftUI
//       bindings observe the change.
//
// Exit codes: 0 ok, 1 command failed (element not found / AX error),
// 2 usage, 3 this process is not AX-trusted (grant the invoking terminal
// Accessibility in System Settings).

import ApplicationServices
import Foundation

// MARK: - Argument parsing

var pid: pid_t?
var command: String?
var titleArg: String?
var valueArg: String?

let argv = CommandLine.arguments
var i = 1
while i < argv.count {
    let a = argv[i]
    func next(_ flag: String) -> String {
        guard i + 1 < argv.count else {
            FileHandle.standardError.write(Data("\(flag): missing value\n".utf8))
            exit(2)
        }
        i += 1
        return argv[i]
    }
    switch a {
    case "--pid":   pid = pid_t(next("--pid"))
    case "--title": titleArg = next("--title")
    case "--value": valueArg = next("--value")
    case "tree", "windows", "press", "set":
        command = a
    default:
        FileHandle.standardError.write(Data("unknown argument: \(a)\n".utf8))
        exit(2)
    }
    i += 1
}

guard let pid, let command else {
    FileHandle.standardError.write(Data(
        "usage: SupervisorE2EDriver --pid <n> <tree|windows|press --title T|set --title T --value V>\n".utf8))
    exit(2)
}

// Reading another process's AX tree requires this process (the terminal /
// script host) to be AX-trusted. Fail loudly and distinctly — a scenario
// script must be able to tell "no permission" apart from "button missing".
guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data(
        "SupervisorE2EDriver: this process is not AX-trusted. Grant Accessibility to the invoking terminal in System Settings > Privacy & Security > Accessibility.\n".utf8))
    exit(3)
}

// MARK: - AX helpers

func copyAttr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else { return nil }
    return ref
}

func stringAttr(_ element: AXUIElement, _ name: String) -> String? {
    copyAttr(element, name) as? String
}

/// Value attribute stringified: text fields hold String, checkboxes/sliders
/// hold numbers. Anything else is reported by CF type description so the
/// tree stays JSON-serializable.
func valueString(_ element: AXUIElement) -> String? {
    guard let raw = copyAttr(element, kAXValueAttribute as String) else { return nil }
    if let s = raw as? String { return s }
    if let n = raw as? NSNumber { return n.stringValue }
    return String(describing: CFCopyTypeIDDescription(CFGetTypeID(raw)))
}

func pointAttr(_ element: AXUIElement, _ name: String) -> CGPoint? {
    guard let raw = copyAttr(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    var pt = CGPoint.zero
    guard AXValueGetValue(raw as! AXValue, .cgPoint, &pt) else { return nil }
    return pt
}

func sizeAttr(_ element: AXUIElement, _ name: String) -> CGSize? {
    guard let raw = copyAttr(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    var sz = CGSize.zero
    guard AXValueGetValue(raw as! AXValue, .cgSize, &sz) else { return nil }
    return sz
}

func boolAttr(_ element: AXUIElement, _ name: String) -> Bool? {
    (copyAttr(element, name) as? NSNumber)?.boolValue
}

/// Filter an AX-returned CFArray down to actual AXUIElements. A Swift `as?`
/// between CF class types is UNCHECKED at runtime (any CF type "casts" to
/// any other), so the honest conditional cast is a CFGetTypeID comparison
/// first; only then is the downcast known-safe. Non-element entries (a
/// misbehaving AX host can return anything) are dropped instead of crashing
/// the driver.
func axElements(_ raw: CFTypeRef?) -> [AXUIElement] {
    guard let array = raw as? [AnyObject] else { return [] }
    return array.compactMap { item in
        guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
        return (item as! AXUIElement)
    }
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    axElements(copyAttr(element, kAXChildrenAttribute as String))
}

func actions(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success,
          let list = names as? [String] else { return [] }
    return list
}

// MARK: - Tree walking

/// The strings a title match runs against, in match-priority order. SwiftUI
/// scatters the human-visible label across different attributes depending on
/// the control (Button → title or description, SecureField → placeholder),
/// so matching only kAXTitle would miss half the onboarding UI.
func matchableStrings(_ element: AXUIElement) -> [String] {
    var out: [String] = []
    for attr in [
        kAXTitleAttribute as String,
        kAXDescriptionAttribute as String,
        "AXPlaceholderValue",
        "AXIdentifier",
        "AXLabel",
    ] {
        if let s = stringAttr(element, attr), !s.isEmpty { out.append(s) }
    }
    return out
}

/// Depth-first walk with a visit callback; returns the first element the
/// callback accepts. Caps guard against pathological/cyclic trees (AX trees
/// are acyclic in practice, but a wedged app can report garbage).
func findFirst(
    root: AXUIElement,
    maxDepth: Int = 60,
    maxNodes: Int = 50_000,
    where accepts: (AXUIElement) -> Bool
) -> AXUIElement? {
    var visited = 0
    func walk(_ el: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < maxDepth, visited < maxNodes else { return nil }
        visited += 1
        if accepts(el) { return el }
        for child in children(el) {
            if let hit = walk(child, depth: depth + 1) { return hit }
        }
        return nil
    }
    return walk(root, depth: 0)
}

/// Element lookup used by press/set: exact title match anywhere in the tree
/// first (never surprised by substring collisions like "Continue" vs
/// "Continue anyway"), then a case-insensitive substring pass as fallback.
func findElement(
    root: AXUIElement,
    title: String,
    role predicate: @escaping (AXUIElement) -> Bool
) -> AXUIElement? {
    if let exact = findFirst(root: root, where: { el in
        predicate(el) && matchableStrings(el).contains(title)
    }) {
        return exact
    }
    let needle = title.lowercased()
    return findFirst(root: root, where: { el in
        predicate(el) && matchableStrings(el).contains { $0.lowercased().contains(needle) }
    })
}

// MARK: - JSON dump

func nodeJSON(_ element: AXUIElement, depth: Int, maxDepth: Int = 60) -> [String: Any] {
    var node: [String: Any] = [:]
    node["role"] = stringAttr(element, kAXRoleAttribute as String) ?? "?"
    if let sub = stringAttr(element, kAXSubroleAttribute as String) { node["subrole"] = sub }
    if let title = stringAttr(element, kAXTitleAttribute as String), !title.isEmpty { node["title"] = title }
    if let desc = stringAttr(element, kAXDescriptionAttribute as String), !desc.isEmpty { node["description"] = desc }
    if let ph = stringAttr(element, "AXPlaceholderValue"), !ph.isEmpty { node["placeholder"] = ph }
    if let ident = stringAttr(element, "AXIdentifier"), !ident.isEmpty { node["identifier"] = ident }
    if let value = valueString(element) { node["value"] = value }
    if let pt = pointAttr(element, kAXPositionAttribute as String) {
        node["position"] = ["x": pt.x, "y": pt.y]
    }
    if let sz = sizeAttr(element, kAXSizeAttribute as String) {
        node["size"] = ["w": sz.width, "h": sz.height]
    }
    if let enabled = boolAttr(element, kAXEnabledAttribute as String) { node["enabled"] = enabled }
    if depth < maxDepth {
        let kids = children(element)
        if !kids.isEmpty {
            node["children"] = kids.map { nodeJSON($0, depth: depth + 1, maxDepth: maxDepth) }
        }
    }
    return node
}

func printJSON(_ obj: Any) {
    guard let data = try? JSONSerialization.data(
        withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]
    ), let text = String(data: data, encoding: .utf8) else {
        FileHandle.standardError.write(Data("SupervisorE2EDriver: JSON serialization failed\n".utf8))
        exit(1)
    }
    print(text)
}

// MARK: - Commands

let app = AXUIElementCreateApplication(pid)

// A pid with no AX tree (dead process, or an agent app before its first
// window) reports no attributes at all; detect that once, uniformly.
guard copyAttr(app, kAXRoleAttribute as String) != nil else {
    FileHandle.standardError.write(Data(
        "SupervisorE2EDriver: no AX tree for pid \(pid) (process dead, not an app, or no UI yet)\n".utf8))
    exit(1)
}

switch command {
case "tree":
    printJSON(nodeJSON(app, depth: 0))

case "windows":
    let wins = axElements(copyAttr(app, kAXWindowsAttribute as String))
    printJSON(wins.map { win -> [String: Any] in
        var entry: [String: Any] = ["title": stringAttr(win, kAXTitleAttribute as String) ?? ""]
        if let pt = pointAttr(win, kAXPositionAttribute as String) { entry["position"] = ["x": pt.x, "y": pt.y] }
        if let sz = sizeAttr(win, kAXSizeAttribute as String) { entry["size"] = ["w": sz.width, "h": sz.height] }
        return entry
    })

case "press":
    guard let title = titleArg else {
        FileHandle.standardError.write(Data("press: --title is required\n".utf8))
        exit(2)
    }
    // "Pressable" = advertises AXPress, whatever the role — SwiftUI renders
    // some tappable things as AXButton, others as generic groups with a
    // press action.
    guard let el = findElement(root: app, title: title, role: { actions($0).contains(kAXPressAction as String) }) else {
        FileHandle.standardError.write(Data("press: no pressable element titled \"\(title)\" in pid \(pid)\n".utf8))
        exit(1)
    }
    let err = AXUIElementPerformAction(el, kAXPressAction as CFString)
    guard err == .success else {
        FileHandle.standardError.write(Data("press: AXPress failed (\(err.rawValue)) on \"\(title)\"\n".utf8))
        exit(1)
    }
    print("ok: pressed \"\(title)\"")

case "set":
    guard let title = titleArg, let value = valueArg else {
        FileHandle.standardError.write(Data("set: --title and --value are required\n".utf8))
        exit(2)
    }
    let textRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        "AXSecureTextField",   // SecureField on older SwiftUI; newer reports AXTextField + secure subrole
    ]
    guard let el = findElement(root: app, title: title, role: { e in
        guard let role = stringAttr(e, kAXRoleAttribute as String) else { return false }
        return textRoles.contains(role)
    }) else {
        FileHandle.standardError.write(Data("set: no text field titled \"\(title)\" in pid \(pid)\n".utf8))
        exit(1)
    }
    // Focus first: SwiftUI bindings sync on focus/edit events, and an
    // unfocused kAXValue write can leave the on-screen text and the binding
    // out of agreement.
    _ = AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    let err = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, value as CFTypeRef)
    guard err == .success else {
        FileHandle.standardError.write(Data("set: kAXValue write failed (\(err.rawValue)) on \"\(title)\"\n".utf8))
        exit(1)
    }
    print("ok: set \"\(title)\" (\(value.count) chars)")

default:
    // Unreachable — the parser only assigns known commands — but the switch
    // must be exhaustive over String.
    FileHandle.standardError.write(Data("unknown command: \(command)\n".utf8))
    exit(2)
}
