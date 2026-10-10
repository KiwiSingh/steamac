# Music-bank profiles (development)

BepisLoader imports `Ryo/Digimon Story Time Stranger/bgm/<bank>.acb/<cue>.cue/` HCA tracks and volume YAML alongside loose assets. Original filenames and bytes are retained in immutable source packages; `.DS_Store` folder metadata is ignored. Both `track.yaml` and `track.hca.yaml` are supported. Only the `volume` setting is implemented; unsupported settings, encrypted/truncated HCA, and unsupported bank layouts stop publication.

Distinct tracks targeting the same cue combine into a random CRI sequence. Matching source filenames follow profile priority, including volume-file conflicts. Loop information remains in each HCA. A self-contained ARM64 compiler reads the user's original CPK banks, builds embedded AFS2 banks, and preserves the original cue mapping/category sequence commands. Current support covers single-cue, single-track, memory-backed BGM templates; complex/streamed banks require further support.

The native loader matches the exact original bank SHA-256 and substitutes immutable compiled bytes through the game's CRI memory-bank function. The function RVA and prologue are checked only for the pinned executable. A failed replacement load falls back to the original bank. The MVGL texture/table hooks continue to operate. Existing Steam launch options remain unchanged.

Requires `assetAudioBanksV1` from the matching Steamac guest layer. Restart the VM after updating Steamac. Close the game before applying a profile. Source packages, previous snapshots and pinned loader backups are retained on the VM disk.

Implementation contains no Ryo runtime code/binaries. CRI UTF serialization uses the MIT-licensed SonicAudioLib subset at commit `178b025d7e17f5b781c678f738772871e0f1d30a`; source and license are included. User music and original game banks are never distributed.

Validation: synthetic bank round trips/random sequence/volume and input rejection passed; actual package compiled 46 tracks into 17 banks; native replacement/fallback callbacks passed in an isolated ARM64 Proton prefix. Checked combined live publication retained DigiRide and both costume mods: 1,759 files / 228,999,145 bytes. Audible playback, volume, looping and repeated random selection await gameplay confirmation.
