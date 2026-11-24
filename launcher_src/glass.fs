#version 450
#extension GL_EXT_scalar_block_layout : require
// A panel: one light blue all over, with only a faint, smooth variation from 2D noise (value noise in window
// coordinates, so neighbouring panels share it), and the 1 px border. `milk` lightens the blue towards white (a dialog,
// whose text sits over the dimmed window, is nearly white). Outside the pane: nothing. Drawn by draw_shader over `rect`
// (straight alpha blending: opaque inside, antialiased at the outline). Compiled by tools/launcher_shader.sh (the
// uniforms: shaders.odin's Glass_Uniforms; `backdrop` and `gloss` are no longer used).
layout(location = 0) in vec2 fragTexCoord;
layout(location = 1) in vec4 fragColor;
layout(location = 0) out vec4 finalColor;
layout(set = 1, binding = 0) uniform sampler2D backdrop; // the background, blurred, in window space
layout(scalar, set = 0, binding = 0) uniform Uniforms {
	vec4 rect;    // x, y, w, h of the pane in window px
	vec2 res;     // the window in px
	vec4 border;  // rgb: the border; a: its opacity
	float radius; // corner radius in px
	float scale;  // the UI's scale
	float milk;   // 0 .. 1: how much white tint (0.18 for a panel; more for a dialog over a dimmed window)
	float gloss;  // strength of the sheen
};

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	f = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	return mix(mix(hash21(i), hash21(i + vec2(1, 0)), f.x), mix(hash21(i + vec2(0, 1)), hash21(i + vec2(1, 1)), f.x), f.y);
}

float sd_box(vec2 p, vec2 b, float r) {
	vec2 q = abs(p) - b + r;
	return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

void main() {
	vec2 p = gl_FragCoord.xy;
	vec2 hs = rect.zw * 0.5;
	vec2 c = rect.xy + hs;
	float d = sd_box(p - c, hs, radius);
	float cover = clamp(0.5 - d, 0.0, 1.0);
	if (cover <= 0.0) discard;

	const vec3 BLUE = vec3(0.855, 0.918, 0.992); // the panels' light blue
	vec2 q = p / (150.0 * scale);
	float n = vnoise(q) * 0.6 + vnoise(q * 2.3 + vec2(5.2, 1.3)) * 0.4; // 0 .. 1, smooth
	vec3 col = mix(BLUE, vec3(1.0), clamp(milk, 0.0, 1.0) * 0.8);
	col += (n - 0.5) * 0.03; // the variation: a few levels either way

	// the border: the outermost pixel
	float bw = 1.0 - smoothstep(0.0, 1.0, -d - 0.5);
	vec3 outc = mix(col, border.rgb, bw * border.a);
	finalColor = vec4(outc, cover);
}
