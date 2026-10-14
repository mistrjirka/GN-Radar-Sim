shader_type spatial;
render_mode unshaded, cull_disabled;
uniform sampler2D radar_image : filter_linear_mipmap, repeat_disable;
uniform float powered = 0.0;
uniform float has_frame = 0.0;
uniform float intensity = 1.20;
uniform float resolve_progress = 1.0;
uniform float resolving = 0.0;
uniform vec2 target_uv = vec2(-1.0);
// The whole acquired image is visible at once. Larger spatial detail resolves
// first, then finer detail, uniformly across the screen. No sweep or reveal mask.
// This is a presentation effect AFTER real data arrives, not radar computation.
void fragment() {
    vec2 p = UV * 2.0 - 1.0;
    vec2 uv = (p * (1.0 + 0.021 * dot(p,p))) * 0.5 + 0.5;
    float edge = 1.0 - smoothstep(0.90, 1.01, max(abs(p.x),abs(p.y)));
    float vignette = 1.0 - 0.16 * dot(p,p);
    float scanline = 0.973 + 0.027 * sin(UV.y * 1024.0 * 3.14159265);
    float softness = 4.5 * pow(1.0-clamp(resolve_progress,0.0,1.0),1.25) * resolving;
    // Level zero is the unmodified radar data. No unsharp mask or invented detail.
    float signal = textureLod(radar_image, uv, softness).r * has_frame;
    vec3 phosphor = vec3(0.27,1.0,0.22) * signal * intensity * vignette * scanline;
    if (target_uv.x>=0.0 && resolving<0.5) {
        float d=length(uv-target_uv);
        float mark=1.0-smoothstep(0.0015,0.0035,abs(d-0.010));
        phosphor+=vec3(0.28,0.65,0.20)*mark;
    }
    vec3 glass = vec3(0.002,0.009,0.004) + powered * vec3(0.002,0.008,0.001);
    ALBEDO = (glass + phosphor * powered) * edge;
}
