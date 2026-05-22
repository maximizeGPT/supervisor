// SupervisorDevTools — small CLI utility for Checkpoint C smoke testing.
//
// Subcommands:
//   inject-key <key>   Write <key> to the same Keychain entry Supervisor
//                       reads from, using KeychainAccess so the ACL grants
//                       read to anything signed under the same identity.
//   delete-key         Remove the entry.
//   show               Print whether a key is present.

import Foundation
import SupervisorCore

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: SupervisorDevTools <inject-key KEY | delete-key | show>")
    exit(2)
}

let store = KeychainAPIKeyStore()

switch args[1] {
case "inject-key":
    guard args.count >= 3 else {
        print("usage: SupervisorDevTools inject-key <key>")
        exit(2)
    }
    do {
        try store.write(args[2])
        print("ok: key written (len=\(args[2].count))")
    } catch {
        print("ERROR: \(error)")
        exit(1)
    }
case "delete-key":
    do { try store.delete(); print("ok: deleted") }
    catch { print("ERROR: \(error)"); exit(1) }
case "show":
    do {
        if let k = try store.read() {
            print("present (len=\(k.count))")
        } else {
            print("absent")
        }
    } catch {
        print("ERROR: \(error)")
        exit(1)
    }
default:
    print("unknown subcommand: \(args[1])")
    exit(2)
}
