# Music-bank profiles (development)

BepisLoader imports `Ryo/Digimon Story Time Stranger/bgm/<bank>.acb/<cue>.cue/` HCA tracks and volume YAML alongside loose assets. Original filenames and bytes are retained in immutable source packages; `.DS_Store` folder metadata is ignored. Both `track.yaml` and `track.hca.yaml` are supported. Only the `volume` setting is implemented; unsupported settings, encrypted/truncated HCA, and unsupported bank layouts stop publication.

Distinct tracks targeting the same cue combine into a random CRI sequence. Matching source filenames follow profile priority, including volume-file conflicts. Loop information remains in each HCA. A self-contained ARM64 compiler reads the user's original CPK banks, builds embedded AFS2 banks, and preserves the original cue mapping/category sequence commands. Current support covers single-cue, single-track, memory-backed BGM templates; complex/streamed banks require further support.

The native loader matches the exact original bank SHA-256 and substitutes immutable compiled bytes through the game's CRI memory-bank function. The function RVA and prologue are checked only for the pinned executable. A failed replacement load falls back to the original bank. The MVGL texture/table hooks continue to operate. Existing Steam launch options remain unchanged.

Requires `assetAudioBanksV1` from the matching Steamac guest layer. Restart the VM after updating Steamac. Close the game before applying a profile. Source packages, previous snapshots and pinned loader backups are retained on the VM disk.

Implementation contains no Ryo runtime code/binaries. CRI UTF serialization uses the MIT-licensed SonicAudioLib subset at commit `178b025d7e17f5b781c678f738772871e0f1d30a`; source and license are included. User music and original game banks are never distributed.

Banks and rebuilt child tables use SonicAudioLib's `Adx2Settings`, including 32-byte data alignment. An in-game control accepted the unchanged bank with automatic allocation. A serialization-only comparison rejected the default unaligned layout and accepted the ADX2 layout with identical parsed contents. Regression checks cover alignment of the root and all rebuilt child tables.

Volume YAML is honored. For example, `volume: 0.3` attenuates the replacement to 30%; it is not a default volume imposed by BepisLoader. Users can import a separate settings-only package with the same Ryo folder/YAML paths and give its files priority in the conflict review. `volume: 1.0` requests full volume. Keep the original music package enabled: settings without matching HCA tracks are rejected. Disable the settings package to restore the author's values. Original downloads remain unchanged.

Validation: compiler round trips/random sequence/volume/input rejection and alignment checks passed on macOS and ARM64 Linux; the actual package compiled 46 tracks into 17 banks. All 17 root tables and rebuilt child tables passed independent alignment/hash checks. Native replacement/fallback callbacks passed in an isolated ARM64 Proton prefix. Checked combined live publication retained DigiRide and both costume mods: 1,759 files / 229,006,998 bytes. The user confirmed classic playback for Looming Threat and comfortable volume/clean looping with a separately installed full-volume overlay. That overlay changed only the Looming Threat bank; every other compiled music/asset hash remained identical. Other cues and extended random-selection behavior have not received the same gameplay confirmation.

The new app bundles and releases remain subject to fresh bundle audit. Private game banks, downloaded tracks, diagnostic loaders and the personal volume overlay are not release assets.
