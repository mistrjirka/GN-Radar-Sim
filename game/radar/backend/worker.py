#!/usr/bin/env python3
"""Private, non-blocking Godot radar worker; file IPC, no servers or API keys.

Godot owns one worker and one request at a time. Requests, state, images and
manifests are published atomically. A scan uses a frozen pose and world version;
the UI keeps its previous completed scan while computation runs.
"""
from __future__ import annotations
import os
os.environ.setdefault('OPENBLAS_NUM_THREADS','1')
os.environ.setdefault('OMP_NUM_THREADS','4')
import argparse, copy, json, math, signal, sys, time, traceback
from pathlib import Path
import numpy as np
from PIL import Image
from scene_world import load_scene, native_models_world, export_scene, atom_json, ROOT
from approved_renderer import Instrument, measure, image_measurements, save

PRESETS={
 'survey':dict(range_resolution_m=6.,azimuth_resolution_m=8.,n_az=720,n_rg=800),
 'map':dict(range_resolution_m=4.,azimuth_resolution_m=5.,n_az=1200,n_rg=1400),
 'detail':dict(range_resolution_m=2.,azimuth_resolution_m=2.5,n_az=1800,n_rg=2000),
}
FIXTURE=ROOT.parent/'reference'/'approved_valley_south.png'

def request_config(req):
    quality=req.get('quality','detail')
    if quality not in PRESETS:raise ValueError('quality must be survey, map or detail')
    p=PRESETS[quality]
    cfg=Instrument(name='v7_source_preserving',range_resolution_m=p['range_resolution_m'],
         azimuth_resolution_m=p['azimuth_resolution_m'],range_window='rectangular',
         azimuth_window='rectangular',normalize_sampling=True)
    return cfg,p


def render(world,pose,quality,path):
    world.rng.bit_generator.state=copy.deepcopy(world._initial_rng)
    cfg,p=request_config({'quality':quality})
    # Python scalars preserve the approved NumPy casting behavior. NumPy float64
    # pose scalars would silently promote intermediate float32 range fields.
    measurement=measure(world,tuple(float(v) for v in pose),n_az=p['n_az'],n_rg=p['n_rg'])
    power,image,stats=image_measurements(world,measurement,cfg)
    path=Path(path);temporary=path.with_name(path.stem+'.tmp.png')
    save(temporary,image);os.replace(temporary,path)
    return image,stats


def png_diff(a,b):
    aa=np.asarray(Image.open(a).convert('L'),dtype=np.float32)
    bb=np.asarray(Image.open(b).convert('L'),dtype=np.float32)
    if aa.shape!=bb.shape:return {'match':False,'reason':'size mismatch','size_a':list(aa.shape),'size_b':list(bb.shape)}
    delta=np.abs(aa-bb)
    return {'match':bool(delta.max()==0),'max_pixel_error':float(delta.max()),
            'mean_pixel_error':float(delta.mean()),'changed_pixels':int(np.count_nonzero(delta)),
            'pixel_count':int(delta.size),'mse':float(np.mean(delta**2))}

class Worker:
    def __init__(self,folder,cache,parent=0):
        self.folder=Path(folder).resolve();self.folder.mkdir(parents=True,exist_ok=True)
        self.cache=Path(cache).resolve();self.parent=parent
        self.world=None;self.native=None;self.world_key=None;self.stopping=False
        self.last_id=-1;self.started=time.time()
        for sig in (signal.SIGTERM,signal.SIGINT):signal.signal(sig,lambda *_:setattr(self,'stopping',True))

    def publish(self,stage,request_id=-1,**fields):
        atom_json(self.folder/'status.json',dict(protocol=1,pid=os.getpid(),stage=stage,
                  id=request_id,updated_unix=time.time(),**fields))

    def ensure_world(self,req):
        seed=int(req.get('seed',42));scenario=req.get('scenario','valley')
        key=(seed,scenario)
        if key!=self.world_key:
            self.publish('generating',int(req['id']),message='Building shared terrain and radar fields')
            self.world=load_scene(self.cache,seed,scenario)
            self.native=native_models_world(self.world)
            self.world_key=key
        return self.world

    def execute(self,req):
        rid=int(req['id']);action=req.get('action')
        if action=='stop':self.stopping=True;return
        if action not in ('prepare','scan','validate'):raise ValueError('Unknown action')
        self.ensure_world(req)
        models=req.get('models','preferred')
        if models not in ('preferred','reference'):raise ValueError('Unknown model mode')
        manifest=export_scene(self.native if models=='preferred' else self.world,self.folder/'world',models) if action in ('prepare','validate') else None
        if action=='prepare':
            self.publish('ready',rid,manifest=str(self.folder/'world'/'manifest.json'),
                         seed=self.world._seed,scenario=self.world._scenario,model_mode=models)
            return
        quality=req.get('quality','detail');request_config(req)
        pose=np.asarray(req.get('pose',[0,-2400,1450]),dtype=float)
        if pose.shape!=(3,) or not np.isfinite(pose).all():raise ValueError('Invalid radar pose')
        if not 100<=pose[2]<=6000:raise ValueError('Radar altitude must be 100..6000m')
        if not 1200<=np.hypot(pose[0],pose[1])<=10000:raise ValueError('Prototype radar must remain 1.2..10km from map center')
        self.publish('scanning',rid,message='Calculating radar returns',pose=pose.tolist(),quality=quality)
        start=time.perf_counter()
        validation=None
        if action=='validate':
            pose=np.array([0.,-2400.,1450.]);quality='detail'
            refpath=self.folder/f'reference_{rid}.png'
            _,refstats=render(self.world,pose,quality,refpath)
            validation={'reference_render':str(refpath),'reference_stats':refstats,
                        'fixture':str(FIXTURE) if self.world_key==(42,'valley') else None}
            if self.world_key==(42,'valley'):
                validation['regression']=png_diff(refpath,FIXTURE)
            else:
                validation['regression']={'match':None,'reason':'No historic approved pixel fixture for this seed/layout; geometry replay only.'}
        path=self.folder/f'scan_{rid}.png'
        selected=self.native if models=='preferred' else self.world
        displayed,stats=render(selected,pose,quality,path)
        # Raw luma avoids PNG decoding on Godot's main thread. Same grayscale LUT
        # and north-up row order as the artifact PNG; not a second tone mapper.
        from approved_renderer import plt
        raw_bytes=plt.get_cmap('gray')(displayed,bytes=True)[::-1,:,0].copy()
        rawpath=path.with_suffix('.r8');rawtmp=rawpath.with_suffix('.tmp')
        raw_bytes.tofile(rawtmp);os.replace(rawtmp,rawpath)
        if validation:
            validation['model_change']=png_diff(path,validation['reference_render'])
            A=np.asarray(Image.open(path).convert('L')).astype(float)
            B=np.asarray(Image.open(validation['reference_render']).convert('L')).astype(float)
            diff=np.uint8(np.clip(np.abs(A-B)*4,0,255))
            diffpath=self.folder/f'difference_{rid}.png';Image.fromarray(diff).save(diffpath)
            validation['difference_image']=str(diffpath)
            validation['geometry']={'launchers':6,'entities':len(self.world._entities),
                'shared_coordinate_mapping':'Godot(x,elevation,-north)',
                'radar_changed_surface_cells':int(self.native._changed_mask.sum()),
                'optical_models':'v3 native primitive designs, shared manifest / radar top-surface rasterization',
                'limitation':'Grid and statistical facet proxies; sub-grid wheels/lattice members are not independently electromagnetic.'}
            atom_json(self.folder/f'validation_{rid}.json',validation)
        self.publish('complete',rid,image=str(path),raw_image=str(rawpath),width=int(displayed.shape[1]),height=int(displayed.shape[0]),pose=pose.tolist(),quality=quality,model_mode=models,
          seed=self.world._seed,scenario=self.world._scenario,stats=stats,validation=validation,
          wall_seconds=time.perf_counter()-start,completed_unix=time.time())
        # Bound transient storage; no source files or references are removed.
        for pattern in ('scan_*.png','scan_*.r8','difference_*.png','reference_*.png','validation_*.json'):
            old=sorted(self.folder.glob(pattern),key=lambda p:p.stat().st_mtime)
            for p in old[:-8]:p.unlink(missing_ok=True)

    def run(self):
        self.publish('idle')
        while not self.stopping:
            if self.parent:
                try:os.kill(self.parent,0)
                except ProcessLookupError:break
                except PermissionError:pass
            if (self.folder/'stop').exists():break
            reqpath=self.folder/'request.json'
            try:
                if reqpath.exists():
                    req=json.loads(reqpath.read_text());rid=int(req['id'])
                    if rid>self.last_id:
                        self.last_id=rid
                        try:self.execute(req)
                        except Exception as e:
                            traceback.print_exc()
                            self.publish('error',rid,message=str(e),log=str(self.folder/'worker.log'))
            except (json.JSONDecodeError,OSError,KeyError,ValueError) as e:
                print('Invalid/incomplete request:',e,flush=True)
            time.sleep(.08)
        self.publish('stopped',self.last_id)


def main():
    p=argparse.ArgumentParser();p.add_argument('--session',required=True)
    p.add_argument('--cache',default=str(ROOT/'cache'));p.add_argument('--parent',type=int,default=0)
    p.add_argument('--once',help='Execute a request JSON file and exit (tests)')
    a=p.parse_args();folder=Path(a.session);folder.mkdir(parents=True,exist_ok=True)
    log=(folder/'worker.log').open('a',buffering=1)
    sys.stdout=log;sys.stderr=log
    try:
        w=Worker(folder,a.cache,a.parent)
        if a.once:w.execute(json.loads(Path(a.once).read_text()))
        else:w.run()
    except Exception:
        traceback.print_exc();raise
if __name__=='__main__':main()
