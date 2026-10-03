# Helpers shared by the in-container steps (sourced).

# newloop [losetup options] FILE -> prints /dev/loopN
# `docker run --privileged` gives the container a /dev snapshot taken at start,
# so loop devices the kernel allocates later have no node; create it.
newloop() {
    local l minor
    l=$(losetup -f) || return 1
    l=${l%% *}                       # "/dev/loop5 (lost)" when the node is missing
    minor=${l#/dev/loop}
    [[ -b $l ]] || mknod "$l" b 7 "$minor" || return 1
    losetup "${@:1:$#-1}" "$l" "${@: -1}" || return 1
    echo "$l"
}
