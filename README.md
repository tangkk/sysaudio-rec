# sysaudio-rec

`sysaudio-rec` is a macOS command-line audio recorder. On macOS 13 or newer, it
records system audio through `ScreenCaptureKit`, so it captures system output
regardless of which output device the audio is routed to. On macOS 12 and older,
it records from the `Loopback Audio` virtual input by default.

## Requirements

- macOS 13 or newer for native route-independent system audio capture
- macOS 12 with a Loopback device named `Loopback Audio`
- Xcode command-line tools / Swift
- `ffmpeg`

Install `ffmpeg`:

```sh
brew install ffmpeg
```

Native route-independent system audio capture is not available on macOS 12. On
macOS 12 and older, the default recorder uses a Loopback device named
`Loopback Audio`. The Loopback fallback records through CoreAudio, uses the
device's actual sample rate and channel layout, and writes PCM to `ffmpeg` from
a background queue so the realtime audio callback is not blocked. If the device
has more than two input channels, the recorder uses channels 1 and 2 for the
MP3. Use `--device` only if your virtual input has a different name.

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

List CoreAudio input devices:

```sh
.build/release/sysaudio-rec --list-devices
```

Record to a timestamped MP3 in `~/Downloads`:

```sh
.build/release/sysaudio-rec
```

On macOS 13 or newer, this uses native system audio capture. On macOS 12 and
older, this records from `Loopback Audio`.

Record from a different CoreAudio input device:

```sh
.build/release/sysaudio-rec --device "Some Other Device"
```

Record into a directory:

```sh
.build/release/sysaudio-rec ~/Downloads/recordings
```

Record to a specific file:

```sh
.build/release/sysaudio-rec ~/Downloads/session.mp3
```

Stop recording with `Esc` or `Ctrl-C`.
