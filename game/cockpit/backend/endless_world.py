"""Unbounded terrain provider and rolling chart sheets, with bounded RAM/disk work.

Only local image arrays use float32. Geographic coordinates are float64. A rolling
sheet is NOT a mission boundary: the next sheet is generated before its edge arrives.
"""
from __future__ import annotations
import copy, math, time
from collections import OrderedDict
from types import SimpleNamespace
from pathlib import Path
import numpy as np
from PIL import Image
from scipy.ndimage import gaussian_filter
from sortie_region import SortieRegion
from endless_terrain import fields, noise
from endless_features import FeatureCells
from region_features import add_features
from approved_renderer import g

CHART_WIDTH=16000.0
CHART_HEIGHT=20000.0
CHART_STEP=10.0
STREAM_STEP=2000.0
SHEET_FORWARD=4000.0

class EndlessWorld(SortieRegion):
    def __init__(self,seed):
        self.seed=int(seed)
        if not 0<=self.seed<=2147483647:raise ValueError('Invalid seed')
        self._patches=OrderedDict();self.features=FeatureCells(self.seed)
        self.start=[-1800.,-7600.]
        self._initial_sheet=self.sheet_manifest(self.start)
        self.bounds=tuple(self._initial_sheet['bounds'])

    def ground(self,x,y):return fields(x,y,self.seed)

    def public_manifest(self):
        local=self.local_manifest(self.start)
        local.pop('emitters',None)
        return dict(**local,
            start=self.start,target=self.start,egress=self.start,heading=0.0,
            initial_scan_center=[self.start[0],self.start[1]+2000],initial_scan_extent=1600.,
            chart_note='OPEN FLIGHT / PILOT HOLDS YOUR COMMANDED HEADING',
            world_version='endless-v1',suggested_routes={},checkpoints=[])

    def emitters(self):return self._emitters(self._initial_sheet['bounds'])

    def _emitters(self,bounds):
        return [{k:copy.deepcopy(v) for k,v in r.items() if k!='layout_angle'} for r in self.features.query(bounds)['sites']]

    @staticmethod
    def sheet_manifest(center):
        c=np.asarray(center,dtype=np.float64)
        if c.shape!=(2,) or not np.isfinite(c).all():raise ValueError('Invalid geographic position')
        sx=math.floor(float(c[0])/STREAM_STEP)*STREAM_STEP
        sy=math.floor(float(c[1])/STREAM_STEP)*STREAM_STEP+SHEET_FORWARD
        return {'bounds':[sx-CHART_WIDTH/2,sx+CHART_WIDTH/2,sy-CHART_HEIGHT/2,sy+CHART_HEIGHT/2],
                'stream_step_m':STREAM_STEP,'sheet_forward_m':SHEET_FORWARD,
                'sheet_center':[sx,sy],'sheet_key':f'{int(sx)}:{int(sy)}','endless':True}

    def local_manifest(self,center):
        sheet=self.sheet_manifest(center)
        data=self.features.query(sheet['bounds'])
        return dict(**sheet,seed=self.seed,scenario='endless',suspected=copy.deepcopy(data['suspected']),
            landmarks=[{'position':[b['x'],b['y']],'label':'BRIDGE'} for b in data['bridges']],
            emitters=self._emitters(sheet['bounds']))

    def clamp_center(self,center,extent):
        c=np.asarray(center,dtype=np.float64)
        if c.shape!=(2,) or not np.isfinite(c).all():raise ValueError('Invalid area center')
        if not 400<=float(extent)<=4000:raise ValueError('Scan width must be 400..4000m')
        return c.copy()  # No clamp, finite mission boundary, or wraparound.

    def patch(self,center,extent):
        start=time.perf_counter();c=self.clamp_center(center,extent)
        key=(float(c[0]),float(c[1]),float(extent))
        if key in self._patches:
            self._patches.move_to_end(key);return self._patches[key],c
        w=g.RadarTestWorldV6_5.__new__(g.RadarTestWorldV6_5)
        w.size_m=float(extent);w.N=min(1536,max(512,int(round(extent/(2000/1536)))))
        w.dx=w.size_m/w.N
        q=np.linspace(-extent/2,extent/2,w.N,dtype=np.float32)
        w.X,w.Y=np.meshgrid(q,q)
        w._world_center=c.tolist();w._region=self
        w._global_x=w.X.astype(np.float64)+c[0];w._global_y=w.Y.astype(np.float64)+c[1]
        data=self.features.query([c[0]-extent/2,c[0]+extent/2,c[1]-extent/2,c[1]+extent/2])
        f=self.ground(w._global_x,w._global_y)
        w._ground_height=f['ground'];w._water_mask=f['water'];w.mat_id=f['mat']
        w.height=(f['ground']+f['canopy']).astype(np.float32)
        w.soil_rough=f['soil_rough'];w.furrow_az=f['furrow_az'];w.furrow_str=f['furrow_str']
        for name in ('dihedral_str','dihedral_az','wall_nx','wall_ny','trihedral_str','mp_height','mp_bounce2','mp_bounce3'):
            setattr(w,name,np.zeros((w.N,w.N),np.float32))
        w._feature_bases={}
        points=[(r['x'],r['y']) for r in data['warehouses']]
        for s in data['sites']:
            x,y=s['position'];points.append((x,y))
            points.extend((x+132*math.cos(s['layout_angle']+i*math.pi/3),y+132*math.sin(s['layout_angle']+i*math.pi/3)) for i in range(6))
        if points:
            xy=np.asarray(points,np.float64);heights=fields(xy[:,0],xy[:,1],self.seed,False)['ground']
            w._feature_bases=dict(zip(points,map(float,heights)))
        smooth=gaussian_filter(w.height,1.2)
        add_features(w,SimpleNamespace(**data))
        w.smooth_h_for_normals=smooth;w._compute_normals()
        w.rng=np.random.default_rng(self.seed+42);w._initial_rng=copy.deepcopy(w.rng.bit_generator.state)
        w._generation_s=time.perf_counter()-start
        self._patches[key]=w
        while len(self._patches)>3:self._patches.popitem(last=False)
        return w,c

    def chart_pixels(self,bounds):
        x0,x1,y0,y1=map(float,bounds)
        n=round((x1-x0)/CHART_STEP);m=round((y1-y0)/CHART_STEP)
        # Pixel-center sampling on an absolute grid. Overlapping sheets have
        # identical terrain, contours and grain, not newly seeded 'paper noise'.
        x=x0+(np.arange(n)+.5)*CHART_STEP;y=y1-(np.arange(m)+.5)*CHART_STEP
        X,Y=np.meshgrid(x,y)
        f=fields(X,Y,self.seed,False)
        paper=np.empty((m,n,3),np.float32);paper[:]=[.76,.69,.50]
        paper+=(noise(X,Y,25,self.seed+866)-.5)[...,None]*.017
        levels=np.floor(f['ground']/20).astype(np.int16)
        # Fixed world sample neighbour ensures no sheet-edge contour discontinuity.
        left=fields(np.full(m,x0-CHART_STEP/2),y,self.seed,False)['ground']
        above=fields(x,np.full(n,y1+CHART_STEP/2),self.seed,False)['ground']
        lines=levels!=np.column_stack([np.floor(left/20).astype(np.int16),levels[:,:-1]])
        lines|=levels!=np.vstack([np.floor(above/20).astype(np.int16),levels[:-1,:]])
        paper[lines]*=.70;paper[f['water']]=[.38,.51,.50];paper[f['mat']==1]=[.36,.32,.23]
        cellx=np.floor(X/CHART_STEP).astype(np.int64);celly=np.floor(Y/CHART_STEP).astype(np.int64)
        stipple=(f['mat']==3)&(((cellx*17+celly*11)%79)<2);paper[stipple]=[.4,.43,.29]
        grid=(np.mod(X,1000)<CHART_STEP)|(np.mod(Y,1000)<CHART_STEP)
        paper[grid]*=.85
        return np.uint8(np.clip(paper,0,1)*255)

    def write_chart(self,path,center=None):
        manifest=self.local_manifest(self.start if center is None else center)
        pixels=self.chart_pixels(manifest['bounds'])
        Image.fromarray(pixels).save(path)
        return manifest
