# FFmpeg Tools

A set of interactive Bash tools for converting, compressing, trimming, merging and GIF-ing video with FFmpeg. They are built for **Termux on Android** (phone-friendly menus, thermal protection, low-CPU defaults) but also run on regular Linux.

| Script | What it does |
| --- | --- |
| `convert.sh` | Batch video converter with a full settings menu, chunked encoding, resume support and failure diagnostics |
| `compress.sh` | Compress videos to a target file size or bitrate (H.264 / AV1), optional resolution cap, video → GIF |
| `trim.sh` | Cut, split and join parts of a video, either losslessly (stream copy) or with exact re-encoded cuts |
| `merge.sh` | Merge all videos in one or more folders into a single file per folder |
| `v2g.sh` | Batch Video → GIF and GIF → Video converter |

`convert.sh` loads the `lib-*.sh` files next to it. The other four scripts are standalone.

---

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [convert.sh](#convertsh)
- [compress.sh](#compresssh)
- [trim.sh](#trimsh)
- [merge.sh](#mergesh)
- [v2g.sh](#v2gsh)
- [Default folders and environment overrides](#default-folders-and-environment-overrides)
- [Project layout](#project-layout)
- [Troubleshooting](#troubleshooting)

---

## Requirements

**Always needed**

- Bash 4.0 or newer
- `ffmpeg` and `ffprobe`
- Standard tools: `awk`, `sed`, `grep`, `find`, `xargs`, `sort`, `stat`, `realpath`, `du`, `date`, `sha256sum` and friends (all included in Termux's `coreutils`, `findutils`, `gawk`, `grep`, `diffutils`)

**Encoders (depending on what you use)**

- `libx264`, `libopus` (compress/trim/GIF→video defaults)
- `libsvtav1` (default codec in `convert.sh`; optional AV1 in `compress.sh`)
- `libx265`, `libvpx`, `libvpx-vp9`, `libaom-av1` (selectable in `convert.sh`)

**Optional**

- `mkvmerge` (package `mkvtoolnix`): `merge.sh` uses it first, then falls back to FFmpeg concat. `convert.sh` also checks for it at startup.
- `termux-api` plus the Termux:API app: battery-temperature guard in `compress.sh`
- `mediainfo`: last-resort bitrate fallback in the probe library

### Termux setup

```bash
pkg update
pkg install ffmpeg coreutils findutils gawk grep sed diffutils
# optional, for merge.sh / convert.sh:
pkg install x11-repo && pkg install mkvtoolnix
# optional, for the temperature guard in compress.sh:
pkg install termux-api

# give Termux access to /sdcard (needed for the default folders):
termux-setup-storage
```

`convert.sh` checks its dependencies on launch and prints the exact `pkg install` line for anything missing.

---

## Installation

1. Put all 14 files in the same folder (for example `~/ffmpeg_tools`).
2. Make them executable:

   ```bash
   chmod +x ~/ffmpeg_tools/*.sh
   ```

   If you downloaded them to your phone's Downloads folder, you can copy them into Termux's home first:

   ```bash
   cp /sdcard/Download/*.sh "$HOME/" && chmod +x "$HOME"/*.sh
   ```

3. Run any script from that folder, e.g. `./convert.sh`.

> **Keep `convert.sh` and every `lib-*.sh` file together.** `convert.sh` exits with an error if a module is missing.

---

## convert.sh

The main tool. It converts a single file or a whole folder using one set of settings and shows a live progress bar with ETA.

### Usage

```bash
./convert.sh                      # interactive menu
./convert.sh /path/to/video.mp4   # convert one file with the saved settings
./convert.sh /path/to/folder      # convert every video in a folder
```

With a path argument it skips the menu and exits with a non-zero status if any file failed, so it is usable from scripts and cron.

### Main menu

| Key | Action |
| --- | --- |
| `1` | Video codec: SVT-AV1 (default), H.264, H.265, VP8, VP9, libaom-AV1 |
| `2` | Quality (CRF), lower = better |
| `3` | Speed preset |
| `4` | Audio codec: Opus (default), AAC, FLAC, MP3, or copy |
| `5` | Audio bitrate |
| `6` | Advanced settings (below) |
| `7` | Start. Enter a path, or press Enter to use the default input folders |
| `8` | Save settings to the config file |
| `9` | Diagnose (open the failure-diagnosis menu) |
| `0` | Exit |

Choosing a codec also sets sensible defaults for preset and container (e.g. SVT-AV1 → preset 6 / `mkv`, H.264 → `medium` / `mp4`) and warns when your bitrate limits do not suit the codec.

### Advanced settings

- **Output format:** mkv, mp4, webm, mov, avi
- **Pixel format:** copy source, force 8-bit (`yuv420p`), or force 10-bit (`yuv420p10le`)
- **Frame rate:** `auto` (constant frame rate only for variable-frame-rate sources) or `source` (never touch timing)
- **Bitrate limits:** optional `maxrate` / `bufsize` with per-codec sanity checks
- **Chunk threshold:** files longer than this are split into chunks (default 30 min)
- **Chunk duration:** default (30–35 min chunks) or a manual length
- **Cooldown:** fixed pause between files/chunks, or *auto* (waits on CPU temperature)
- **Scaling:** OFF, 720p, 1080p or a custom resolution, always keeping aspect ratio
- **Sharpening:** optional edge-aware sharpening (slower)
- **Progress style:** simple, or an advanced bar (horizontal blocks, ASCII, shading, braille)
- **File sorting:** order in which a batch is processed
- **CPU threads:** keep this low (1–4) on phones

### Built-in defaults

| Setting | Default |
| --- | --- |
| Video codec | `libsvtav1`, CRF 20, preset 6 |
| Audio | `libopus`, 80 kbps |
| Container | `mkv` |
| Chunk threshold | 1800 s |
| Cooldown | 600 s |
| CPU threads | 2 |
| Output folder | `/sdcard/Movies/ffmpeg/Converted` |

### Features

- **Batch confirmation:** shows a paged file list and lets you review before starting.
- **Chunked encoding with resume:** long files are split, encoded piece by piece and merged. If you stop mid-way, the chunk folder is kept; rerun the script and it picks up where it left off.
- **Completion markers:** finished inputs are recorded (by a hash of their path) so reruns skip them.
- **Integrity checks:** inputs are probed and checked before encoding.
- **Logs:** per-file FFmpeg logs are kept in the log folder.
- **Clean interrupt handling:** Ctrl+C stops FFmpeg and reports what was preserved.

### Failure diagnostics and recovery

When a file fails, `convert.sh` does not stop the batch. It:

1. Classifies the failure (corrupt input, truncated file, decode errors, out of space, etc.).
2. Isolates the problem media into a `.ffmpeg_diagnostics/<timestamp>/` folder inside the batch's input folder, with a failure report.
3. After the batch, offers a **diagnosis menu** (also reachable with `9` from the main menu) that walks through decode tests on the source and output step by step and can **recover** the video and/or audio stream, re-mux them, and verify the result.

### Configuration file

Press `8` to save settings to `video_converter.conf`. The file next to the script is used if it exists; otherwise a `video_converter.conf` in the current directory is used if present; otherwise a new one is created next to the script. It is a plain `KEY="value"` file and can be edited by hand.

---

## compress.sh

Interactive compressor aimed at hitting a size or bitrate target, with protection for phone CPUs and batteries.

```bash
./compress.sh
```

You are prompted for an input file or folder; then:

| Key | Action |
| --- | --- |
| `1` | Compress to a **target size** (MB) |
| `2` | Compress to a **target bitrate** |
| `3` | Compression method: **H.264** or **AV1** (SVT-AV1) |
| `4` | Resolution cap (`Disabled` or `WIDTHxHEIGHT`) |
| `5` | Convert video to **GIF** (two-pass palette, size-targeted retries) |
| `6` | Exit |
| `T` | CPU / thermal settings |

**Notes**

- "MB" means MiB (1024 × 1024 bytes).
- Audio is encoded as Opus (64 kbps by default, and that amount is reserved when targeting a size). Size targets that would need less than 50 kbps of video bitrate are refused.
- If a size target is overshot, the file is re-encoded once more by default (`MAX_SIZE_RETRIES`).
- Existing output files are handled by `OVERWRITE_POLICY` (`rename` | `skip` | `overwrite`).
- A warning is shown for GIFs from clips longer than 30 seconds.
- **Thermal guard** (needs `termux-api`): pauses encoding when battery temperature exceeds a limit (default 40 °C) and resumes at 37 °C. Also configurable: thread count, `nice` level, cooldown between files, x264 preset.

Default output folder: `/sdcard/Movies/ffmpeg/Compressed`. Edit the settings block at the top of the script or use the in-app menus.

---

## trim.sh

Cut or split a video from the command line or an interactive menu.

```bash
./trim.sh                                    # interactive menu
./trim.sh FILE RANGES...                     # cut ranges (START-END)
./trim.sh FILE TIMESTAMPS...                 # split at the given points
./trim.sh FILE N                             # split into N equal parts (N >= 2)
```

**Options (after FILE)**

| Option | Meaning |
| --- | --- |
| `-e`, `--encode` | Re-encode for exact cuts (MP4 output) instead of stream copy |
| `--size MB` | Re-encode and aim for roughly this size per output file |
| `--crf N` | H.264 quality, 0–51 (default 23) |
| `--preset NAME` | x264 preset (default `medium`) |
| `-h`, `--help` | Show help |

**Time format**

Dot-separated, from the right: seconds, minutes, hours, milliseconds.

| Written | Means |
| --- | --- |
| `1` | 1 s |
| `10.1` | 10 min 1 s |
| `4.1.10` | 4 h 1 min 10 s |
| `0.0.1.500` | 1.5 s |
| `s` / `e` | start / end of the video |

A single number as the only argument means "split into N equal parts", so use `0.5` for a cut at 5 seconds.

**Example**

```bash
./trim.sh video.mp4 s-11 2.2-4.4.4 m 5.5.5.555-e
```

Produces two outputs: (1) 0–11 s, and (2) `00:02:02–04:04:04` joined (`m`) with `05:05:05.555–end`.

**Copy vs re-encode**

- *Copy* is instant and keeps the original format, but cuts snap to keyframes.
- *Re-encode* is slower but frame-accurate. Audio is AAC so it plays everywhere.

Defaults can be overridden via environment: `OUTDIR`, `VCODEC`, `THREADS`. Default output: `/sdcard/Movies/ffmpeg/Trimmed`. Finished parts are kept if you abort; the unfinished one is removed.

---

## merge.sh

Merges every video in a folder into one file, in name order.

```bash
./merge.sh "/sdcard/Movies/Trip/Day 1" "/sdcard/Movies/Trip/Day 2"
./merge.sh                      # prompts for folders, one per line; blank line to finish
```

- Accepts `.mp4`, `.mkv`, `.webm`, `.mov`. Hidden files are ignored.
- Folders are searched at any depth: if a given folder has no videos itself, each subfolder containing videos is merged separately under its own folder name.
- **Method:** `mkvmerge` when available (output is Matroska), otherwise FFmpeg's concat demuxer. Concat needs all files to share the same codec, resolution and audio format, and the script refuses otherwise.
- Folders with a single video are skipped. The output folder is never scanned, so earlier merges are not merged again.
- Checks free space first and prints a batch summary (successful / failed / skipped). Exits non-zero if any folder failed.

Output folder: `/sdcard/Movies/ffmpeg/Merged` (override with `MERGE_OUTDIR=/path ./merge.sh ...`).

---

## v2g.sh

Standalone batch converter between video and animated GIF, with its own menu.

- **Video → GIF:** two-pass `palettegen` / `paletteuse`, dither and palette-stats options, optional start time and duration.
- **GIF → Video:** MP4 (H.264), WebM (VP9) or MKV, with CRF, preset, pixel format and VP9 quality settings.
- Frame rate and width can each follow the source (`dynamic`) or be fixed.
- FFmpeg thread count defaults to 1 for the lowest CPU load.

Default folders (all editable from the menu or at the top of the script):

| Purpose | Path |
| --- | --- |
| Video → GIF input | `/sdcard/Movies/ffmpeg/Converted` |
| Video → GIF output | `/sdcard/Movies/ffmpeg/GIF/Video-to-GIF` |
| GIF → Video output | `/sdcard/Movies/ffmpeg/GIF/GIF-to-Video` |

---

## Default folders and environment overrides

| Script | Default output | Override |
| --- | --- | --- |
| `convert.sh` | `/sdcard/Movies/ffmpeg/Converted` | Settings menu / config file |
| `compress.sh` | `/sdcard/Movies/ffmpeg/Compressed` | `COMPRESS_OUTDIR` |
| `trim.sh` | `/sdcard/Movies/ffmpeg/Trimmed` | `OUTDIR` |
| `merge.sh` | `/sdcard/Movies/ffmpeg/Merged` | `MERGE_OUTDIR` |
| `v2g.sh` | `/sdcard/Movies/ffmpeg/GIF/...` | Menu / top of script |

`convert.sh` looks for input in `/sdcard/Movies/ffmpeg/Job` and `/storage/F437-7513/Movies/ffmpeg/Job` (the second is an SD-card path; change `DEFAULT_INPUT_DIR_2` in `convert.sh` to match your card's ID), unless you give it a path. Its logs go to `/sdcard/Movies/ffmpeg/Logs` and completion markers to `/sdcard/Movies/ffmpeg/.video_status/completed` unless changed in the config.

Debugging aid for `convert.sh`: `VERBOSE_LOAD=1 ./convert.sh` lists each module and the functions it loads.

---

## Project layout

```
convert.sh              Main converter (entry point)
├─ lib-config.sh        Config load/save, completion markers, dependency check, bitrate/scaling rules
├─ lib-probe.sh         ffprobe helpers: stream info, bitrates, integrity checks, fps handling
├─ lib-encode.sh        Batch queue, ETA, chunking, FFmpeg encode, chunk merge
├─ lib-diagnostics.sh   Failure classification, isolation, reports, post-batch menu
├─ lib-diag-recovery.sh Step-by-step diagnosis and stream recovery
├─ lib-ui-kit.sh        Terminal UI primitives (rows, boxes, prompts, colours)
├─ lib-ui-info.sh       Input/output info panels and progress bars
├─ lib-ui-main_menu.sh  Main menu
└─ lib-ui-adv_menu.sh   Advanced settings menu

compress.sh             Standalone: size/bitrate compression and GIF
trim.sh                 Standalone: cut, split, join
merge.sh                Standalone: folder merge
v2g.sh                  Standalone: video <-> GIF
```

---

## Troubleshooting

**"Cannot create or write" a folder under `/sdcard`**
Run `termux-setup-storage` and accept the permission prompt.

**`convert.sh`: "FAILED TO LOAD" or "MISSING REQUIRED FUNCTION"**
A `lib-*.sh` file is missing or in a different folder. Keep them all next to `convert.sh`.

**"MISSING DEPENDENCIES"**
Run the `pkg install ...` command the script prints. `mkvmerge` needs `x11-repo` first.

**Encoder not available**
Your FFmpeg build may not include `libsvtav1`, `libx265`, etc. Check with `ffmpeg -encoders | grep -i av1`, or pick a different codec.

**Phone gets hot or throttles**
Lower CPU threads, raise the preset number (faster), enable cooldown (auto in `convert.sh`), or turn on the thermal guard in `compress.sh`.

**`merge.sh`: "files do not share the same codec / size / audio format"**
FFmpeg concat can only join identical streams. Install `mkvtoolnix` (it handles more cases), or re-encode the files to matching settings first with `convert.sh`.

**Trim cuts are a bit off**
Copy mode snaps to keyframes. Use `-e` / `--encode` for exact cuts.

**Windows line endings**
If a script fails with `\r: command not found`, convert it with `sed -i 's/\r$//' *.sh`.
