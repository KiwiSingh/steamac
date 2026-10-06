#version 450
// DXVK-style value-returning helpers, including a helper that needs the mesh stream.
layout(triangles) in;
layout(triangle_strip, max_vertices = 3) out;
layout(location = 1) in vec4 icol[];
layout(location = 1) out vec4 ocol;
float dp3_f32(vec3 a, vec3 b) { return fma(a.z, b.z, fma(a.y, b.y, a.x * b.x)); }
float dp4_f32(vec4 a, vec4 b) { return fma(a.w, b.w, dp3_f32(a.xyz, b.xyz)); }
float dp2_f32(vec2 a, vec2 b) { return fma(a.y, b.y, a.x * b.x); }
uint cvt_f32_u32(float a) { return uint(a); }
vec4 color(vec4 c) {
  return vec4(dp2_f32(c.xy, vec2(1, 0)), dp3_f32(c.xyz, vec3(0, 1, 0)),
              dp4_f32(c, vec4(0, 0, 1, 0)), float(cvt_f32_u32(c.w)));
}
int emit_vertex(int i) {
  gl_Position = gl_in[i].gl_Position;
  ocol = color(icol[i]);
  EmitVertex();
  return i + 1;
}
int forward_emit(int i) { return emit_vertex(i); }
void main() {
  for (int i = 0; i < 3;) i = forward_emit(i);
  EndPrimitive();
}
