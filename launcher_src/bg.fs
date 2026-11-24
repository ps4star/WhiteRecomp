#version 450
#extension GL_EXT_scalar_block_layout : require
// The launcher's window background: frosted blue glass. One blue all over, varied only by smooth 2D noise: large soft
// clouds a little lighter and deeper (the frost), a finer, fainter layer over them, and the gloss of glass -- a broad
// sheen down from the top and two wide, soft diagonal light streaks. No grain: every layer is smooth value noise or a
// gradient. Still: nothing moves. Compiled by tools/launcher_shader.sh (the uniforms: shaders.odin's Bg_Uniforms).
layout(location = 0) in vec2 fragTexCoord;
layout(location = 1) in vec4 fragColor;
layout(location = 0) out vec4 finalColor;
layout(scalar, set = 0, binding = 0) uniform Uniforms {
	vec2 res;    // the target in px
	float scale; // the UI's scale at this target's size
};

const vec3 BLUE = vec3(0.560, 0.745, 0.945);  // the blue
const vec3 LIGHT = vec3(0.760, 0.865, 0.985); // where the frost is thicker
const vec3 DEEP = vec3(0.440, 0.650, 0.910);  // where it is thinner

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

float fbm(vec2 p) {
	float v = 0.0, a = 0.5;
	for (int i = 0; i < 5; i++) {
		v += a * vnoise(p);
		p = mat2(1.6, 1.2, -1.2, 1.6) * p + vec2(3.1, 7.7);
		a *= 0.5;
	}
	return v / 0.97;
}

void main() {
	vec2 uv = gl_FragCoord.xy / res; // 0 .. 1, y down
	vec2 q = gl_FragCoord.xy / (320.0 * max(scale, 0.25));

	// the frost: large soft clouds, lighter and deeper than the blue (domain-warped, so they swirl a little)
	vec2 w = vec2(fbm(q + vec2(1.7, 9.2)), fbm(q + vec2(8.3, 2.8)));
	float f = fbm(q + 1.4 * w);
	vec3 col = mix(DEEP, BLUE, smoothstep(0.20, 0.50, f));
	col = mix(col, LIGHT, smoothstep(0.50, 0.85, f) * 0.85);
	// a finer, fainter layer: frost that is not quite even
	col += (fbm(q * 4.0 + w * 2.0) - 0.5) * 0.035;

	// the gloss: a broad sheen down from the top, and two wide soft streaks of light across the glass
	col = mix(col, vec3(1.0), (1.0 - smoothstep(0.0, 0.45, uv.y)) * 0.16);
	float diag = uv.x * (res.x / res.y) * 0.55 + uv.y;
	col = mix(col, vec3(1.0), exp(-pow((diag - 0.55) / 0.10, 2.0)) * 0.10);
	col = mix(col, vec3(1.0), exp(-pow((diag - 0.80) / 0.05, 2.0)) * 0.07);

	col += (hash21(gl_FragCoord.xy) - 0.5) / 255.0; // against banding (one level: not a grain you can see)
	finalColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
