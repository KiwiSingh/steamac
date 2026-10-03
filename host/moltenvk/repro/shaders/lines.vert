#version 450
// Two horizontal lines: primitive 0 on the left, primitive 1 on the right.
layout(location = 0) out vec4 opos;
layout(location = 1) out vec4 ocol;
const vec2 pos[4] = vec2[](vec2(-0.875, -0.5), vec2(-0.125, -0.5), vec2(0.125, -0.5), vec2(0.875, -0.5));
void main() {
  opos = vec4(pos[gl_VertexIndex], 0.5, 1.0);
  ocol = vec4(0.0, 1.0, 0.0, 1.0);
  gl_Position = opos;
}
