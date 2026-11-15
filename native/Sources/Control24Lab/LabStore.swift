import AppKit
import Combine
import Control24Core
import Darwin
import Foundation
import Network
import os
import UniformTypeIdentifiers

enum Workspace: String, CaseIterable, Identifiable {
    case surface="Surface", inventory="Control inventory", profiles="Profiles & mappings", protocolLab="Protocol lab"
    var id: String {rawValue}
    var icon: String {
        switch self {case .surface:"slider.horizontal.below.rectangle";case .inventory:"list.bullet.rectangle";case .profiles:"arrow.triangle.branch";case .protocolLab:"waveform.path.ecg"}
    }
}

enum Resources {
    static func url(_ name: String, _ ext: String) throws -> URL {
        if let url=Bundle.main.url(forResource:name,withExtension:ext) {return url}
        if let url=Bundle.module.url(forResource:name,withExtension:ext,subdirectory:"Resources") {return url}
        throw LabError.invalid("Missing bundled resource: \(name).\(ext)")
    }
}

@MainActor
final class LabStore: ObservableObject {
    @Published var page: Workspace? = .surface
    @Published var selected="fader:0"
    @Published var activeID="ardour"
    @Published var profiles=Profile.defaults
    private var automationControl = "fader"

    @Published var armed = false {
        didSet { updateMeterOutput() }
    }
    private struct MeterOutput: Sendable {
        let host: String
        let send: @Sendable (Int, Int, UInt64) -> Void
    }
    private let meterOutput = OSAllocatedUnfairLock<MeterOutput?>(initialState: nil)

    private func updateMeterOutput() {
        let output = armed && profile.adapter == "osc"
            ? hardwareProxy.meterSender().map { MeterOutput(host: profile.host, send: $0) }
            : nil
        meterOutput.withLock { $0 = output }
    }
    @Published var values: [String:Double]=[:]
    @Published var text: [String:String]=[:]
    @Published var pressed: Set<String>=[]
    @Published var leds: [String:Bool]=[:]
    @Published var events: [LabEvent]=[]
    @Published var error: String?
    @Published var feedbackStatus="Feedback listener off"
    @Published var showHotspots=true
    @Published var nativePreview="No hardware command has been sent."
    @Published var mappingMode=false
    @Published var actionPickerPresented=false
    @Published var hardwareSheetPresented=false
    @Published var dawStatus="DAW not connected"
    @Published private(set) var processorStatus: String?
    @Published private(set) var processorControls: [ProcessorControl] = []
    private struct ProcessorRequest: Sendable {
        let channel: Int32
        let dynamics: Bool
        let allInserts: Bool
        let choice: Int
        let profileID: String
        let host: String
        let port: Int
        let sendLabels: (@Sendable ([String]) -> Void)?
        var plugin: Int32?
        var lastLabels: [String]?
    }
    private let processorRequest = OSAllocatedUnfairLock<ProcessorRequest?>(initialState: nil)
    private var processorMode: ProcessorMode?
    private var processorTimeout: Task<Void, Never>?
    private var processorRefresh: Task<Void, Never>?

    @Published var awaitingHardwareBinding: String?
    let catalog: Catalog
    let layout: ControlLayout
    let actionCatalog: ActionCatalog
    let geometry: SurfaceGeometry
    let photograph: NSImage
    let directory: URL
    var controls: [String:Control]
    var layoutByID: [String:ControlLayout.Region]
    private var wireBindings: [String:String]=[:]
    private var decoder=NativeDecoder()
    private var hardwareDecoder=NativeDecoder()
    private var pendingDAWSetup: (String,Int,Int)?
    private var dawFaderPositions: [Int: Double] = [:]
    private var movedWhileTouched: Set<Int> = []
    private var touched: Set<Int>=[]
    private var pending: [String:(position: Double, driveMotor: Bool)]=[:]
    private var commanded: [String:Int]=[:]
    private var sequence=0
    private var generation=0
    private let socketFD: Int32
    private var listener: NWListener?
    private var connections: [NWConnection]=[]
    private var listenerEpoch=0
    private var barsCounter = false
    private var counterReadings: [String: String] = [:]
    private var pendingMeterLevels: [String: Double] = [:]
    private var meterDisplayTask: Task<Void, Never>?
    private var lastLabelRefresh = Date.distantPast

    private func refreshDeskLabels() {
        guard armed else { return }
        hardwareProxy.labelPage((0..<24).map { channel in
            if processorMode == nil { return text["scribble:\(channel)"] ?? "" }
            return processorControls.indices.contains(channel) ? processorControls[channel].label : ""
        })
    }

    private func refreshCounter() {
        let path = barsCounter ? "/position/bbt" : "/position/smpte"
        guard let digits = counterReadings[path], digits != text["counter"] else { return }
        text["counter"] = digits
        if armed { hardwareProxy.showTimecode(digits) }
    }

    lazy var hardwareProxy: HardwareProxy=HardwareProxy { [weak self] fields in
        guard let self else {return}
        if let hex=fields["hex"],let data=try? Wire.data(hex:hex) {self.ingestHardware(data,mac:fields["mac"] ?? "unknown", arrival: fields["arrival"])}
        else if let state=fields["status"] {
            if ["online", "offline", "stopped"].contains(state) { self.updateMeterOutput() }
            self.record("hardware",state,fields["message"] ?? fields["mode"] ?? "",source:"helper")
            if state == "online", self.hardwareProxy.isManaged,
               self.activeID == "ardour", self.profile.host == "127.0.0.1" {
                self.connectDAW()
                if !self.armed { self.toggleOutput() }
            }
        }
    }

    struct Configuration: Codable {var activeID: String;var profiles: [Profile];var wireBindings: [String:String]?}

    init(directory: URL? = nil) throws {
        catalog=try JSONDecoder().decode(Catalog.self,from:Data(contentsOf:Resources.url("catalog","json")))
        layout=try JSONDecoder().decode(ControlLayout.self,from:Data(contentsOf:Resources.url("control-layout","json")))
        layoutByID=Dictionary(uniqueKeysWithValues:layout.regions.map {($0.id,$0)})
        actionCatalog=try JSONDecoder().decode(ActionCatalog.self,from:Data(contentsOf:Resources.url("daw-actions","json")))
        controls=Dictionary(uniqueKeysWithValues:catalog.controls.map {($0.id,$0)})
        geometry=try JSONDecoder().decode(SurfaceGeometry.self,from:Data(contentsOf:Resources.url("surface-geometry","json")))
        photograph = (try? Resources.url("control24-reference", "png")).flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(size: NSSize(width: 1000, height: 527), flipped: false) { rect in
                NSColor.windowBackgroundColor.setFill()
                rect.fill()
                return true
            }
        self.directory=directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Control24Lab",isDirectory:true)
        try FileManager.default.createDirectory(at:self.directory,withIntermediateDirectories:true)
        socketFD=Darwin.socket(AF_INET,SOCK_DGRAM,0)
        guard socketFD>=0 else {throw LabError.invalid("Cannot create the OSC socket.")}
        let configURL=self.directory.appendingPathComponent("profiles.json")
        if FileManager.default.fileExists(atPath:configURL.path) {
            do {
                let config=try JSONDecoder().decode(Configuration.self,from:Data(contentsOf:configURL))
                guard config.profiles.count==6,Set(config.profiles.map(\.id))==Set(Profile.defaults.map(\.id)) else {throw LabError.invalid("Unexpected profile IDs.")}
                for profile in config.profiles {try validate(profile)}
                profiles=config.profiles.map {saved in
                    var updated=saved
                    if ["ardour","mixbus"].contains(saved.id),let preset=Profile.defaults.first(where:{$0.id==saved.id}) {
                        updated.mappings.merge(preset.mappings) {existing,_ in existing}
                    }
                    return updated
                }
                wireBindings=(config.wireBindings ?? [:]).filter {controls[$0.value] != nil}
                if profiles.contains(where:{$0.id==config.activeID}) {activeID=config.activeID}
            } catch {self.error="Could not load saved profiles. Defaults are active. \(error.localizedDescription)"}
        }
        record("session","Native Swift application started","OSC output disabled",source:"app")
        NotificationCenter.default.addObserver(forName:NSApplication.willResignActiveNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.releaseAll() }
        }
    }

    var profile: Profile {profiles.first(where:{$0.id==activeID}) ?? profiles[0]}
    var control: Control? {controls[selected]}
    var channel: Int {max(0,(control?.channel ?? 1)-1)}
    var destination: String {"\(profile.host):\(profile.port)"}
    deinit {Darwin.close(socketFD)}

    private let eventLogQueue = DispatchQueue(label: "com.control24.lab.event-log")

    func record(_ kind: String, _ control: String="", _ value: String="", source: String="simulator") {
        sequence+=1
        let event=LabEvent(id:sequence,time:Date(),kind:kind,control:control,value:value,source:source,
                           profile:activeID,target:destination,generation:generation)
        events.append(event)
        if events.count>3000 {events.removeFirst(events.count-3000)}
        let url = directory.appendingPathComponent("events.ndjson")
        eventLogQueue.async { [weak self] in
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                var data = try encoder.encode(event)
                data.append(10)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                let file = try FileHandle(forWritingTo: url)
                defer { try? file.close() }
                try file.seekToEnd()
                try file.write(contentsOf: data)
            } catch {
                let message = error.localizedDescription
                Task { @MainActor [weak self] in
                    self?.error = "Could not write the event log: \(message)"
                }
            }
        }
    }

    func validate(_ p: Profile) throws {
        var addr=in_addr()
        guard p.host.withCString({inet_pton(AF_INET,$0,&addr)})==1,
              (0...65535).contains(p.port),!p.name.isEmpty,p.name.count<=80,
              ["osc","hui","mcu"].contains(p.adapter),p.mappings.count<=1500 else {throw LabError.invalid("Check the profile name, IPv4 address, port, and adapter.")}
        for (id,m) in p.mappings {
            guard controls[id] != nil else {throw LabError.invalid("Unknown mapped control: \(id)")}
            _ = try OSC.encode(path:m.path,args:m.args.map {$0 == .string("$value") || $0 == .string("$toggle") ? .int(0):$0})
        }
    }
    func persist() throws {
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(Configuration(activeID:activeID,profiles:profiles,wireBindings:wireBindings)).write(to:directory.appendingPathComponent("profiles.json"),options:.atomic)
    }
    func switchProfile(_ id: String) {
        guard profiles.contains(where:{$0.id==id}),id != activeID else {return}
        releaseAll()
        closeProcessorMode()
        armed=false;generation+=1;activeID=id
        values=[:];text=[:];leds=[:];pending=[:];commanded=[:];touched=[];movedWhileTouched=[]
        pendingDAWSetup=nil;dawStatus="DAW not connected"
        do {try persist();record("profile",profile.name,"Output disabled",source:"app")}
        catch {self.error=error.localizedDescription}
    }
    func save(_ p: Profile) {
        do {
            try validate(p)
            guard let index=profiles.firstIndex(where:{$0.id==p.id}) else {throw LabError.invalid("Unknown profile.")}
            var updated=profiles;updated[index]=p
            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
            try encoder.encode(Configuration(activeID:activeID,profiles:updated,wireBindings:wireBindings)).write(to:directory.appendingPathComponent("profiles.json"),options:.atomic)
            closeProcessorMode()
            armed=false;generation+=1;profiles=updated;record("profile-saved",p.name,"Output disabled",source:"app")
        } catch {self.error=error.localizedDescription}
    }
    func toggleOutput() {
        if armed {closeProcessorMode();armed=false;record("output","OSC","Disabled",source:"app");return}
        do {
            try validate(profile)
            guard profile.adapter=="osc",profile.port>0,!profile.mappings.isEmpty else {throw LabError.invalid("Choose an OSC profile and configure its destination and mappings first.")}
            mappingMode=false;armed=true;record("output","OSC",destination,source:"app")
            for (id, on) in leds {
                if let led = controls[id]?.led {
                    hardwareProxy.setButtonLED(section: led.section, note: led.note, on: on)
                }
            }
            for channel in 0..<24 {
                if let position = dawFaderPositions[channel], !touched.contains(channel) {
                    hardwareProxy.moveFader(channel: channel, value: Int(position))
                }
                if let label=text["scribble:\(channel)"] {
                    hardwareProxy.labelChannel(channel, name:label)
                }
            }
        } catch {self.error=error.localizedDescription}
    }
    func releaseAll() {
        for id in Array(pressed) {input(id,0)}
    }
    func pulse(_ id: String) {
        selected=id;input(id,1)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for:.milliseconds(120))
            self?.input(id,0)
        }
    }
    func toggleMappingMode() {
        releaseAll();closeProcessorMode();armed=false;mappingMode.toggle()
        record("learn-mode","Mapping mode",mappingMode ? "Click or press a control, then choose its action":"Off",source:"app")
    }
    func pickControl(_ id: String) {
        selected=id
        if mappingMode,let c=controls[id],c.kind != "analog" {actionPickerPresented=true}
    }
    func assign(_ action: ActionCatalog.Definition) {
        do {
            guard let c=control,action.profiles.contains(activeID),action.kinds.contains(c.kind) else {throw LabError.invalid("This action does not match the selected control/profile.")}
            var updated=profile;updated.mappings[c.id]=try action.resolved(for:c)
            save(updated);actionPickerPresented=false
            record("assignment",c.id,action.title,source:"app")
        } catch {self.error=error.localizedDescription}
    }
    func applySuggestedProfile() {
        guard let suggested=Profile.defaults.first(where:{$0.id==activeID}),["ardour","mixbus"].contains(activeID) else {return}
        var updated=profile
        updated.mappings.merge(suggested.mappings) {_,new in new}
        updated.status=activeID=="ardour" ? "Ardour · OSC profile":"Mixbus 12 · standard OSC profile · live validation pending"
        save(updated)
    }
    func ingestHardware(_ data: Data, mac: String, arrival: String? = nil) {
        do {
            let decoded=try hardwareDecoder.decode(data)
            guard !decoded.isEmpty else { return }
            if let arrival, decoded.contains(where: {
                $0.value == 1 && ($0.control == "button:0:2" || $0.control == "button:0:3")
            }) {
                HardwareProxy.writeTiming("\(arrival) button-ipc-arrival")
                HardwareProxy.writeTiming("\(DispatchTime.now().uptimeNanoseconds) button-ui-handled")
            }
            record("frame",mac,Wire.hex(data),source:"hardware")
            for event in decoded {
                guard let rawID=event.control,let value=event.value else {record(event.kind,mac,event.raw,source:"hardware");continue}
                if event.kind=="button",value==1,let target=awaitingHardwareBinding {
                    wireBindings[rawID]=target;awaitingHardwareBinding=nil;try persist()
                    selected=target;record("wire-binding",target,rawID,source:"hardware")
                    continue
                }
                let id=wireBindings[rawID] ?? rawID
                input(id,value,source:"hardware")
            }
        } catch {self.error=error.localizedDescription}
    }

    func input(_ id: String, _ value: Double, source: String="simulator") {
        guard value.isFinite else {error="Input value must be finite.";return}
        guard let c=controls[id] else {record("unknown",id,String(value),source:source);return}
        let isButton=["button","touch"].contains(c.kind)
        guard !isButton || value==0 || value==1 else {error="Button input must be 0 or 1.";return}
        if c.kind=="fader", !(0...16383).contains(value) {error="Fader value must be 0–16383.";return}
        if c.kind=="encoder", !(-64...63).contains(value) {error="Encoder delta must be −64…63.";return}
        let repeated=isButton && pressed.contains(id)==(value != 0)
        if isButton {if value != 0 {pressed.insert(id)} else {pressed.remove(id)}}
        if c.kind=="fader" {
            values[id]=value.rounded()
            if source == "hardware", let channel = c.channel, touched.contains(channel - 1) {
                movedWhileTouched.insert(channel - 1)
            }
        }
        record(c.kind,id,String(format:"%g",value),source:source)
        if c.kind=="touch",let ch=c.channel.map({$0-1}) {
            if value != 0 {touched.insert(ch)}
            else {
                touched.remove(ch)
                let id="fader:\(ch)"
                let moved = movedWhileTouched.remove(ch) != nil
                if let update=pending.removeValue(forKey:id), !(moved && update.driveMotor) {
                    applyFaderFeedback(id, channel:ch, position:update.position, driveMotor:update.driveMotor)
                }
            }
        }
        if id == "button:25:19", !repeated, value == 1, !mappingMode, source != "offline replay" {
            barsCounter.toggle()
            refreshCounter()
            return
        }
        if mappingMode,source != "offline replay" {
            if !repeated,(!isButton || value != 0),c.kind != "analog" {
                selected=id;actionPickerPresented=true
                record("learn",id,"Choose an action",source:source)
            }
            return
        }
        if armed, activeID == "ardour", value == 1, !repeated,
           source == "hardware" || source == "simulator",
           let target = ["button:24:24": "fader", "button:24:26": "pan_stereo_position",
                         "button:24:28": "mute"][id], profile.mappings[id] == nil {
            automationControl = target
            record("automation", id, "Selected \(target) for automation mode", source: source)
            return
        }
        let keys=[0,2,4,6,8,50]
        if c.section==24,let note=c.note,let index=keys.firstIndex(of:note),value != 0,!repeated,
           pressed.contains("button:24:35"),pressed.contains("button:24:36") {
            switchProfile(Profile.defaults[index].id);return
        }
        if source == "hardware" || source == "simulator" {
            if armed, ["ardour", "mixbus"].contains(activeID), profile.adapter == "osc",
               c.kind == "button", !repeated, value == 1, let channel = c.channel,
               c.section == channel - 1, let note = c.note {
                if [2, 3, 10].contains(note) {
                    openProcessor(channel: channel, dynamics: note == 3, allInserts: note == 10)
                    return
                }
                if [1, 6].contains(note) {closeProcessorMode()}
            }
            if processorMode != nil, c.kind == "encoder", let channel = c.channel {
                turnProcessorControl(at: channel - 1, delta: value)
                return
            }
            if processorMode != nil, c.kind == "button", c.note == 4,
               let channel = c.channel, c.section == channel - 1 {
                if value == 1, !repeated {turnProcessorControl(at: channel - 1, delta: 1, switchOnly: true)}
                return
            }
            if !repeated, value == 1, ["button:27:10", "button:27:12"].contains(id) {closeProcessorMode()}
        }
        if c.kind=="encoder" {values[id]=max(0,min(1,(values[id] ?? 0.5)+value/100))}
        guard !repeated,let mapping=profile.mappings[id] else {return}
        guard !(isButton && value==0 && mapping.trigger != "both") else {return}
        let next=1-(commanded[id] ?? ((leds[id] ?? false) ? 1:0))
        commanded[id]=next
        let normalized=c.kind=="fader" ? value/16383:value
        let args=mapping.args.map {arg -> OSCValue in
            if arg == .string("$value") {return .float(Float(normalized))}
            if arg == .string("$position") {return .float(Float(values[id] ?? 0.5))}
            if arg == .string("$delta") {return .float(Float(value))}
            if case .string(let text) = arg, text.hasPrefix("$float:"), let number = Float(text.dropFirst(7)) { return .float(number) }
            if arg == .string("$toggle") {return .int(Int32(next))}
            return arg
        }
        do {
            let path = activeID == "ardour" && mapping.path == "/select/fader/automation"
                ? "/select/\(automationControl)/automation" : mapping.path
            let packet=try OSC.encode(path:path,args:args)
            let send=armed && ["simulator","hardware"].contains(source) && profile.adapter=="osc"
            if send {
                try sendUDP(packet,host:profile.host,port:profile.port)
                if mapping.path == "/strip/select", activeID == "ardour",
                   args.count == 2, let strip = args[0].number, (1...24).contains(strip),
                   strip.rounded() == strip, args[1].number == 1 {
                    for channel in 0..<24 {
                        feedback("button:\(channel):6", value: channel == Int(strip) - 1 ? 1 : 0,
                                 source: "OSC feedback")
                    }
                }
            }
            record("route",id,"\(path) \(args.map(\.display).joined(separator:" "))",source:send ? "UDP sent · delivery unconfirmed":"Preview only")
        } catch {armed=false;self.error=error.localizedDescription;record("route-error",id,error.localizedDescription,source:"app")}
    }

    func feedback(_ id: String, value: Double, source: String="simulated feedback") {
        guard value.isFinite,let c=controls[id] else {return}
        if c.led != nil || c.kind=="led" {
            guard value==0 || value==1 else {return}
            let on = value != 0
            if source == "OSC feedback", armed, leds[id] != on, let led = c.led {
                hardwareProxy.setButtonLED(section: led.section, note: led.note, on: on)
            }
            leds[id]=on;commanded[id]=on ? 1:0
        } else if c.kind=="fader" {
            guard (0...16383).contains(value) else {return}
            let driveMotor = source == "OSC feedback"
            if let channel=c.channel {
                let ch=channel-1
                if touched.contains(ch) {
                    pending[id]=(value,driveMotor)
                } else {
                    applyFaderFeedback(id, channel:ch, position:value, driveMotor:driveMotor)
                }
            } else {values[id]=value}
        } else {values[id]=value}
        record("feedback",id,String(format:"%g",value),source:source)
    }
    private func applyFaderFeedback(_ id: String, channel: Int, position: Double, driveMotor: Bool) {
        let changed = dawFaderPositions[channel] != position
        if driveMotor { dawFaderPositions[channel] = position }
        values[id] = position
        if driveMotor && armed && changed {
            hardwareProxy.moveFader(channel: channel, value: Int(position.rounded()))
        }
    }
    func decode(_ hex: String) {
        do {
            let data=try Wire.data(hex:hex), decoded=try decoder.decode(data)
            record("frame","Ethernet payload",Wire.hex(data),source:"offline replay")
            for e in decoded {
                if let id=e.control,let value=e.value {input(id,value,source:"offline replay")}
                else {record(e.kind,"Native payload",e.raw,source:"offline replay")}
            }
        } catch {self.error=error.localizedDescription}
    }
    func preview(_ c: Control, number: Double, display: String) {
        do {
            guard number.isFinite,number>=0,number<=16383 else {throw LabError.invalid("Invalid feedback value.")}
            let data: Data
            if c.kind=="fader" {data=try Wire.fader(channel:(c.channel ?? 1)-1,value:Int(number))}
            else if c.kind=="ring" {data=try Wire.ring(channel:(c.channel ?? 1)-1,position:Int(number))}
            else if c.kind=="scribble" {data=try Wire.scribble(channel:(c.channel ?? 1)-1,text:display)}
            else if c.kind=="counter" {data=try Wire.counter(display)}
            else if let led=c.led {data=try Wire.led(section:led.section,note:led.note,on:number != 0)}
            else {throw LabError.invalid("This output encoding is not implemented yet.")}
            nativePreview="NATIVE  \(Wire.hex(data))\n\nFRAME  \(Wire.hex(Wire.frame([data])))\n\nPreview only · hardware transmission not implemented"
            if ["scribble","counter"].contains(c.kind) {text[c.id]=String(display.prefix(c.kind=="counter" ? 8:4));record("feedback",c.id,display,source:"simulated feedback")}
            else {feedback(c.id,value:number)}
        } catch {self.error=error.localizedDescription}
    }

    private func sendUDP(_ data: Data, host: String, port: Int) throws {
        try Self.sendUDP(data, host: host, port: port, socketFD: socketFD)
    }

    nonisolated private static func sendUDP(_ data: Data, host: String, port: Int, socketFD: Int32) throws {
        var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family=sa_family_t(AF_INET);address.sin_port=UInt16(port).bigEndian
        guard host.withCString({inet_pton(AF_INET,$0,&address.sin_addr)})==1 else {throw LabError.invalid("Invalid destination IPv4 address.")}
        let sent=data.withUnsafeBytes {buffer in
            withUnsafePointer(to:&address) {pointer in
                pointer.withMemoryRebound(to:sockaddr.self,capacity:1) {
                    sendto(socketFD,buffer.baseAddress,buffer.count,0,$0,socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent==data.count else {throw LabError.invalid("UDP send failed: \(String(cString:strerror(errno)))")}
    }

    func startFeedback(port: Int) {
        stopFeedback()
        guard (1...65535).contains(port),let port=NWEndpoint.Port(rawValue:UInt16(port)) else {error="Choose a UDP feedback port from 1–65535.";return}
        do {
            let listener=try NWListener(using:.udp,on:port), epoch=listenerEpoch
            self.listener=listener;feedbackStatus="Starting UDP \(port.rawValue)…"
            listener.stateUpdateHandler={ [weak self] status in
                Task { @MainActor [weak self] in
                    guard let self,self.listenerEpoch==epoch else {return}
                    switch status {
                    case .ready:
                        self.feedbackStatus="Listening · UDP \(port.rawValue)"
                        if let setup=self.pendingDAWSetup,setup.0==self.activeID,setup.1==self.generation {
                            self.pendingDAWSetup=nil;self.configureDAW(feedbackPort:setup.2)
                        }
                    case .failed(let e):self.feedbackStatus="Listener failed";self.error=e.localizedDescription
                    default:break
                    }
                }
            }
            listener.newConnectionHandler={ [weak self] connection in
                Task { @MainActor [weak self] in
                    guard let self,self.listenerEpoch==epoch else {connection.cancel();return}
                    if self.connections.count>=64 {self.connections.removeFirst().cancel()}
                    self.connections.append(connection)
                    connection.start(queue:.global(qos:.userInitiated))
                    let request = self.processorRequest
                    let meters = self.meterOutput
                    Self.receive(connection) { [weak self] packets,host in
                        let arrival = DispatchTime.now().uptimeNanoseconds
                        if let (path, args) = packets.first, path == "/strip/meter",
                           args.count == 2, let strip = args[0].number, (1...24).contains(strip),
                           strip.rounded() == strip, let value = args[1].number, value.isFinite {
                            let channel = Int(strip) - 1
                            let segments = min(14, Int(max(0, min(1, value)) * 15))
                            meters.withLock { output in
                                guard output?.host == host else { return }
                                HardwareProxy.writeTiming("\(arrival) meter-in \(channel + 1) \(segments)")
                                output?.send(channel, segments, arrival)
                            }
                        }
                        var descriptorRequested = false
                        if let self, let (path, args) = packets.first, path == "/strip/plugin/list" {
                            descriptorRequested = request.withLock { state in
                                guard var current = state, current.host == host, args.first == .int(current.channel),
                                      let candidate = Self.processorCandidate(args, request: current) else { return false }
                                do {
                                    let data = try OSC.encode(path: "/strip/plugin/descriptor", args: [.int(current.channel), .int(candidate.0)])
                                    try Self.sendUDP(data, host: host, port: current.port, socketFD: self.socketFD)
                                    if current.plugin == nil { current.plugin = candidate.0 }
                                    state = current
                                    return true
                                } catch { return false }
                            }
                        }
                        if let (path, end) = packets.last, path == "/strip/plugin/descriptor_end" {
                            request.withLock { state in
                                guard var current = state, current.host == host, let plugin = current.plugin,
                                      end.count >= 2, end[0] == .int(current.channel), end[1] == .int(plugin),
                                      let send = current.sendLabels else { return }
                                var labels: [Int32: String] = [:]
                                for (path, args) in packets where path == "/strip/plugin/descriptor" {
                                    guard args.count >= 11, args[0] == end[0], args[1] == end[1],
                                          case .int(let index) = args[2], index > 0,
                                          case .int(let flags) = args[4], flags & 128 != 0, flags & 256 == 0,
                                          let lower = args[6].number, let upper = args[7].number, lower < upper,
                                          case .int(let count) = args[9], count >= 0,
                                          args.count == 11 + 2 * Int(count), args.last?.number != nil else { continue }
                                    labels[index] = args[3].display
                                }
                                let names = labels.sorted { $0.key < $1.key }.prefix(24).map { $0.value }
                                let page = names + Array(repeating: "", count: 24 - names.count)
                                if page != current.lastLabels {
                                    send(page)
                                    current.lastLabels = page
                                    state = current
                                }
                            }
                        }
                        let sentDescriptor = descriptorRequested
                        Task { @MainActor [weak self] in
                            guard let self,self.listenerEpoch==epoch else {return}
                            if let path = packets.last?.0, path.hasPrefix("/strip/plugin/") {
                                HardwareProxy.writeTiming("\(arrival) osc-arrival \(path)")
                                HardwareProxy.writeTiming("\(DispatchTime.now().uptimeNanoseconds) osc-handled \(path)")
                            }
                            for (path, args) in packets {
                                self.receiveOSC(path, args: args, host: host, arrival: arrival, descriptorRequested: sentDescriptor)
                            }
                        }
                    }
                }
            }
            listener.start(queue:.global(qos:.userInitiated))
        } catch {self.error=error.localizedDescription}
    }
    nonisolated private static func receive(
        _ connection: NWConnection,
        descriptors: [(String, [OSCValue])] = [],
        handler: @escaping @Sendable ([(String, [OSCValue])], String) -> Void
    ) {
        connection.receiveMessage { data, _, _, error in
            var pending = descriptors
            if let data, case .hostPort(let host, _) = connection.endpoint {
                let address = String(describing: host)
                if let (path, args) = try? OSC.decode(data) {
                    switch path {
                    case "/strip/plugin/descriptor":
                        if pending.count < 16384 { pending.append((path, args)) }
                    case "/strip/plugin/descriptor_end":
                        handler(pending + [(path, args)], address)
                        pending.removeAll()
                    default:
                        handler([(path, args)], address)
                    }
                } else {
                    handler([("", [])], address)
                }
            }
            if error == nil { receive(connection, descriptors: pending, handler: handler) }
            else { connection.cancel() }
        }
    }
    func stopFeedback() {
        meterDisplayTask?.cancel()
        meterDisplayTask = nil
        pendingMeterLevels.removeAll()
        closeProcessorMode()
        pendingDAWSetup=nil
        dawFaderPositions.removeAll()
        listenerEpoch+=1;listener?.cancel();listener=nil
        connections.forEach {$0.cancel()};connections=[];feedbackStatus="Feedback listener off"
    }
    func connectDAW(feedbackPort: Int=9126) {
        guard ["ardour","mixbus"].contains(activeID),profile.adapter=="osc",profile.port>0 else {error="Select the Ardour or Mixbus OSC profile first.";return}
        armed=false;dawStatus="Starting feedback listener…"
        startFeedback(port:feedbackPort)
        pendingDAWSetup=(activeID,generation,feedbackPort)
    }
    private func configureDAW(feedbackPort: Int) {
        do {
            // Local checkout osc.h: buttons, variables, heartbeat, globals, BBT,
            // SMPTE, positional meters and OSC 1.0; no SSID path extensions.
            let setup: [OSCValue]=[.int(24),.int(31),.int(24827),.int(3),.int(0),.int(0),.int(Int32(feedbackPort))]
            try sendUDP(OSC.encode(path:"/set_surface",args:setup),host:profile.host,port:profile.port)
            try sendUDP(OSC.encode(path:"/refresh",args:[]),host:profile.host,port:profile.port)
            dawStatus="Setup sent · awaiting DAW feedback"
            record("daw-setup",profile.name,"24 strips · positional faders · UDP feedback \(feedbackPort)",source:"app")
        } catch {self.error=error.localizedDescription;dawStatus="Setup failed"}
    }
    private func receiveOSC(_ path: String, args: [OSCValue], host: String, arrival: UInt64, descriptorRequested: Bool) {
        guard profile.adapter=="osc",host==profile.host else {return}
        guard !path.isEmpty else {
            record("osc-error", "UDP", "Malformed OSC packet", source: "OSC feedback")
            return
        }
        do {
            let receiving = "Receiving OSC feedback · \(profile.name)"
            if dawStatus != receiving { dawStatus = receiving }
            if receiveProcessorFeedback(path, args, descriptorRequested: descriptorRequested) {return}
            if args.count==1,let value=args[0].number,
               let id=["/transport_play":"button:28:16","/record_enabled":"button:28:17","/rec_enable_toggle":"button:28:17","/loop_toggle":"button:28:9"][path] {
                feedback(id,value:value,source:"OSC feedback");return
            }
            if path == "/heartbeat" {
                if Date().timeIntervalSince(lastLabelRefresh) >= 5 {
                    lastLabelRefresh = Date()
                    refreshDeskLabels()
                }
                if armed {
                    for channel in 0..<24 {
                        let id = "button:\(channel):6"
                        if let led = controls[id]?.led {
                            hardwareProxy.setButtonLED(section: led.section, note: led.note, on: leds[id] ?? false)
                        }
                    }
                }
                return
            }
            if ["/position/smpte", "/position/bbt"].contains(path), let value = args.first {
                let digits = String(value.display.filter(\.isNumber))
                if path == "/position/bbt", digits.count >= 8 {
                    counterReadings[path] = String(digits.suffix(8))
                } else if digits.count == 8 {
                    counterReadings[path] = digits
                }
                refreshCounter()
                return
            }
            guard args.count==2,let index=args[0].number,index.rounded()==index,(1...24).contains(index) else {
                record("osc-unmapped",path,args.map(\.display).joined(separator:" "),source:"OSC feedback");return
            }
            let ch=Int(index)-1
            if path=="/strip/meter", let value=args[1].number, value.isFinite {
                // In positional meter mode, Ardour sends (dBFS + 94) / 100.
                let id = "meter:\(ch)"
                let level = max(0, min(1, value))
                pendingMeterLevels[id] = level
                if meterDisplayTask == nil {
                    meterDisplayTask = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(50))
                        guard !Task.isCancelled, let self else { return }
                        var updated = self.values
                        updated.merge(self.pendingMeterLevels) { _, latest in latest }
                        self.pendingMeterLevels.removeAll(keepingCapacity: true)
                        self.meterDisplayTask = nil
                        if updated != self.values { self.values = updated }
                    }
                }
                return
            }
            if path=="/strip/name" {
                let id="scribble:\(ch)"
                let label=String(args[1].display.prefix(4))
                if text[id] == label { return }
                text[id]=label
                if armed, processorMode == nil {hardwareProxy.labelChannel(ch, name:label)}
                record("feedback",id,args[1].display,source:"OSC feedback")
            }
            else if path=="/strip/fader",let value=args[1].number,(0...1).contains(value) {feedback("fader:\(ch)",value:(value*16383).rounded(),source:"OSC feedback")}
            else if path=="/strip/pan_stereo_position",let value=args[1].number,(0...1).contains(value) {
                values["encoder:\(ch)"]=value;values["ring:\(ch)"]=(value*14).rounded()
                record("feedback","encoder:\(ch)",args[1].display,source:"OSC feedback")
            }
            else if let note=["/strip/mute":8,"/strip/solo":7,"/strip/recenable":0,"/strip/select":6][path],let value=args[1].number {feedback("button:\(ch):\(note)",value:value,source:"OSC feedback")}
            else {record("osc-unmapped",path,args.map(\.display).joined(separator:" "),source:"OSC feedback")}
        }
    }

    func exportLog() {
        let panel=NSSavePanel();panel.nameFieldStringValue="control24-swift-events.ndjson"
        if panel.runModal() == .OK,let url=panel.url {
            do {let logURL = directory.appendingPathComponent("events.ndjson"); try eventLogQueue.sync { try Data(contentsOf:logURL) }.write(to:url,options:.atomic)}
            catch {self.error=error.localizedDescription}
        }
    }
    func exportCatalog() {
        let panel=NSSavePanel();panel.nameFieldStringValue="control24-catalog.json";panel.allowedContentTypes=[.json]
        if panel.runModal() == .OK,let url=panel.url {
            do {try Data(contentsOf:Resources.url("catalog","json")).write(to:url,options:.atomic)}
            catch {self.error=error.localizedDescription}
        }
    }
    func importCapture() {
        let panel=NSOpenPanel();panel.allowsMultipleSelection=false
        if panel.runModal() == .OK,let url=panel.url {
            do {
                let data=try Data(contentsOf:url)
                guard data.count<=10_000_000 else {throw LabError.invalid("Use captures smaller than 10 MB for this workbench.")}
                let content=String(decoding:data,as:UTF8.self)
                for line in content.split(whereSeparator:\.isNewline) {
                    if let item=try JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any],let hex=item["hex"] as? String {decode(hex)}
                }
            } catch {self.error=error.localizedDescription}
        }
    }
}

struct ProcessorControl: Identifiable {
    var id: String { "\(path):\(index)" }
    let path: String
    let index: Int32
    let label: String
    var value: Double
    var lower = 0.0
    var upper = 1.0
    var flags = 0
    var steps: [Double] = []

    var position: Double {
        if flags & 4 != 0, lower > 0, value > 0 {
            return max(0, min(1, log(value / lower) / log(upper / lower)))
        }
        return max(0, min(1, (value - lower) / (upper - lower)))
    }

    var ringPosition: Int { 1 + Int((position * 13).rounded()) }

    func adjusted(by delta: Double) -> Double {
        if !steps.isEmpty {
            let nearest = steps.indices.min { abs(steps[$0] - value) < abs(steps[$1] - value) } ?? 0
            return steps[max(0, min(steps.count - 1, nearest + Int(delta)))]
        }
        if flags & 64 != 0 {return delta > 0 ? upper : lower}
        if flags & 2 != 0 {return max(lower, min(upper, value.rounded() + delta))}
        let target = max(0, min(1, position + delta / 100))
        if flags & 4 != 0, lower > 0 {return lower * pow(upper / lower, target)}
        return lower + target * (upper - lower)
    }
}

private struct ProcessorMode {
    let channel: Int32
    let dynamics: Bool
    let allInserts: Bool
    let choice: Int
    var plugin: Int32?
    var name = ""
    var confirmed = false
    var received: [String: ProcessorControl] = [:]
    var requested: [Int32: Double] = [:]
}

extension LabStore {
    private func refreshEncoderRings() {
        guard armed else { return }
        for channel in 0..<24 {
            let position = processorControls.indices.contains(channel)
                ? processorControls[channel].ringPosition : 0
            hardwareProxy.setEncoderRing(channel: channel, position: position)
        }
    }

    func closeProcessorMode() {
        resetProcessorMode(restoreTrackLabels: true)
    }

    private func resetProcessorMode(restoreTrackLabels: Bool) {
        let wasOpen = processorMode != nil
        processorRequest.withLock { $0 = nil }
        processorMode = nil
        if wasOpen, restoreTrackLabels { refreshDeskLabels() }
        processorTimeout?.cancel()
        processorRefresh?.cancel()
        processorControls = []
        if wasOpen { refreshEncoderRings() }
        processorStatus = nil
    }

    private func sendProcessorOSC(_ path: String, _ args: [OSCValue]) {
        do {
            try sendUDP(OSC.encode(path: path, args: args), host: profile.host, port: profile.port)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func openProcessor(channel: Int, dynamics: Bool, allInserts: Bool) {
        let same = processorMode?.channel == Int32(channel) && processorMode?.dynamics == dynamics && processorMode?.allInserts == allInserts
        let choice = same && !processorControls.isEmpty ? (processorMode?.choice ?? 0) + 1 : 0
        resetProcessorMode(restoreTrackLabels: false)
        processorMode = ProcessorMode(channel: Int32(channel), dynamics: dynamics, allInserts: allInserts, choice: choice)
        let request = ProcessorRequest(channel: Int32(channel), dynamics: dynamics, allInserts: allInserts,
                                       choice: choice, profileID: activeID, host: profile.host, port: profile.port,
                                       sendLabels: armed ? hardwareProxy.processorLabelSender() : nil)
        processorRequest.withLock { $0 = request }
        HardwareProxy.writeTiming("\(DispatchTime.now().uptimeNanoseconds) processor-request")
        processorStatus = "Reading channel \(channel) \(dynamics ? "dynamics" : "EQ")…"
        sendProcessorOSC("/strip/plugin/list", [.int(Int32(channel))])
        processorTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.processorControls.isEmpty else {return}
            self.processorStatus = "No processor feedback. Connect the DAW and press EQ or DYN again."
        }
    }

    private func turnProcessorControl(at index: Int, delta: Double, switchOnly: Bool = false) {
        guard armed, delta != 0, var mode = processorMode, mode.confirmed,
              processorControls.indices.contains(index) else {return}
        var control = processorControls[index]
        control.value = mode.requested[control.index] ?? control.value
        if switchOnly, control.flags & 64 == 0, control.steps.isEmpty {return}
        let value = switchOnly && control.flags & 64 != 0
            ? (control.value > control.lower ? control.lower : control.upper)
            : control.adjusted(by: delta)
        guard let plugin = mode.plugin else {return}
        sendProcessorOSC("/strip/plugin/parameter", [.int(mode.channel), .int(plugin), .int(control.index), .float(Float(value))])
        control.value = value
        processorControls[index] = control
        hardwareProxy.setEncoderRing(channel: index, position: control.ringPosition)
        mode.requested[control.index] = value
        processorMode = mode
        record("processor", control.label, String(format: "%g", value), source: mode.name)
    }

    nonisolated private static func processorCandidate(_ args: [OSCValue], request: ProcessorRequest) -> (Int32, String, Int)? {
        let candidates = stride(from: 1, to: args.count - 2, by: 3).compactMap { index -> (Int32, String, Int)? in
            guard case .int(let plugin) = args[index], plugin > 0 else {return nil}
            let name = args[index + 1].display
            if request.allInserts { return (plugin, name, 0) }
            let lower = name.lowercased()
            let builtIns = request.dynamics ? ["comp", "gate", "ssl comp", "ssl gate"] : ["32c eq", "9kj eq"]
            if request.profileID == "mixbus", let priority = builtIns.firstIndex(of: lower) {
                return (plugin, name, priority)
            }
            if request.dynamics {
                if lower.hasPrefix("ace compressor") {return (plugin, name, 10)}
                if lower.contains("gate") || lower.contains("expander") {return (plugin, name, 11)}
            } else if lower.hasPrefix("ace eq") {
                return (plugin, name, 10)
            }
            return nil
        }.sorted { ($0.2, $0.0) < ($1.2, $1.0) }
        guard !candidates.isEmpty else { return nil }
        return candidates[request.choice % candidates.count]
    }

    private func receiveProcessorFeedback(_ path: String, _ args: [OSCValue], descriptorRequested: Bool) -> Bool {
        guard var mode = processorMode else {return false}
        if path == "/strip/plugin/list", args.first == .int(mode.channel) {
            guard let request = processorRequest.withLock({ $0 }),
                  let candidate = Self.processorCandidate(args, request: request) else {
                closeProcessorMode()
                processorStatus = "No \(mode.allInserts ? "inserts" : mode.dynamics ? "compressor, gate or expander" : "ACE EQ") found on channel \(mode.channel)."
                processorTimeout?.cancel()
                return true
            }
            if let plugin = mode.plugin, (plugin != candidate.0 || mode.name != candidate.1) {
                closeProcessorMode()
                processorStatus = "The insert list changed. Press INSERTS, EQ or DYN to load it again."
                return true
            }
            mode.plugin = candidate.0
            mode.name = candidate.1
            mode.received = [:]
            processorMode = mode
            if !descriptorRequested {
                sendProcessorOSC("/strip/plugin/descriptor", [.int(mode.channel), .int(candidate.0)])
            }
            return true
        } else if let plugin = mode.plugin, args.count >= 2,
                  args[0] == .int(mode.channel), args[1] == .int(plugin) {
            if path == "/strip/plugin/descriptor_end" {
                mode.confirmed = true
                mode.requested.removeAll()
            } else if path == "/strip/plugin/descriptor", args.count >= 11,
                      case .int(let index) = args[2], index > 0, case .int(let flags) = args[4],
                      flags & 128 != 0, flags & 256 == 0,
                      let lower = args[6].number, let upper = args[7].number, lower < upper,
                      case .int(let count) = args[9], count >= 0, args.count == 11 + 2 * Int(count),
                      let value = args.last?.number {
                let steps = stride(from: 10, to: args.count - 1, by: 2).compactMap {args[$0].number}.sorted()
                let control = ProcessorControl(path: "/strip/plugin/parameter", index: index,
                                               label: args[3].display, value: value,
                                               lower: lower, upper: upper, flags: Int(flags) | (mode.name == "Comp" && args[3].display == "Mode" ? 2 : 0), steps: steps)
                mode.received[control.id] = control
            } else {return false}
        } else {return false}

        processorMode = mode
        if path == "/strip/plugin/descriptor_end", mode.confirmed {
            let previousLabels = processorControls.map(\.label)
            let previousPositions = processorControls.map(\.ringPosition)
            processorControls = Array(mode.received.values.sorted { $0.index < $1.index }.prefix(24))
            if previousLabels != processorControls.map(\.label) {
                HardwareProxy.writeTiming("\(DispatchTime.now().uptimeNanoseconds) processor-labels-ready")
                refreshDeskLabels()
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(100))
                    self?.refreshDeskLabels()
                }
            }
            if previousPositions != processorControls.map(\.ringPosition) {
                refreshEncoderRings()
            }
            if !processorControls.isEmpty {
                processorStatus = "CH \(mode.channel) · \(mode.name) · Press again for next processor"
                if processorRefresh == nil || processorRefresh?.isCancelled == true {
                    processorRefresh = Task { [weak self] in
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .milliseconds(650))
                            guard !Task.isCancelled, let self, let current = self.processorMode else {return}
                            self.sendProcessorOSC("/strip/plugin/list", [.int(current.channel)])
                        }
                    }
                }
            }
        }
        return true
    }
}
