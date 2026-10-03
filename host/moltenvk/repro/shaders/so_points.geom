#version 450
// DXVK-style stream-output geometry shader: no position, points out, only captured outputs.
layout(triangles) in;
layout(points, max_vertices = 3) out;
layout(location = 0) in vec4 ipos[];
layout(xfb_buffer = 0, xfb_stride = 40) out;
layout(location = 0, xfb_buffer = 0, xfb_offset = 0) out vec4 a;
layout(location = 1, xfb_buffer = 0, xfb_offset = 16) out vec4 b;
layout(location = 2, xfb_buffer = 0, xfb_offset = 32) out float c;
layout(location = 3, xfb_buffer = 0, xfb_offset = 36) out uint d;
void main() {
  for (int i = 0; i < 3; i++) {
    a = ipos[i];
    b = vec4(float(gl_PrimitiveIDIn), float(i), 1.0, 2.0);
    c = 0.5 + float(i);
    d = uint(gl_PrimitiveIDIn * 10 + i);
    EmitVertex();
  }
}
