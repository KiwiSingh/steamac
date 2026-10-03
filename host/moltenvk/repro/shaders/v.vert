#version 450
// Two triangles: primitive 0 in the left half, primitive 1 in the right half.
layout(location = 0) out vec4 opos;
layout(location = 1) out vec4 ocol;
const vec2 pos[6] = vec2[](vec2(-1, -1), vec2(0, -1), vec2(-1, 1), vec2(0, -1), vec2(1, -1), vec2(0, 1));
void main() {
  opos = vec4(pos[gl_VertexIndex], 0.5, 1.0);
  ocol = vec4(0.0, 1.0, 0.0, 1.0);
  gl_Position = opos;
}
