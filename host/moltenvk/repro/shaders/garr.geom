#version 450
// Geometry shader with an array output varying followed by another varying (vkd3d-proton / UE4: Stellar Blade's
// cube map GS writes float4 TEXCOORD[2] at location 2): Metal mesh vertex types cannot hold arrays.
layout(triangles) in;
layout(triangle_strip, max_vertices = 3) out;
layout(location = 0) in vec4 ipos[];
layout(location = 2) out vec4 oarr[2];
layout(location = 4) out vec4 oafter;
void main() {
  for (int i = 0; i < 3; i++) {
    gl_Position = ipos[i];
    oarr[0] = vec4(0.0, 0.0, 0.25, 0.0);
    oarr[1] = vec4(0.0, 1.0, 0.25, 0.0);
    oafter = vec4(0.5, 0.0, 0.0, 0.0);
    EmitVertex();
  }
  EndPrimitive();
}
