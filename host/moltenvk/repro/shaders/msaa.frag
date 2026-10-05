#version 450
// Counts fragment shader invocations.
layout(set = 0, binding = 0, std430) buffer Count { uint n; };
void main()
{
	atomicAdd(n, 1u);
}
