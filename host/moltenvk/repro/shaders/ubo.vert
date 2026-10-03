#version 450
#extension GL_EXT_scalar_block_layout : require
// zink-style uniform buffers: an array of blocks of uint[] indexed by a dynamically uniform
// value, in a push-descriptor set (Metal: discrete buffers). Two triangles as in v.vert.
layout(set = 0, binding = 0, scalar) uniform ubo { uint _m0[16]; } uniform_0_32[2];
layout(push_constant) uniform pc_t { int idx; } pc;
layout(location = 0) out vec4 opos;
layout(location = 1) out vec4 ocol;
const vec2 pos[6] = vec2[](vec2(-1, -1), vec2(0, -1), vec2(-1, 1), vec2(0, -1), vec2(1, -1), vec2(0, 1));
void main() {
  opos = vec4(pos[gl_VertexIndex], 0.5, 1.0);
  ocol = uintBitsToFloat(uvec4(uniform_0_32[pc.idx]._m0[0], uniform_0_32[pc.idx]._m0[1],
                               uniform_0_32[pc.idx]._m0[2], uniform_0_32[pc.idx]._m0[3]));
  gl_Position = opos;
}
