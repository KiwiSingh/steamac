#version 450
// glslang gl_in[] block input (DXVK/glslang style).
layout(triangles) in;
layout(triangle_strip, max_vertices = 3) out;
layout(location = 1) in vec4 icol[];
layout(location = 1) out vec4 ocol;
void main() {
  for (int i = 0; i < 3; i++) {
    gl_Position = gl_in[i].gl_Position;
    ocol = icol[i];
    EmitVertex();
  }
  EndPrimitive();
}
