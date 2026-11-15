import Control24Core
import SwiftUI

struct SurfaceRegion: Identifiable {
    var id: String
    var points: [Point]
    var channel: Int?
    var encoder=false
}

struct ProjectedRegion: Shape {
    var points: [Point]
    func path(in rect: CGRect) -> Path {
        Path {path in
            guard let first=points.first else {return}
            path.move(to:CGPoint(x:first.x*rect.width/1000,y:first.y*rect.height/527))
            for p in points.dropFirst() {path.addLine(to:CGPoint(x:p.x*rect.width/1000,y:p.y*rect.height/527))}
            path.closeSubpath()
        }
    }
}

struct SurfaceWorkspace: View {
    @EnvironmentObject var store: LabStore
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                HStack {
                    VStack(alignment:.leading,spacing:6) {Eyebrow(text:"Original Control|24 · seated view");Text("Surface monitor").font(.title2.weight(.medium))}
                    Spacer()
                    Toggle("Hotspots",isOn:$store.showHotspots).toggleStyle(.switch).controlSize(.small)
                }
                if let status = store.processorStatus {
                    HStack {
                        Text(status).font(.callout)
                        Spacer()
                        Button("Return to Pan") { store.closeProcessorMode() }
                    }
                    if !store.processorControls.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 125))], alignment: .leading) {
                            ForEach(Array(store.processorControls.enumerated()), id: \.element.id) { index, parameter in
                                VStack(alignment: .leading) {
                                    Text("\(index + 1). \(parameter.label)").lineLimit(1).help(parameter.label)
                                    HStack {
                                        Button("−") { store.input("encoder:\(index)", -1) }
                                        Text(String(format: "%g", parameter.value)).monospacedDigit()
                                        Button("+") { store.input("encoder:\(index)", 1) }
                                    }
                                }.font(.caption)
                            }
                        }
                    }
                }
                PhotographSurface()
                    .background(RadialGradient(colors:[Color(red:0.20,green:0.24,blue:0.18),Color.labPanel],center:.center,startRadius:0,endRadius:600),in:RoundedRectangle(cornerRadius:8))
                    .overlay(RoundedRectangle(cornerRadius:8).stroke(.white.opacity(0.08)))
                HStack(spacing:14) {
                    Label("Press / touch",systemImage:"circle.fill").foregroundStyle(Color.labAccent)
                    Label("Feedback",systemImage:"circle.fill").foregroundStyle(Color.labAmber)
                    Spacer()
                    Text("Drag faders · click buttons · select an encoder").foregroundStyle(.secondary)
                }.font(.system(size:10))
                channelFocus
                Divider()
                HStack {
                    Eyebrow(text:"Profile keys")
                    ForEach(Array(store.profiles.enumerated()),id:\.element.id) {index,profile in
                        Button("\(index+1)") {store.switchProfile(profile.id)}
                            .help(profile.name).tint(profile.id==store.activeID ? Color.labAccent:Color.secondary)
                    }
                    Spacer()
                    Text("Desk: Shift + Option + F1–F6").font(.caption2).foregroundStyle(.secondary)
                }
                Text("Panel geometry is projected to match the photograph; positions remain a prototype calibration. The source image’s illumination is static. Hardware is not connected.")
                    .font(.system(size:10)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }.padding(22)
        }
    }
    private var channelFocus: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Eyebrow(text:"Channel focus")
                Picker("Channel",selection:Binding(get:{store.channel},set:{store.selected="fader:\($0)"})) {
                    ForEach(0..<24,id:\.self) {Text(String(format:"Channel %02d",$0+1)).tag($0)}
                }.labelsHidden().frame(width:135)
                Spacer()
                Text("\(Int(store.values["fader:\(store.channel)"] ?? 0)) / 16383").font(.caption.monospacedDigit()).foregroundStyle(Color.labAccent)
            }
            Slider(value:Binding(get:{store.values["fader:\(store.channel)"] ?? 0},set:{store.input("fader:\(store.channel)",$0.rounded())}),in:0...16383) {Text("Channel fader")} onEditingChanged: {editing in store.input("button:\(store.channel):9",editing ? 1:0)}
                .accessibilityLabel("Channel \(store.channel+1) motor fader")
            if let level=store.values["meter:\(store.channel)"] {
                ProgressView(value:level) {
                    Text("Channel meter")
                } currentValueLabel: {
                    Text(level == 0 ? "−∞ dBFS" : String(format:"%.1f dBFS",level*100-94))
                        .monospacedDigit()
                }
                .tint(Color.labAccent)
            }

            HStack(spacing:7) {
                ForEach([(6,"Select"),(2,"EQ"),(3,"DYN"),(1,"Pan"),(7,"Solo"),(8,"Mute"),(0,"Record"),(9,"Touch")],id:\.0) {note,label in
                    Button(label) {store.pulse("button:\(store.channel):\(note)")}
                        .tint(store.pressed.contains("button:\(store.channel):\(note)") ? Color.labAccent:Color.secondary)
                }
                Spacer()
                Button("Encoder −") {store.input("encoder:\(store.channel)",-1)}
                Button("Encoder +") {store.input("encoder:\(store.channel)",1)}
            }.controlSize(.small)
        }.padding(15).background(.white.opacity(0.025),in:RoundedRectangle(cornerRadius:7))
    }
}

struct PhotographSurface: View {
    @EnvironmentObject var store: LabStore
    private var geometry: SurfaceGeometry {store.geometry}
    private var regions: [SurfaceRegion] {
        var result=store.layout.regions.map {r in
            SurfaceRegion(id:r.id,points:r.outline(geometry:geometry),encoder:store.controls[r.id]?.kind=="encoder")
        }
        for ch in 0..<24 {
            let u=geometry.fader(channel:ch,value:0).x
            let v=(geometry.faders.topV+geometry.faders.bottomV)/2
            let height=(geometry.faders.bottomV-geometry.faders.topV)*geometry.lower.height+14
            result.append(SurfaceRegion(id:"fader:\(ch)",points:geometry.lower.outline(u:u,v:v,width:17,height:height),channel:ch))
        }
        return result
    }
    var body: some View {
        GeometryReader {proxy in
            ZStack(alignment:.topLeading) {
                Image(nsImage:store.photograph).resizable().aspectRatio(contentMode:.fit).brightness(-0.07).saturation(0.8)
                Canvas {context,size in draw(&context,size:size)}.allowsHitTesting(false)
                ForEach(regions) {region in
                    SurfaceHitTarget(region:region,size:proxy.size)
                }
            }.frame(width:proxy.size.width,height:proxy.size.height,alignment:.topLeading)
        }.aspectRatio(1000.0/527,contentMode:.fit)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        context.scaleBy(x:size.width/1000,y:size.height/527)
        func path(_ points: [Point]) -> Path {Path {p in if let first=points.first {p.move(to:CGPoint(x:first.x,y:first.y));for point in points.dropFirst() {p.addLine(to:CGPoint(x:point.x,y:point.y))};p.closeSubpath()}}}
        for ch in 0..<24 {
            let uv=geometry.fader(channel:ch,value:store.values["fader:\(ch)"] ?? 0)
            let middle=(geometry.faders.topV+geometry.faders.bottomV)/2
            let height=(geometry.faders.bottomV-geometry.faders.topV)*geometry.lower.height+14
            let lane=path(geometry.lower.outline(u:uv.x,v:middle,width:11,height:height))
            context.fill(lane,with:.color(Color(red:0.49,green:0.50,blue:0.45)))
            let top=geometry.lower.project(uv.x,geometry.faders.topV),bottom=geometry.lower.project(uv.x,geometry.faders.bottomV)
            var slit=Path();slit.move(to:CGPoint(x:top.x,y:top.y));slit.addLine(to:CGPoint(x:bottom.x,y:bottom.y))
            context.stroke(slit,with:.color(.black.opacity(0.8)),lineWidth:1.5)
            let cap=path(geometry.lower.outline(u:uv.x,v:uv.y,width:11,height:12))
            context.fill(cap,with:.linearGradient(Gradient(colors:[.white.opacity(0.9),Color(red:0.49,green:0.55,blue:0.46),.white.opacity(0.75)]),startPoint:CGPoint(x:0,y:geometry.lower.project(uv.x,uv.y-0.02).y),endPoint:CGPoint(x:0,y:geometry.lower.project(uv.x,uv.y+0.02).y)))
            context.stroke(cap,with:.color(.white.opacity(0.6)),lineWidth:0.6)
            // Neutralize photographed text; draw native text into the upper panel's coordinate basis.
            let x=181+20.4*Double(ch),center=geometry.upper.inverse(Point(x,192))
            let mask=path(geometry.upper.outline(u:center.x,v:center.y,width:18,height:10))
            context.fill(mask,with:.color(Color(red:0.10,green:0.12,blue:0.08)))
            let processor = store.processorControls.indices.contains(ch) ? store.processorControls[ch] : nil
            let label = store.processorStatus == nil
                ? store.text["scribble:\(ch)"] ?? "----"
                : String(processor?.label.prefix(4) ?? "")
            drawPanelText(label,center:Point(x,192),panel:geometry.upper,fontSize:6.5,color:.labAmber,context:context)
            let knob=geometry.upper.inverse(Point(x,207))
            let ring=path(geometry.upper.outline(u:knob.x,v:knob.y,width:18,height:18,round:true))
            if let position = store.processorStatus == nil ? store.values["ring:\(ch)"] : processor.map({$0.position * 14}) {
                context.stroke(ring.trimmedPath(from:0,to:(position+1)/15),with:.color(.labAmber),lineWidth:1.8)
            }
            if let position = store.processorStatus == nil ? store.values["encoder:\(ch)"] : processor?.position {
                let angle=(-135+270*position)*Double.pi/180
                let endpoint=geometry.upper.project(knob.x+sin(angle)*6/geometry.upper.width,knob.y-cos(angle)*6/geometry.upper.height)
                var needle=Path();needle.move(to:CGPoint(x:x,y:207));needle.addLine(to:CGPoint(x:endpoint.x,y:endpoint.y))
                context.stroke(needle,with:.color(.labAccent),lineWidth:1)
            }
        }
        let counterCenter=geometry.upper.inverse(Point(799,54))
        context.fill(path(geometry.upper.outline(u:counterCenter.x,v:counterCenter.y,width:94,height:19)),with:.color(Color(red:0.05,green:0.12,blue:0.06)))
        drawPanelText(store.text["counter"] ?? "--------",center:Point(799,54),panel:geometry.upper,fontSize:15,color:.green,context:context)
        for region in regions {
            let selected=store.selected==region.id,down=store.pressed.contains(region.id)
            if store.showHotspots || selected || down {
                context.fill(path(region.points),with:.color(Color.labAccent.opacity(down ? 0.6:selected ? 0.13:0.025)))
                context.stroke(path(region.points),with:.color(Color.labAccent.opacity(selected || down ? 0.9:0.28)),lineWidth:selected ? 1:0.5)
            }
            if let on=store.leds[region.id],on {
                let center=region.points.reduce(Point(0,0)) {Point($0.x+$1.x/Double(region.points.count),$0.y+$1.y/Double(region.points.count))}
                let panel=center.y<247 ? geometry.upper:geometry.lower,uv=panel.inverse(center)
                context.fill(path(panel.outline(u:uv.x,v:uv.y,width:4,height:4,round:true)),with:.color(.labAmber))
            }
        }
    }
    private func drawPanelText(_ value: String,center: Point,panel: Panel,fontSize: Double,color: Color,context: GraphicsContext) {
        let uv=panel.inverse(center),origin=panel.project(uv.x,uv.y)
        let right=panel.project(uv.x+1/panel.width,uv.y),down=panel.project(uv.x,uv.y+1/panel.height)
        var ctx=context
        ctx.concatenate(CGAffineTransform(a:right.x-origin.x,b:right.y-origin.y,c:down.x-origin.x,d:down.y-origin.y,tx:origin.x,ty:origin.y))
        ctx.draw(Text(value).font(.system(size:fontSize,weight:.medium,design:.monospaced)).foregroundStyle(color),at:.zero,anchor:.center)
    }
}

struct SurfaceHitTarget: View {
    @EnvironmentObject var store: LabStore
    var region: SurfaceRegion
    var size: CGSize
    @State private var held=false
    private var bounds: CGRect {
        let xs=region.points.map(\.x),ys=region.points.map(\.y)
        return CGRect(x:xs.min() ?? 0,y:ys.min() ?? 0,width:(xs.max() ?? 1)-(xs.min() ?? 0),height:(ys.max() ?? 1)-(ys.min() ?? 0))
    }
    private var localPoints: [Point] {
        let b=bounds
        return region.points.map {Point(($0.x-b.minX)/b.width*1000,($0.y-b.minY)/b.height*527)}
    }
    var body: some View {
        ProjectedRegion(points:localPoints).fill(.white.opacity(0.001))
            .contentShape(ProjectedRegion(points:localPoints))
            .gesture(DragGesture(minimumDistance:0).onChanged {gesture in
                if !held {store.pickControl(region.id)}
                if let ch=region.channel {
                    if !held {held=true;store.input("button:\(ch):9",1)}
                    let p=Point(bounds.minX+gesture.location.x*1000/size.width,bounds.minY+gesture.location.y*527/size.height)
                    store.input(region.id,store.geometry.faderValue(at:p))
                } else if !held {
                    held=true
                    if region.encoder {return}
                    if store.controls[region.id]?.kind=="button" {store.input(region.id,1)}
                }
            }.onEnded {_ in release()})
            .onDisappear {release()}
            .accessibilityElement(children:.ignore)
            .accessibilityLabel(store.controls[region.id]?.name ?? region.id)
            .accessibilityValue(region.channel != nil ? String(Int(store.values[region.id] ?? 0)):store.pressed.contains(region.id) ? "Pressed":"Released")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {if store.controls[region.id]?.kind=="button" {store.pulse(region.id)} else {store.pickControl(region.id)}}
            .accessibilityAdjustableAction {direction in
                if region.channel != nil {store.input(region.id,max(0,min(16383,(store.values[region.id] ?? 0)+(direction == .increment ? 128:-128))))}
                else if region.encoder {store.input(region.id,direction == .increment ? 1:-1)}
            }
            .help(store.controls[region.id]?.name ?? region.id)
            .frame(width:bounds.width*size.width/1000,height:bounds.height*size.height/527)
            .offset(x:bounds.minX*size.width/1000,y:bounds.minY*size.height/527)
    }
    private func release() {
        guard held else {return};held=false
        if let ch=region.channel {store.input("button:\(ch):9",0)}
        else if !region.encoder && store.controls[region.id]?.kind=="button" {store.input(region.id,0)}
    }
}
