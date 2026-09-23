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

Running the binary directly opens a lightweight recorder window with an input
source picker and live waveform. Use `--no-gui` when embedding it in a local
service or when terminal-only control is preferred.

## Usage

List CoreAudio input devices:

```sh
.build/release/sysaudio-rec --list-devices
```

For local integrations, return the same devices as JSON:

```sh
.build/release/sysaudio-rec --list-devices-json
```

Record to a timestamped MP3 in `~/Downloads`:

```sh
.build/release/sysaudio-rec
```

On macOS 13 or newer, this uses native system audio capture. On macOS 12 and
older, this records from `Loopback Audio`.

Record from a different CoreAudio input device, including a microphone:

```sh
.build/release/sysaudio-rec --device "Some Other Device"
```

Run without the native window:

```sh
.build/release/sysaudio-rec --no-gui --device "Built-in Microphone"
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

## Use with Web Media Inspector

A web page cannot launch a local binary by itself, so
[Web Media Inspector](https://github.com/tangkk/web-media-inspector) talks to a
small local service that runs `sysaudio-rec` on your Mac. If the page says
`sysaudio-rec` is missing, or its Record button cannot connect, set it up like
this:

```sh
# 1. Build sysaudio-rec (see Build above)
git clone https://github.com/tangkk/sysaudio-rec.git ~/Projects/sysaudio-rec
cd ~/Projects/sysaudio-rec && swift build -c release

# 2. Start the local recording service (Node.js required)
git clone https://github.com/tangkk/web-media-inspector.git ~/Projects/web-media-inspector
cd ~/Projects/web-media-inspector
npm install
npm run recording-service   # or `npm run dev` to also serve the app locally
```

Keep the two repositories side by side under `~/Projects`, since the service
looks for `~/Projects/sysaudio-rec/.build/release/sysaudio-rec`. The service
listens on `http://localhost:5173`; keep it running while you record, then
reload the page. To start it automatically, use
`scripts/recording/start-recording-bridge.sh` from the web-media-inspector repo.
