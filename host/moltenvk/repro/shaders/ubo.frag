#version 450
#extension GL_EXT_scalar_block_layout : require
// Same layout in a regular descriptor set (Metal: argument buffer); multiplies the colour.
layout(set = 1, binding = 0, scalar) uniform ubo { uint _m0[16]; } uniform_1_32[2];
layout(push_constant) uniform pc_t { int idx; } pc;
layout(location = 1) in vec4 icol;
layout(location = 0) out vec4 c;
void main() {
  uint k = uint(pc.idx) * 4u;
  c = icol * uintBitsToFloat(uvec4(uniform_1_32[pc.idx]._m0[k], uniform_1_32[pc.idx]._m0[k + 1u],
                                   uniform_1_32[pc.idx]._m0[k + 2u], uniform_1_32[pc.idx]._m0[k + 3u]));
}
