#version 450
// Passes vi.vert's points through the (emulated) geometry stage.
layout(points) in;
layout(points, max_vertices = 1) out;
layout(location = 0) in vec4 v_col[];
layout(location = 0) out vec4 g_col;
void main()
{
	gl_Position = gl_in[0].gl_Position;
	gl_PointSize = 1.0;
	g_col = v_col[0];
	EmitVertex();
}
