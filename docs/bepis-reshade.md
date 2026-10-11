# ReShade installation bridge

`reShadeInstallV1` is advertised by the bundled guest agent. Steamac forwards these commands over its existing Bepis bridge; it does not rewrite Steam's VDF or launch options.

- `reshade-target <appid> <encoded-executable>` returns `reshade-target <encoded-directory> <sha256>`. Discovery confines the target to that AppID's Steam library directory, checks a regular Windows x64 executable and requires the game closed before staging begins.
- `reshade-install <appid> <encoded-stage>` returns `reshade-installed`. The stage must be a unique `.bepis-reshade-stage-<uuid>` directory beside the executable. `manifest.json` identifies schema 1, AppID, absolute executable and its hash, package name, and a path-to-SHA256 `files` object. Payloads live under `files/`.
- `reshade-state <appid> <encoded-executable>` returns `reshade-state installed` or `reshade-state absent`. This is read-only and can run during gameplay. It checks the saved receipt, DXGI runtime and pinned compiler; damaged installations return an error instead of silently omitting required overrides.

Root payloads are ReShade `dxgi.dll`, the pinned x64 `d3dcompiler_47.dll`, preset/configuration `.ini` files and x64 `.addon64` files. Shader/texture content lives beneath `reshade-shaders/`. Other root DLLs, executables, absolute paths, traversal, symbolic links and case aliases are rejected. Packages are limited to 256 MiB, 4,096 files and 64 MiB per file. ReShade binary identity checks establish layout/architecture, not author trust; the UI explicitly identifies executable addons before installation.

Publication uses a nonblocking per-directory lock and exclusive staging copies. Identical destination bytes are retained. A differing destination is replaceable only when its exact old hash is recorded in `.bepis-reshade.json`; game files and user edits cannot be overwritten. Managed replacements use atomic exchanges, retaining the old bytes in `transaction/`. Failures roll back only this transaction's exact new bytes; journals are retained for inspection/recovery. A running game stops publication. Successful installation writes the receipt only after payload publication.

The host selects a preset and prepares portable ReShade configuration. Launch guidance combines `dxgi=n,b;d3dcompiler_47=n,b` with existing overrides and the managed asset loader's `winmm=n,b` when active. Users copy it into Steam manually; Steam can stay open. ReShade runtime/shader/addon packages are supplied by the user, and the Microsoft SDK component is downloaded and hash-verified on demand rather than redistributed with either app.

Tests: `cargo test --locked --manifest-path guest/progress-agent/Cargo.toml --bin fx-bepis-agent`. `examples/reshade-install.rs` invokes the same installer for isolated fixtures and explicit manual deployments; it does not bypass checks.
