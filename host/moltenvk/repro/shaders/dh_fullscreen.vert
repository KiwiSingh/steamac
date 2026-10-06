#version 450
// Fullscreen triangle with a 3D coordinate for heap/dh_loop_header.spvasm (descriptor_heap.c).
layout(location = 0) out vec3 uvw;

void main()
{
	vec2 p = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
	uvw = vec3(p, 0.5);
	gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
