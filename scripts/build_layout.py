"""Manual-audited physical control coordinates for the ORIGINAL Control|24.

Coordinates are PDF points in the cropped page-50 drawing (printed p40,
Figure 1), transcribed and cross-checked against its vector primitives and
the enlarged component drawings on printed pp41–51, 53–59, 63–70, 73–85.
The manual establishes physical location/label; upstream establishes wire
addresses. Neither is a substitute for verifying addresses on the user's desk.
"""
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
catalog=json.loads((ROOT/'data/catalog.json').read_text())
controls={c['id']:c for c in catalog['controls']}
regions=[]
source='https://images.thomann.de/pics/atg/atgdata/document/manual/138371_manual.pdf'


def add(id,x,y,w=2.90,h=2.90,shape='circle',label=None,notes=None):
    if id not in controls:
        raise ValueError(f'Missing catalog control {id}')
    c=controls[id]
    plane='upper' if y<195 else 'lower'
    # The diagram shows both panel planes flattened. Project each plane separately.
    bounds=[94.13,106.575,372.938,194.90] if plane=='upper' else [98.719,195.0,368.348,279.186]
    l,t,r,b=bounds
    region=dict(id=id,plane=plane,u=round((x-l)/(r-l),8),v=round((y-t)/(b-t),8),
                width=round(w/(r-l),8),height=round(h/(b-t),8),shape=shape,
                manual=dict(pdf_page=50,printed_page=40,figure=1,x=x,y=y,source=source),
                label=label or c['name'],placement_status='manual-audited',wire_status=c.get('input_status','source-reported' if c.get('section') is not None else 'unverified'))
    if notes:region['notes']=notes
    regions.append(region)


def button(sec,note,x,y,**kw):add(f'button:{sec}:{note}',x,y,**kw)

# Meter selectors; function keys are TWO VERTICAL COLUMNS, not a horizontal row.
for i,note in enumerate([10,11,12,9,14]):button(24,note,105.98,114.71+4.05*i)
for i,note in enumerate([0,2,4,6,8]):button(24,note,105.98,136.75+4.048*i)
for i,note in enumerate([50,51,52,53,54]):button(24,note,116.56,136.70+4.048*i)
button(24,15,105.98,158.13);button(24,1,116.56,158.13)
button(25,19,328.43,128.92)

for ch in range(24):
    x=121.324+7.1453*ch
    button(ch,0,x,158.135)
    if ch<16:
        button(ch,11,x,138.42,label=f'Preamp {ch+1:02d} · high-pass filter',notes='Upstream label was unknown. Placement/HPF identity from manual; wire association needs hardware confirmation.')
        button(ch,12,x,142.42,label=f'Preamp {ch+1:02d} · source')
        add(f'analog:{ch}:gain',122.5235+7.1453*ch,150.156,4.8,4.8,shape='circle')
    else:
        add(f'analog:submixer:{ch-16}',x,151.0,4.8,4.8)
    add(f'scribble:{ch}',x,174.9,6.2,2.4,shape='rect')
    add(f'encoder:{ch}',122.4995+7.1453*ch,180.98,4.8,4.8)
    button(ch,4,122.49+7.1453*ch,186.63,label=f'CH {ch+1:02d} · encoder switch')
    for note,y in [(1,198.31),(2,202.35),(3,206.38),(10,210.42),(5,219.18),(6,224.81)]:button(ch,note,x,y)
    button(ch,7,x+.165,229.61,shape='rect')
    button(ch,8,x+.165,233.695,shape='rect')

# Channel bar and assignments.
for note,x,y in [(0,121.324,168.07),(1,128.47,168.07),(3,157.05,163.63),(9,164.20,163.63),
                 (2,157.05,167.76),(4,164.20,167.76),(7,178.49,163.63),(8,185.63,163.63),
                 (5,178.49,167.67),(6,185.63,167.67),(10,199.92,163.51)]:button(29,note,x,y)
for i in range(5):button(29,11+i,199.92+7.1453*i,167.67)
for note,x in [(16,235.649),(17,242.795),(18,249.94),(19,257.085),(22,264.231),(23,271.376),(20,278.521),(21,285.667)]:button(29,note,x,167.67)
for note,x,y in [(16,105.98,173.13),(17,116.54,173.13),(18,105.98,176.97),(19,116.54,176.97),
                 (22,105.98,182.49),(39,116.54,182.46),(40,116.54,186.64),(13,116.54,190.83)]:button(24,note,x,y)

# Channel settings, automation, keyboard modifiers.
for note,x,y in [(43,105.98,198.51),(44,105.98,202.56),(45,105.98,206.61),(5,116.56,202.32),(3,116.56,210.47),
                 (41,105.98,215.11),(42,105.98,219.16),(7,105.98,224.96),(46,105.98,229.70),(20,116.56,229.70)]:button(24,note,x,y)
for i in range(6):
    button(24,23+2*i,105.98,235.15+4.048*i)
    button(24,24+2*i,116.56,235.15+4.048*i)
button(24,21,111.16,258.73)
for note,x in [(47,105.98),(48,111.16),(49,116.56)]:button(24,note,x,263.63)
for note,x,y in [(35,105.98,269.84),(36,116.56,269.84),(37,105.98,273.75),(38,116.56,273.75)]:button(24,note,x,y)

# Main edit section.
for i,note in enumerate([23,24,25,26,27]):button(27,note,294.18+5.4*i,200.52)
for i,note in enumerate([4,5,6,7,8,9,28,29]):button(27,note,323.82+5.108*i,200.52)
for i,note in enumerate([8,9,10,11,20]):button(25,note,294.18+5.4*i,209.55)
for i,note in enumerate([0,1,2,3]):button(27,note,331.02+7.20*i,209.41)
for note,x,y in [(0,294.18,218.39),(2,301.34,218.39),(6,308.56,218.39),(4,315.79,218.39),
                 (1,294.18,224.08),(3,301.34,224.08),(7,308.56,224.08),(5,315.79,224.08)]:button(25,note,x,y)
for i,note in enumerate([13,14,15,16]):button(27,note,331.02+7.20*i,218.39)
for note,x in [(17,322.70),(18,331.02),(30,338.18),(31,345.40),(32,352.63)]:
    button(27,note,x,224.08,notes='2006 manual diagram and upstream primary/alternate legends differ in this row. Preserve the wire ID and verify against the physical unit before renaming.')

# Navigation, numeric keypad, transport, jog and banks.
for sec,note,x,y in [(27,22,293.65,230.94),(27,19,293.65,238.33),(25,12,311.28,230.94),
    (25,13,317.14,230.94),(25,14,323.0,230.94),(25,15,317.14,236.79),(25,16,312.81,241.21),
    (25,17,321.52,241.21),(25,18,317.14,245.5),(27,33,332.98,241.21),
    (27,20,347.55,230.94),(27,21,357.24,230.94),(28,18,329.11,250.92),(28,19,336.85,250.92)]:button(sec,note,x,y)
for note,x,y in [(10,345.36,240.23),(11,349.95,240.23),(12,354.55,240.23),(13,359.15,240.23),
    (7,345.36,244.21),(8,349.95,244.21),(9,354.55,244.21),(14,359.15,244.21),
    (4,345.36,248.20),(5,349.95,248.20),(6,354.55,248.20),(15,359.15,248.20),
    (1,345.36,252.18),(2,349.95,252.18),(3,354.55,252.18),
    (0,349.95,256.17),(16,354.55,256.17),(17,359.15,256.17)]:button(26,note,x,y,shape='rect')
for note,x,y in [(9,293.65,249.10),(10,299.58,249.10),(0,293.65,255.07),(1,299.58,255.07),
    (2,305.51,255.07),(3,311.44,255.07),(4,317.37,255.07),
    (7,293.65,261.03),(5,299.58,261.03),(6,305.51,261.03),(8,311.44,261.03),(11,317.37,261.03)]:button(28,note,x,y)
for i,note in enumerate([12,13,14,15,16,17]):button(28,note,293.0+5.35*i,273.88,w=4.0,h=4.0,shape='rect')
for note,x in [(10,343.5),(11,348.81),(12,354.12)]:button(27,note,x,273.88)
add('jog',332.70,267.90,18,18)

# Monitoring buttons: existing wire observations, not invented MIDI addresses.
for note,x,y in [(16,309.80,161.69),(17,309.80,170.33),(19,309.80,179.04),
    (20,322.81,161.69),(21,327.76,161.69),(22,332.71,161.69),(18,327.70,177.99),
    (7,336.71,180.52),(8,341.68,180.52),(15,346.65,180.52),(6,322.80,189.01),
    (0,329.60,188.80),(2,334.43,188.80),(1,339.26,188.80),(4,344.09,188.80),(5,348.92,188.80),(3,353.75,188.80),
    (12,358.28,160.28),(13,358.28,164.28),(14,358.28,168.28),(9,358.28,173.58),(10,358.28,177.58),(11,358.28,181.58)]:
    button(30,note,x,y,shape='rect' if note in [0,1,2,3,4,5,7,8,15] else 'circle')

# Analog pots are visible/selectable but are not promised to emit digital events.
for id,x,y in [('analog:submixer-master',287.7,151.0),('analog:aux-level',299.13,161.69),
    ('analog:listen-mic-level',299.13,170.33),('analog:headphone-level',299.13,179.04),
    ('analog:talkback-level',299.13,187.75),('analog:alt-monitor',327.70,170.33),('analog:monitor-level',341.68,170.33)]:add(id,x,y,4.8,4.8)
add('counter',342.0,119.9,29,7,shape='rect')
add('channel-bar:top',142.5,165.4,6.2,2.5,shape='rect')
add('channel-bar:bottom',149.5,165.4,6.2,2.5,shape='rect')

assert len({r['id'] for r in regions})==len(regions), 'Duplicate physical regions'
button_ids={id for id,c in controls.items() if c['kind']=='button'}
placed={r['id'] for r in regions}
missing=sorted(button_ids-placed)
if missing:raise ValueError(f'Buttons missing physical positions: {missing}')
out=dict(model=catalog['model'],manual_revision='PN 9106-18918-00 REV A 03/06',
         source=source,coordinate_system='Cropped PDF page 50, printed page 40, figure 1',
         regions=regions,coverage=dict(physical_regions=len(regions),buttons=len(button_ids),
         buttons_placed=len(button_ids & placed),buttons_missing=missing),
         caveats=['Placement is audited against the guide; wire addresses remain source-reported until live validation.',
                  'The guide and upstream legends differ in the lower edit-tools row.',
                  'Analog pots and rear phantom switches are not arbitrarily assignable digital inputs.'])
(ROOT/'data/control-layout.json').write_text(json.dumps(out,indent=2)+'\n')
print(json.dumps(out['coverage']))
