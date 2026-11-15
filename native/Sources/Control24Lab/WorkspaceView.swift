import Control24Core
import SwiftUI

extension Color {
    static let labAccent=Color(red:0.82,green:0.92,blue:0.54)
    static let labAmber=Color(red:0.94,green:0.70,blue:0.39)
    static let labPanel=Color(red:0.095,green:0.11,blue:0.10)
}

struct Eyebrow: View {
    var text: String
    var body: some View {Text(text.uppercased()).font(.system(size:9,weight:.semibold)).tracking(1.5).foregroundStyle(.secondary)}
}

struct RootView: View {
    @EnvironmentObject var store: LabStore
    @State private var showInspector=true
    var body: some View {
        NavigationSplitView {
            List(selection:$store.page) {
                Section("Workspace") {
                    ForEach(Workspace.allCases) {page in Label(page.rawValue,systemImage:page.icon).tag(page)}
                }
                Section("Destinations") {
                    ForEach(store.profiles) {profile in
                        Button {store.switchProfile(profile.id)} label: {
                            HStack {
                                Image(systemName:profile.id==store.activeID ? "circle.inset.filled":"circle").foregroundStyle(profile.id==store.activeID ? Color.labAccent:Color.secondary)
                                Text(profile.name).font(.system(size:12)).lineLimit(1)
                            }
                        }.buttonStyle(.plain).padding(.vertical,3)
                    }
                }
            }
            .navigationTitle("Control|24")
            .navigationSplitViewColumnWidth(min:175,ideal:205,max:250)
            .safeAreaInset(edge:.bottom) {
                VStack(alignment:.leading,spacing:7) {
                    Eyebrow(text:"Original Digidesign")
                    Text("Control|24 Lab · Swift 0.3").font(.caption)
                    Text("Simulation / offline replay").font(.caption2).foregroundStyle(Color.labAccent)
                }.frame(maxWidth:.infinity,alignment:.leading).padding(16)
            }
        } detail: {
            VStack(spacing:0) {
                destinationHeader
                Divider()
                switch store.page ?? .surface {
                case .surface:VSplitView {SurfaceWorkspace().frame(minHeight:430);EventStream().frame(minHeight:120,idealHeight:175,maxHeight:320)}
                case .inventory:InventoryView()
                case .profiles:ProfileEditor()
                case .protocolLab:ProtocolWorkbench()
                }
            }
            .background(Color(red:0.065,green:0.075,blue:0.07))
            .navigationTitle(store.page?.rawValue ?? "Surface")
        }
        .inspector(isPresented:$showInspector) {ControlInspector().environmentObject(store).inspectorColumnWidth(min:255,ideal:280,max:340)}
        .toolbar {
            ToolbarItemGroup(placement:.primaryAction) {
                Button(store.mappingMode ? "Learning mappings":"Learn mappings",systemImage:store.mappingMode ? "hand.tap.fill":"hand.tap") {store.toggleMappingMode()}
                    .tint(store.mappingMode ? Color.labAccent:Color.secondary)
                Button("Hardware",systemImage:"cable.connector") {store.hardwareSheetPresented=true}
                Label("Hardware offline",systemImage:"cable.connector.slash").font(.caption).foregroundStyle(.secondary)
                Button(store.armed ? "Disable OSC output":"Enable OSC output",systemImage:store.armed ? "stop.circle.fill":"paperplane") {store.toggleOutput()}
                    .tint(store.armed ? .labAmber:.labAccent).disabled(store.profile.adapter != "osc")
                Button("Inspector",systemImage:"sidebar.right") {showInspector.toggle()}
            }
        }
        .sheet(isPresented:$store.actionPickerPresented) {ActionChooser().environmentObject(store)}
        .sheet(isPresented:$store.hardwareSheetPresented) {HardwareSettings(proxy:store.hardwareProxy).environmentObject(store)}
        .tint(.labAccent)
        .alert("Control|24 Lab",isPresented:Binding(get:{store.error != nil},set:{if !$0 {store.error=nil}})) {
            Button("OK") {store.error=nil}
        } message: {Text(store.error ?? "")}
    }
    private var destinationHeader: some View {
        HStack(spacing:16) {
            Image(systemName:"arrow.triangle.branch").font(.title3).foregroundStyle(Color.labAccent)
            VStack(alignment:.leading,spacing:4) {Eyebrow(text:"Active profile");Text(store.profile.name).font(.headline)}
            Spacer()
            VStack(alignment:.trailing,spacing:4) {
                Text(store.destination).font(.system(.caption,design:.monospaced))
                Text("\(store.profile.adapter.uppercased()) · \(store.armed ? "OUTPUT ENABLED":"preview only")")
                    .font(.caption2).foregroundStyle(store.armed ? Color.labAmber:Color.secondary)
            }
            if ["ardour","mixbus"].contains(store.activeID) {
                Button("Connect DAW") {store.connectDAW()}.controlSize(.small).help("Request a 24-strip OSC surface and start feedback; output remains disabled")
            }
        }.padding(.horizontal,22).padding(.vertical,14)
    }
}

struct InventoryView: View {
    @EnvironmentObject var store: LabStore
    @State private var search=""
    @State private var kind="All types"
    private var rows: [Control] {store.catalog.controls.filter {
        (kind=="All types" || $0.kind==kind) && (search.isEmpty || "\($0.id) \($0.name) \($0.group)".localizedCaseInsensitiveContains(search))
    }}
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {VStack(alignment:.leading,spacing:6) {Eyebrow(text:"Research baseline");Text("Control inventory").font(.title2)};Spacer();Button("Export catalog…",systemImage:"square.and.arrow.up") {store.exportCatalog()}}
            Text("\(store.catalog.controls.count) research entries, including output addresses and analog candidates. Hardware verification is outstanding.").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Search control, address, or group",text:$search).textFieldStyle(.roundedBorder)
                Picker("Type",selection:$kind) {Text("All types").tag("All types");ForEach(Array(Set(store.catalog.controls.map(\.kind))).sorted(),id:\.self) {Text($0).tag($0)}}.frame(width:175)
                Text("\(rows.count)").monospacedDigit().foregroundStyle(.secondary)
            }
            Table(rows,selection:Binding<String?>(get:{store.selected},set:{if let id=$0 {store.selected=id}})) {
                TableColumn("Control",value:\.name).width(min:230,ideal:330)
                TableColumn("Type",value:\.kind).width(75)
                TableColumn("ID",value:\.id).width(min:100,ideal:135)
                TableColumn("Evidence",value:\.evidence).width(min:120,ideal:145)
            }
        }.padding(22)
    }
}

struct EventStream: View {
    @EnvironmentObject var store: LabStore
    @State private var filter="All events"
    @State private var frozen: [LabEvent]?
    var rows: [LabEvent] {(frozen ?? store.events).filter {filter=="All events" || $0.kind==filter}.suffix(150).reversed()}
    var body: some View {
        VStack(spacing:0) {
            HStack {
                Eyebrow(text:"Event stream");Text("\(store.events.last?.id ?? 0)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Picker("Filter",selection:$filter) {ForEach(["All events","route","feedback","unknown","frame"],id:\.self) {Text($0).tag($0)}}.labelsHidden().frame(width:125)
                Button(frozen==nil ? "Pause view":"Resume view") {frozen=frozen==nil ? store.events:nil}
                Button("Export…") {store.exportLog()}
            }.padding(.horizontal,18).padding(.vertical,9)
            Divider()
            ScrollView {
                LazyVStack(spacing:0) {
                    ForEach(rows) {e in
                        HStack(alignment:.top,spacing:12) {
                            Text(e.time,format:.dateTime.hour().minute().second()).foregroundStyle(.secondary).frame(width:64,alignment:.leading)
                            Text(e.kind.uppercased()).foregroundStyle(e.kind=="feedback" ? Color.labAmber:Color.labAccent).frame(width:82,alignment:.leading)
                            Text(store.controls[e.control]?.name ?? e.control).frame(maxWidth:.infinity,alignment:.leading).lineLimit(1)
                            Text(e.value).frame(width:130,alignment:.leading).lineLimit(1).help(e.value)
                            Text(e.source).foregroundStyle(.secondary).frame(width:135,alignment:.leading).lineLimit(1)
                        }.font(.system(size:10,design:.monospaced)).padding(.horizontal,18).padding(.vertical,8)
                        Divider().opacity(0.4)
                    }
                }
            }.overlay {if rows.isEmpty {Text("Press a button or move a fader to begin.").font(.caption).foregroundStyle(.secondary)}}
        }.background(Color.labPanel)
    }
}

struct ControlInspector: View {
    @EnvironmentObject var store: LabStore
    @State private var feedbackNumber=0.0
    @State private var display="CH01"
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                if let c=store.control {
                    VStack(alignment:.leading,spacing:9) {
                        Eyebrow(text:"Control inspector")
                        Text(c.name).font(.title3.weight(.medium)).fixedSize(horizontal:false,vertical:true)
                        Text(c.kind.uppercased()).font(.caption2.monospaced()).padding(.horizontal,7).padding(.vertical,4).background(Color.labAccent.opacity(0.14),in:RoundedRectangle(cornerRadius:4)).foregroundStyle(Color.labAccent)
                    }
                    Grid(alignment:.leading,horizontalSpacing:12,verticalSpacing:10) {
                        row("ID",c.id)
                        row("Evidence",c.evidence)
                        row("Hardware verified","No")
                        row("Placement",store.layoutByID[c.id]?.placement_status ?? (c.kind=="fader" ? "Projected fader track":c.kind=="touch" ? "Fader sensor":"Output / rear panel"))
                        if let input=c.input_status {row("Digital input",input)}
                        row("Pressed",store.pressed.contains(c.id) ? "Yes":"No")
                        row("Feedback LED",store.leds[c.id].map {$0 ? "On":"Off"} ?? "Unknown")
                        if let section=c.section,let note=c.note {row("Address",String(format:"sec %02x · note %02x",section,note))}
                    }.font(.caption)
                    Divider()
                    if ["button","touch","fader","encoder"].contains(c.kind) {
                        Button("Assign action…",systemImage:"arrow.triangle.branch") {store.actionPickerPresented=true}
                            .buttonStyle(.borderedProminent)
                        if c.kind=="button" || c.kind=="touch" {
                            Button("Learn hardware address") {store.awaitingHardwareBinding=c.id;store.mappingMode=true;store.armed=false}
                            if store.awaitingHardwareBinding==c.id {Text("Press this button on the connected desk. Its next hardware press will be associated with this physical control.").font(.caption).foregroundStyle(Color.labAccent)}
                        }
                    }
                    if let placement=store.layoutByID[c.id] {
                        Text("Manual p\(placement.manual.printed_page), figure \(placement.manual.figure). \(placement.notes ?? "Wire addresses still require live verification.")")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Divider()
                    VStack(alignment:.leading,spacing:10) {
                        Eyebrow(text:"Simulate input")
                        if ["button","touch"].contains(c.kind) {Button("Press & release",systemImage:"hand.tap") {store.pulse(c.id)}}
                        else if c.kind=="encoder" {
                            HStack {Button("−1 detent") {store.input(c.id,-1)};Button("+1 detent") {store.input(c.id,1)}}
                        } else if c.kind=="fader" {Text("Drag its cap on the photograph or use the channel slider.").font(.caption).foregroundStyle(.secondary)}
                        else if c.kind=="analog" {Text("Inventory candidate. Digital observability is not established.").font(.caption).foregroundStyle(.secondary)}
                        else {Text("Feedback / output control").font(.caption).foregroundStyle(.secondary)}
                    }
                    Divider()
                    VStack(alignment:.leading,spacing:10) {
                        Eyebrow(text:"Feedback / native encoding")
                        if c.led != nil {
                            Toggle("LED on",isOn:Binding(get:{feedbackNumber != 0},set:{feedbackNumber=$0 ? 1:0}))
                        } else if ["scribble","counter"].contains(c.kind) {
                            TextField(c.kind=="counter" ? "Eight digits":"Four characters",text:$display).textFieldStyle(.roundedBorder)
                        } else if ["fader","ring"].contains(c.kind) {
                            TextField("Value",value:$feedbackNumber,format:.number).textFieldStyle(.roundedBorder)
                        }
                        Button("Preview encoding & feedback") {store.preview(c,number:feedbackNumber,display:display)}
                            .disabled(c.led==nil && !["fader","ring","scribble","counter"].contains(c.kind))
                        if c.kind == "fader", let channel = c.channel {
                            Button("Send position to desk") {
                                store.hardwareProxy.moveFader(channel: channel - 1, value: Int(feedbackNumber.rounded()))
                            }
                            .disabled(!feedbackNumber.isFinite || !(0...16383).contains(feedbackNumber))
                        }
                        Text(store.nativePreview).font(.system(size:10,design:.monospaced)).textSelection(.enabled)
                            .padding(10).frame(maxWidth:.infinity,alignment:.leading).background(.black.opacity(0.25),in:RoundedRectangle(cornerRadius:6))
                    }
                    Divider()
                    VStack(alignment:.leading,spacing:10) {
                        Eyebrow(text:"Profile mapping")
                        Text(store.profile.mappings[c.id].map {"\($0.title.map {$0+"\n"} ?? "")\($0.path)\n\($0.args.map(\.display).joined(separator:", "))"} ?? "Unmapped · input is still logged")
                            .font(.caption.monospaced()).textSelection(.enabled)
                        Button("Edit mapping",systemImage:"arrow.up.right") {store.page = .profiles}
                    }
                    if let source=c.source,let url=URL(string:source) {Link("View protocol evidence ↗",destination:url).font(.caption)}
                }
            }.padding(20)
        }.background(Color.labPanel)
        .onChange(of:store.selected) {_,_ in
            feedbackNumber=store.values[store.selected] ?? ((store.leds[store.selected] ?? false) ? 1:0)
            display=store.control?.kind=="counter" ? "01020304":store.text[store.selected] ?? "CH01"
            store.nativePreview="No hardware command has been sent."
        }
    }
    @ViewBuilder private func row(_ key: String, _ value: String) -> some View {
        GridRow {Text(key).foregroundStyle(.secondary);Text(value).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.trailing)}
    }
}
