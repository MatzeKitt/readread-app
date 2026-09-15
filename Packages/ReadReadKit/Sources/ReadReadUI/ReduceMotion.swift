import SwiftUI

/// Animation that yields to the Reduce Motion setting.
///
/// Neither `withAnimation` nor `.animation(_:value:)` consults it — SwiftUI animates whatever it is
/// told to animate, and honouring the setting is the app's job. Someone who has turned Reduce
/// Motion on has usually done so because movement makes them ill, so an app that ignores it is not
/// merely unpolished.
///
/// What is reduced here is the *transition*, never the outcome: a picture asked to zoom still
/// zooms, it simply arrives there rather than travelling. That distinction is the whole setting —
/// "reduce motion", not "do less".
private struct MotionSafeAnimation<Value: Equatable>: ViewModifier {

    let animation: Animation
    let value: Value

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {

    /// `.animation(_:value:)`, skipped when the reader has asked for less movement.
    func motionSafeAnimation<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(MotionSafeAnimation(animation: animation, value: value))
    }
}

extension Animation {

    /// This animation, or none at all when the reader has asked for less movement.
    ///
    /// For the imperative side, where `withAnimation` is called from a button or a key press and
    /// there is no modifier to hang the environment off — the view reads
    /// `\.accessibilityReduceMotion` and passes it in.
    static func motionSafe(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}
