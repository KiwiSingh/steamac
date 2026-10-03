#version 450
// A quad in the left half as one line with adjacency (v0..v3, counter-clockwise from bottom-left).
layout(location = 0) out vec4 opos;
layout(location = 1) out vec4 ocol;
const vec2 pos[4] = vec2[](vec2(-1, -1), vec2(0, -1), vec2(0, 1), vec2(-1, 1));
void main() {
  opos = vec4(pos[gl_VertexIndex], 0.5, 1.0);
  ocol = vec4(0.0, 1.0, 0.0, 1.0);
  gl_Position = opos;
}
