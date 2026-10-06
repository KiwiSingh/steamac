#version 450
layout(location = 0) out vec4 color;
layout(set = 0, binding = 0, std430) buffer Stores { uint values[]; } stores;
void discard_negative(float x)
{
    if (x < 0.0)
        discard;
}
void outer(float x)
{
    discard_negative(x);
}
void main()
{
    outer(gl_FragCoord.x - 2.0);
    stores.values[uint(gl_FragCoord.y) * 4u + uint(gl_FragCoord.x)] = 123u;
    color = vec4(0.25, 0.5, 0.75, 1);
}
