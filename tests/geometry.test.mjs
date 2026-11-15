import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {Panel} from '../web/panel.mjs';
const geometry=JSON.parse(readFileSync(new URL('../data/surface-geometry.json',import.meta.url)));
test('both panel homographies map exact photo corners and invert points',()=>{
  for(const corners of Object.values(geometry.planes)) {
    const p=new Panel(corners);
    [[0,0],[1,0],[1,1],[0,1]].forEach(([u,v],i)=>p.project(u,v).forEach((value,j)=>assert.ok(Math.abs(value-corners[i][j])<1e-8)));
    for(let u=0;u<=1;u+=.05)for(let v=0;v<=1;v+=.05){const [x,y]=p.project(u,v),[uu,vv]=p.inverse(x,y);assert.ok(Math.abs(u-uu)<1e-9&&Math.abs(v-vv)<1e-9);}
  }
});
test('fader caps lean with the panel and widen toward the seated edge',()=>{
  const p=new Panel(geometry.planes.lower,800,255);
  const left=p.outline(.086,.8,11,12),right=p.outline(.7024,.8,11,12);
  assert.ok(left[3][0]<left[0][0]);assert.ok(right[3][0]>right[0][0]);
  assert.ok(left[2][0]-left[3][0]>left[1][0]-left[0][0]);
});
test('drag inverse recovers positions on every fader travel',()=>{
  const p=new Panel(geometry.planes.lower),f=geometry.faders;
  for(let ch=0;ch<24;ch++)for(const value of [0,127,8192,16383]) {
    const u=f.firstU+ch*f.stepU,v=f.topV+(1-value/16383)*(f.bottomV-f.topV);
    const [,recovered]=p.inverse(...p.project(u,v));
    assert.ok(Math.abs(Math.round((f.bottomV-recovered)/(f.bottomV-f.topV)*16383)-value)<1);
  }
});
