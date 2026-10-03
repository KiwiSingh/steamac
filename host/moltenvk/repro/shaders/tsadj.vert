#version 450
// Triangle strip with adjacency, 8 vertices = 2 triangles: even vertices are the strip
// (v0, v2, v4) and (v4, v2, v6) covering the left half; odd vertices (adjacency) are off-screen.
layout(location = 0) out vec4 opos;
layout(location = 1) out vec4 ocol;
const vec2 pos[8] = vec2[](vec2(-1, -1), vec2(9, 9), vec2(0, -1), vec2(9, 9),
                           vec2(-1, 1), vec2(9, 9), vec2(0, 1), vec2(9, 9));
void main() {
  opos = vec4(pos[gl_VertexIndex], 0.5, 1.0);
  ocol = vec4(0.0, 1.0, 0.0, 1.0);
  gl_Position = opos;
}
