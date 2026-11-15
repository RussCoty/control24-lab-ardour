import Foundation

public enum Wire {
    public static func hex(_ data: Data) -> String {data.map {String(format:"%02x",$0)}.joined(separator:" ")}
    public static func data(hex: String) throws -> Data {
        let clean=hex.filter { !$0.isWhitespace }
        guard clean.count % 2 == 0, clean.count <= 131072 else {throw LabError.invalid("Expected complete hexadecimal bytes.")}
        var result=Data();var index=clean.startIndex
        while index<clean.endIndex {
            let end=clean.index(index,offsetBy:2)
            guard let value=UInt8(clean[index..<end],radix:16) else {throw LabError.invalid("Invalid hexadecimal byte.")}
            result.append(value);index=end
        }
        return result
    }
    public static func frame(_ messages: [Data], sequence: UInt32 = 1, acknowledgement: UInt32 = 0, command: UInt16? = nil) -> Data {
        let body=messages.reduce(Data(),+), length=16+body.count
        var bytes=[UInt8](repeating:0,count:16)
        bytes[0]=UInt8((length>>8)&255);bytes[1]=UInt8(length&255)
        for i in 0..<4 {bytes[4+i]=UInt8((sequence>>UInt32(24-8*i))&255)}
        for i in 0..<4 {bytes[8+i]=UInt8((acknowledgement>>UInt32(24-8*i))&255)}
        let cmd=command ?? UInt16(clamping:messages.count)
        bytes[14]=UInt8(cmd>>8);bytes[15]=UInt8(cmd&255)
        var data=Data(bytes)+body
        if data.count<46 {data.append(Data(repeating:0,count:46-data.count))}
        return data
    }
    public static func led(section: Int, note: Int, on: Bool) throws -> Data {
        guard (0...31).contains(section),(0...127).contains(note) else {throw LabError.invalid("Invalid LED address.")}
        return Data([0x90,UInt8(note),UInt8(section | (on ? 0x40:0))])
    }
    public static func fader(channel: Int, value: Int) throws -> Data {
        guard (0..<24).contains(channel),(0...16383).contains(value) else {throw LabError.invalid("Fader requires channel 1–24 and value 0–16383.")}
        return Data([0xb0,UInt8(channel),UInt8(value>>7),UInt8(channel+32),UInt8(value&127)])
    }
    public static func meter(channel: Int, segments: Int) throws -> [Data] {
        guard (0..<24).contains(channel), (0...14).contains(segments) else {
            throw LabError.invalid("Invalid channel meter level.")
        }
        let mask = (1 << segments) - 1
        return [channel, channel + 32].map { address in
            Data([0xf0, 0x13, 1, 0x10, UInt8(address), UInt8(mask >> 7), UInt8(mask & 127), 0xf7])
        }
    }
    public static func scribble(channel: Int, text: String) throws -> Data {
        guard (0..<24).contains(channel) else {throw LabError.invalid("Invalid display channel.")}
        let chars=Array(text.unicodeScalars.prefix(4)).map {UInt8($0.value<128 ? $0.value:63)}
        return Data([0xf0,0x13,1,0x40,UInt8(0x20+channel),0]+chars+Array(repeating:32,count:4-chars.count)+[0xf7])
    }
    public static func ring(channel: Int, position: Int) throws -> Data {
        guard (0..<24).contains(channel),(0...14).contains(position) else {throw LabError.invalid("Invalid encoder-ring position.")}
        let high=(1...7).contains(position) ? 0x40>>(position-1):0
        let low=(8...14).contains(position) ? 0x40>>(position-8):0
        return Data([0xf0,0x13,1,0,UInt8(channel | (position==0 ? 0x40:0)),UInt8(high),UInt8(low),0xf7])
    }
    public static func counter(_ text: String) throws -> Data {
        let chars=Array(text.utf8), segments: [UInt8]=[0x7e,0x30,0x6d,0x79,0x33,0x5b,0x5f,0x70,0x7f,0x7b]
        guard chars.count==8,chars.allSatisfy({$0==32 || (48...57).contains($0)}) else {throw LabError.invalid("Counter requires exactly eight digits or spaces.")}
        return Data([0xf0,0x13,1,0x30,0x19,0x2a]+chars.reversed().map {$0==32 ? 0:segments[Int($0-48)]}+[0xf7])
    }
}

public struct NativeEvent: Sendable, Equatable {
    public var kind: String
    public var control: String?
    public var value: Double?
    public var raw: String
}
public struct NativeDecoder: Sendable {
    var msb=[Int?](repeating:nil,count:24)
    public init() {}
    public mutating func decode(_ data: Data) throws -> [NativeEvent] {
        let bytes=Array(data)
        guard bytes.count>=16 else {throw LabError.invalid("Truncated Control|24 header.")}
        let length=Int(bytes[0])*256+Int(bytes[1]),command=Int(bytes[14])*256+Int(bytes[15])
        guard length>=16,length<=bytes.count else {throw LabError.invalid("Invalid declared frame length.")}
        let raw=Wire.hex(data.prefix(length))
        if length==50 {return [NativeEvent(kind:"announce",raw:raw)]}
        if length==16 || command==0xa000 || command==0xe200 {return [NativeEvent(kind:"link",raw:raw)]}
        var messages: [[UInt8]]=[], status: UInt8?, pending: [UInt8]=[], sysex: [UInt8]?
        for b in bytes[16..<length] {
            if b>=0xf8 {continue}
            if sysex != nil {
                sysex!.append(b)
                if b==0xf7 {messages.append(sysex!);sysex=nil}
            } else if b==0xf0 {sysex=[b];status=nil;pending=[]}
            else if b&0x80 != 0 {status=b<0xf0 ? b:nil;pending=[]}
            else if let s=status {
                pending.append(b)
                let needed=[0xc0,0xd0].contains(s&0xf0) ? 1:2
                if pending.count==needed {messages.append([s]+pending);pending=[]}
            }
        }
        guard pending.isEmpty,sysex==nil else {throw LabError.invalid("Truncated native MIDI message.")}
        var cached=msb, events: [NativeEvent]=[]
        for m in messages {
            var e=NativeEvent(kind:"unknown",raw:Wire.hex(Data(m)))
            if m.count==3 && [0x80,0x90].contains(m[0]&0xf0) {
                e.kind="button";e.control="button:\(m[2]&0xbf):\(m[1])";e.value=m[2]&0x40 != 0 ? 1:0
            } else if m.count==3 && m[0]&0xf0==0xb0 {
                let cc=Int(m[1]), value=Int(m[2])
                if cc<24 {cached[cc]=value;continue}
                if (32..<56).contains(cc),let high=cached[cc-32] {
                    e.kind="fader";e.control="fader:\(cc-32)";e.value=Double((high<<7)|value)
                } else if (64..<88).contains(cc)||cc==92 {
                    e.kind="encoder";e.control=cc==92 ? "jog":"encoder:\(cc-64)";e.value=Double(value-64)
                }
            }
            events.append(e)
        }
        msb=cached
        return events
    }
}

public enum OSC {
    private static func string(_ value: String) throws -> Data {
        guard !value.contains("\0") else {throw LabError.invalid("OSC text cannot contain NUL.")}
        var data=Data(value.utf8);data.append(0)
        while data.count%4 != 0 {data.append(0)}
        return data
    }
    public static func encode(path: String, args: [OSCValue]) throws -> Data {
        guard path.hasPrefix("/"),args.count<=16 else {throw LabError.invalid("Expected an OSC path beginning with / and at most 16 arguments.")}
        var tags=",",body=Data()
        for arg in args {
            switch arg {
            case .int(let v):tags+="i";body.append(contentsOf:(0..<4).map {UInt8((UInt32(bitPattern:v)>>UInt32(24-8*$0))&255)})
            case .float(let v):
                guard v.isFinite else {throw LabError.invalid("OSC value must be finite.")}
                tags+="f";body.append(contentsOf:(0..<4).map {UInt8((v.bitPattern>>UInt32(24-8*$0))&255)})
            case .string(let v):tags+="s";body.append(try string(v))
            }
        }
        return try string(path)+string(tags)+body
    }
    public static func decode(_ data: Data) throws -> (String,[OSCValue]) {
        let bytes=Array(data);var offset=0
        func readString() throws -> String {
            guard offset<bytes.count,let end=bytes[offset...].firstIndex(of:0),
                  let value=String(bytes:bytes[offset..<end],encoding:.utf8) else {throw LabError.invalid("Malformed OSC text.")}
            offset=(end+4) & ~3
            guard offset<=bytes.count else {throw LabError.invalid("Truncated OSC padding.")}
            return value
        }
        let path=try readString(), tags=try readString()
        guard path.hasPrefix("/"),tags.hasPrefix(",") else {throw LabError.invalid("Expected OSC message; bundles are not supported yet.")}
        var args: [OSCValue]=[]
        for tag in tags.dropFirst() {
            if tag=="s" {args.append(.string(try readString()));continue}
            if tag == "d" {
                guard offset + 8 <= bytes.count else {throw LabError.invalid("Truncated OSC double.")}
                let bits = bytes[offset..<offset+8].reduce(UInt64(0)) {($0 << 8) | UInt64($1)}
                let value = Float(Double(bitPattern: bits))
                guard value.isFinite else {throw LabError.invalid("OSC value must be finite.")}
                args.append(.float(value))
                offset += 8
                continue
            }
            guard offset+4<=bytes.count,tag=="i"||tag=="f" else {throw LabError.invalid("Invalid OSC argument.")}
            let value=bytes[offset..<offset+4].reduce(UInt32(0)) {($0<<8)|UInt32($1)};offset+=4
            if tag=="i" {args.append(.int(Int32(bitPattern:value)))}
            else {
                let f=Float(bitPattern:value)
                guard f.isFinite else {throw LabError.invalid("OSC value must be finite.")}
                args.append(.float(f))
            }
        }
        guard offset==bytes.count else {throw LabError.invalid("Trailing OSC bytes.")}
        return (path,args)
    }
}
