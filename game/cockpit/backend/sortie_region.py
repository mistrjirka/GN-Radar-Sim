"""Finite 12 x 18 km seeded sortie region, sampled only where radar is requested.

This replaces the short test patch in sortie mode, not the approved renderer.
Global coordinate noise and feature records make overlap identical across scans.
World-space metres are never stretched to pretend the old 2 km scene is larger.
"""
from __future__ import annotations
import copy, hashlib, json, math, time
from collections import OrderedDict
from pathlib import Path
import numpy as np
from scipy.ndimage import gaussian_filter
from PIL import Image,ImageDraw
from region_noise import land_fields, river_x, noise
from region_features import add_features
from approved_renderer import g

VERSION='sortie-region-1'
BOUNDS=(-6000.,6000.,-9000.,9000.)
SCAN_EXTENTS=(600.,1000.,1600.,2000.,3200.,4000.)

class SortieRegion:
    """Small world descriptor + bounded three-patch memory cache, not a fine atlas."""
    def __init__(self,seed):
        self.seed=int(seed)
        if not 0<=self.seed<=2147483647:raise ValueError('Invalid seed')
        self.bounds=BOUNDS;self._patches=OrderedDict()
        rng=np.random.default_rng(self.seed+54199)
        self.start=[-1800.,-7600.]
        self.target=[float(rng.uniform(1050,2300)),float(rng.uniform(4800,5900))]
        self.egress=[-1700.,-7600.]
        self.sites=[];self.suspected=[]
        for i,(x,y) in enumerate([(-1700,-4200),(1500,-3900),(-2300,-900),(1850,300),
                                   (-1400,2500),(1300,3550),(3200,5500)]):
            p=[x+float(rng.uniform(-450,450)),y+float(rng.uniform(-350,350))]
            self.sites.append(dict(id=i,position=p,power=float(rng.uniform(.72,1.)),
                phase=float(rng.uniform(0,9)),disabled=False,layout_angle=float(rng.uniform(0,math.pi))))
            offset=rng.uniform(-310,310,2)
            self.suspected.append(dict(center=(np.array(p)+offset).tolist(),radius=620.,label='SAM ?'))
        # Stale intelligence is explicitly not a promise of an emitting contact.
        for x,y in [(-3550,4600),(3350,-1900)]:
            self.suspected.append(dict(center=[x+float(rng.uniform(-220,220)),y],radius=580.,label='UNCONFIRMED'))
        self.bridges=[dict(x=float(river_x(np.array(y),seed)),y=float(y),length=165.,width=12.)
                      for y in (-4900,-1400,2300,5500)]
        self.warehouses=[]
        for village in [(-2800,-5300),(2100,-2000),(-2500,1500),self.target]:
            for k in range(3):
                self.warehouses.append(dict(x=float(village[0]+(k%2)*110),y=float(village[1]+(k//2)*90),
                    length=84.,width=40.,angle=float(rng.choice([0,.18,-.32])),height=14.,ridge=3.))
        # Resolve elevations once from world coordinates, not from the pixels
        # present in a particular scan crop. A half-visible roof must not move.
        points=[(r['x'],r['y']) for r in self.warehouses]
        for site in self.sites:
            x,y=site['position'];points.append((x,y))
            for k in range(6):
                a=site['layout_angle']+k*math.pi/3
                points.append((x+132*math.cos(a),y+132*math.sin(a)))
        xy=np.asarray(points,dtype=np.float32)
        base=land_fields(xy[:,0],xy[:,1],self.seed)['ground']
        self.feature_bases={p:float(h) for p,h in zip(points,base)}
        # Candidate routes are intelligence-based pencilled suggestions, not an
        # omniscient path solver. Both encounter uncertainty and cost flight time.
        self.routes={
          'western':[[ -3350.,-4900.],[-3850.,-900.],[-3500.,3200.],[-1600.,6000.],self.target],
          'direct':[[ -1600.,-3400.],[-750.,800.],self.target],
        }
        self.landmarks=[{'position':[b['x'],b['y']],'label':'BRIDGE '+str(i+1)} for i,b in enumerate(self.bridges)]
        self.checkpoints=[{'name':'INBOUND','position':[-1500.,-4100.],'radius':2400.},
                          {'name':'RIVER LINE','position':[0.,800.],'radius':5000.},
                          {'name':'OBJECTIVE APPROACH','position':self.target,'radius':2000.}]

    def public_manifest(self):
        return dict(seed=self.seed,scenario='sortie',bounds=list(self.bounds),start=self.start,target=self.target,
            egress=self.egress,suspected=copy.deepcopy(self.suspected),landmarks=copy.deepcopy(self.landmarks),
            suggested_routes=copy.deepcopy(self.routes),checkpoints=copy.deepcopy(self.checkpoints),
            initial_scan_center=[-1500.,-4600.],initial_scan_extent=2000.,
            chart_note='CONTOURS 20m · INTELLIGENCE UNCONFIRMED',
            map_size_km=[12,18],world_version=VERSION,
            fictional_rules='Prototype sortie scale, timings and threats; no real weapons performance.')

    def emitters(self):
        return [{k:copy.deepcopy(v) for k,v in r.items() if k!='layout_angle'} for r in self.sites]

    def ground(self,x,y):
        fields=land_fields(x,y,self.seed)
        X=np.asarray(x);Y=np.asarray(y)
        # Civilian valley road and cross-country links, present in both views.
        trunk=(abs(X-(river_x(Y,self.seed)-240))<4.5)&(~fields['water'])
        road=trunk
        for b in self.bridges:
            road=road|((abs(Y-b['y'])<4)&(abs(X)<3600)&(~fields['water']))
        fields['mat'][road]=1;fields['canopy'][road]=0
        return fields

    def clamp_center(self,center,extent):
        c=np.asarray(center,dtype=np.float64)
        extent=float(extent)
        if c.shape!=(2,) or not np.isfinite(c).all():raise ValueError('Invalid scan center')
        if extent not in SCAN_EXTENTS:raise ValueError('Unsupported area size')
        b=self.bounds;h=extent*.5
        return np.array([np.clip(c[0],b[0]+h,b[1]-h),np.clip(c[1],b[2]+h,b[3]-h)])

    def patch(self,center,extent):
        start=time.perf_counter();c=self.clamp_center(center,extent)
        key=(float(c[0]),float(c[1]),float(extent))
        if key in self._patches:
            self._patches.move_to_end(key)
            w=self._patches[key];w._generation_s=0.;return w,c
        w=g.RadarTestWorldV6_5.__new__(g.RadarTestWorldV6_5)
        w.size_m=float(extent);w.N=min(1536,max(512,int(round(extent/(2000/1536)))))
        w.dx=w.size_m/w.N
        q=np.linspace(-extent/2,extent/2,w.N,dtype=np.float32)
        w.X,w.Y=np.meshgrid(q,q)
        w._world_center=c.tolist()
        w._feature_bases=self.feature_bases
        w._region=self
        # Offset arithmetic stays float32, matching the approved source fields.
        w._global_x=w.X+np.float32(c[0]);w._global_y=w.Y+np.float32(c[1])
        f=self.ground(w._global_x,w._global_y)
        w._ground_height=f['ground'];w._water_mask=f['water'];w.mat_id=f['mat']
        w.height=(f['ground']+f['canopy']).astype(np.float32)
        w.soil_rough=f['soil_rough'];w.furrow_az=f['furrow_az'];w.furrow_str=f['furrow_str']
        for field in ('dihedral_str','dihedral_az','wall_nx','wall_ny','trihedral_str','mp_height','mp_bounce2','mp_bounce3'):
            setattr(w,field,np.zeros((w.N,w.N),np.float32))
        # Normals use stable geographic microrelief, not the rasterized vertical
        # walls; those retain their own outward-facing facet fields.
        smooth=gaussian_filter(w.height,1.2)
        add_features(w,self)
        w.smooth_h_for_normals=smooth
        w._compute_normals()
        w.rng=np.random.default_rng(self.seed+42)
        w._initial_rng=copy.deepcopy(w.rng.bit_generator.state)
        w._generation_s=time.perf_counter()-start
        self._patches[key]=w
        while len(self._patches)>3:self._patches.popitem(last=False)
        return w,c

    def write_chart(self,path):
        """One finite paper atlas; enemy geometry never enters chart pixels."""
        n=1536;m=2304
        x=np.linspace(self.bounds[0],self.bounds[1],n,dtype=np.float32)
        y=np.linspace(self.bounds[3],self.bounds[2],m,dtype=np.float32)
        X,Y=np.meshgrid(x,y)
        f=self.ground(X,Y)
        paper=np.empty((m,n,3),np.float32);paper[:]=[.76,.69,.50]
        grain=noise(X,Y,25,self.seed+866)-.5
        paper+=grain[...,None]*.017
        contour=np.floor(f['ground']/20).astype(np.int16)
        lines=np.zeros((m,n),bool)
        lines[1:]|=contour[1:]!=contour[:-1];lines[:,1:]|=contour[:,1:]!=contour[:,:-1]
        paper[lines]*=.70
        paper[f['water']]=[.38,.51,.50];paper[f['mat']==1]=[.38,.34,.24]
        yy,xx=np.mgrid[:m,:n]
        stipple=(f['mat']==3)&(((xx*17+yy*11)%79)<2)
        paper[stipple]=[.4,.43,.29]
        image=Image.fromarray(np.uint8(np.clip(paper,0,1)*255))
        draw=ImageDraw.Draw(image)
        for xgrid in range(-6000,6001,1000):
            px=(xgrid+6000)/12000*n;draw.line((px,0,px,m),fill=(135,119,85),width=1)
        for ygrid in range(-9000,9001,1000):
            py=(9000-ygrid)/18000*m;draw.line((0,py,n,py),fill=(135,119,85),width=1)
        # Civilian landmarks are charted; the emitter position list is not used.
        for b in self.bridges:
            px=(b['x']+6000)/12000*n;py=(9000-b['y'])/18000*m
            draw.line((px-12,py,px+12,py),fill=(70,63,48),width=3)
        image.save(path)
        return {'width':n,'height':m,'world_bounds':list(self.bounds)}
