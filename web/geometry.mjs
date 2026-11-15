import {Panel,path} from './panel.mjs';
export {Panel,path} from './panel.mjs';
export const geometry=await fetch('/surface-geometry.json').then(r=>r.json());
export const upper=new Panel(geometry.planes.upper,750,221);
export const lower=new Panel(geometry.planes.lower,800,255);
export function panelAt(x,y) {return y<247?upper:lower;}
export function faderLocation(channel,value) {
  return [geometry.faders.firstU+channel*geometry.faders.stepU,
    geometry.faders.topV+(1-value/16383)*(geometry.faders.bottomV-geometry.faders.topV)];
}
