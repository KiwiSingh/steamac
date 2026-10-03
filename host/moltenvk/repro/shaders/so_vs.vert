#version 450
// Vertex shader capturing transform feedback itself (no geometry shader): not supported, pipeline
// creation must fail cleanly.
layout(location = 0, xfb_buffer = 0, xfb_stride = 16, xfb_offset = 0) out vec4 a;
void main() {
  a = vec4(float(gl_VertexIndex));
  gl_Position = vec4(0.0, 0.0, 0.0, 1.0);
}
