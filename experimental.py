import numpy as np
import trimesh
import matplotlib.pyplot as plt

class RadarSimulator:
    def __init__(self):
        # --- CONFIGURATION ---
        self.velocity = 200.0   # m/s (Aircraft speed)
        self.radar_pos = np.array([0, 0, 1000]) # Aircraft at 1km altitude
        self.wavelength = 0.03  # X-Band (approx 3cm)
        self.beamwidth_deg = 3.5 
        
        # Resolution settings
        # High azimuth count to get clean definition on the cube edges
        self.azimuth_count = 500 
        self.elevation_count = 150 

    def create_scene(self, cube_rotation_deg=45):
        """
        Creates the simulation world (Mesh).
        """
        objects = []

        # 1. The Floor (Large area to capture shadows)
        # We place it slightly below z=0 to avoid z-fighting with bottom of cube
        floor = trimesh.creation.box(extents=[4000, 4000, 1]) 
        floor.apply_translation([1250, 1250, -0.5]) 
        floor.visual.face_colors = [100, 100, 100, 255]
        objects.append(floor)

        # 2. The Cube (Target)
        # 100m x 100m x 100m
        cube = trimesh.creation.box(extents=[100, 100, 100])
        
        # Rotate around Z axis
        cube.apply_transform(trimesh.transformations.rotation_matrix(np.radians(cube_rotation_deg), [0, 0, 1]))
        
        # Place on top of floor (Z=0 to Z=100)
        # Center is at Z=50
        cube.apply_translation([1250, 1250, 50]) 
        objects.append(cube)

        scene = trimesh.util.concatenate(objects)
        return scene

    def get_pointing_angles(self, target_pos):
        """
        Calculates Azimuth and Elevation to look at a specific point.
        """
        vec = target_pos - self.radar_pos
        dist = np.linalg.norm(vec)
        
        # Azimuth (Angle around Z axis, 0 is North/Y)
        # Note: We use (x, y) for atan2. 
        az = np.arctan2(vec[0], vec[1]) 
        
        # Elevation (Angle from +Z axis/Up)
        el = np.arccos(vec[2] / dist)
        
        return az, el

    def scan(self, scene_mesh):
        """
        Simulates the Radar Scan using Raycasting and DBS processing.
        """
        # --- 1. AUTO-AIM ---
        # Look at the ground spot (1250, 1250, 0)
        target_center = np.array([1250, 1250, 0]) 
        az_center, el_center = self.get_pointing_angles(target_center)
        
        # Define Field of View (FoV)
        # 15 degrees wide to see context around the cube
        az_width = np.radians(15) 
        el_height = np.radians(15)

        # Generate Grid of Angles
        az_angles = np.linspace(az_center - az_width/2, az_center + az_width/2, self.azimuth_count)
        el_angles = np.linspace(el_center - el_height/2, el_center + el_height/2, self.elevation_count)
        
        az_grid, el_grid = np.meshgrid(az_angles, el_angles)
        az_flat, el_flat = az_grid.flatten(), el_grid.flatten()
        
        # Convert Spherical -> Cartesian Directions
        x = np.sin(el_flat) * np.sin(az_flat)
        y = np.sin(el_flat) * np.cos(az_flat)
        z = np.cos(el_flat)
        
        ray_dirs = np.column_stack((x, y, z))
        ray_origins = np.tile(self.radar_pos, (len(ray_dirs), 1))

        # --- 2. RAYCASTING ---
        # multiple_hits=False : Stops at the first surface (solves the "ghost" issue)
        locations, index_ray, index_tri = scene_mesh.ray.intersects_location(
            ray_origins=ray_origins,
            ray_directions=ray_dirs,
            multiple_hits=False 
        )
        
        if len(locations) == 0:
            print("No hits! Check aiming logic.")
            return [], []

        # --- 3. SIGNAL PROCESSING ---
        real_beam_data = []
        dbs_data = []
        
        # Pre-fetch normals for lighting calc
        all_normals = scene_mesh.face_normals[index_tri]

        for i, hit_point in enumerate(locations):
            # Geometry
            rel_pos = hit_point - self.radar_pos
            dist = np.linalg.norm(rel_pos)
            true_az = np.arctan2(hit_point[0], hit_point[1])

            # Vector Math
            view_dir = rel_pos / dist
            normal = all_normals[i]
            
            # Dot Product: 1.0 = Perpendicular (Bright), 0.0 = Glancing (Dark)
            incidence = abs(np.dot(view_dir, normal))
            
            # --- INTENSITY MODEL ---
            # Identify if we hit the Cube or the Floor based on Height (Z)
            is_cube = hit_point[2] > 2.0 
            
            if is_cube:
                # CUBE: Specular Reflection (Shiny)
                # Power of 4 makes faces very bright only if looking straight at them.
                # We multiply by 10 to make it "hot"
                intensity = (incidence ** 4) * 10.0
                
                # Boost the Top Face slightly so it's visible despite the bad angle
                # (The top face normal is roughly [0,0,1])
                if normal[2] > 0.9: 
                    intensity = 2.0 # Force a baseline visibility for top
                    
            else:
                # FLOOR: Diffuse Reflection (Rough)
                # 0.05 base + incidence^2
                # Ensures we always see the ground, even at glancing angles
                intensity = 0.05 + (incidence ** 2) * 0.2

            # Speckle Noise (Radar "Grain")
            intensity *= np.random.uniform(0.5, 1.5)

            # --- DOPPLER CALCULATION ---
            # v_closing = v_aircraft * cos(angle)
            cos_theta = np.cos(true_az)
            doppler = (2 * self.velocity * cos_theta) / self.wavelength

            # --- MODE A: REAL BEAM (BLURRY) ---
            # Simulate poor angular resolution by adding noise to the Angle
            beam_noise = np.radians(np.random.normal(0, self.beamwidth_deg/2.0))
            meas_az_rb = true_az + beam_noise
            
            rb_x = dist * np.sin(meas_az_rb)
            rb_y = dist * np.cos(meas_az_rb)
            real_beam_data.append([rb_x, rb_y, intensity])

            # --- MODE B: DBS (SHARPENED) ---
            # Simulate frequency measurement -> Angle
            # Add small Hz noise (FFT bin size)
            fd_meas = doppler + np.random.normal(0, 15.0)
            
            # Reverse the Doppler Equation: theta = acos( (fd * lambda) / 2v )
            val = (fd_meas * self.wavelength) / (2 * self.velocity)
            val = np.clip(val, -1.0, 1.0) # Safety clamp
            
            meas_az_dbs = np.arccos(val)
            
            # Ambiguity Fix: If hit was on the left (negative X), flip angle
            # (In a real radar, this requires complex IQ processing or beam steering)
            if hit_point[0] < 0: meas_az_dbs = -meas_az_dbs
            
            dbs_x = dist * np.sin(meas_az_dbs)
            dbs_y = dist * np.cos(meas_az_dbs)
            dbs_data.append([dbs_x, dbs_y, intensity])

        return np.array(real_beam_data), np.array(dbs_data)

# --- EXECUTION ---
if __name__ == "__main__":
    sim = RadarSimulator()
    
    # Create Scene (Try rotating: 0, 30, 45)
    scene = sim.create_scene(cube_rotation_deg=0)
    
    print("Simulating Radar Scan... (Raycasting)")
    rb, dbs = sim.scan(scene)

    # --- VISUALIZATION ---
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 7), facecolor='black')

    def plot_sim(ax, data, title):
        if len(data) == 0: return
        
        # Filter very weak noise for a cleaner plot
        mask = data[:,2] > 0.02
        d = data[mask]
        
        # Sort by intensity (Draw bright points on top of dim ones)
        d = d[d[:, 2].argsort()]
        
        # Plot (Inferno colormap matches radar phosphor screens well)
        ax.scatter(d[:,0], d[:,1], c=d[:,2], cmap='inferno', s=3, alpha=1.0)
        
        ax.set_title(title, color='white', fontsize=14)
        ax.set_aspect('equal')
        
        # Center the Camera on the Target
        target_x, target_y = 1250, 1250
        radius = 300 # Meters around target
        
        ax.set_xlim(target_x - radius, target_x + radius)
        ax.set_ylim(target_y - radius, target_y + radius)
        
        # Style
        ax.grid(True, color='#333333', alpha=0.5, linestyle=':')
        ax.set_facecolor('black')
        
        # Draw small crosshair at true center
        ax.plot(target_x, target_y, 'w+', markersize=10, alpha=0.3)

    plot_sim(ax1, rb, "Real Beam (Blurry)")
    plot_sim(ax2, dbs, "DBS (Sharpened)\nNote: Top Face appears at Bottom (Layover)")

    plt.tight_layout()
    plt.show()