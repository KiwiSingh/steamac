# Checked asset-mod publication for BepisLoader

Adds `assetModInstallV1` to the existing `bepis.sock` handshake. `asset-mod-install <appid> <adapter> <encoded-stage>` validates the selected game, package, pinned x64 bootstrap payloads and file hashes, publishes a unique asset bundle with Linux `renameat2(RENAME_NOREPLACE)`, and links bootstrap files without replacement. It does not run arbitrary commands or change Steam Launch Options. The game must be closed; Steam may stay open.

The first adapter is `dsts-mvgl-v1`, for Digimon Story Time Stranger AppID 1984270 and executable SHA-256 `ff9de825a543bf874cfb7e73ed951256d3ce4e8702957afa3b26ca6487a81688`. raw asset files are bounded (4096 files, 64 MiB per file, 256 MiB total), matched case-insensitively and hashed against the manifest. Symlinks, special files, unsupported adapters, unexpected staged files, conflicting native loaders and incorrect payload hashes are rejected. Staged bootstrap bytes use `.payload` names so incomplete staging is not an ASI search target. Partial failures retain their evidence and never authorize launch.

`asset-mod-disable <appid>` parks only the checked, pinned native ASI under a non-ASI filename using no-replace publication. Assets are retained. Existing generic mod-launch reservations and recovery/installation gates remain unchanged. Current recovery-inventory source changes are included in this branch so installing the companion agent does not discard that work.

BepisLoader reports the exact manual launch setting after installation. It specifies the published asset path, executable hash, and native winmm override. There is no Steam shutdown, restart, automatic VDF rewrite or direct launch bypass.

The native adapter's corresponding source is in https://github.com/KiwiSingh/unloaded-ii-linux/tree/codex/arm64-linux/src/native/mvgl-assets . It is independently implemented under that repository's GPL-3.0 license, uses MIT-licensed DSTS signatures and BSD-licensed MinHook, and bypasses the unresolved managed Reloaded-II hosting path.

Validation: host unit suite; prior ARM64 VM suite including the Linux no-replace test; GitHub Actions checks final source on Linux x64 and ARM64. BepisLoader's actual eye-texture replacement was also visually confirmed in ARM64 SteamOS/x64 Proton gameplay. None of these observations constitutes a runtime attestation for arbitrary future games or mods.

## Combined profiles (Kiwi Build 6 development)

`assetModProfilesV1` adds `asset-profile-state <appid>` and `asset-profile-publish <appid> <adapter> <encoded-stage>`. State is stored as bounded `profile.json` inside the active snapshot and derives from the stable `.bepis-assets-active` pointer. The state request returns its current immutable root as a base token; stale updates fail before publication. Known older single-package bundles are discovered disabled for initial review.

A stage contains the usual assets, manifest and pinned bootstrap payloads plus profile metadata describing up to 64 ordered, enabled/disabled package references. The guest verifies each referenced package and its exact bytes, recomputes case-insensitive conflict winners from load order, and checks that the supplied merged manifest matches. Referenced snapshot bytes are bounded to 256 MiB. Empty composites are accepted only as explicit profiles; the native adapter remains inert when there are no active assets.

Publication retains immutable bundles. First activation uses no-replace rename; subsequent activation exchanges the owned pointer atomically with renameat2(RENAME_EXCHANGE), checks the displaced link against the expected previous pointer and retains it. Unexpected raced-in content is restored and retained rather than deleted. Changing the profile never edits Steam settings or deletes packages. Close the game before applying; native asset bytes are snapshotted at launch.
