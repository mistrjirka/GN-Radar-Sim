import numpy as np
import trimesh
import matplotlib.pyplot as plt
import math

class RadarSimulator:
    def __init__(self):
        # Aircraft Physics
        self.velocity = 200.0   # m/s
        self.radar_pos = np.array([0, 0, 1000]) # Aircraft at 1km altitude
        self.wavelength = 0.03  # X-Band
        self.beamwidth_deg = 4.0 
        
        # Raycasting settings
        self.azimuth_count = 300  # Horizontal rays
        self.elevation_count = 50 # Vertical rays
        
        # Added a slight resolution bump just to make the ground look less like dots
        self.azimuth_count = 400  
        self.elevation_count = 100 

    def create_scene(self):
        objects = []

        # 1. The Floor
        floor = trimesh.creation.box(extents=[1000, 1000, 1]) 
        floor.apply_translation([1250, 1250, -0.5]) 
        objects.append(floor)

        # 2. The Cube
        cube = trimesh.creation.box(extents=[80, 80, 80])
        cube.apply_transform(trimesh.transformations.rotation_matrix(np.radians(45), [0, 0, 1]))
        cube.apply_translation([1250, 1250, 40]) 
        objects.append(cube)

        scene = trimesh.util.concatenate(objects)
        return scene

    def scan(self, scene_mesh):
        # --- 1. GENERATE RAYS ---
        az_center = np.radians(45)
        el_center = np.radians(135)

        # Slightly widened the scan area so we see more ground around the cube
        az_angles = np.linspace(az_center - 0.25, az_center + 0.25, self.azimuth_count)
        el_angles = np.linspace(el_center - 0.15, el_center + 0.15, self.elevation_count)
        
        ray_dirs = []
        for az in az_angles:
            for el in el_angles:
                x = np.sin(el) * np.sin(az)
                y = np.sin(el) * np.cos(az)
                z = np.cos(el)
                ray_dirs.append([x, y, z])
        
        ray_dirs = np.array(ray_dirs)
        ray_origins = np.tile(self.radar_pos, (len(ray_dirs), 1))

        # --- 2. RAYCASTING ---
        locations, index_ray, index_tri = scene_mesh.ray.intersects_location(
            ray_origins=ray_origins,
            ray_directions=ray_dirs
        )
        
        if len(locations) == 0:
            print("No hits!")
            return [], []

        # --- 3. PROCESS HITS ---
        real_beam_data = []
        dbs_data = []

        # Get all normals at once for speed (optimization)
        all_normals = scene_mesh.face_normals[index_tri]

        for i, hit_point in enumerate(locations):
            rel_pos = hit_point - self.radar_pos
            dist = np.linalg.norm(rel_pos)
            true_az = np.arctan2(hit_point[0], hit_point[1])

            # -- CALCULATE INTENSITY (FIXED) --
            view_dir = rel_pos / dist
            normal = all_normals[i]
            
            # Dot product (Cosine of angle)
            incidence = np.dot(view_dir, normal)
            
            # --- THE FIX IS HERE ---
            # Old: abs(incidence) ** 4  (Too dim for ground)
            # New: 0.1 + abs(incidence) ** 2
            # The 0.1 adds "Diffuse" reflection (Roughness), so ground always reflects a bit.
            intensity = 0.1 + (abs(incidence) ** 2)
            
            # Noise
            intensity *= np.random.uniform(0.5, 1.5)

            # -- DOPPLER --
            cos_theta = np.cos(true_az)
            doppler = (2 * self.velocity * cos_theta) / self.wavelength

            # -- A. REAL BEAM --
            beam_noise = np.radians(np.random.normal(0, self.beamwidth_deg/2.0))
            measured_az_rb = true_az + beam_noise
            
            rb_x = dist * np.sin(measured_az_rb)
            rb_y = dist * np.cos(measured_az_rb)
            real_beam_data.append([rb_x, rb_y, intensity])

            # -- B. DBS --
            fd_measured = doppler + np.random.normal(0, 10.0)
            val = (fd_measured * self.wavelength) / (2 * self.velocity)
            val = np.clip(val, -1.0, 1.0)
            measured_az_dbs = np.arccos(val)
            
            if hit_point[0] < 0: measured_az_dbs = -measured_az_dbs
            
            dbs_x = dist * np.sin(measured_az_dbs)
            dbs_y = dist * np.cos(measured_az_dbs)
            dbs_data.append([dbs_x, dbs_y, intensity])

        return np.array(real_beam_data), np.array(dbs_data)

# --- RUN IT ---
sim = RadarSimulator()
scene = sim.create_scene()
print("Raycasting scene...")
rb, dbs = sim.scan(scene)

# --- PLOT ---
fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 6))

def plot_sim(ax, data, title):
    if len(data) == 0: return
    
    # --- VISUALIZATION FIX ---
    # Changed from 0.05 to 0.01 so we don't accidentally hide the ground
    mask = data[:,2] > 0.01 
    d = data[mask]
    
    # Sort by intensity so bright cube points draw ON TOP of dim ground points
    d = d[d[:, 2].argsort()]
    
    ax.scatter(d[:,0], d[:,1], c=d[:,2], cmap='inferno', s=2, alpha=0.8)
    ax.set_title(title)
    ax.set_aspect('equal')
    ax.set_xlim(800, 1700)
    ax.set_ylim(800, 1700)
    ax.grid(True, alpha=0.2)
    ax.set_facecolor('black')

plot_sim(ax1, rb, "Real Beam (Blurry)")
plot_sim(ax2, dbs, "DBS (Sharpened)\nGround is now visible + Shadow")

plt.show()