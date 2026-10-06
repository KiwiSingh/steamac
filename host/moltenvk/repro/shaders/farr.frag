#version 450
// Reads garr.geom's array varying and the varying after it.
layout(location = 2) in vec4 iarr[2];
layout(location = 4) in vec4 iafter;
layout(location = 0) out vec4 c;
void main() { c = vec4(iarr[0].r + iafter.r, iarr[1].g, iarr[0].b + iarr[1].b, 1.0); }
