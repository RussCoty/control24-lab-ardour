// Projective panel geometry, independent of DOM/state. TL, TR, BR, BL corners.
export class Panel {
  constructor(corners, physicalWidth=800, physicalHeight=170) {
    this.corners=corners;this.physicalWidth=physicalWidth;this.physicalHeight=physicalHeight;
    const [[x0,y0],[x1,y1],[x2,y2],[x3,y3]]=corners;
    const dx1=x1-x2,dx2=x3-x2,dx3=x0-x1+x2-x3;
    const dy1=y1-y2,dy2=y3-y2,dy3=y0-y1+y2-y3;
    const denominator=dx1*dy2-dx2*dy1;
    const g=Math.abs(dx3)+Math.abs(dy3)<1e-9?0:(dx3*dy2-dx2*dy3)/denominator;
    const h=Math.abs(dx3)+Math.abs(dy3)<1e-9?0:(dx1*dy3-dx3*dy1)/denominator;
    this.m=[x1-x0+g*x1,x3-x0+h*x3,x0,y1-y0+g*y1,y3-y0+h*y3,y0,g,h];
  }
  project(u,v) {
    const [a,b,c,d,e,f,g,h]=this.m,q=g*u+h*v+1;
    return [(a*u+b*v+c)/q,(d*u+e*v+f)/q];
  }
  inverse(x,y) {
    const [a,b,c,d,e,f,g,h]=this.m;
    const aa=a-x*g,bb=b-x*h,cc=x-c,dd=d-y*g,ee=e-y*h,ff=y-f;
    const det=aa*ee-bb*dd;
    return [(cc*ee-bb*ff)/det,(aa*ff-cc*dd)/det];
  }
  outline(u,v,width,height,circle=false) {
    const w=width/this.physicalWidth/2,h=height/this.physicalHeight/2;
    if(circle)return Array.from({length:40},(_,i)=>this.project(u+Math.cos(i*Math.PI/20)*w,v+Math.sin(i*Math.PI/20)*h));
    return [[u-w,v-h],[u+w,v-h],[u+w,v+h],[u-w,v+h]].map(([u,v])=>this.project(u,v));
  }
}
export function path(points,origin=[0,0]) {
  return points.map(([x,y],i)=>`${i?'L':'M'} ${(x-origin[0]).toFixed(3)} ${(y-origin[1]).toFixed(3)}`).join(' ')+' Z';
}
