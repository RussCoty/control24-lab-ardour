import Foundation
import XCTest
@testable import Control24Core

final class CoreTests: XCTestCase {
    func testRunningStatusAndRealtimeByte() throws {
        var decoder=NativeDecoder()
        let payload=try Wire.data(hex:"90 10 5c 10 1c b0 00 f8 40 20 01 40 3f")
        let events=try decoder.decode(Wire.frame([payload]))
        XCTAssertEqual(events.map(\.control),["button:28:16","button:28:16","fader:0","encoder:0"])
        XCTAssertEqual(events.map(\.value),[1,0,8193,-1])
    }
    func testEveryFaderRoundTrip() throws {
        for channel in 0..<24 {
            for value in [0,127,128,8192,16383] {
                var decoder=NativeDecoder()
                let frame=Wire.frame([try Wire.fader(channel:channel,value:value)])
                XCTAssertEqual(frame.count,46)
                let event=try XCTUnwrap(decoder.decode(frame).first)
                XCTAssertEqual(event.control,"fader:\(channel)")
                XCTAssertEqual(event.value,Double(value))
            }
        }
    }
    func testLSBWithoutMSBIsUnknown() throws {
        var decoder=NativeDecoder()
        XCTAssertEqual(try decoder.decode(Wire.frame([Data([0xb0,32,127])])).first?.kind,"unknown")
    }
    func testTruncationAndInvalidLengths() throws {
        var decoder=NativeDecoder()
        for data in [Data(),Data(repeating:0,count:16),Wire.frame([Data([0xb0,0])]),Wire.frame([Data([0xf0,0x13])])] {
            XCTAssertThrowsError(try decoder.decode(data))
        }
    }
    func testFailedFrameDoesNotPolluteFaderCache() throws {
        var decoder=NativeDecoder()
        XCTAssertThrowsError(try decoder.decode(Wire.frame([Data([0xb0,0,64,32])])))
        XCTAssertEqual(try decoder.decode(Wire.frame([Data([0xb0,32,127])])).first?.kind,"unknown")
    }
    func testOutputBytes() throws {
        XCTAssertEqual(Wire.hex(try Wire.led(section:28,note:16,on:true)),"90 10 5c")
        XCTAssertEqual(Wire.hex(try Wire.scribble(channel:23,text:"ABCDE")),"f0 13 01 40 37 00 41 42 43 44 f7")
        XCTAssertEqual(Wire.hex(try Wire.ring(channel:0,position:0)),"f0 13 01 00 40 00 00 f7")
        XCTAssertEqual(try Wire.counter("01020304").count,15)
        XCTAssertThrowsError(try Wire.counter("too long!"))
        XCTAssertThrowsError(try Wire.fader(channel:24,value:0))
    }
    func testOSCEncodingRoundTrip() throws {
        let args: [OSCValue]=[.int(1),.int(-3),.float(0.5),.string("Track one")]
        let (path,decoded)=try OSC.decode(OSC.encode(path:"/test",args:args))
        XCTAssertEqual(path,"/test");XCTAssertEqual(decoded,args)
    }
    func testMalformedOSCAndNonfiniteValues() throws {
        for packet in [Data(),Data("#bundle\0".utf8),Data("/unterminated".utf8),Data([47,0,0,0,44,105,0,0,0])] {
            XCTAssertThrowsError(try OSC.decode(packet))
        }
        XCTAssertThrowsError(try OSC.encode(path:"/test",args:[.float(.nan)]))
        XCTAssertThrowsError(try OSC.encode(path:"/bad\0path",args:[]))
    }
    func testProfileSerialization() throws {
        let data=try JSONEncoder().encode(Profile.defaults)
        let decoded=try JSONDecoder().decode([Profile].self,from:data)
        XCTAssertEqual(decoded,Profile.defaults)
        XCTAssertEqual(decoded.count,6)
        XCTAssertEqual(decoded[2].mappings["fader:23"]?.args,[.int(24),.string("$value")])
    }
    func testHomographyCornersAndInverse() {
        let corners: [[Double]]=[[100,249],[898,249],[946,419],[48,419]]
        let plane=Panel(corners:corners)
        for (i,uv) in [Point(0,0),Point(1,0),Point(1,1),Point(0,1)].enumerated() {
            let projected=plane.project(uv.x,uv.y)
            XCTAssertEqual(projected.x,corners[i][0],accuracy:1e-8)
            XCTAssertEqual(projected.y,corners[i][1],accuracy:1e-8)
        }
        for u in stride(from:0.0,through:1.0,by:0.05) {
            for v in stride(from:0.0,through:1.0,by:0.05) {
                let result=plane.inverse(plane.project(u,v))
                XCTAssertEqual(result.x,u,accuracy:1e-9);XCTAssertEqual(result.y,v,accuracy:1e-9)
            }
        }
    }
    func testControlsFollowPanelPerspective() {
        let p=Panel(corners:[[100,249],[898,249],[946,419],[48,419]])
        let left=p.outline(u:0.086,v:0.8,width:11,height:12)
        let right=p.outline(u:0.7024,v:0.8,width:11,height:12)
        XCTAssertLessThan(left[3].x,left[0].x) // left caps lean left toward the seated edge
        XCTAssertGreaterThan(right[3].x,right[0].x) // right caps lean right
        XCTAssertGreaterThan(left[2].x-left[3].x,left[1].x-left[0].x) // cap widens in front
        let ellipse=p.outline(u:0.85,v:0.85,width:60,height:60,round:true)
        let width=ellipse.map(\.x).max()!-ellipse.map(\.x).min()!
        let height=ellipse.map(\.y).max()!-ellipse.map(\.y).min()!
        XCTAssertLessThan(height,width) // circles on the lower plane foreshorten
    }
    func testHexRejectsPartialAndInvalidBytes() {
        XCTAssertThrowsError(try Wire.data(hex:"abc"))
        XCTAssertThrowsError(try Wire.data(hex:"zz"))
    }
}
