import Foundation

public struct Catalog: Decodable, Sendable {
    public var model: String
    public var revision: String
    public var controls: [Control]
}
public struct Control: Decodable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var kind: String
    public var group: String
    public var evidence: String
    public var section: Int?
    public var note: Int?
    public var channel: Int?
    public var source: String?
    public var led: LED?
    public var input_status: String?
    public struct LED: Decodable, Hashable, Sendable {
        public var section: Int
        public var note: Int
        public var label: String
    }
}
public enum OSCValue: Codable, Equatable, Sendable {
    case int(Int32), float(Float), string(String)
    public init(from decoder: Decoder) throws {
        let c=try decoder.singleValueContainer()
        if let v=try? c.decode(Int32.self) {self = .int(v)}
        else if let v=try? c.decode(Float.self) {self = .float(v)}
        else {self = .string(try c.decode(String.self))}
    }
    public func encode(to encoder: Encoder) throws {
        var c=encoder.singleValueContainer()
        switch self {case .int(let v):try c.encode(v);case .float(let v):try c.encode(v);case .string(let v):try c.encode(v)}
    }
    public var display: String {
        switch self {case .int(let v):String(v);case .float(let v):String(v);case .string(let v):v}
    }
    public var number: Double? {
        switch self {case .int(let v):return Double(v);case .float(let v):return Double(v);case .string:return nil}
    }
}
public struct Mapping: Codable, Equatable, Sendable {
    public var path: String
    public var args: [OSCValue]
    public var trigger: String?
    public var title: String?
    public init(path: String, args: [OSCValue], trigger: String? = nil, title: String? = nil) {
        self.path=path;self.args=args;self.trigger=trigger;self.title=title
    }
}
public struct ControlLayout: Decodable, Sendable {
    public var model: String
    public var manual_revision: String
    public var regions: [Region]
    public var coverage: Coverage
    public struct Coverage: Decodable, Sendable {
        public var physical_regions: Int
        public var buttons: Int
        public var buttons_placed: Int
        public var buttons_missing: [String]
    }
    public struct Region: Decodable, Identifiable, Sendable {
        public var id: String
        public var plane: String
        public var u: Double
        public var v: Double
        public var width: Double
        public var height: Double
        public var shape: String
        public var label: String
        public var placement_status: String
        public var wire_status: String
        public var notes: String?
        public var manual: Manual
        public struct Manual: Decodable, Sendable {
            public var pdf_page: Int
            public var printed_page: Int
            public var figure: Int
            public var source: String
        }
        public func outline(geometry: SurfaceGeometry) -> [Point] {
            let panel=plane=="upper" ? geometry.upper:geometry.lower
            return panel.outline(u:u,v:v,width:width*panel.width,height:height*panel.height,round:shape=="circle")
        }
        public func center(geometry: SurfaceGeometry) -> Point {
            (plane=="upper" ? geometry.upper:geometry.lower).project(u,v)
        }
    }
}
public struct ActionCatalog: Decodable, Sendable {
    public var target: String
    public var checkout: String
    public var base_revision: String
    public var actions: [Definition]
    public struct Definition: Decodable, Identifiable, Sendable {
        public var id: String
        public var title: String
        public var group: String
        public var mapping: Mapping
        public var kinds: [String]
        public var profiles: [String]
        public var requires_channel: Bool
        public var source: String
        public func resolved(for control: Control) throws -> Mapping {
            var result=mapping;result.title=title
            result.args=try mapping.args.map {arg in
                if arg == .string("$channel") {
                    guard let channel=control.channel else {throw LabError.invalid("Choose a channel control for this action.")}
                    return .int(Int32(channel))
                }
                return arg
            }
            return result
        }
    }
}
public struct Profile: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var adapter: String
    public var host: String
    public var port: Int
    public var mappings: [String: Mapping]
    public var status: String

    public static var defaults: [Profile] {
        let specs=[("pt-local","Pro Tools · local","hui",0),("pt-remote","Pro Tools · network","hui",0),
                   ("ardour","Ardour","osc",3819),("mixbus","Mixbus","osc",3819),
                   ("resolve","DaVinci Resolve","mcu",0),("lighting","Lighting · OSC","osc",9000)]
        return specs.map { id,name,adapter,port in
            var mappings: [String:Mapping]=[:]
            if id == "ardour" || id == "mixbus" {
                for ch in 0..<24 {
                    mappings["fader:\(ch)"]=Mapping(path:"/strip/fader",args:[.int(Int32(ch+1)),.string("$value")])
                    mappings["encoder:\(ch)"]=Mapping(path:"/strip/pan_stereo_position",args:[.int(Int32(ch+1)),.string("$position")])
                    mappings["button:\(ch):9"]=Mapping(path:"/strip/fader/touch",args:[.int(Int32(ch+1)),.string("$value")],trigger:"both")
                    mappings["button:\(ch):6"]=Mapping(path:"/strip/select",args:[.int(Int32(ch+1)),.int(1)])
                    for (note,path) in [(7,"solo"),(8,"mute"),(0,"recenable")] {
                        mappings["button:\(ch):\(note)"]=Mapping(path:"/strip/\(path)",args:[.int(Int32(ch+1)),.string("$toggle")])
                    }
                }
                for (note,path) in [(16,"/transport_play"),(15,"/transport_stop"),(17,"/rec_enable_toggle")] {
                    mappings["button:28:\(note)"]=Mapping(path:path,args:[])
                }
                for (id,path) in [("button:28:13","/rewind"),("button:28:14","/ffwd"),("button:28:5","/goto_start"),
                                  ("button:28:6","/goto_end"),("button:28:9","/loop_toggle"),("button:27:10","/bank_down"),
                                  ("button:27:12","/bank_up"),("button:27:21","/save_state")] {
                    mappings[id]=Mapping(path:path,args:[])
                }
                for (note,mode) in [(18,2),(19,3)] {
                    mappings["button:28:\(note)"]=Mapping(path:"/jog/mode",args:[.string("$float:\(mode)")])
                }
                mappings["jog"]=Mapping(path:"/jog",args:[.string("$delta")])
                for (note,mode) in [(33,0),(31,1),(23,2),(25,3),(27,4)] {
                    mappings["button:24:\(note)"]=Mapping(path:"/select/fader/automation",args:[.int(Int32(mode))])
                }
                mappings["button:27:20"]=Mapping(path:"/undo",args:[])
                for (note,path) in [(2,"/toggle_punch_in"),(3,"/toggle_punch_out")] {
                    mappings["button:28:\(note)"]=Mapping(path:path,args:[])
                }
                let editActions = [
                    (4,"Editing/editor-cut"), (5,"Editing/editor-copy"),
                    (6,"Editing/editor-paste"), (7,"Editing/editor-delete"),
                    (8,"Editor/split-region"), (28,"Region/duplicate-region"),
                    (14,"Editing/set-mouse-mode-range"), (15,"Editing/set-mouse-mode-object"),
                    (16,"Editing/set-mouse-mode-draw"), (18,"Editor/set-mouse-mode-object-range"),
                ]
                for (note,action) in editActions {
                    mappings["button:27:\(note)"]=Mapping(path:"/access_action",args:[.string(action)])
                }
                if id=="ardour" {
                    let surfaceActions = [
                        ("button:25:0","Common/show-mixer"),
                        ("button:25:1","Common/show-editor"),
                        ("button:25:7","Window/toggle-locations"),
                        ("button:25:6","ProcessorMenu/edit"),
                        ("button:24:5","ProcessorMenu/edit"),
                        ("button:29:2","ProcessorMenu/ab_plugins"),
                        ("button:24:19","Editor/toggle-all-existing-automation"),
                        ("button:25:8","Editor/zoom-to-session"),
                        ("button:25:9","Editor/zoom-to-selection"),
                        ("button:25:10","Editor/zoom-to-extents"),
                        ("button:25:2","Transport/focus-on-clock"),
                        ("button:25:5","Editor/show-editor-mixer"),
                        ("button:25:11","Editor/toggle-zoom"),
                        ("button:25:20","Editor/zoom-to-selection-horiz"),
                        ("button:25:13","Editor/toggle-zoom"),
                        ("button:25:14","Editor/select-from-regions"),
                        ("button:25:16","Editing/temporal-zoom-out"),
                        ("button:25:17","Editing/temporal-zoom-in"),
                        ("button:26:16","Transport/numpad-decimal"),
                        ("button:27:0","Editor/cycle-edit-mode"),
                        ("button:27:17","Window/toggle-virtual-keyboard"),
                        ("button:27:19","Common/ToggleMaximalMixer"),
                        ("button:27:22","Window/toggle-session-options-editor"),
                        ("button:27:23","Editor/group-selected-regions"),
                        ("button:27:26","Editor/ungroup-selected-regions"),
                        ("button:29:4","ProcessorMenu/edit-generic"),
                        ("button:29:5","Window/toggle-midi-connection-manager"),
                        ("button:28:0","Transport/PlaySelection"),
                        ("button:28:7","Transport/ToggleExternalSync"),
                        ("button:27:32","MIDI/panic"),
                        ("button:25:15","Editor/select-prev-route"),
                        ("button:25:18","Editor/select-next-route"),
                        ("button:26:14","Editor/nudge-backward"),
                        ("button:26:15","Editor/nudge-forward"),
                        ("button:27:3","Editing/cycle-snap-mode"),
                    ]
                    for (control,action) in surfaceActions {
                        mappings[control]=Mapping(path:"/access_action",args:[.string(action)])
                    }
                    mappings["button:24:20"]=Mapping(path:"/access_action",args:[.string("Main/cancel-solo")])
                    mappings["button:24:15"] = Mapping(path: "/select/record_safe", args: [.string("$toggle")])
                    mappings["button:24:46"] = Mapping(path: "/select/solo_safe", args: [.string("$toggle")])
                    mappings["button:27:9"] = Mapping(path: "/add_marker", args: [])
                    mappings["button:24:1"]=Mapping(path:"/rec_enable_toggle",args:[])

                }
            }
            return Profile(id:id,name:name,adapter:adapter,host:"127.0.0.1",port:port,mappings:mappings,
                           status: id == "ardour" || id == "mixbus" ? "OSC implemented · DAW verification pending" : id == "lighting" ? "Venue command map needed" : "Adapter planned")
        }
    }
}
public struct LabEvent: Codable, Identifiable, Sendable {
    public var id: Int
    public var time: Date
    public var kind: String
    public var control: String
    public var value: String
    public var source: String
    public var profile: String
    public var target: String
    public var generation: Int
    public init(id: Int,time: Date,kind: String,control: String,value: String,source: String,
                profile: String,target: String,generation: Int) {
        self.id=id;self.time=time;self.kind=kind;self.control=control;self.value=value
        self.source=source;self.profile=profile;self.target=target;self.generation=generation
    }
}
public enum LabError: LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? {if case .invalid(let message)=self{return message};return nil}
}
