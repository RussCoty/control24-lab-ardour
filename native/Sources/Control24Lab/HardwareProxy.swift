import AppKit
import Combine
import Foundation
import Network
import SwiftUI
import ServiceManagement
@preconcurrency import XPC

@MainActor
final class HardwareProxy: ObservableObject {
    @Published var status="Receiver off"
    @Published var lastMAC=""
    @Published var running=false
    let token=UUID().uuidString
    let port: UInt16=9127
    fileprivate var localHelper: Process?
    private var listener: NWListener?
    private var connections: [NWConnection]=[]
    private var epoch=0
    private weak var activeConnection: NWConnection?

    private let service = SMAppService.daemon(plistName: "com.control24.bridge.plist")
    private var serviceConnection: xpc_connection_t?
    var isManaged: Bool { serviceConnection != nil }
    private var pendingManagedStart: (String, String)?

    func connectManaged(interface: String? = nil, mac: String? = nil, requestApproval: Bool = false) {
        guard serviceConnection == nil else { return }
        if service.status == .notRegistered || service.status == .notFound {
            do { try service.register() }
            catch {
                status = "Could not register the bridge: \(error.localizedDescription)"
                NSLog("%@", status)
                return
            }
        }
        if service.status == .requiresApproval {
            status = "Approve Control24 Lab in Login Items & Extensions, then click Connect again or reopen Lab."
            if requestApproval { SMAppService.openSystemSettingsLoginItems() }
            return
        }
        guard service.status == .enabled else {
            status = "macOS bridge service unavailable (status \(service.status.rawValue))."
            NSLog("%@", status)
            return
        }
        let defaults = UserDefaults.standard
        let device = interface ?? defaults.string(forKey: "hardwareInterface") ?? "en0"
        let address = mac ?? defaults.string(forKey: "hardwareMAC") ?? "00:a0:7e:a2:1c:76"
        start()
        pendingManagedStart = (device, address)
        if running { launchManagedBridge() }
    }

    private func launchManagedBridge() {
        guard let (device, address) = pendingManagedStart else { return }
        pendingManagedStart = nil
        let connection = xpc_connection_create_mach_service(
            "com.control24.bridge", nil, UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED)
        )
        serviceConnection = connection
        let currentEpoch = epoch
        xpc_connection_set_event_handler(connection) { [weak self] event in
            guard xpc_get_type(event) == XPC_TYPE_ERROR else { return }
            Task { @MainActor [weak self] in
                guard let self, self.epoch == currentEpoch else { return }
                self.stop()
                self.status = "Managed bridge disconnected. Click Connect to retry."
            }
        }
        xpc_connection_resume(connection)
        let request = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(request, "token", token)
        xpc_dictionary_set_string(request, "interface", device)
        xpc_dictionary_set_string(request, "mac", address)
        xpc_connection_send_message_with_reply(connection, request, nil) { [weak self] reply in
            guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY,
                  let error = xpc_dictionary_get_string(reply, "error") else { return }
            let message = String(cString: error)
            Task { @MainActor [weak self] in
                guard let self, self.epoch == currentEpoch else { return }
                self.stop()
                self.status = message
            }
        }
    }

    func moveFader(channel: Int, value: Int) {
        send(["channel": String(channel), "value": String(value)])
    }

    func labelPage(_ labels: [String]) {
        guard activeConnection != nil else { return }
        var request = ["channel": "0"]
        for (channel, label) in labels.enumerated() {
            request["label\(channel)"] = String(label.prefix(4))
        }
        send(request)
    }

    func processorLabelSender() -> (@Sendable ([String]) -> Void)? {
        guard let connection = activeConnection else { return nil }
        let token = self.token
        return { labels in
            var fields = ["channel": "0", "token": token]
            for (channel, label) in labels.enumerated() {
                fields["label\(channel)"] = String(label.prefix(4))
            }
            guard let data = try? JSONSerialization.data(withJSONObject: fields) else { return }
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    func labelChannel(_ channel: Int, name: String) {
        send(["channel": String(channel), "label": name])
    }

    func setEncoderRing(channel: Int, position: Int) {
        send(["channel": String(channel), "ring": String(position)])
    }

    func meterSender() -> (@Sendable (Int, Int, UInt64) -> Void)? {
        guard let connection = activeConnection else { return nil }
        let token = self.token
        return { channel, segments, arrival in
            let fields = ["channel": String(channel), "meter": String(segments), "token": token,
                          "arrival": String(arrival), "forward": String(DispatchTime.now().uptimeNanoseconds)]
            guard let data = try? JSONSerialization.data(withJSONObject: fields) else { return }
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    func showTimecode(_ digits: String) {
        guard activeConnection != nil else { return }
        send(["channel": "0", "timecode": digits])
    }

    func setButtonLED(section: Int, note: Int, on: Bool) {
        guard activeConnection != nil else { return }
        send(["channel": "0", "ledSection": String(section), "ledNote": String(note), "ledOn": on ? "1" : "0"])
    }

    private func send(_ request: [String: String]) {
        guard let activeConnection else {
            status = "Connect the desk in active mode first"
            return
        }
        let fields = request.merging(["token": token]) { _, token in token }
        guard let data = try? JSONSerialization.data(withJSONObject: fields) else {return}
        activeConnection.send(content: data, completion: .contentProcessed { _ in })
    }

    private nonisolated static let timingQueue = DispatchQueue(label: "com.control24.lab.timing")

    nonisolated static func writeTiming(_ line: String) {
        timingQueue.async {
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/Control24Timing.log")
            let data = Data((line + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private let handler: @MainActor ([String:String])->Void
    init(handler: @escaping @MainActor ([String:String])->Void) {self.handler=handler}
    func start() {
        guard !running else {return}
        stop();let epoch=self.epoch
        do {
            let parameters=NWParameters.udp
            parameters.requiredLocalEndpoint = .hostPort(host:.ipv4(.loopback),port:NWEndpoint.Port(rawValue:port)!)
            let listener=try NWListener(using:parameters)
            self.listener=listener;status="Starting local receiver…"
            listener.stateUpdateHandler={ [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self,self.epoch==epoch else {return}
                    switch state {
                    case .ready:self.running=true;self.status="Waiting for capture helper · 127.0.0.1:\(self.port)"
                        self.launchManagedBridge()
                    case .failed(let error):self.running=false;self.status=error.localizedDescription
                    default:break
                    }
                }
            }
            listener.newConnectionHandler={ [weak self] connection in
                Task { @MainActor [weak self] in
                    guard let self,self.epoch==epoch,case .hostPort(let host,_)=connection.endpoint,
                          String(describing:host)=="127.0.0.1" else {connection.cancel();return}
                    if self.connections.count>=16 {self.connections.removeFirst().cancel()}
                    self.connections.append(connection);connection.start(queue:.global(qos:.userInitiated))
                    let token = self.token
                    Self.receive(connection) { [weak self] data in
                        let arrival = DispatchTime.now().uptimeNanoseconds
                        guard var fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
                              fields["token"] == token else { return }
                        if let event = fields["timing"], let timestamp = fields["timestamp"] {
                            Self.writeTiming("\(timestamp) \(event) \(fields["payload"] ?? "")")
                            return
                        }
                        fields["arrival"] = String(arrival)
                        let message = fields
                        Task { @MainActor [weak self] in
                            guard let self, self.epoch == epoch else { return }
                            let fields = message
                            if fields["status"] == "online" { Self.writeTiming("bridge online") }
                            if let mac = fields["mac"], self.lastMAC != mac { self.lastMAC = mac }
                            if fields["status"] == "online" {self.activeConnection = connection}
                            if ["offline", "stopped"].contains(fields["status"] ?? ""), self.activeConnection === connection {
                                self.activeConnection = nil
                            }
                            if let state=fields["status"] {self.status="\(state) · \(fields["message"] ?? fields["mode"] ?? fields["interface"] ?? fields["mac"] ?? "")"}
                            self.handler(fields)
                        }
                    }
                }
            }
            listener.start(queue:.global(qos:.userInitiated))
        } catch {status=error.localizedDescription}
    }
    func stop() {
        epoch += 1
        if let serviceConnection { xpc_connection_cancel(serviceConnection) }
        serviceConnection = nil
        pendingManagedStart = nil
        if let localHelper, localHelper.isRunning {localHelper.terminate()}
        localHelper=nil
        activeConnection=nil
        listener?.cancel();listener=nil
        connections.forEach {$0.cancel()};connections=[];running=false;status="Receiver off"
    }
    nonisolated private static func receive(_ connection: NWConnection,handler: @escaping @Sendable (Data)->Void) {
        connection.receiveMessage {data,_,_,error in
            if let data {handler(data)}
            if error==nil {receive(connection,handler:handler)} else {connection.cancel()}
        }
    }
}

struct HardwareSettings: View {
    @EnvironmentObject var store: LabStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var proxy: HardwareProxy
    @AppStorage("hardwareInterface") private var interface="en0"
    @AppStorage("hardwareMAC") private var mac="00:a0:7e:a2:1c:76"
    @AppStorage("hardwareActive") private var active=true
    private var helper: URL? {
        let paths=[Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Control24Bridge"),
                   Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("Control24Bridge")]
        return paths.compactMap {$0}.first {FileManager.default.isExecutableFile(atPath:$0.path)}
    }
    private func quote(_ value: String) -> String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    private var command: String {
        guard let helper else {return "Build the native application to include Control24Bridge."}
        var command="sudo \(quote(helper.path)) --interface \(quote(interface)) --port \(proxy.port) --token \(quote(proxy.token))"
        if !mac.isEmpty {command+=" --mac \(quote(mac))"}
        if active {command+=" --active"}
        return command
    }
    private func connect() {
        proxy.connectManaged(interface: interface, mac: mac, requestApproval: true)
    }

    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {VStack(alignment:.leading,spacing:7) {Eyebrow(text:"Hardware bridge");Text("Connect the original Control|24").font(.title2)};Spacer();Button("Done") {dismiss()}}
            Text("The app stays unprivileged. A small native helper accesses only EtherType 0x885F and relays desk packets to this local receiver.").font(.callout).foregroundStyle(.secondary)
            HStack {TextField("Ethernet interface",text:$interface);TextField("Console MAC (optional for passive discovery)",text:$mac)}.textFieldStyle(.roundedBorder)
            Toggle("Own an active console session",isOn:$active)
            Text(active ? "Active mode requires the console MAC. It sends handshake/keepalive and echoes the desk’s own fader movement. Use one active surface owner at a time.":"Passive mode sends no Ethernet commands. It can discover announcements or observe a working session; an offline desk may not send button events.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Connect to Control|24") {connect()}
                    .disabled(helper == nil || interface.isEmpty || (active && mac.isEmpty))
                Button("Stop receiver") {proxy.stop()}
                Text(proxy.status).font(.caption).foregroundStyle(Color.labAccent)
            }
            Text("Connect starts the helper and asks for macOS approval when needed. The command below is available for manual troubleshooting.").font(.caption)
            Text(command).font(.system(size:11,design:.monospaced)).textSelection(.enabled).padding(12).frame(maxWidth:.infinity,alignment:.leading).background(.black.opacity(0.25),in:RoundedRectangle(cornerRadius:6))
            HStack {
                Button("Copy helper command") {NSPasteboard.general.clearContents();NSPasteboard.general.setString(command,forType:.string)}
                    .disabled(helper==nil || interface.isEmpty || (active && mac.isEmpty))
                if !proxy.lastMAC.isEmpty {Text("Detected: \(proxy.lastMAC)").font(.caption.monospaced())}
            }
            Divider()
            Text("For assignment: enable Learn mappings, press a button on the desk (or click its on-screen counterpart), then choose an action. If the source-reported wire address differs, select the physical button and use Learn hardware address.").font(.callout)
        }.padding(24).frame(width:720)
        .onChange(of:proxy.lastMAC) {_,value in if mac.isEmpty {mac=value}}
    }
}
