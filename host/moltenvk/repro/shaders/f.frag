#version 450
layout(location = 1) in vec4 icol;
layout(location = 0) out vec4 c;
void main() { c = vec4(icol.rgb, 1.0); }
