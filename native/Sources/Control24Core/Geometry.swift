import Foundation

public struct Point: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

/// A homography maps a flat physical panel to the photographed quadrilateral.
/// Controls are projected corner by corner; they are never screen-aligned rectangles.
public struct Panel: Sendable {
    let m: [Double]
    public var width: Double
    public var height: Double

    public init(corners: [[Double]], width: Double = 800, height: Double = 255) {
        precondition(corners.count == 4 && corners.allSatisfy { $0.count == 2 })
        self.width = width; self.height = height
        let x0=corners[0][0], y0=corners[0][1], x1=corners[1][0], y1=corners[1][1]
        let x2=corners[2][0], y2=corners[2][1], x3=corners[3][0], y3=corners[3][1]
        let dx1=x1-x2, dx2=x3-x2, dx3=x0-x1+x2-x3
        let dy1=y1-y2, dy2=y3-y2, dy3=y0-y1+y2-y3
        let divisor=dx1*dy2-dx2*dy1
        let affine=abs(dx3)+abs(dy3)<1e-9
        let g=affine ? 0 : (dx3*dy2-dx2*dy3)/divisor
        let h=affine ? 0 : (dx1*dy3-dx3*dy1)/divisor
        m=[x1-x0+g*x1,x3-x0+h*x3,x0,y1-y0+g*y1,y3-y0+h*y3,y0,g,h]
    }

    public func project(_ u: Double, _ v: Double) -> Point {
        let q=m[6]*u+m[7]*v+1
        return Point((m[0]*u+m[1]*v+m[2])/q,(m[3]*u+m[4]*v+m[5])/q)
    }

    public func inverse(_ p: Point) -> Point {
        let a=m[0]-p.x*m[6], b=m[1]-p.x*m[7], c=p.x-m[2]
        let d=m[3]-p.y*m[6], e=m[4]-p.y*m[7], f=p.y-m[5]
        let det=a*e-b*d
        return Point((c*e-b*f)/det,(a*f-c*d)/det)
    }

    public func outline(u: Double, v: Double, width: Double, height: Double, round: Bool = false) -> [Point] {
        let w=width/self.width/2, h=height/self.height/2
        if round {
            return (0..<48).map { i in
                let angle=Double(i)*Double.pi/24
                return project(u+cos(angle)*w,v+sin(angle)*h)
            }
        }
        return [project(u-w,v-h),project(u+w,v-h),project(u+w,v+h),project(u-w,v+h)]
    }
}

public struct SurfaceGeometry: Codable, Sendable {
    public var imageWidth: Double
    public var imageHeight: Double
    public var planes: [String: [[Double]]]
    public var faders: Faders

    public struct Faders: Codable, Sendable {
        public var firstU: Double
        public var stepU: Double
        public var topV: Double
        public var bottomV: Double
    }
    public var upper: Panel { Panel(corners: planes["upper"]!, width: 750, height: 221) }
    public var lower: Panel { Panel(corners: planes["lower"]!, width: 800, height: 255) }

    public func fader(channel: Int, value: Double) -> Point {
        Point(faders.firstU+Double(channel)*faders.stepU,
              faders.topV+(1-value/16383)*(faders.bottomV-faders.topV))
    }
    public func faderValue(at imagePoint: Point) -> Double {
        let v=lower.inverse(imagePoint).y
        return (max(0,min(1,(faders.bottomV-v)/(faders.bottomV-faders.topV)))*16383).rounded()
    }
}
