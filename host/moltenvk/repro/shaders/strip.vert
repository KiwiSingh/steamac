#version 450
// Triangle strip over the left half: primitive 0 = (v0 v1 v2), primitive 1 = (v1 v3 v2).
layout(location = 0) out vec4 opos;
layout(location = 1) out vec4 ocol;
const vec2 pos[4] = vec2[](vec2(-1, -1), vec2(0, -1), vec2(-1, 1), vec2(0, 1));
void main() {
  opos = vec4(pos[gl_VertexIndex], 0.5, 1.0);
  ocol = vec4(0.0, 1.0, 0.0, 1.0);
  gl_Position = opos;
}
