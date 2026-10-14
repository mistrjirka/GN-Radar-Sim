#!/usr/bin/env python3
"""Fictional cockpit-game worker. Reuses the approved radar, not the old SAR fork.

A selected area is resampled from the actual mission fields before the approved
measurement + statistical image formation. Only the paper chart has a selection
frame; returned radar pixels contain no UI, targets, text or aiming rectangles.
The original radar worker and its bit-exact reference tests remain untouched.
"""
from __future__ import annotations
import os
os.environ.setdefault('OPENBLAS_NUM_THREADS','1')
os.environ.setdefault('OMP_NUM_THREADS','4')
import copy,json,math,signal,sys,time,traceback,argparse
from pathlib import Path
import numpy as np
from scipy.ndimage import map_coordinates,gaussian_filter
from PIL import Image,ImageDraw,ImageFont
ROOT=Path(__file__).resolve().parent
RADAR=ROOT.parents[1]/'radar'/'backend'
sys.path.insert(0,str(RADAR))
from scene_world import load_scene,native_models_world,atom_json,ground_at,ARRAY_FIELDS
from model_library import entity
from sortie_region import SortieRegion
from endless_world import EndlessWorld
from chart_stream import ChartStream
from scan_acceleration import ParallelRadar
from approved_renderer import Instrument,measure,image_measurements,plt


def mission_world(seed,cache):
    w=load_scene(cache,seed,'valley')
    w._entities=copy.deepcopy(w._entities)
    rng=np.random.default_rng(seed+7751)
    # Fictitious game emitters; same locations are rasterized into the radar scene.
    additional=[]
    for zone in [(-590,440),(610,-570)]:
        for attempt in range(100):
            x=zone[0]+float(rng.uniform(-110,110));y=zone[1]+float(rng.uniform(-110,110))
            ix=int((x+1000)/2000*(w.N-1));iy=int((y+1000)/2000*(w.N-1))
            if w.mat_id[iy,ix] in (2,6) and w._ground_height[iy,ix]<130:break
        e=entity('radar',x,y,ground_at(w,x,y),scale=(1,1,1))
        w._entities.append(e);additional.append([x,y])
    native=native_models_world(w)
    native._chart_ground=w._ground_height.copy();native._chart_mat=w.mat_id.copy()
    sites=[[-500.,-450.],*additional]
    emitters=[];suspected=[]
    for i,p in enumerate(sites):
        emitters.append({'id':i,'position':p,'power':float(rng.uniform(.7,1.0)),
            'phase':float(rng.uniform(0,9)),'disabled':False})
        jitter=rng.uniform(-100,100,size=2)
        suspected.append({'center':(np.asarray(p)+jitter).tolist(),'radius':260.,'label':'SAM ?'})
    # One plausible stale intelligence area with no guaranteed emitter.
    suspected.append({'center':[610,580],'radius':235.,'label':'UNCONFIRMED'})
    public={'seed':seed,'bounds':[-1000,1000,-1000,1000],
      'start':[0.,-1870.],'target':[565.,235.], 'egress':[850.,-1500.],
      'suspected':suspected,'chart_note':'CONTOURS 20m · CONTACTS UNCONFIRMED',
      'fictional_rules':'Placeholder game mechanics, not real radar/weapons specifications.'}
    return native,public,emitters


def chart_image(w,path):
    """Backlit paper chart of actual terrain, without precise enemy locations."""
    if isinstance(w,SortieRegion):
        return w.write_chart(path)
    n=1536
    rng=np.random.default_rng(w._seed+135)
    h=w._chart_ground[::-1]
    mat=w._chart_mat[::-1]
    paper=np.empty((n,n,3),np.float32)
    noise=gaussian_filter(rng.normal(size=(n,n)),.55)
    paper[:]=[.76,.69,.50]
    paper+=noise[...,None]*.008
    # Encoded contour ink rather than hillshaded grayscale radar imagery.
    level=np.floor(h/20).astype(np.int16)
    lines=(level!=np.roll(level,1,0))|(level!=np.roll(level,1,1))
    paper[lines]*=.55
    water=w._water_mask[::-1]
    paper[water]=[.38,.51,.50]
    roads=mat==1
    paper[roads]=[.38,.34,.24]
    forest=mat==3
    yy,xx=np.mgrid[:n,:n]
    stipple=forest&(((xx*17+yy*11)%53)<2)
    paper[stipple]=[.40,.43,.29]
    im=Image.fromarray(np.uint8(np.clip(paper,0,1)*255));d=ImageDraw.Draw(im)
    for a in range(0,n,192):
        d.line([(a,0),(a,n)],fill=(143,127,93),width=1)
        d.line([(0,a),(n,a)],fill=(143,127,93),width=1)
    im.save(path)


def selected_world(world,center,extent):
    """Area selection changes measurement geometry; never a fake screen zoom."""
    if isinstance(world,SortieRegion):
        return world.patch(center,extent)
    c=np.asarray(center,dtype=float)
    extent=float(extent)
    if c.shape!=(2,) or not np.isfinite(c).all():raise ValueError('Invalid area center')
    if extent not in (600.,1000.,1600.,2000.):raise ValueError('Unsupported area size')
    half=extent/2
    c=np.clip(c,-1000+half,1000-half)
    if extent==2000. and np.all(c==0):return world,c
    out=copy.copy(world)
    out.N=max(512,int(round(extent/(2000/1536))))
    out.size_m=extent;out.dx=extent/out.N
    lin=np.linspace(-half,half,out.N,dtype=np.float32)
    out.X,out.Y=np.meshgrid(lin,lin)
    x=out.X+c[0];y=out.Y+c[1]
    coords=[(y+1000)/2000*(world.N-1),(x+1000)/2000*(world.N-1)]
    discrete={'mat_id','furrow_az','dihedral_az','mp_height','wall_nx','wall_ny'}
    for key in ARRAY_FIELDS:
        if key in ('X','Y'):continue
        arr=getattr(world,key)
        setattr(out,key,map_coordinates(arr,coords,order=0 if key in discrete else 1,mode='nearest'))
    out.rng=np.random.default_rng();out._initial_rng=copy.deepcopy(world._initial_rng)
    return out,c


def render_patch(world,pose,center,extent,quality,folder,rid,accelerator=None):
    patch_started=time.perf_counter()
    patch,c=selected_world(world,center,extent)
    patch_seconds=time.perf_counter()-patch_started
    pose=[float(v) for v in pose]
    if len(pose)!=3 or not np.isfinite(pose).all():raise ValueError('Invalid aircraft pose')
    if not 100<=pose[2]<=5000:raise ValueError('Invalid game altitude')
    if not isinstance(world,EndlessWorld) and any(abs(v)>10000 for v in pose[:2]):raise ValueError('Aircraft outside prototype region')
    local=[pose[0]-float(c[0]),pose[1]-float(c[1]),pose[2]]
    # Reference-range PSF becomes singular exactly overhead. The cockpit refuses
    # such a request instead of silently fabricating a displaced aircraft.
    if np.hypot(*local[:2])<100:raise ValueError('SCAN INHIBITED · select an area ahead of the aircraft')
    if quality not in ('detail','map','survey'):raise ValueError('Invalid mode')
    samples={'detail':(1800,2000,2.,2.5),'map':(1200,1400,4.,5.),'survey':(720,800,6.,8.)}[quality]
    patch.rng.bit_generator.state=copy.deepcopy(patch._initial_rng)
    cfg=Instrument(name='v7_source_preserving',range_resolution_m=samples[2],azimuth_resolution_m=samples[3],
                   range_window='rectangular',azimuth_window='rectangular',normalize_sampling=True)
    do_measure=measure if accelerator is None else accelerator.measure
    do_image=image_measurements if accelerator is None else accelerator.image
    m=do_measure(patch,tuple(local),n_az=samples[0],n_rg=samples[1])
    _,image,stats=do_image(patch,m,cfg)
    encode_started=time.perf_counter()
    raw=plt.get_cmap('gray')(image,bytes=True)[::-1,:,0].copy()
    file=folder/f'radar_{rid}.r8';tmp=file.with_suffix('.tmp')
    raw.tofile(tmp);os.replace(tmp,file)
    png=folder/f'radar_{rid}.png';Image.fromarray(raw).save(png)
    return {'raw_image':str(file),'image':str(png),'width':raw.shape[1],'height':raw.shape[0],
      'center':c.tolist(),'extent':extent,'pose':pose,'stats':stats,'quality':quality,
      'terrain_seconds':patch_seconds,'encoding_and_write_seconds':time.perf_counter()-encode_started}

class MissionWorker:
    def __init__(self,folder,cache,parent):
        self.folder=Path(folder).resolve();self.folder.mkdir(exist_ok=True,parents=True)
        self.cache=cache;self.parent=parent;self.last=-1;self.world=None;self.seed=None;self.stop=False
        self.chart_stream=ChartStream(self.folder)
        self.accelerator=ParallelRadar(int(os.environ.get('RADAR_NUMERIC_WORKERS','3')))
        for s in (signal.SIGTERM,signal.SIGINT):signal.signal(s,lambda *_:setattr(self,'stop',True))
    def status(self,stage,rid=-1,**data):
        atom_json(self.folder/'status.json',dict(stage=stage,id=rid,pid=os.getpid(),**data))
    def execute(self,req):
        rid=int(req['id']);action=req['action']
        if action=='stop':self.stop=True;return
        if action not in ('prepare','scan'):raise ValueError('Invalid action')
        seed=int(req.get('seed',42))
        if seed<0 or seed>2147483647:raise ValueError('Invalid seed')
        scenario=req.get('scenario','reference')
        if scenario not in ('reference','sortie','endless'):
            raise ValueError('Unknown scenario')
        if self.world is None or seed!=self.seed or scenario!=getattr(self,'scenario',None):
            self.status('generating',rid)
            if scenario=='endless':
                self.world=EndlessWorld(seed)
                self.public=self.world.public_manifest();self.emitters=self.world.emitters()
            elif scenario=='sortie':
                self.world=SortieRegion(seed)
                self.public=self.world.public_manifest()
                self.emitters=self.world.emitters()
            else:
                self.world,self.public,self.emitters=mission_world(seed,self.cache)
            self.seed=seed;self.scenario=scenario
            chart_image(self.world,self.folder/'chart.png')
        if action=='prepare':
            atom_json(self.folder/'mission.json',dict(**self.public,emitters=self.emitters,chart=str(self.folder/'chart.png')))
            self.status('ready',rid,manifest=str(self.folder/'mission.json'));return
        self.status('scanning',rid)
        start=time.perf_counter()
        result=render_patch(self.world,req['pose'],req.get('center',[0,0]),float(req.get('extent',2000)),
                            req.get('quality','detail'),self.folder,rid,accelerator=self.accelerator)
        self.status('complete',rid,**result,wall_seconds=time.perf_counter()-start)
        for pattern in ('radar_*.png','radar_*.r8'):
            files=sorted(self.folder.glob(pattern),key=lambda x:x.stat().st_mtime)
            for f in files[:-5]:f.unlink(missing_ok=True)
    def run(self):
        self.status('idle')
        while not self.stop:
            if self.parent:
                try:os.kill(self.parent,0)
                except ProcessLookupError:break
                except PermissionError:pass
            try:
                worked=False
                if (self.folder/'stop').exists():break
                path=self.folder/'request.json'
                if path.exists():
                    req=json.loads(path.read_text());rid=int(req['id'])
                    if rid>self.last:
                        self.last=rid;worked=True
                        try:self.execute(req)
                        except Exception as e:
                            traceback.print_exc();self.status('error',rid,message=str(e))
            except (OSError,KeyError,ValueError,json.JSONDecodeError):pass
            if not worked:self.chart_stream.poll(self.world)
            time.sleep(.08)
        self.status('stopped',self.last)

def main():
    p=argparse.ArgumentParser();p.add_argument('--session',required=True);p.add_argument('--cache',required=True)
    p.add_argument('--parent',type=int,default=0);p.add_argument('--once')
    a=p.parse_args();folder=Path(a.session);folder.mkdir(exist_ok=True,parents=True)
    with (folder/'worker.log').open('a',buffering=1) as log:
        sys.stdout=log;sys.stderr=log
        w=MissionWorker(folder,a.cache,a.parent)
        try:
            if a.once:w.execute(json.loads(Path(a.once).read_text()))
            else:w.run()
        finally:w.accelerator.close()
if __name__=='__main__':main()
