# Sound Sync

Sound Sync plays whatever is playing on a Mac through two or more Bluetooth speakers at the same time, and keeps them lined up.

It is a menu-bar app. It captures system audio, sends that audio to each speaker you check, and uses the Mac microphone to measure how late each speaker is. Calibration also compares their tone and turns down the bands where a speaker is weaker than the others, without trying to make them equally loud.

Any paired Bluetooth speaker, headphones, or other playback device can be used. **Add speaker** lists the ones that are paired or connected. Pick one and it is added to the speaker list. At least two have to be added.

## What you need

- A Mac on **macOS 15 or later** (Apple silicon or Intel; the build script targets `arm64`, so an Intel Mac needs the target in `build.sh` changed to `x86_64` or a universal build)
- **Xcode** installed, from the App Store or [developer.apple.com](https://developer.apple.com/xcode/). Command Line Tools alone are not enough, because the app uses the macOS SDK and Swift.
- The Xcode license accepted once:

  ```sh
  sudo xcodebuild -license
  ```

- At least two Bluetooth speakers already paired in **System Settings → Bluetooth**. Headphones and other Bluetooth playback devices show up too. Keyboards, mice, and microphones do not.
- Every speaker you use in the **same room as the Mac**, close enough that the built-in microphone can hear a short sweep from each
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

Open the app. It stays in the menu bar as **Sync**, with the two-speaker icon, and does not appear in the Dock or in Cmd+Tab. Click **Sync** to open the window. Closing the window leaves it running. The same icon is what Finder shows for `SoundSync.app`.

Turn the switch on. macOS will ask for permission. Allow all of these:

| Prompt | Why |
| --- | --- |
| Bluetooth | Connects to the speakers you add |
| Microphone | Hears the test sweep during calibration |
| System audio | Captures music, the browser, and anything else playing on the Mac |

If a prompt was dismissed, turn the app off and on again, or enable Sound Sync under **System Settings → Privacy & Security** for Bluetooth, Microphone, and System Audio Recording.

The speaker list starts with the Pulse 4 and the SRS-XB13 if this Mac was already using them. Anything else stays out until you add it. Open **Add speaker** and pick a paired or connected Bluetooth device. It shows up in the list with its own volume slider. **Remove** takes it back out. Press **Refresh** if you paired a speaker after the window opened.

Turn the speakers in that list on before you flip the switch. The app connects them, sends all Mac audio to each one, and silences the MacBook speakers. Turning the app off restores the output device that was selected before. Add or remove speakers only while Sound Sync is off.

## Calibrate

Press **Calibrate** with the room quiet and every checked speaker connected.

The app checks that those speakers are still connected, then plays a sweep through one speaker at a time while the Mac microphone listens. For that sweep it turns that speaker’s own volume all the way up, then puts the volume back. The sliders in the window do not affect the test tone. More speakers means a longer calibration, one sweep each.

When it finishes, the window shows:

- which speaker is being delayed, and by how many milliseconds
- which speaker is carrying more of the lows, mids, or highs, if their tone differs

Sit the Mac where you listen before you calibrate. If you move a speaker, calibrate again.

## Volume

- The **Mac volume keys** scale every checked speaker together. The window shows the current Mac volume while Sound Sync is on.
- Each speaker has its own slider, a trim on top of that. Leave them different if one speaker is quieter. Together they cover the room. The app does not try to make them the same loudness.

## Tone split

After a calibration, the window lists the cut applied to each checked speaker, in dB, for lows, mids, and highs. A cut is zero or negative. In each band, the strongest speaker is left alone. Each weaker speaker is turned down in that band, by at most 8 dB.

**Tone split** turns those cuts off and back on so you can hear whether the split helps. The sliders do not change.

The measurement is done in the room, with this Mac’s microphone. The app does not download a published frequency curve. It also does not boost a band to invent bass a small speaker cannot produce.

## While it is running

**Quiet recheck.** After you have calibrated once, play something, then let it go quiet for a few seconds. Sound Sync plays the sweep again and updates the delay. The window says **Rechecking delay** while that happens. It does not do this the moment you turn the app on, and it does not do it in the middle of a song.

**Dropped speaker.** If a checked speaker disconnects, that side pauses and the app tries to connect it again. When it comes back, calibrate again. A new Bluetooth connection does not keep the old delay.

## Limits

Classic Bluetooth speakers do not share a clock. The delay measured at the Mac is right at that moment, at the microphone. It drifts over a song, which is why the quiet recheck exists. Standing somewhere other than the Mac will not match the measurement.

macOS has to keep every speaker connected as its own audio output. More speakers make that less reliable. If one will not connect, turn it off and on, then switch Sound Sync on again.

The list only includes paired Bluetooth devices whose class is audio playback, plus any Bluetooth audio output already connected. A speaker that macOS does not report as audio will not appear.

## Troubleshooting

**The app quit as soon as you turned it on.** The Bluetooth privacy text was missing from an old build. Current `Info.plist` includes `NSBluetoothAlwaysUsageDescription`. Rebuild with `./build.sh`.

**Calibrate says it cannot hear a speaker.** Move that speaker closer, keep the room quiet, and try again. The sweep turns the speaker up on its own. If the speaker’s buttons are at minimum and the system cannot change that volume, raise it from the speaker, then calibrate again.

**A speaker is missing from the list.** Pair it in Bluetooth settings, turn it on, and press Refresh. It has to be a playback device. A keyboard or mouse will not appear.

**Only some speakers play.** The others are off, not added, or failed to connect. Each speaker in the list needs its own Bluetooth audio connection.

**Nothing is in the menu bar.** Open `build/SoundSync.app` again. The menu item is labeled **Sync**. Click it to open the window. On a Mac with an external display, the window opens on the screen under the pointer. Sound Sync does not show in the Dock or in Cmd+Tab.

**`./build.sh` cannot find `swiftc`.** Install Xcode, run `sudo xcodebuild -license`, then run the script again.
