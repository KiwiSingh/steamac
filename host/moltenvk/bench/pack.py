#!/usr/bin/env python3
"""A fixed random sample of a MoltenVK shader dump (MVK_CONFIG_SHADER_DUMP_DIR) for shaders.sh: most shaders of a
game are variants of each other, so a seeded 10% gives the same per-shader picture in a tenth of the time.

  host/moltenvk/bench/pack.py <dump dir> <pack dir> [--percent 10] [--seed 1] [--match TEXT]

Samples PERCENT of the vertex + fragment pipelines (pipeline-<hash>.txt with their shaders), of the geometry
shader pipelines (pipeline-gs-*.txt) and of the compute shaders, and copies them with their SPIR-V and MSL.
--match keeps only shaders whose MSL contains TEXT (pipelines by their vertex shader), e.g. RootConstants for
vkd3d-proton's (the dump also holds the Steam client's). The pack holds the game's shaders: keep it under work/.
"""
import argparse
import os
import random
import shutil


def shader_files(dump, kind, h):
    return [f"shader-{kind}-{h}.spv", f"shader-{kind}-{h}.metal"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dump")
    ap.add_argument("pack")
    ap.add_argument("--percent", type=float, default=10)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--match")
    a = ap.parse_args()

    names = set(os.listdir(a.dump))

    def has_shader(kind, h):
        if not all(f in names for f in shader_files(a.dump, kind, h)):
            return False
        if a.match:
            with open(os.path.join(a.dump, f"shader-{kind}-{h}.metal"), errors="replace") as f:
                return a.match in f.read()
        return True

    def stages(name):
        out = {}
        with open(os.path.join(a.dump, name)) as f:
            for line in f:
                key, _, value = line.strip().partition(": ")
                if key in ("VS", "GS", "FS") and value:
                    out[key.lower()[0] + "s"] = value
        return out

    pipelines, gs_pipelines, computes = [], [], []
    for name in sorted(names):
        if name.startswith("pipeline-gs-") and name.endswith(".txt"):
            st = stages(name)
            if st and all(has_shader(k, h) for k, h in st.items()):
                gs_pipelines.append((name, st))
        elif name.startswith("pipeline-") and name.endswith(".txt"):
            st = stages(name)
            if "vs" in st and all(has_shader(k, h) for k, h in st.items()):
                pipelines.append((name, st))
        elif name.startswith("shader-cs-") and name.endswith(".spv"):
            h = name[len("shader-cs-"):-len(".spv")]
            if has_shader("cs", h):
                computes.append(h)

    rng = random.Random(a.seed)

    def sample(items):
        n = max(1, round(len(items) * a.percent / 100)) if items else 0
        return sorted(rng.sample(items, n))

    picked_p, picked_g, picked_c = sample(pipelines), sample(gs_pipelines), sample(computes)
    os.makedirs(a.pack, exist_ok=True)
    files = set()
    for name, st in picked_p + picked_g:
        files.add(name)
        for kind, h in st.items():
            files.update(shader_files(a.dump, kind, h))
    for h in picked_c:
        files.update(shader_files(a.dump, "cs", h))
    for f in sorted(files):
        shutil.copy2(os.path.join(a.dump, f), os.path.join(a.pack, f))
    kinds = {}
    for f in files:
        if f.startswith("shader-") and f.endswith(".spv"):
            kinds[f[7:9]] = kinds.get(f[7:9], 0) + 1
    summary = (f"{a.percent:g}% of {a.dump} (seed {a.seed}{', match ' + a.match if a.match else ''}): "
               f"{len(picked_p)}/{len(pipelines)} vertex+fragment pipelines, {len(picked_g)}/{len(gs_pipelines)} "
               f"geometry shader pipelines, {len(picked_c)}/{len(computes)} compute shaders; shaders "
               + ", ".join(f"{k} {v}" for k, v in sorted(kinds.items())))
    with open(os.path.join(a.pack, "PACK.txt"), "w") as f:
        f.write(summary + "\n")
    print(summary)


if __name__ == "__main__":
    main()
