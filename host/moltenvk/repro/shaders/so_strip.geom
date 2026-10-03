#version 450
// Triangle-strip output with a varying number of vertices per input primitive: primitive p emits a
// strip of 3 + (p % 2) vertices (1 or 2 triangles). Captures gl_Position (gl_PerVertex member) and a
// varying in buffer 0, and the vertex number in buffer 1.
layout(triangles) in;
layout(triangle_strip, max_vertices = 4) out;
layout(location = 0) in vec4 ipos[];
layout(xfb_buffer = 0, xfb_stride = 32) out gl_PerVertex { layout(xfb_offset = 0) vec4 gl_Position; };
layout(location = 1, xfb_buffer = 0, xfb_offset = 16) out vec4 col;
layout(location = 2, xfb_buffer = 1, xfb_stride = 8, xfb_offset = 4) out uint vnum;
void main() {
  int n = 3 + (gl_PrimitiveIDIn % 2);
  for (int i = 0; i < n; i++) {
    gl_Position = ipos[i % 3] + vec4(0.0, 0.0, 0.0, float(i));
    col = vec4(float(gl_PrimitiveIDIn), float(i), 0.0, 1.0);
    vnum = uint(gl_PrimitiveIDIn * 100 + i);
    EmitVertex();
  }
  EndPrimitive();
}
