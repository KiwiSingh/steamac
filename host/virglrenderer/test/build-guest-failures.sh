#!/bin/sh
# Cross-build guest_failures.c for the arm64 SteamOS guest (Debian bookworm arm64 container:
# gcc, the Vulkan headers/loader stub and glslang for the SPIR-V).
#   host/virglrenderer/test/build-guest-failures.sh   ->  work/build/guest-failures/guest_failures
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
out=$root/work/build/guest-failures
mkdir -p "$out"
cp "$here/guest_failures.c" "$out/"

cat > "$out/guest_failures.vert" << 'EOF'
#version 450
void main()
{
    vec2 p = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
EOF
cat > "$out/guest_failures.frag" << 'EOF'
#version 450
layout(location = 0) out vec4 color;
void main()
{
    color = vec4(1.0, 0.5, 0.25, 1.0);
}
EOF
# Metal has no double: SPIRV-Cross emits it and the MSL does not compile (a host failure that
# does not depend on MoltenVK's limits)
cat > "$out/guest_failures_bad.frag" << 'EOF'
#version 450
layout(location = 0) out vec4 color;
layout(push_constant) uniform P { float x; } p;
void main()
{
    double d = double(p.x) * 1.000000001lf;
    color = vec4(float(d));
}
EOF
cat > "$out/guest_failures.comp" << 'EOF'
#version 450
layout(local_size_x_id = 0) in;
void main()
{
}
EOF

docker run --rm --platform linux/arm64 -v "$out:/w" -w /w debian:bookworm sh -c '
    set -eu
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        gcc libc6-dev libvulkan-dev glslang-tools > /dev/null
    spv() { glslangValidator -V --vn "$1" -o "$1.h" "$2" > /dev/null; }
    spv guest_failures_vert guest_failures.vert
    spv guest_failures_frag guest_failures.frag
    spv guest_failures_frag_bad guest_failures_bad.frag
    spv guest_failures_comp guest_failures.comp
    cat guest_failures_vert.h guest_failures_frag.h guest_failures_frag_bad.h \
        guest_failures_comp.h > guest_failures_spv.h
    gcc -std=c11 -O2 -Wall -Wextra -Werror -pthread -o guest_failures guest_failures.c -lvulkan
'
echo ">> $out/guest_failures"
