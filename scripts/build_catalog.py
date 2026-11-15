"""Extract factual addresses from the pinned upstream reference maps.

Usage: python3 scripts/build_catalog.py /path/to/C24-Engine-Renewed
Does not import or execute upstream code. Generated catalog is checked in.
"""
import json
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parents[1]
source = pathlib.Path(sys.argv[1]) / 'Control24-LED-Finder'
mapping = json.loads((source / 'c24_mapping.json').read_text())
leds = json.loads((source / 'c24_led_dictionary.json').read_text())
revision = '94d7a3ba42726db8fd5da8151429cc7d28ea7b47'
url = f'https://github.com/Davitekk/C24-Engine-Renewed/blob/{revision}/Control24-LED-Finder/'
catalog = {}


def add(id, name, kind, group, **kwargs):
    catalog[id] = dict(id=id, name=name, kind=kind, group=group,
                       evidence='inventory-candidate' if kind == 'analog' else 'source-reported',
                       hardware_verified=False, **kwargs)


for name, item in mapping.items():
    if item['type'] != 'BUTTON':
        continue  # two encoder entries conflict with the engine's actual CC decoder
    section, note = item['sec_dec'], item['btn_dec']
    for sec in (range(16 if note in (11,12) else 24) if section == 0 else [section]):
        ch = sec + 1 if section == 0 else None
        id = f'button:{sec}:{note}'
        panel_name='High-pass filter' if section==0 and note==11 else 'Source' if section==0 and note==12 else 'Encoder switch' if section==0 and note==4 else name.split(' / ')[-1]
        add(id, f'CH {ch:02d} · {panel_name}' if ch else name,
            'touch' if section == 0 and note == 9 else 'button',
            'Channel strips' if ch else name.split(' / ')[0],
            section=sec, note=note, channel=ch, source=url+'c24_mapping.json')

for ch in range(24):
    for kind, name in [('fader', 'Motor fader'), ('encoder', 'Rotary encoder'),
                       ('ring', 'Encoder LED ring'), ('scribble', 'Four-character display'),
                       ('meter', 'Meter'), ('automation', 'Automation indicators')]:
        add(f'{kind}:{ch}', f'CH {ch+1:02d} · {name}', kind, 'Channel strips', channel=ch+1,
            source=f'https://github.com/Davitekk/C24-Engine-Renewed/blob/{revision}/Control24-Engine/motore.py')
add('jog', 'Jog / shuttle wheel', 'encoder', 'Navigation', cc=92,
    source=f'https://github.com/Davitekk/C24-Engine-Renewed/blob/{revision}/Control24-Engine/motore.py')
add('counter', 'Eight-digit main counter', 'counter', 'Displays')
add('counter-mode', 'Counter mode indicators', 'indicator', 'Displays')
for row in ('top', 'bottom'):
    add(f'channel-bar:{row}', f'Channel bar · {row}', 'display', 'Displays')

for item in leds.values():
    section, note = item['sec_dec'], item['note_dec']
    for sec in (range(24) if section == 0 else [section]):
        id = f'button:{sec}:{note}'
        led = dict(section=sec, note=note, label=item['name'], source=url+'c24_led_dictionary.json')
        if id in catalog:
            catalog[id]['led'] = led
        else:
            add(f'led:{sec}:{note}', item['name'], 'led', 'Additional LED addresses', led=led,
                source=url+'c24_led_dictionary.json')

# Addresses absent from the button map, but observed by the engine or LED map.
for section,note,name in [(24,46,'SOLO SAFE'),(24,20,'SOLO CLEAR'),(27,22,'UTILITY')]:
    id=f'button:{section}:{note}'
    if id not in catalog:
        add(id,name,'button','Global controls',section=section,note=note,
            source=f'https://github.com/Davitekk/C24-Engine-Renewed/blob/{revision}/Control24-Engine/motore.py')
    if f'led:{section}:{note}' in catalog:
        catalog[id]['led']=catalog.pop(f'led:{section}:{note}')['led']
for item in leds.values():
    if item['sec_dec']!=30:continue
    section,note=30,item['note_dec'];id=f'button:{section}:{note}'
    add(id,item['name'].replace(' BUTTON LED',''),'button','Analog monitor switches',section=section,note=note,
        input_status='source-reported' if note in range(9) or note==15 else 'unverified input; LED address only',
        evidence_note='Local monitor switching remains a hardware function; mapping a digital event cannot disable the analog function.',
        source=url+'c24_led_dictionary.json',led=catalog.pop(f'led:{section}:{note}')['led'])

# Analog controls are explicitly separate from Ethernet-observable controls.
for ch in range(16):
    for kind in ('gain',):
        add(f'analog:{ch}:{kind}', f'Preamp {ch+1:02d} · {kind}', 'analog', 'Analog front end',
            evidence_note='Inventory candidate; confirm exact switch grouping from guide/hardware',
            digital_observability='not established')
for name in ('Monitor level', 'Headphone level', 'Talkback level', 'Aux level', 'Listen mic level', 'Alt monitor','Submixer master'):
    add('analog:'+name.lower().replace(' ', '-'), name, 'analog', 'Analog monitoring',
        digital_observability='not established')
for ch in range(8):add(f'analog:submixer:{ch}',f'Submixer input {ch+1}','analog','Analog submixer',digital_observability='analog only')
for bank in (1,2):add(f'analog:phantom-bank:{bank}',f'Rear phantom-power bank {bank}','analog','Rear panel',digital_observability='rear analog switch; no front-panel hotspot')

out = dict(model='Digidesign Control|24 (original)', revision=revision,
           notes=['Channel button templates expand over 24 strips; preamp HPF/source expand over 16 preamps only.',
                  'Two ambiguous upstream encoder-map entries excluded; engine CC ranges used.',
                  'Catalog is a research baseline, not a claim of complete hardware coverage.',
                  'Physical panel positions are separately audited in control-layout.json.',
                  'LED-only monitor addresses do not establish digital input capability.'],
           controls=list(catalog.values()))
(root/'data'/'catalog.json').write_text(json.dumps(out, indent=2)+'\n')
print(f'Wrote {len(catalog)} catalog entries')
