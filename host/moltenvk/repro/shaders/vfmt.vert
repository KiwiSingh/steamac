#version 450
// v.vert with positions and colors from a vertex buffer in 8/16-bit formats (SCALED / NORM), as
// glamor sends them (GL_SHORT positions -> R16G16_SSCALED). The color is (0, 128, 0, 255) UNORM8.
layout(location = 0) in vec2 pos;
layout(location = 1) in vec4 col;
layout(location = 0) out vec4 opos;
layout(location = 1) out vec4 ocol;
void main() {
  opos = vec4(pos, 0.5, 1.0);
  ocol = col;
  gl_Position = opos;
}
