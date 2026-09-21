import CoreMotion

final class HeadMotionService {
    struct Reading {
        let pitchDegrees: Double
        let yawDegrees: Double
        let rollDegrees: Double
        let accelerationX: Double
        let accelerationY: Double
        let accelerationZ: Double
    }

    private let manager = CMHeadphoneMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "AirPodsSensorLab.HeadMotion"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start(onReading: @escaping @Sendable (Reading) -> Void) {
        guard manager.isDeviceMotionAvailable else { return }
        manager.startDeviceMotionUpdates(to: queue) { motion, _ in
            guard let motion else { return }
            let radiansToDegrees = 180.0 / Double.pi
            onReading(Reading(
                pitchDegrees: motion.attitude.pitch * radiansToDegrees,
                yawDegrees: motion.attitude.yaw * radiansToDegrees,
                rollDegrees: motion.attitude.roll * radiansToDegrees,
                accelerationX: motion.userAcceleration.x,
                accelerationY: motion.userAcceleration.y,
                accelerationZ: motion.userAcceleration.z
            ))
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}

