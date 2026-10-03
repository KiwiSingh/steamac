#version 450
// One triangle per instance: binding 0 = per-vertex position (v.vert's first triangle), binding 1 =
// per-instance offset (VK_VERTEX_INPUT_RATE_INSTANCE). Instance 0 covers the left half's lower-left
// triangle, instance 1 the same triangle shifted right (v.vert's second triangle).
layout(location = 0) in vec2 pos;
layout(location = 2) in vec2 ioff;
layout(location = 0) out vec4 opos;
layout(location = 1) out vec4 ocol;
void main() {
  opos = vec4(pos + ioff, 0.5, 1.0);
  ocol = vec4(0.0, 1.0, 0.0, 1.0);
  gl_Position = opos;
}
