#version 450
// zink-style: pass gl_PrimitiveIDIn through to the fragment shader.
layout(triangles) in;
layout(triangle_strip, max_vertices = 3) out;
layout(location = 0) in vec4 ipos[];
layout(location = 1) in vec4 icol[];
layout(location = 1) out vec4 ocol;
void main() {
  for (int i = 0; i < 3; i++) {
    gl_Position = ipos[i];
    ocol = icol[i];
    gl_PrimitiveID = gl_PrimitiveIDIn;
    EmitVertex();
  }
  EndPrimitive();
}
