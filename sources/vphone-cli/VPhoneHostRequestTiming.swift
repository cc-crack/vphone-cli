import Foundation
import CoreFoundation

enum VPhoneHostRequestTiming {
    static let MaximumScreenDelayMilliseconds = 2_000
    static let MaximumSwipeDurationMilliseconds = 2_000

    static func screenDelayMilliseconds(from value: Any?) -> Int? {
        boundedMilliseconds(
            from: value,
            defaultValue: 500,
            maximum: MaximumScreenDelayMilliseconds
        )
    }

    static func swipeDurationMilliseconds(from value: Any?) -> Int? {
        boundedMilliseconds(
            from: value,
            defaultValue: 300,
            maximum: MaximumSwipeDurationMilliseconds
        )
    }

    static func nanoseconds(milliseconds: Int) -> UInt64 {
        UInt64(milliseconds) * UInt64(NSEC_PER_MSEC)
    }

    private static func boundedMilliseconds(
        from value: Any?,
        defaultValue: Int,
        maximum: Int
    ) -> Int? {
        guard let value else { return defaultValue }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        let integerTypes = ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"]
        guard integerTypes.contains(String(cString: number.objCType)),
              let milliseconds = number as? Int
        else {
            return nil
        }
        guard (0...maximum).contains(milliseconds) else { return nil }
        return milliseconds
    }
}
