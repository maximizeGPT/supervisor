// kqueue_spike.swift — Phase 0 spike for Supervisor v0.1.0.
//
// Verifies whether DispatchSourceFileSystemObject (kqueue) reliably fires on
// every append to an actively-written JSONL file on this macOS version.
//
// Usage:
//   swift kqueue_spike.swift <jsonl-path> [duration-seconds]
//
// Output: one line per kqueue event, with timestamp, event mask, bytes read,
// and lines counted since last event. On exit, prints totals.
//
// Verification approach: count lines in the file before & after, compare to
// the spike's emitted line count. They should match exactly.

import Foundation

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: kqueue_spike <jsonl-path> [duration-seconds]\n".utf8))
    exit(1)
}

// Disable stdout buffering so we see events the moment they fire.
setbuf(stdout, nil)

let path = CommandLine.arguments[1]
let duration: TimeInterval = CommandLine.arguments.count >= 3
    ? (Double(CommandLine.arguments[2]) ?? 60)
    : 60

let fd = open(path, O_EVTONLY)
guard fd >= 0 else {
    let err = String(cString: strerror(errno))
    FileHandle.standardError.write(Data("open failed: \(err)\n".utf8))
    exit(2)
}

// Seek to EOF so we only count NEW appends.
let initialOffset = lseek(fd, 0, SEEK_END)

let formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

print("[start] file=\(path)")
print("[start] initial_offset=\(initialOffset)")
print("[start] duration_s=\(Int(duration))")
print("[start] watching for: write | extend | delete | rename | attrib")
FileHandle.standardOutput.synchronizeFile()

let queue = DispatchQueue(label: "kqueue.spike", qos: .utility)
let mask: DispatchSource.FileSystemEvent = [.write, .extend, .delete, .rename, .attrib]
let source = DispatchSource.makeFileSystemObjectSource(
    fileDescriptor: fd,
    eventMask: mask,
    queue: queue
)

var eventCount = 0
var totalBytes: Int = 0
var totalLines: Int = 0
var lastReadOffset = initialOffset

let bufSize = 65_536
let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 1)

source.setEventHandler {
    let now = formatter.string(from: Date())
    let data = source.data
    eventCount += 1

    var maskParts: [String] = []
    if data.contains(.write)  { maskParts.append("write")  }
    if data.contains(.extend) { maskParts.append("extend") }
    if data.contains(.delete) { maskParts.append("delete") }
    if data.contains(.rename) { maskParts.append("rename") }
    if data.contains(.attrib) { maskParts.append("attrib") }
    let maskStr = maskParts.joined(separator: "|")

    // Drain everything new from the FD.
    var thisEventBytes = 0
    var thisEventLines = 0
    while true {
        let n = read(fd, buffer, bufSize)
        if n <= 0 { break }
        thisEventBytes += n
        // Count newlines in this chunk.
        let bytes = buffer.assumingMemoryBound(to: UInt8.self)
        for i in 0..<n {
            if bytes[i] == 0x0A { thisEventLines += 1 }
        }
    }
    totalBytes += thisEventBytes
    totalLines += thisEventLines
    lastReadOffset += off_t(thisEventBytes)

    print("[\(now)] event#\(eventCount) mask=\(maskStr) this_bytes=\(thisEventBytes) this_lines=\(thisEventLines) cum_bytes=\(totalBytes) cum_lines=\(totalLines)")
    fflush(stdout)

    if data.contains(.delete) || data.contains(.rename) {
        print("[warn] delete/rename — source going to cancel")
        fflush(stdout)
    }
}

source.setCancelHandler {
    close(fd)
    buffer.deallocate()
}

source.resume()

// Heartbeat every 5s so we can see the watcher is alive even if no events fire.
let heartbeat = DispatchSource.makeTimerSource(queue: queue)
heartbeat.schedule(deadline: .now() + 5, repeating: 5)
heartbeat.setEventHandler {
    let now = formatter.string(from: Date())
    print("[\(now)] heartbeat events_so_far=\(eventCount) lines_so_far=\(totalLines)")
    fflush(stdout)
}
heartbeat.resume()

DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
    let now = formatter.string(from: Date())
    print("[\(now)] [done] events=\(eventCount) total_bytes=\(totalBytes) total_lines=\(totalLines) final_offset=\(lastReadOffset)")
    fflush(stdout)
    source.cancel()
    heartbeat.cancel()
    exit(0)
}

dispatchMain()
