#version 450
layout(location = 0) out vec4 v_col;
vec2 corner(uint i) { return vec2(float((i << 1) & 2u), float(i & 2u)) * 2.0 - 1.0; }
void main()
{
	gl_Position = vec4(corner(uint(gl_VertexIndex)), 0.0, 1.0);
	v_col = vec4(0.25, 0.5, 0.75, 1.0);
}
