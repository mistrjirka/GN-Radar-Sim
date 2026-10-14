#!/usr/bin/env python3
"""Fictional ground-mapping radar scene: bridge, river, 6-vehicle radar site, warehouses.

No target-class brightness enhancement is applied to image pixels.
All visible features are represented as 3D material footprints plus discrete
stationary scattering facets. Geometric facets use the same response law
for bridges, structures, vehicles and warehouses. Radial arrangement is
purely a test-scene aesthetic choice, not a real installation layout.
"""
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"v2"))
import numpy as np
from scipy import ndimage as ndi
class Scene:
    def _sample_height(self,x,y):
        return self._sample_array(self.height,x,y)
    def _sample_array(self,arr,x,y,order=1):
        ix=(np.asarray(x)-float(self.x[0]))/float(self.x[1]-self.x[0])
        iy=(np.asarray(y)-float(self.y[0]))/float(self.y[1]-self.y[0])
        return ndi.map_coordinates(arr,[iy,ix],order=order,mode="nearest")

class GroundRadarScene(Scene):
    def __init__(self,seed=112788,n_ground=190000,nx=510,ny=620):
        self.rng=np.random.default_rng(seed)
        self.x=np.linspace(-320,320,nx,dtype=np.float32)
        self.y=np.linspace(790,1580,ny,dtype=np.float32)
        X,Y=np.meshgrid(self.x,self.y,indexing="xy")
        self.xx,self.yy=X,Y
        n=ndi.gaussian_filter(self.rng.standard_normal(X.shape),sigma=9)
        n=n/(n.std()+1e-9)
        hills=(58*np.exp(-.5*((X-290)/100)**2-.5*((Y-1480)/100)**2)
               +40*np.exp(-.5*((X+290)/130)**2-.5*((Y-1500)/140)**2)
               +19*np.exp(-.5*((X-225)/130)**2-.5*((Y-1360)/110)**2))
        H=np.maximum(4.5+2.15*n+hills,0.7)
        mat=np.zeros_like(H,dtype=np.uint8)
        river_y=1240+37*np.sin(X/90)+14*np.sin(X/23)
        self.river=abs(Y-river_y)<(44+3*np.sin(X/50)**2)
        H[self.river]=1.3
        mat[self.river]=1
        self.forest=(~self.river)&(Y>1360)&((np.sin(X/35)+np.cos(Y/48)
                       +ndi.gaussian_filter(self.rng.normal(size=H.shape),12)*5.5)>.36)
        mat[self.forest]=2
        # River banks are physically rough (bright), even where water is very dark.
        water_boundary=ndi.binary_dilation(self.river,iterations=3)&~self.river
        mat[water_boundary]=3
        # Road leading over the river bridge, toward compound and warehouses.
        bridge_x=-170
        bridge_y=float(1240+37*np.sin(bridge_x/90)+14*np.sin(bridge_x/23))
        roads=((np.abs(X+170)<5)&(Y<bridge_y+95)&(Y>1090))|(
                (np.abs(Y-1106)<4)&(X>-174)&(X<245))
        mat[roads & ~self.river]=3
        self.bridge_data=[(bridge_x,bridge_y,True)]
        self.bridge_mask=(np.abs(X-bridge_x)<9)&(np.abs(Y-bridge_y)<101)
        H[self.bridge_mask]=13.
        mat[self.bridge_mask]=5  # concrete deck; metal rails remain discrete scatterers
        self.bridge_box=(-224,-116,bridge_y-130,bridge_y+130)
        # Smoother clearing from altered land cover and a prepared surface,
        # not a radar-specific 'target' mask or drawn-on label.
        cx,cy=-55,1015
        self.central_xy=(cx,cy)
        clearing=((X-cx)/140)**4+((Y-cy)/133)**4<=1
        self.clearing=clearing
        H[clearing]=np.minimum(H[clearing],6.)
        mat[clearing]=3
        # Real concrete vehicle pads. 6 evenly spaced placements are fictional.
        self.launchers=[]
        for i in range(6):
            theta=np.pi/6+i*np.pi/3
            px=cx+77*np.cos(theta)
            py=cy+77*np.sin(theta)
            # Long axis follows radial placement. Symmetrical plan, no real-world layout.
            self.launchers.append((float(px),float(py),float(theta)))
        def mask_rect(px,py,length,width,angle):
            u=(X-px)*np.cos(angle)+(Y-py)*np.sin(angle)
            v=-(X-px)*np.sin(angle)+(Y-py)*np.cos(angle)
            return (np.abs(u)<=length/2)&(np.abs(v)<=width/2)
        self.rects=[]
        def rectangle(px,py,L,W,theta,height,material):
            m=mask_rect(px,py,L,W,theta)
            H[m]=height
            mat[m]=material
            self.rects.append((px,py,L,W,theta,height,material))
        # Pad surface extends beyond vehicles. Launchers are metallic rectangular platforms.
        for px,py,theta in self.launchers:
            pad=mask_rect(px,py,36,23,theta)
            H[pad]=np.maximum(H[pad],6.)
            mat[pad]=5
            rectangle(px,py,26,8,theta,10.5,6)
            # Raised canister set nearer one end of each launcher; metallic.
            px2=px+6*np.cos(theta)
            py2=py+6*np.sin(theta)
            rectangle(px2,py2,11,5,theta,13.0,6)
        # Central command hut, mast plus low equipment near center.
        rectangle(cx,cy,18,16,0,14.5,4)
        rectangle(cx-13,cy+20,11,8,.2,7,6)
        # Warehouses on the eastern approach, coherent concrete/steel roof returns.
        self.warehouses=[]
        for px,py,L,W,h in ((154,945,58,32,17),(236,945,50,32,16),
                             (156,1030,62,34,19),(239,1040,50,30,15),
                             (174,1118,76,30,14)):
            self.warehouses.append((px,py,L,W,h))
            service=mask_rect(px,py,L+10,W+8,0)
            H[service]=np.maximum(H[service],5.)
            mat[service]=5
            rectangle(px,py,L,W,0,h,4)
        self.height=H.astype(np.float32)
        self.material=mat
        self.water=self.river
        self.buildings=[(px,py) for px,py,*rest in self.warehouses]
        self.vehicles=[(px,py,26,8,6) for px,py,theta in self.launchers]
        self.site_box=(-206,92,862,1176)
        self.warehouse_box=(105,294,882,1178)
        self.bridge_box=(-232,-105,bridge_y-128,bridge_y+128)
        # Layers of sampling support a coherent ground-backscatter field.
        self.build_scatterers(n_ground)
        self.labels=dict(
            radar_center=[cx,cy],
            launcher_centers=[[round(px,2),round(py,2)] for px,py,_ in self.launchers],
            warehouses=[[v[0],v[1],v[2],v[3]] for v in self.warehouses],
            bridge_x=bridge_x,river_center_y_at_bridge=bridge_y)
    def build_scatterers(self,n_ground):
        sigma0=np.array([.026,.00012,.10,.040,.09,.06,.55])
        # Sample random spatially uniform stationary elementary ground scatterers.
        x=self.rng.uniform(self.x[0],self.x[-1],n_ground)
        y=self.rng.uniform(self.y[0],self.y[-1],n_ground)
        z=self._sample_height(x,y)
        kinds=np.clip(self._sample_array(self.material,x,y,order=0).astype(int),0,6)
        gy,gx=np.gradient(self.height,float(self.y[1]-self.y[0]),float(self.x[1]-self.x[0]))
        normals=np.stack([-self._sample_array(gx,x,y),-self._sample_array(gy,x,y),np.ones_like(x)],axis=1)
        normals/=np.linalg.norm(normals,axis=1,keepdims=True)
        amps=np.sqrt(sigma0[kinds])*self.rng.lognormal(-.08,.32,len(x))
        pos=[np.stack([x,y,z],axis=1)]
        amp=[amps]
        normal=[normals]
        tag=[np.zeros(n_ground,np.uint8)]
        orient=[np.zeros((n_ground,2),dtype=float)]
        mats=[kinds]
        def add(sx,sy,sz,a,typ,direction,material=6):
            pos.append(np.array([[sx,sy,sz]],float))
            amp.append(np.array([a],float))
            normal.append(np.array([[0,0,1]],float))
            tag.append(np.array([typ],np.uint8))
            orient.append(np.array([[np.cos(direction),np.sin(direction)]],float))
            mats.append(np.array([material],int))
        def rect_scatterers(px,py,L,W,angle,h,mat):
            # Four walls of a 3D box, with directional specular panels and
            # some 2-bounce wall-ground corners. One common model for every box.
            axis=np.array([np.cos(angle),np.sin(angle)])
            perp=np.array([-np.sin(angle),np.cos(angle)])
            def point_uv(u,v):
                return (px+axis[0]*u+perp[0]*v,
                        py+axis[1]*u+perp[1]*v)
            wall_density=max(3,int(max(L,W)/4))
            for sgn in (-1,1):
                for a in np.linspace(-1,1,wall_density):
                    ix,iy=point_uv(a*L*.5,sgn*W*.5)
                    add(ix,iy,h*.65,2.6,1,angle+sgn*np.pi/2,mat)
                for a in np.linspace(-1,1,wall_density):
                    ix,iy=point_uv(sgn*L*.5,a*W*.5)
                    add(ix,iy,h*.65,2.6,1,angle+(0 if sgn==1 else np.pi),mat)
            for u_sign in (-1,1):
                for v_sign in (-1,1):
                    ix,iy=point_uv(u_sign*L*.5,v_sign*W*.5)
                    add(ix,iy,h*.25,14.0 if mat==6 else 8.5,2,
                        angle+(0 if u_sign==1 else np.pi),mat)
            # Sharp 'roof hardware' is not added to the concrete warehouses.
        for rect in self.rects:
            rect_scatterers(*rect)
        # Truss bridge: two longitudinal metal rails plus supports and deck
        # end transitions; separate facet directions for glints.
        bx,by,_=self.bridge_data[0]
        for yy in np.linspace(by-97,by+97,75):
            for xx,orientation in ((bx-7,np.pi),(bx+7,0.)):
                add(xx,yy,19.5,2.2,1,orientation)
        for yy in np.linspace(by-90,by+90,16):
            add(bx-7,yy,8.0,13.0,2,np.pi)
            add(bx+7,yy,8.0,13.0,2,0.)
        # Diagonal cross braces; their highlights shift with azimuth.
        for yy in np.linspace(by-85,by+85,36):
            add(bx+2,yy,17.0,2.0,1,np.pi/4)
        # The central radar/communications structure and equipment (generic
        # metal lattice; this is a fictional game installation).
        cx,cy=self.central_xy
        for z in range(3,35,2):
            for theta in (0,2*np.pi/3,4*np.pi/3):
                add(cx+3*np.cos(theta),cy+3*np.sin(theta),float(z),
                    2.5,1,theta+np.pi/2)
        for theta in np.linspace(0,2*np.pi,32,endpoint=False):
            add(cx+8*np.cos(theta),cy+8*np.sin(theta),35.0,
                5.5,3,theta)
        add(cx,cy,35.0,25,3,np.pi*1.5)
        self.pos=np.concatenate(pos).astype(np.float32)
        self.amp=np.concatenate(amp).astype(np.float32)
        self.normals=np.concatenate(normal).astype(np.float32)
        self.kind=np.concatenate(tag)
        self.orient=np.concatenate(orient).astype(np.float32)
        self.matcode=np.concatenate(mats)
        self.phases=self.rng.uniform(0,2*np.pi,len(self.amp)).astype(np.float32)
        self.mask_ground=(self.kind==0)
        self.targets=np.array([[cx,cy]],float)
    def test_scene_masks(self):
        X,Y=self.xx,self.yy
        out={}
        for name,(x0,x1,y0,y1) in (
            ("bridge",self.bridge_box),
            ("site",self.site_box),
            ("warehouses",self.warehouse_box),
            ("grass",(-320,-230,850,925)),
            ("water",(260,310,1190,1300))):
            out[name]=(X>=x0)&(X<=x1)&(Y>=y0)&(Y<=y1)
        return out
