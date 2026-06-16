# sysaudio-rec

`sysaudio-rec` is a macOS command-line recorder for currently playing system audio.
It records through `ScreenCaptureKit`, so it captures system output regardless of
which output device the audio is routed to. It writes MP3 in real time and stops
cleanly on `Ctrl-C`.

## Requirements

- macOS 13 or newer
- Xcode command-line tools / Swift
- `ffmpeg`

Install `ffmpeg`:

```sh
brew install ffmpeg
```

Native route-independent system audio capture is not available on macOS 12.
On macOS 12 and older, a virtual audio device workflow such as BlackHole is
required, but that cannot satisfy the "capture regardless of output route"
requirement.

The first run may prompt for Screen Recording permission. If capture does not
start, allow the terminal app you are using in:

`System Settings -> Privacy & Security -> Screen & System Audio Recording`

## Build

```sh
swift build -c release
```

The binary will be at:

```sh
.build/release/sysaudio-rec
```

## Usage

Record to a timestamped MP3 in `~/Downloads`:

```sh
.build/release/sysaudio-rec
```

Record into a directory:

```sh
.build/release/sysaudio-rec ~/Downloads/recordings
```

Record to a specific file:

```sh
.build/release/sysaudio-rec ~/Downloads/session.mp3
```

Stop recording with `Ctrl-C`.
