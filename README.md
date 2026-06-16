# sysaudio-rec

`sysaudio-rec` is a macOS command-line audio recorder. On macOS 13 or newer, it
records system audio through `ScreenCaptureKit`, so it captures system output
regardless of which output device the audio is routed to. On macOS 12, it can
record from a Loopback virtual audio input.

## Requirements

- macOS 13 or newer for native route-independent system audio capture
- macOS 12 with Loopback for `--device` recording
- Xcode command-line tools / Swift
- `ffmpeg`

Install `ffmpeg`:

```sh
brew install ffmpeg
```

Native route-independent system audio capture is not available on macOS 12. On
macOS 12, use Loopback and pass the Loopback device name with `--device`.

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

List devices visible to `ffmpeg`:

```sh
.build/release/sysaudio-rec --list-devices
```

Record native system audio to a timestamped MP3 in `~/Downloads` on macOS 13+:

```sh
.build/release/sysaudio-rec
```

Record from Loopback on macOS 12:

```sh
.build/release/sysaudio-rec --device "Loopback Audio"
```

Record into a directory:

```sh
.build/release/sysaudio-rec --device "Loopback Audio" ~/Downloads/recordings
```

Record to a specific file:

```sh
.build/release/sysaudio-rec --device "Loopback Audio" ~/Downloads/session.mp3
```

Stop recording with `Ctrl-C`.
