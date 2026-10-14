shader_type spatial;
render_mode unshaded, cull_disabled;
uniform sampler2D radar_image : filter_linear, repeat_disable;
uniform float powered = 0.0;
uniform float has_frame = 0.0;
uniform float intensity = 1.20;
// Display-only CRT treatment. No reticle, rectangle, text, symbols or target gain.
void fragment() {
    vec2 p = UV * 2.0 - 1.0;
    vec2 uv = (p * (1.0 + 0.021 * dot(p,p))) * 0.5 + 0.5;
    float edge = 1.0 - smoothstep(0.90, 1.01, max(abs(p.x),abs(p.y)));
    float vignette = 1.0 - 0.16 * dot(p,p);
    float scanline = 0.973 + 0.027 * sin(UV.y * 1024.0 * 3.14159265);
    float signal = texture(radar_image, uv).r * has_frame;
    vec3 phosphor = vec3(0.27,1.0,0.22) * signal * intensity * vignette * scanline;
    vec3 glass = vec3(0.002,0.009,0.004) + powered * vec3(0.002,0.008,0.001);
    ALBEDO = (glass + phosphor * powered) * edge;
}
