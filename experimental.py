import numpy as np
import trimesh
import matplotlib.pyplot as plt
from PIL import Image
from tqdm import tqdm

class RadarSimulator:
    def __init__(self):
        self.velocity = 200.0   
        self.radar_pos = np.array([0, 0, 1000]) 
        self.wavelength = 0.03  
        self.beamwidth_deg = 3.5 
        
        # Raycasting Resolution
        self.azimuth_count = 500 
        self.elevation_count = 150 

    def load_heightmap_to_mesh(self, image_path, world_size=2000, max_height=100):
        """
        Converts a greyscale image into a 3D Trimesh object.
        """
        try:
            # Load image and convert to Greyscale (L)
            img = Image.open(image_path).convert('L')
        except FileNotFoundError:
            print(f"ERROR: Could not find {image_path}. Generating flat terrain instead.")
            return trimesh.creation.box(extents=[world_size, world_size, 1])

        # Downscale slightly if resolution is huge (keeps raycasting fast)
        # 256x256 is perfectly fine.
        width, height = img.size
        pixels = np.array(img)
        
        # Create a grid of X, Y coordinates
        x = np.linspace(0, world_size, width)
        y = np.linspace(0, world_size, height)
        xv, yv = np.meshgrid(x, y)
        
        # Scale Z values (0-255 -> 0-max_height)
        z = (pixels / 255.0) * max_height
        
        # Flatten arrays to create vertex list
        # We center the terrain at 1250, 1250
        x_flat = xv.flatten() + (1250 - world_size/2)
        y_flat = yv.flatten() + (1250 - world_size/2)
        z_flat = z.flatten()
        
        vertices = np.column_stack((x_flat, y_flat, z_flat))
        
        # Create Faces (Triangles)
        # This connects the grid points into triangles
        faces = []
        for r in range(height - 1):
            for c in range(width - 1):
                # Indices in the flattened array
                i0 = r * width + c
                i1 = i0 + 1
                i2 = (r + 1) * width + c
                i3 = i2 + 1
                
                # Two triangles per grid square
                faces.append([i0, i2, i1])
                faces.append([i1, i2, i3])
        
        # Create the mesh
        terrain_mesh = trimesh.Trimesh(vertices=vertices, faces=faces)
        
        # Calculate normals for lighting/radar reflection
        terrain_mesh.fix_normals()
        
        return terrain_mesh

    def create_scene(self, heightmap_path):
        objects = []
        
        # 1. THE TERRAIN (From Heightmap)
        print("Generating Terrain Mesh...")
        terrain = self.load_heightmap_to_mesh(heightmap_path, world_size=1000, max_height=80)
        objects.append(terrain)

        # 2. THE CUBE
        cube = trimesh.creation.box(extents=[60, 60, 60])
        cube.apply_transform(trimesh.transformations.rotation_matrix(np.radians(45), [0, 0, 1]))
        
        # Place cube. We put it at Z=60 so it sits roughly "on" the hills 
        # (You might need to adjust this depending on how high your black/white pixels are)
        cube.apply_translation([1250, 1250, 60]) 
        objects.append(cube)

        return trimesh.util.concatenate(objects)

    def scan(self, scene_mesh):
        # --- AIMING ---
        target_center = np.array([1250, 1250, 0]) 
        vec = target_center - self.radar_pos
        dist_center = np.linalg.norm(vec)
        az_center = np.arctan2(vec[0], vec[1]) 
        el_center = np.arccos(vec[2] / dist_center)
        
        # --- RAYS ---
        az_width = np.radians(15) 
        el_height = np.radians(15)

        az_angles = np.linspace(az_center - az_width/2, az_center + az_width/2, self.azimuth_count)
        el_angles = np.linspace(el_center - el_height/2, el_center + el_height/2, self.elevation_count)
        
        az_grid, el_grid = np.meshgrid(az_angles, el_angles)
        az_flat, el_flat = az_grid.flatten(), el_grid.flatten()
        
        x = np.sin(el_flat) * np.sin(az_flat)
        y = np.sin(el_flat) * np.cos(az_flat)
        z = np.cos(el_flat)
        
        ray_dirs = np.column_stack((x, y, z))
        ray_origins = np.tile(self.radar_pos, (len(ray_dirs), 1))

        # --- RAYCAST ---
        locations, index_ray, index_tri = scene_mesh.ray.intersects_location(
            ray_origins=ray_origins,
            ray_directions=ray_dirs,
            multiple_hits=False 
        )
        
        print(f"Rays Cast: {len(ray_dirs)}, Hits: {len(locations)}")
        if len(locations) == 0: return [], []

        dbs_data = []
        all_normals = scene_mesh.face_normals[index_tri]

        for i, hit_point in enumerate(tqdm(locations, desc="Processing hits", unit="ray")):
            # Geometry
            rel_pos = hit_point - self.radar_pos
            dist = np.linalg.norm(rel_pos)
            true_az = np.arctan2(hit_point[0], hit_point[1])
            normal = all_normals[i]
            view_dir = rel_pos / dist
            
            # --- INTENSITY (STRENGTH) ---
            # Dot Product: How perpendicular is the surface?
            incidence = abs(np.dot(view_dir, normal))
            
            # HEIGHT CHECK: Cube vs Terrain
            # The Cube is likely higher than the surrounding terrain in this spot
            # We assume anything above Z=50 is the cube (adjust based on your heightmap!)
            is_cube = hit_point[2] > 55.0 
            
            if is_cube:
                # CUBE: Specular (Shiny)
                # Very bright if hit head-on, dim if glancing
                intensity = (incidence ** 6) * 15.0 
                # Layover fix: Boost top face slightly so we can see it
                if normal[2] > 0.8: intensity = max(intensity, 2.0)
            else:
                # TERRAIN: Diffuse (Rough)
                # Heightmap ground reflects moderately in all directions
                # We also modulate by height to make "hills" look brighter than "valleys"
                intensity = 0.1 + (incidence * 0.5)
            
            # Speckle Noise
            intensity *= np.random.uniform(0.5, 1.5)

            # --- DBS MATH ---
            cos_theta = np.cos(true_az)
            doppler = (2 * self.velocity * cos_theta) / self.wavelength

            fd_meas = doppler + np.random.normal(0, 15.0)
            val = np.clip((fd_meas * self.wavelength) / (2 * self.velocity), -1, 1)
            meas_az_dbs = np.arccos(val)
            if hit_point[0] < 0: meas_az_dbs = -meas_az_dbs
            
            dbs_x = dist * np.sin(meas_az_dbs)
            dbs_y = dist * np.cos(meas_az_dbs)
            
            # Save: X, Y, Intensity
            dbs_data.append([dbs_x, dbs_y, intensity])

        return np.array(dbs_data)

# --- EXECUTION ---
if __name__ == "__main__":
    sim = RadarSimulator()
    
    # PUT YOUR PATH HERE
    path_to_heightmap = "assets/heightmaps/Perlin_22-256x256.png"
    
    scene = sim.create_scene(path_to_heightmap)
    print("Raycasting complex terrain... (This may take a moment)")
    dbs_data = sim.scan(scene)

    # --- PLOTTING ---
    plt.figure(figsize=(10, 10), facecolor='black')
    ax = plt.gca()

    if len(dbs_data) > 0:
        # Sort so bright pixels (Cube) draw on top of dim pixels (Ground)
        dbs_data = dbs_data[dbs_data[:, 2].argsort()]
        
        # Plot with INFERNO colormap (Dark -> Red -> Yellow -> White)
        sc = ax.scatter(dbs_data[:,0], dbs_data[:,1], c=dbs_data[:,2], cmap='inferno', s=4, alpha=1.0)
        
        # Add colorbar
        cbar = plt.colorbar(sc, ax=ax, fraction=0.046, pad=0.04)
        cbar.set_label('Return Strength (Intensity)', color='white')
        cbar.ax.yaxis.set_tick_params(color='white')
        plt.setp(plt.getp(cbar.ax.axes, 'yticklabels'), color='white')

    ax.set_title("DBS Radar: Cube on Perlin Terrain", color='white')
    ax.set_aspect('equal')
    ax.set_facecolor('black')
    
    # Frame the camera
    ax.set_xlim(1000, 1500)
    ax.set_ylim(1000, 1500)
    ax.grid(True, color='#333333', linestyle=':')

    plt.show()