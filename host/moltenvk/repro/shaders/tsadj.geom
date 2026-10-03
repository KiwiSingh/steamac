#version 450
// Triangles with adjacency in: emit the triangle (inputs 0, 2, 4).
layout(triangles_adjacency) in;
layout(triangle_strip, max_vertices = 3) out;
layout(location = 1) in vec4 icol[];
layout(location = 1) out vec4 ocol;
void main() {
  for (int i = 0; i < 6; i += 2) { gl_Position = gl_in[i].gl_Position; ocol = icol[i]; EmitVertex(); }
  EndPrimitive();
}
