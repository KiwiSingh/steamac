#version 450
// GL_QUADS as zink draws them: lines with adjacency in, the quad out as two triangles.
layout(lines_adjacency) in;
layout(triangle_strip, max_vertices = 6) out;
layout(location = 1) in vec4 icol[];
layout(location = 1) out vec4 ocol;
void emit(int i) { gl_Position = gl_in[i].gl_Position; ocol = icol[i]; EmitVertex(); }
void main() {
  emit(0); emit(1); emit(3); EndPrimitive();
  emit(1); emit(2); emit(3); EndPrimitive();
}
