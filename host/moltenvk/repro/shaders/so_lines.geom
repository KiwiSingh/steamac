#version 450
// Line strip of 3 vertices (2 lines) per input primitive, captured.
layout(triangles) in;
layout(line_strip, max_vertices = 3) out;
layout(location = 0) in vec4 ipos[];
layout(location = 0, xfb_buffer = 0, xfb_stride = 16, xfb_offset = 0) out vec4 a;
void main() {
  for (int i = 0; i < 3; i++) {
    gl_Position = ipos[i];
    a = vec4(float(gl_PrimitiveIDIn), float(i), 0.0, 0.0);
    EmitVertex();
  }
  EndPrimitive();
}
