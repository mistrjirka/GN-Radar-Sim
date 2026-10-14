"""Deterministic feature cells: each geographic cell owns its sites/compounds.

Small cell metadata is bounded in memory. Hash IDs fit exactly in JSON/Godot
integers (below 2**52). Terrain/radar/query order never determines placement.
"""
from collections import OrderedDict
import hashlib, math
import numpy as np
from endless_terrain import fields, river_center, crossing_y

CELL=4096.0

class FeatureCells:
    def __init__(self,seed):
        self.seed=seed;self.cache=OrderedDict()

    def cell(self,ix,iy):
        key=(int(ix),int(iy))
        if key in self.cache:
            self.cache.move_to_end(key);return self.cache[key]
        digest=hashlib.blake2b(f'{self.seed}:{ix}:{iy}:features-v1'.encode(),digest_size=16).digest()
        rng=np.random.default_rng(int.from_bytes(digest,'little'))
        record={'sites':[],'warehouses':[],'suspected':[]}
        ox=ix*CELL;oy=iy*CELL
        # One optional emplacement, placed on land of suitable local slope.
        if rng.random()<.52:
            for _ in range(12):
                x=ox+rng.uniform(500,CELL-500);y=oy+rng.uniform(500,CELL-500)
                dx=np.array([0,-150,150,0,0]);dy=np.array([0,0,0,-150,150])
                terrain=fields(x+dx,y+dy,self.seed,False)
                if not terrain['water'].any() and np.ptp(terrain['ground'])<70:break
            else:x=y=None
            if x is not None:
                id_=int.from_bytes(digest[:7],'little')&((1<<52)-1)
                site=dict(id=id_,position=[float(x),float(y)],power=float(rng.uniform(.70,1)),
                          phase=float(rng.uniform(0,9)),disabled=False,layout_angle=float(rng.uniform(0,math.pi)))
                record['sites'].append(site)
                jitter=rng.uniform(-280,280,2)
                record['suspected'].append(dict(center=[x+float(jitter[0]),y+float(jitter[1])],radius=610.,label='SAM ?'))
        if rng.random()<.16:
            record['suspected'].append(dict(center=[ox+float(rng.uniform(500,CELL-500)),oy+float(rng.uniform(500,CELL-500))],radius=570.,label='UNCONFIRMED'))
        if rng.random()<.72:
            x=ox+rng.uniform(500,CELL-700);y=oy+rng.uniform(500,CELL-700)
            terrain=fields(np.array([x]),np.array([y]),self.seed,False)
            if not terrain['water'][0]:
                angle=float(rng.choice([0,.2,-.3]))
                for k in range(int(rng.integers(2,5))):
                    record['warehouses'].append(dict(x=float(x+110*(k%2)),y=float(y+85*(k//2)),
                        length=float(rng.choice([54,72,84])),width=35.,angle=angle,height=12.,ridge=3.))
        self.cache[key]=record
        while len(self.cache)>96:self.cache.popitem(last=False)
        return record

    def query(self,bounds):
        x0,x1,y0,y1=bounds
        out={'sites':[],'warehouses':[],'suspected':[],'bridges':[]}
        # Margin includes footprints whose owner-cell lies just outside the query.
        for iy in range(math.floor((y0-300)/CELL),math.floor((y1+300)/CELL)+1):
            for ix in range(math.floor((x0-300)/CELL),math.floor((x1+300)/CELL)+1):
                data=self.cell(ix,iy)
                for name in ('sites','warehouses','suspected'):
                    for r in data[name]:
                        x,y=r.get('position',r.get('center',[r.get('x'),r.get('y')]))
                        margin=800 if name=='suspected' else 220
                        if x0-margin<=x<=x1+margin and y0-margin<=y<=y1+margin:out[name].append(r)
        for band in range(math.floor((x0-1000)/10000),math.floor((x1+1000)/10000)+2):
            for row in range(math.floor((y0-600)/3500),math.floor((y1+600)/3500)+1):
                y=float(crossing_y(row,self.seed));x=float(river_center(y,band,self.seed))
                if x0-180<x<x1+180 and y0-50<y<y1+50:
                    out['bridges'].append(dict(x=x,y=y,length=175.,width=12.))
        return out
