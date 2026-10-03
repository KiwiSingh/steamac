#version 450
// v.vert shifted by one vertex: vertex 0 is a dummy (a copy of vertex 1, so that a draw that ignores
// firstVertex / vertexOffset has a degenerate first triangle), vertices 1..6 are
// the two triangles of v.vert. Drawn with firstVertex = 1 or vertexOffset = 1.
layout(location = 0) out vec4 opos;
layout(location = 1) out vec4 ocol;
const vec2 pos[7] = vec2[](vec2(-1, -1), vec2(-1, -1), vec2(0, -1), vec2(-1, 1), vec2(0, -1), vec2(1, -1), vec2(0, 1));
void main() {
  opos = vec4(pos[gl_VertexIndex], 0.5, 1.0);
  ocol = vec4(0.0, 1.0, 0.0, 1.0);
  gl_Position = opos;
}
