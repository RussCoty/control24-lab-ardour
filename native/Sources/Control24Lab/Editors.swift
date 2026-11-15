import Control24Core
import SwiftUI

struct ProfileEditor: View {
    @EnvironmentObject var store: LabStore
    @State private var draft=Profile.defaults[2]
    @State private var editing="ardour"
    @State private var mappingID="fader:0"
    @State private var path=""
    @State private var arguments="[]"
    @State private var status=""
    private var mappable: [Control] {store.catalog.controls.filter {["button","fader","encoder"].contains($0.kind)}}
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                VStack(alignment:.leading,spacing:7) {Eyebrow(text:"Native routing / destinations");Text("Profiles & mappings").font(.title2);Text("Saving or switching profiles disables OSC output.").font(.caption).foregroundStyle(.secondary)}
                Picker("Edit profile",selection:$editing) {ForEach(store.profiles) {Text($0.name).tag($0.id)}}
                if ["ardour","mixbus"].contains(editing) {
                    Button(editing=="ardour" ? "Load Ardour OSC preset into draft":"Load Mixbus OSC preset into draft") {
                        if let preset=Profile.defaults.first(where:{$0.id==editing}) {
                            draft.mappings.merge(preset.mappings) {_,new in new};status="Preset loaded into draft · save to persist"
                        }
                    }
                }
                Form {
                    TextField("Name",text:$draft.name)
                    TextField("Destination IPv4",text:$draft.host)
                    TextField("UDP port",value:$draft.port,format:.number.grouping(.never))
                    Picker("Adapter",selection:$draft.adapter) {Text("OSC · implemented").tag("osc");Text("HUI · planned").tag("hui");Text("MCU · planned").tag("mcu")}
                    Text(draft.status).font(.caption).foregroundStyle(.secondary)
                }.formStyle(.grouped)
                HStack {Text("Control mapping").font(.headline);Spacer();Text("\(draft.mappings.count) mappings").font(.caption).foregroundStyle(.secondary)}
                Picker("Control",selection:$mappingID) {ForEach(mappable) {Text($0.name).tag($0.id)}}
                TextField("OSC address, e.g. /strip/fader",text:$path).textFieldStyle(.roundedBorder)
                VStack(alignment:.leading,spacing:8) {Text("Arguments (JSON)").font(.caption);TextEditor(text:$arguments).font(.system(.body,design:.monospaced)).frame(minHeight:80).padding(5).overlay(RoundedRectangle(cornerRadius:5).stroke(.quaternary))}
                Text("$value = normalized fader/input. $position = encoder position. $delta = encoder detents. $toggle = requested on/off state. Desk profile selection uses Shift + Option + F1–F6, leaving normal function keys assignable.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Apply to draft") {applyMapping()}
                    Button("Remove mapping") {draft.mappings.removeValue(forKey:mappingID);loadMapping();status="Removed from draft · save to persist"}
                    Spacer()
                }
                Divider()
                HStack {
                    Button("Save profile & mappings") {
                        if path.isEmpty || applyMapping() {store.save(draft);status=store.error==nil ? "Saved locally · output disabled":"Check the error"}
                    }.buttonStyle(.borderedProminent)
                    Button("Activate profile") {store.switchProfile(draft.id)}
                    Text(status).font(.caption).foregroundStyle(Color.labAccent)
                }
            }.padding(24)
        }
        .onAppear {editing=store.activeID;loadProfile();if mappable.contains(where:{$0.id==store.selected}) {mappingID=store.selected;loadMapping()}}
        .onChange(of:editing) {_,_ in loadProfile()}
        .onChange(of:mappingID) {_,_ in loadMapping()}
        .onChange(of:store.profiles) {_,_ in loadProfile()}
    }
    private func loadProfile() {draft=store.profiles.first(where:{$0.id==editing}) ?? store.profile;status="";loadMapping()}
    private func loadMapping() {
        let m=draft.mappings[mappingID];path=m?.path ?? ""
        let encoder=JSONEncoder();encoder.outputFormatting = .prettyPrinted
        arguments=(try? String(decoding:encoder.encode(m?.args ?? []),as:UTF8.self)) ?? "[]"
    }
    @discardableResult private func applyMapping() -> Bool {
        do {
            let args=try JSONDecoder().decode([OSCValue].self,from:Data(arguments.utf8))
            _ = try OSC.encode(path:path,args:args.map {$0 == .string("$value") || $0 == .string("$toggle") ? .int(0):$0})
            draft.mappings[mappingID]=Mapping(path:path,args:args,trigger:draft.mappings[mappingID]?.trigger);status="Draft updated · save to persist";return true
        } catch {store.error=error.localizedDescription;return false}
    }
}

struct ActionChooser: View {
    @EnvironmentObject var store: LabStore
    @Environment(\.dismiss) private var dismiss
    @State private var search=""
    @State private var selection: String?
    private var actions: [ActionCatalog.Definition] {
        guard let c=store.control else {return []}
        return store.actionCatalog.actions.filter {a in
            a.profiles.contains(store.activeID) && a.kinds.contains(c.kind) && (!a.requires_channel || c.channel != nil)
            && (search.isEmpty || "\(a.title) \(a.group) \(a.mapping.path) \(a.mapping.args.map(\.display).joined(separator:" "))".localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {VStack(alignment:.leading,spacing:6) {Eyebrow(text:"Assign action · \(store.profile.name)");Text(store.control?.name ?? "Choose a control").font(.title2)};Spacer();Button("Cancel") {dismiss()}}
            TextField("Search transport, pan, automation, or action ID…",text:$search).textFieldStyle(.roundedBorder)
            List(selection:$selection) {
                ForEach(actions) {action in
                    VStack(alignment:.leading,spacing:5) {
                        HStack {Text(action.title).font(.system(size:13,weight:.medium));Spacer();Text(action.group).font(.caption2).foregroundStyle(.secondary)}
                        Text("\(action.mapping.path) \(action.mapping.args.map(\.display).joined(separator:" "))").font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)
                    }.padding(.vertical,5).tag(action.id)
                }
            }.listStyle(.inset).frame(minHeight:330)
            HStack {
                Text("\(actions.count) source-verified choices · saves to the active profile").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Assign action") {if let action=actions.first(where:{$0.id==selection}) {store.assign(action)}}
                    .buttonStyle(.borderedProminent).disabled(!actions.contains(where:{$0.id==selection}))
            }
        }.padding(24).frame(width:730,height:560)
        .onChange(of:store.selected) {_,_ in selection=nil}
    }
}

struct ProtocolWorkbench: View {
    @EnvironmentObject var store: LabStore
    @State private var hex="00 1a 00 00 00 00 00 01 00 00 00 00 00 00 00 03 90 10 5c 10 1c b0 00 40 20 00"
    @State private var port=9126
    var body: some View {
        VStack(spacing:0) {
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    VStack(alignment:.leading,spacing:7) {Eyebrow(text:"Protocol lab");Text("See what the desk is saying.").font(.title2);Text("EtherType 0x885F · raw Ethernet · original Control|24").font(.caption.monospaced()).foregroundStyle(.secondary)}
                    Text("Ethernet payload (hex, excluding MAC addresses and EtherType)").font(.caption)
                    TextEditor(text:$hex).font(.system(.body,design:.monospaced)).frame(height:135).padding(8).background(.black.opacity(0.2),in:RoundedRectangle(cornerRadius:6))
                    HStack {
                        Button("Decode & log offline") {store.decode(hex)}.buttonStyle(.borderedProminent)
                        Button("Import capture…") {store.importCapture()}
                    }
                    Text("Offline replay never transmits OSC. Native input decoding, LED/motor/display byte previews, and profile routing run directly in Swift. The optional Hardware helper provides experimental session ownership and keepalive. Physical feedback output still needs implementation and desk validation.").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Text("OSC feedback").font(.headline)
                    HStack {
                        TextField("UDP port",value:$port,format:.number.grouping(.never)).frame(width:95).textFieldStyle(.roundedBorder)
                        Button("Start listener") {store.startFeedback(port:port)}
                        Button("Stop") {store.stopFeedback()}
                        Text(store.feedbackStatus).font(.caption).foregroundStyle(Color.labAccent)
                    }
                    Text("The listener accepts the active profile’s source IPv4 address. Configure the DAW to return strip IDs 1–24 and positional fader values. UDP source IP filtering is not session authentication.").font(.caption).foregroundStyle(.secondary)
                    HStack {Button("Show application data",systemImage:"folder") {NSWorkspace.shared.open(store.directory)};Spacer();Text("Hardware offline").font(.caption).foregroundStyle(.secondary)}
                }.padding(24)
            }
            Divider()
            EventStream().frame(height:200)
        }
    }
}
