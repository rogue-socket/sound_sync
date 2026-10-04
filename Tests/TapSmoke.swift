import CoreAudio
import Foundation

struct SmokeFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

enum TapSmoke {
    static func run() throws {
        let clock = SharedClock()
        let tap = SystemAudioTap(clock: clock)
        try tap.start(mute: .unmuted)
        defer { tap.stop() }

        let sound = "/System/Library/Sounds/Glass.aiff"
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [sound]
        try player.run()

        Thread.sleep(forTimeInterval: 1.2)
        let frames = clock.publishedFrame
        var peak: Float = 0
        let count = min(Int(frames), SharedClock.capacityFrames)
        for index in 0..<count {
            peak = max(peak, abs(clock.storage[index * 2]), abs(clock.storage[index * 2 + 1]))
        }
        player.waitUntilExit()
        print("tap frames=\(frames) rate=\(clock.sampleRate) peak=\(peak)")
        if frames < 100 || peak < 0.01 {
            throw SmokeFailure("system audio tap did not hear the test sound")
        }
    }
}

@main
enum TapSmokeMain {
    static func main() throws {
        try TapSmoke.run()
    }
}
