# Sound Sync

Sound Sync plays whatever is playing on a Mac through two Bluetooth speakers at the same time, and keeps them lined up.

It is a menu-bar app. It captures system audio, sends that audio to both speakers, and uses the Mac microphone to measure how late each speaker is. A later calibration also compares their tone and turns down the bands where one speaker is weaker, without trying to make them equally loud.

The app looks for a **JBL Pulse 4** and a **Sony SRS-XB13**. Those are the speakers it was built around. Another pair means changing the name checks described at the end.

## What you need

- A Mac on **macOS 15 or later** (Apple silicon or Intel; the build script targets `arm64`, so an Intel Mac needs the target in `build.sh` changed to `x86_64` or a universal build)
- **Xcode** installed, from the App Store or [developer.apple.com](https://developer.apple.com/xcode/). Command Line Tools alone are not enough, because the app uses the macOS SDK and Swift.
- The Xcode license accepted once:

  ```sh
  sudo xcodebuild -license
  ```

- Two Bluetooth speakers already paired in **System Settings → Bluetooth**:
  - one whose name contains `Pulse` (the Pulse 4)
  - one whose name contains `XB13` (the SRS-XB13)
- Both speakers in the **same room as the Mac**, close enough that the built-in microphone can hear a short sweep from each
- The Mac sitting **where you listen**. Delay and tone are measured at the microphone, so that is the spot that stays in sync

## Build

```sh
git clone https://github.com/rogue-socket/sound_sync.git
cd sound_sync
chmod +x build.sh
./build.sh
open build/SoundSync.app
```

`./build.sh` does three things:

1. Runs the chirp and tone checks.
2. Builds `build/SoundSync.app` and ad-hoc signs it.
3. Plays a short system sound and checks that system-audio capture hears it. You should hear that sound once during the build.

The script asks `xcrun` for the SDK. If the Xcode license has not been accepted, it falls back to `/Applications/Xcode.app`.

Build products stay in `build/` and are gitignored.

## First launch

Open the app. A **Sound Sync** window appears, a **Sync** item shows in the menu bar, and a Sound Sync icon shows in the Dock.

Turn the switch on. macOS will ask for permission. Allow all of these:

| Prompt | Why |
| --- | --- |
| Bluetooth | Connects to the Pulse 4 and the SRS-XB13 |
| Microphone | Hears the test sweep during calibration |
| System audio | Captures music, the browser, and anything else playing on the Mac |

If a prompt was dismissed, turn the app off and on again, or enable Sound Sync under **System Settings → Privacy & Security** for Bluetooth, Microphone, and System Audio Recording.

Both speakers need to be powered on before you flip the switch. The app connects them, sends all Mac audio to both, and silences the MacBook speakers. Turning the app off restores the output device that was selected before.

## Calibrate

Press **Calibrate** with the room quiet and both speakers connected.

The app checks that both speakers are still connected, then plays a sweep through one speaker at a time while the Mac microphone listens. For that sweep it turns that speaker’s own volume all the way up, then puts the volume back. The sliders in the window do not affect the test tone.

When it finishes, the window shows:

- which speaker is being delayed, and by how many milliseconds
- which speaker is carrying more of the lows, mids, or highs, if their tone differs

Sit the Mac where you listen before you calibrate. If you move a speaker, calibrate again.

## Volume

- The **Mac volume keys** scale both speakers together. The window shows the current Mac volume while Sound Sync is on.
- The **Pulse 4** and **SRS-XB13** sliders are trims on top of that. Leave them different if one speaker is quieter. Together they cover the room. The app does not try to make them the same loudness.

## Tone split

After a calibration, the window lists the cut applied to each speaker, in dB, for lows, mids, and highs. A cut is zero or negative. The speaker that measured stronger in a band is left alone. The weaker one is turned down in that band, by at most 8 dB.

**Tone split** turns those cuts off and back on so you can hear whether the split helps. The sliders do not change.

The measurement is done in the room, with this Mac’s microphone. The app does not download a published frequency curve. It also does not boost a band to invent bass a small speaker cannot produce.

## While it is running

**Quiet recheck.** After you have calibrated once, play something, then let it go quiet for a few seconds. Sound Sync plays the sweep again and updates the delay. The window says **Rechecking delay** while that happens. It does not do this the moment you turn the app on, and it does not do it in the middle of a song.

**Dropped speaker.** If either speaker disconnects, that side pauses and the app tries to connect it again. When it comes back, calibrate again. A new Bluetooth connection does not keep the old delay.

## Limits

Two classic Bluetooth speakers do not share a clock. The delay measured at the Mac is right at that moment, at the microphone. It drifts over a song, which is why the quiet recheck exists. Standing somewhere other than the Mac will not match the measurement.

macOS has to keep both speakers connected as separate audio outputs. If one will not connect, turn it off and on, then switch Sound Sync on again.

## Use a different pair

Name matching is literal:

- `Sources/SoundSync/BluetoothSpeakers.swift` connects paired devices whose names contain `pulse` and `xb13`
- `Sources/SoundSync/CoreAudioSupport.swift` treats an output device as the Pulse if its name contains `pulse`, and as the Sony if its name contains `xb13`

Change those checks to the names shown in **System Settings → Bluetooth**, then run `./build.sh` again.

## Troubleshooting

**The app quit as soon as you turned it on.** The Bluetooth privacy text was missing from an old build. Current `Info.plist` includes `NSBluetoothAlwaysUsageDescription`. Rebuild with `./build.sh`.

**Calibrate says it cannot hear a speaker.** Move that speaker closer, keep the room quiet, and try again. The sweep turns the speaker up on its own. If the speaker’s buttons are at minimum and the system cannot change that volume, raise it from the speaker, then calibrate again.

**Only one speaker plays.** The other one is off, unpaired, or failed to connect. Its name must contain `Pulse` or `XB13` as above.

**Nothing is in the menu bar.** Open `build/SoundSync.app` again. The window title is **Sound Sync**, and the menu item is labeled **Sync**. On a Mac with an external display, the window opens on the screen under the pointer.

**`./build.sh` cannot find `swiftc`.** Install Xcode, run `sudo xcodebuild -license`, then run the script again.
