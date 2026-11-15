import CControl24Capture
import Control24Core
import Darwin
import Foundation

// The only process that needs BPF/root access. No IP traffic is captured, and
// IPC is fixed to loopback with a per-app-session token. It never launches a shell.
let args=Array(CommandLine.arguments.dropFirst())
if args == ["--managed"] { runManagedBridge() }
func option(_ name: String) -> String? {
    guard let index=args.firstIndex(of:name),index+1<args.count else {return nil}
    return args[index+1]
}
func fail(_ message: String) -> Never {FileHandle.standardError.write(Data((message+"\n").utf8));exit(1)}
guard let interface=option("--interface"),let token=option("--token"),!token.isEmpty,
      let portText=option("--port"),let port=UInt16(portText),port>0 else {
    fail("Usage: Control24Bridge --interface en3 --port 9127 --token <app token> [--mac 00:a0:7e:xx:xx:xx] [--active]\nDefault: passive capture. --active owns a surface session and requires the console MAC.")
}
let active=args.contains("--active"),macText=option("--mac")?.lowercased() ?? ""
let macParts=macText.split(separator:":"),mac=macParts.compactMap {UInt8($0,radix:16)}
guard macText.isEmpty || (macParts.count==6 && mac.count==6 && macParts.allSatisfy({$0.count==2})) else {fail("Invalid console MAC")}
guard !active || !macText.isEmpty else {fail("--active requires --mac; first discover the desk using passive mode.")}
let fd=Darwin.socket(AF_INET,SOCK_DGRAM,0)
guard fd>=0 else {fail("Cannot open loopback IPC socket")}
var destination=sockaddr_in();destination.sin_len=UInt8(MemoryLayout<sockaddr_in>.size)
destination.sin_family=sa_family_t(AF_INET);destination.sin_port=port.bigEndian
destination.sin_addr.s_addr=inet_addr("127.0.0.1")
@MainActor func notify(_ fields: [String:String]) {
    var message=fields;message["token"]=token
    guard let data=try? JSONSerialization.data(withJSONObject:message) else {return}
    _ = data.withUnsafeBytes {Darwin.send(fd, $0.baseAddress, $0.count, 0)}
}
let ipcConnected = withUnsafePointer(to: &destination) { address in
    address.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
guard ipcConnected == 0 else {fail("Cannot connect to Lab")}
var errorBuffer=[CChar](repeating:0,count:512)
guard let capture=c24_open(interface,macText,&errorBuffer,errorBuffer.count) else {
    let message=String(decoding:errorBuffer.prefix(while:{$0 != 0}).map {UInt8(bitPattern:$0)},as:UTF8.self)
    notify(["status":"error","message":message]);fail(message)
}
c24_install_signals()
notify(["status":"listening","interface":interface,"mode":active ? "active session":"passive capture"])
print("Control|24 \(active ? "session owner":"passive listener") on \(interface). IPC is loopback only. Press Control-C to stop.")
var sequence: UInt32=1,ack: UInt32=0,lastPing=Date.distantPast,lastRX=Date.distantPast,online=false
var awaitingReply=false
var lastHandshake=Date.distantPast
var initializeAt: Date?
var decoder=NativeDecoder(),buffer=[UInt8](repeating:0,count:65535)
@MainActor func sendFrame(_ payload: Data) {
    let result=mac.withUnsafeBufferPointer {destination in payload.withUnsafeBytes {p in c24_send(capture,destination.baseAddress,p.bindMemory(to:UInt8.self).baseAddress,payload.count)}}
    if result == 0, payload.count > 22, payload[16..<20].elementsEqual([0xf0, 0x13, 1, 0x40]) {
        notify(["timing": "scribble", "timestamp": String(DispatchTime.now().uptimeNanoseconds), "payload": Wire.hex(payload.dropFirst(16))])
    }
    if result<0 {notify(["status":"error","message":"Raw Ethernet send failed"])}
}
@MainActor func command(_ code: UInt16) {
    sendFrame(Wire.frame([],sequence:sequence,acknowledgement:ack,command:code));sequence &+= 1
}
@MainActor func initializeDisplays() {
    let labels = (0..<24).compactMap { channel in
        try? Wire.scribble(channel: channel, text: "")
    }
    sendFrame(Wire.frame(labels, sequence: sequence))
    sequence &+= 1
}
@MainActor func beginHandshake() {
    awaitingReply=true
    notify(["status":"handshake","message":"Waiting for console response"])
    ack=0
    decoder=NativeDecoder()
    for _ in 0..<5 {command(0xe200);usleep(5000)}
    initializeAt=Date().addingTimeInterval(0.2)
    command(0)
    lastPing=Date()
    lastHandshake=Date()
    lastRX=lastHandshake
}
var requestBuffer = [UInt8](repeating: 0, count: 4096)
var touchedChannels = Set<Int>()
var meterLevels = [Int](repeating: 0, count: 24)
var meterTiming: [Int: String] = [:]
var meterFramePending = false
var lastMeterFrame: UInt64 = 0
while c24_should_stop()==0 {
    let count=c24_next(capture,&buffer,buffer.count)
    if count<0 {notify(["status":"error","message":"Capture stopped unexpectedly"]);break}
    if count>14 {
        let source=buffer[6..<12].map {String(format:"%02x",$0)}.joined(separator:":")
        let payload=Data(buffer[14..<Int(count)])
        notify(["hex":Wire.hex(payload),"mac":source])
        if active && source==macText && payload.count>=16 {
            lastRX=Date()
            let bytes=Array(payload),length=Int(bytes[0])*256+Int(bytes[1])
            guard length >= 16, length <= bytes.count else {continue}
            if length == 50 && !online {
                beginHandshake()
            } else if length != 50 && (online || awaitingReply) {
                if !online {
                    online=true
                    awaitingReply=false
                    notify(["status":"online","mac":source])
                }
                ack=bytes[4..<8].reduce(UInt32(0)) {($0<<8)|UInt32($1)}
                // The desk's link replies also advance the receive sequence.
                command(0xa000)
                // Echo only the desk's own fader movement, never an arbitrary position.
                if let decoded=try? decoder.decode(payload) {
                    for event in decoded where event.value == 1 {
                        if let id = event.control, ["button:0:2", "button:0:3"].contains(id) {
                            notify(["timing": id, "timestamp": String(DispatchTime.now().uptimeNanoseconds)])
                        }
                    }
                    for event in decoded where event.kind == "button" && event.control?.hasSuffix(":9") == true {
                        guard let id = event.control, let channel = Int(id.split(separator: ":").dropFirst().first ?? "") else {continue}
                        if event.value == 1 {touchedChannels.insert(channel)}
                        else {touchedChannels.remove(channel)}
                    }
                    for event in decoded where event.kind=="fader" {
                        if let id=event.control,let channel=Int(id.split(separator:":").last ?? ""),let value=event.value,
                           let native=try? Wire.fader(channel:channel,value:Int(value)) {
                            sendFrame(Wire.frame([native],sequence:sequence));sequence &+= 1
                        }
                    }
                }
            }
        }
    }
    if let deadline=initializeAt, Date() >= deadline {
        initializeDisplays()
        initializeAt=nil
    }
    if active && online && Date().timeIntervalSince(lastPing)>=1 {command(0);lastPing=Date()}
    if active && (online || awaitingReply) && Date().timeIntervalSince(lastRX)>4 {
        let message=online ? "Console traffic timed out" : "No response to active handshake"
        online=false
        awaitingReply=false
        initializeAt=nil
        meterLevels = [Int](repeating: 0, count: 24)
        meterTiming.removeAll()
        meterFramePending = false
        notify(["status":"offline","message":message])
    }
    if active && !online && Date().timeIntervalSince(lastHandshake)>=5 {beginHandshake()}
    var timecode: Data?
    var labels: [Int: Data] = [:]
    var lights: [Int: Data] = [:]
    // Bound each drain so that incoming desk events and keepalives still run.
    for _ in 0..<64 {
        let received = Darwin.recv(fd, &requestBuffer, requestBuffer.count, MSG_DONTWAIT)
        guard received > 0 else { break }
        guard active, online,
              let fields = (try? JSONSerialization.jsonObject(with: Data(requestBuffer.prefix(received)))) as? [String: String],
              fields["token"] == token,
              let channel = fields["channel"].flatMap(Int.init), (0..<24).contains(channel) else { continue }

        if fields["label0"] != nil {
            for channel in 0..<24 {
                if let label = fields["label\(channel)"] {
                    labels[channel] = try? Wire.scribble(channel: channel, text: label)
                }
            }
            continue
        }
        if let segments = fields["meter"].flatMap(Int.init), (0...14).contains(segments) {
            meterLevels[channel] = segments
            meterFramePending = true
            if channel < 2, let arrival = fields["arrival"], let forward = fields["forward"] {
                meterTiming[channel] = "\(channel + 1) \(arrival) \(forward) \(DispatchTime.now().uptimeNanoseconds)"
            }
            continue
        }
        let message: Data?
        if let section = fields["ledSection"].flatMap(Int.init),
           let note = fields["ledNote"].flatMap(Int.init),
           let on = fields["ledOn"], on == "0" || on == "1" {
            if let led = try? Wire.led(section: section, note: note, on: on == "1") {
                lights[section * 128 + note] = led
            }
            continue
        } else if let digits = fields["timecode"] {
            if let counter = try? Wire.counter(digits) { timecode = counter }
            continue
        } else if let position = fields["ring"].flatMap(Int.init) {
            message = try? Wire.ring(channel: channel, position: position)
        } else if let label = fields["label"] {
            labels[channel] = try? Wire.scribble(channel: channel, text: label)
            continue
        } else if let value = fields["value"].flatMap(Int.init), !touchedChannels.contains(channel) {
            message = try? Wire.fader(channel: channel, value: value)
        } else {
            message = nil
        }
        if let message {
            sendFrame(Wire.frame([message], sequence: sequence))
            sequence &+= 1
        }
    }
    // Use the same dedicated scribble frame format as display initialization.
    if !labels.isEmpty {
        let scribbles = labels.sorted { $0.key < $1.key }.map { $0.value }
        sendFrame(Wire.frame(scribbles, sequence: sequence))
        sequence &+= 1
    }
    let displays = (timecode.map { [$0] } ?? []) + lights.values
    if !displays.isEmpty {
        sendFrame(Wire.frame(displays, sequence: sequence))
        sequence &+= 1
    }
    let now = DispatchTime.now().uptimeNanoseconds
    if online, meterFramePending, now - lastMeterFrame >= 20_000_000 {
        let meters = meterLevels.enumerated().flatMap { channel, segments in
            (try? Wire.meter(channel: channel, segments: segments)) ?? []
        }
        sendFrame(Wire.frame(meters, sequence: sequence))
        sequence &+= 1
        let sent = DispatchTime.now().uptimeNanoseconds
        notify(["timing": "meter-frame", "timestamp": String(sent), "payload": String(meters.count)])
        for sample in meterTiming.values {
            notify(["timing": "meter", "timestamp": String(sent), "payload": sample])
        }
        meterTiming.removeAll(keepingCapacity: true)
        meterFramePending = false
        lastMeterFrame = sent
    }
    if !online {touchedChannels.removeAll()}
    if count == 0 {usleep(5000)}
}
if active && (online || awaitingReply) {command(0xe300)}
notify(["status":"stopped"]);c24_close(capture);Darwin.close(fd)
