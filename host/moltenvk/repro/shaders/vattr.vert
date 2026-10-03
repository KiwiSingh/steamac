#version 450
// v.vert with the positions from a vertex buffer (binding 0, location 0, 16-byte stride with
// 8 bytes of padding per vertex, so a wrong stride reads the wrong positions).
layout(location = 0) in vec2 pos;
layout(location = 0) out vec4 opos;
layout(location = 1) out vec4 ocol;
void main() {
  opos = vec4(pos, 0.5, 1.0);
  ocol = vec4(0.0, 1.0, 0.0, 1.0);
  gl_Position = opos;
}
