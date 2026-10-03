#version 450
// Triangle list: vertex v at (v, 0, 0, 1) so captured positions identify the vertex.
layout(location = 0) out vec4 opos;
void main() {
  opos = vec4(float(gl_VertexIndex), 0.0, 0.0, 1.0);
  gl_Position = opos;
}
