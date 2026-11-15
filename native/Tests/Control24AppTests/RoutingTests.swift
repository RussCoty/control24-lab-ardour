import Control24Core
import Darwin
import Foundation
import Testing
@testable import Control24Lab

@Suite @MainActor
struct RoutingTests {
    func model() throws -> LabStore {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("control24-swift-tests-\(UUID())")
        return try LabStore(directory:url)
    }

    @Test func bundledCatalogLoadsAndStartsDisarmed() throws {
        let store=try model()
        defer {try? FileManager.default.removeItem(at:store.directory)}
        #expect(store.catalog.controls.count==681)
        #expect(store.controls.count==681)
        #expect(!store.armed)
        #expect(store.geometry.imageWidth==1000)
    }
    @Test func buttonAndFeedbackAreIndependent() throws {
        let store=try model();defer {try? FileManager.default.removeItem(at:store.directory)}
        store.input("button:0:8",1)
        #expect(store.pressed.contains("button:0:8"))
        #expect(store.leds["button:0:8"]==nil)
        let routes=store.events.filter {$0.kind=="route"}.count
        store.feedback("button:0:8",value:1)
        #expect(store.leds["button:0:8"]==true)
        #expect(store.events.filter {$0.kind=="route"}.count==routes)
    }
    @Test func manualLayoutCoversEveryButton() throws {
        let store=try model();defer {try? FileManager.default.removeItem(at:store.directory)}
        let placed=Set(store.layout.regions.map(\.id))
        #expect(placed.count==store.layout.regions.count)
        #expect(store.catalog.controls.filter {$0.kind=="button"}.allSatisfy {placed.contains($0.id)})
        #expect(!placed.contains("button:16:11"))
        let f1=try #require(store.layout.regions.first {$0.id=="button:24:0"})
        let f2=try #require(store.layout.regions.first {$0.id=="button:24:2"})
        #expect(f1.u==f2.u);#expect(f2.v>f1.v)
    }
    @Test func developmentActionsCanBeAssignedAndFunctionKeysRemainAvailable() throws {
        let store=try model();defer {try? FileManager.default.removeItem(at:store.directory)}
        store.switchProfile("ardour")
        store.input("button:24:6",1)
        #expect(store.activeID=="ardour")
        #expect(store.events.contains {$0.kind=="route" && $0.value.contains("quantize-warp-markers")})
        store.input("button:24:6",0)
        store.toggleMappingMode();store.pickControl("button:24:0")
        #expect(store.actionPickerPresented);#expect(!store.armed)
        let action=try #require(store.actionCatalog.actions.first {$0.id=="action:Region/edit-region-pitch"})
        store.assign(action)
        #expect(store.profile.mappings["button:24:0"]?.args==[.string("Region/edit-region-pitch")])
        #expect(!store.armed)
        let restored=try LabStore(directory:store.directory)
        #expect(restored.profile.mappings["button:24:0"]?.args==[.string("Region/edit-region-pitch")])
        #expect(!action.profiles.contains("mixbus"))
    }
    @Test func touchDefersTargetPositionUntilRelease() throws {
        let store=try model();defer {try? FileManager.default.removeItem(at:store.directory)}
        store.input("button:0:9",1);store.input("fader:0",4000)
        store.feedback("fader:0",value:8000)
        #expect(store.values["fader:0"]==4000)
        store.input("button:0:9",0)
        #expect(store.values["fader:0"]==8000)
    }
    @Test func profileSwitchClearsOldStateAndDisablesOutput() throws {
        let store=try model();defer {try? FileManager.default.removeItem(at:store.directory)}
        store.toggleOutput();#expect(store.armed)
        store.input("button:0:9",1);store.feedback("fader:0",value:8000)
        store.input("button:24:35",1);store.input("button:24:36",1)
        store.input("button:24:6",1)
        #expect(store.activeID=="mixbus");#expect(!store.armed)
        store.input("button:0:9",0)
        #expect(store.values["fader:0"]==nil)
    }
    @Test func nativeSettingsPersistWithoutArming() throws {
        let store=try model();defer {try? FileManager.default.removeItem(at:store.directory)}
        var p=store.profile;p.name="Studio B";p.host="192.0.2.42";store.save(p)
        store.toggleOutput()
        let restored=try LabStore(directory:store.directory)
        #expect(restored.profile.name=="Studio B")
        #expect(restored.profile.host=="192.0.2.42")
        #expect(!restored.armed)
    }
    @Test func realUDPLoopbackAndReplayIsolation() throws {
        let store=try model();defer {try? FileManager.default.removeItem(at:store.directory)}
        let fd=Darwin.socket(AF_INET,SOCK_DGRAM,0)
        #expect(fd>=0);defer {Darwin.close(fd)}
        var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family=sa_family_t(AF_INET);address.sin_addr.s_addr=inet_addr("127.0.0.1")
        let bound=withUnsafePointer(to:&address) {p in p.withMemoryRebound(to:sockaddr.self,capacity:1) {Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}
        #expect(bound==0)
        var length=socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to:&address) {p in p.withMemoryRebound(to:sockaddr.self,capacity:1) {getsockname(fd,$0,&length)}}
        var timeout=timeval(tv_sec:0,tv_usec:150000)
        _ = withUnsafePointer(to:&timeout) {setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,$0,socklen_t(MemoryLayout<timeval>.size))}
        var p=store.profile;p.port=Int(UInt16(bigEndian:address.sin_port));store.save(p)
        var buffer=[UInt8](repeating:0,count:1024)
        store.input("fader:0",16383)
        #expect(recv(fd,&buffer,buffer.count,0)<0)
        store.toggleOutput();store.input("fader:0",16383)
        let count=recv(fd,&buffer,buffer.count,0)
        #expect(count>0)
        if count>0 {
            let (path,args)=try OSC.decode(Data(buffer.prefix(count)))
            #expect(path=="/strip/fader");#expect(args==[.int(1),.float(1)])
        }
        store.decode(Wire.hex(Wire.frame([try Wire.fader(channel:0,value:0)])))
        #expect(recv(fd,&buffer,buffer.count,0)<0)
    }
    @Test func connectionNegotiatesTwentyFourStripsOverUDP() async throws {
        let store=try model();defer {store.stopFeedback();try? FileManager.default.removeItem(at:store.directory)}
        let fd=Darwin.socket(AF_INET,SOCK_DGRAM,0);defer {Darwin.close(fd)}
        var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family=sa_family_t(AF_INET);address.sin_addr.s_addr=inet_addr("127.0.0.1")
        let bound=withUnsafePointer(to:&address) {p in p.withMemoryRebound(to:sockaddr.self,capacity:1) {Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}
        #expect(bound==0)
        var length=socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to:&address) {p in p.withMemoryRebound(to:sockaddr.self,capacity:1) {getsockname(fd,$0,&length)}}
        var timeout=timeval(tv_sec:0,tv_usec:150000)
        _ = withUnsafePointer(to:&timeout) {setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,$0,socklen_t(MemoryLayout<timeval>.size))}
        store.switchProfile("ardour")
        var profile=store.profile;profile.port=Int(UInt16(bigEndian:address.sin_port));store.save(profile)
        let feedbackPort=Int.random(in:45000...55000)
        store.connectDAW(feedbackPort:feedbackPort)
        for _ in 0..<100 {
            if store.events.contains(where:{$0.kind=="daw-setup"}) {break}
            try await Task.sleep(for:.milliseconds(20))
        }
        var buffer=[UInt8](repeating:0,count:2048)
        let count=recv(fd,&buffer,buffer.count,0)
        #expect(count>0)
        if count>0 {
            let (path,args)=try OSC.decode(Data(buffer.prefix(count)))
            #expect(path=="/set_surface")
            #expect(args==[.int(24),.int(31),.int(24827),.int(3),.int(0),.int(0),.int(Int32(feedbackPort))])
        }
        let refresh=recv(fd,&buffer,buffer.count,0)
        #expect(refresh>0)
        if refresh>0 {#expect(try OSC.decode(Data(buffer.prefix(refresh))).0=="/refresh")}
        #expect(!store.armed)
    }
}
