"""Build factual action choices from the user's Ardour checkout, without modifying it."""
import json,re,subprocess,sys
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
checkout=Path(sys.argv[1])
revision=subprocess.check_output(['git','-C',str(checkout),'rev-parse','HEAD'],text=True).strip()
actions={}


def add(id,title,group,path,args,kinds=('button','touch'),profiles=('ardour','mixbus'),trigger='press',requires_channel=False,source=None):
    actions[id]=dict(id=id,title=title,group=group,mapping=dict(path=path,args=args,trigger=trigger),
                     kinds=list(kinds),profiles=list(profiles),requires_channel=requires_channel,
                     source=source or 'libs/surfaces/osc/osc.cc')


for id,title,path in [('play','Play','/transport_play'),('stop','Stop','/transport_stop'),('record','Toggle global record','/rec_enable_toggle'),
    ('rewind','Rewind','/rewind'),('forward','Fast forward','/ffwd'),('start','Go to start','/goto_start'),('end','Go to end','/goto_end'),
    ('loop','Toggle loop','/loop_toggle'),('marker','Add marker at playhead','/add_marker'),('save','Save session','/save_state'),
    ('bank-up','Bank right (24 strips)','/bank_up'),('bank-down','Bank left (24 strips)','/bank_down'),('next','Select next track','/select/next'),('previous','Select previous track','/select/previous')]:add('osc:'+id,title,'Transport / navigation',path,[])
add('osc:fader','Channel fader','Channel strips','/strip/fader',['$channel','$value'],kinds=('fader',),requires_channel=True)
add('osc:pan','Channel pan (relative encoder → absolute position)','Channel strips','/strip/pan_stereo_position',['$channel','$position'],kinds=('encoder',),requires_channel=True)
add('osc:touch','Channel fader touch / release','Channel strips','/strip/fader/touch',['$channel','$value'],kinds=('touch',),trigger='both',requires_channel=True)
for path,title in [('mute','Mute'),('solo','Solo'),('recenable','Record enable')]:
    add('osc:'+path,f'Channel {title.lower()} toggle','Channel strips','/strip/'+path,['$channel','$toggle'],requires_channel=True)
    add('osc:selected-'+path,f'Selected track {title.lower()} toggle','Selected track','/select/'+path,['$toggle'])
add('osc:select','Select channel','Channel strips','/strip/select',['$channel',1],requires_channel=True)
for value,title in [(0,'Off'),(1,'Read'),(2,'Write'),(3,'Touch'),(4,'Latch')]:add('osc:auto-'+title.lower(),'Selected fader automation: '+title,'Automation','/select/fader/automation',[value])
add('osc:jog','Jog / scrub (relative wheel)','Transport / navigation','/jog',['$delta'],kinds=('encoder',))

# Native binding/action identifiers from this exact checkout.
bindings=checkout/'gtk2_ardour/ardour.keys.in'
for line in bindings.read_text().splitlines():
    if not line.startswith('@'):continue
    fields=line[1:].split('|')
    if len(fields)<4:continue
    group,path,binding,title=fields[:4]
    if '/' not in path or ':' in path or path.startswith('-'):continue
    if not re.fullmatch(r'[A-Za-z0-9_+./-]+',path):continue
    title=re.sub(r'\\[A-Za-z]+\{([^}]*)\}',r'\1',title).replace('\\&','&')
    add('action:'+path,title or path,'Ardour actions · '+path.split('/')[0],'/access_action',[path],profiles=('ardour',),source=str(bindings.relative_to(checkout)))

source=checkout/'gtk2_ardour/editor_actions.cc'
text=source.read_text()
for match in re.finditer(r'register_region_action\s*\(_region_actions,.*?,\s*"([\w-]+)",\s*_\("([^"]+)"\)',text):
    id,title=match.groups()
    add('action:Region/'+id,title,'Ardour actions · Region','/access_action',['Region/'+id],profiles=('ardour',),source=str(source.relative_to(checkout)))

out=dict(target='User Ardour development checkout',checkout=checkout.name,base_revision=revision,
         build_version=re.search(r'#define VERSIONSTRING "([^"]+)"',(checkout/'build/gtk2_ardour/gtk2ardour-version.h').read_text()).group(1),
         notes=[
                'Action availability is source-verified; the running DAW/session must still make the action sensitive.',
                'Ardour-only actions are not assumed to exist in Mixbus.'],
         actions=sorted(actions.values(),key=lambda a:(a['group'],a['title'])))
(ROOT/'data/daw-actions.json').write_text(json.dumps(out,indent=2)+'\n')
print(f"Indexed {len(actions)} actions")
