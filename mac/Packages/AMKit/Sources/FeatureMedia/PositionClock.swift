import AMProtocol
import Foundation

/// Where the phone's track is now, from its last `media.state` (SPEC section 20): `position_ms`
/// was the position when it was sent, and while playing the Mac moves it on with its own clock at
/// the phone's speed (1.0 when the speed is 0). Never below 0, nor past the duration when there is one.
public enum PositionClock {
    public static func positionMs(_ s: AMMediaState, receivedAt: Date, now: Date) -> Int64 {
        var position = s.positionMs
        if s.playing {
            let speed = s.speed > 0 ? Double(s.speed) : 1
            // A clock that went backwards does not move it back.
            let elapsed = max(0, now.timeIntervalSince(receivedAt))
            position += Int64((elapsed * 1000 * speed).rounded())
        }
        position = max(0, position)
        if s.durationMs > 0 { position = min(position, s.durationMs) }
        return position
    }
}
