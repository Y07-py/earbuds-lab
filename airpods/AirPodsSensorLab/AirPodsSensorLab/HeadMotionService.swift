import CoreMotion
import Foundation

final class HeadMotionService {
    struct Reading: Sendable {
        let pitchDegrees: Double
        let yawDegrees: Double
        let rollDegrees: Double
        let accelerationX: Double
        let accelerationY: Double
        let accelerationZ: Double
        let rotationRateX: Double
        let rotationRateY: Double
        let rotationRateZ: Double
        let gravityX: Double
        let gravityY: Double
        let gravityZ: Double
        let sensorTimestampSeconds: Double
        let callbackUptimeSeconds: Double
        let sessionElapsedSeconds: Double
        let sensorElapsedSeconds: Double
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

    func start(
        sessionOriginUptime: Double,
        onReading: @escaping @Sendable (Reading) -> Void
    ) {
        guard manager.isDeviceMotionAvailable else { return }
        var lastSensorTimestamp: TimeInterval?
        manager.startDeviceMotionUpdates(to: queue) { motion, _ in
            guard let motion else { return }
            let sensorTimestamp = motion.timestamp
            guard sensorTimestamp != lastSensorTimestamp else { return }
            lastSensorTimestamp = sensorTimestamp
            let callbackUptime = ProcessInfo.processInfo.systemUptime
            let radiansToDegrees = 180.0 / Double.pi
            onReading(Reading(
                pitchDegrees: motion.attitude.pitch * radiansToDegrees,
                yawDegrees: motion.attitude.yaw * radiansToDegrees,
                rollDegrees: motion.attitude.roll * radiansToDegrees,
                accelerationX: motion.userAcceleration.x,
                accelerationY: motion.userAcceleration.y,
                accelerationZ: motion.userAcceleration.z,
                rotationRateX: motion.rotationRate.x,
                rotationRateY: motion.rotationRate.y,
                rotationRateZ: motion.rotationRate.z,
                gravityX: motion.gravity.x,
                gravityY: motion.gravity.y,
                gravityZ: motion.gravity.z,
                sensorTimestampSeconds: sensorTimestamp,
                callbackUptimeSeconds: callbackUptime,
                sessionElapsedSeconds: callbackUptime - sessionOriginUptime,
                sensorElapsedSeconds: sensorTimestamp - sessionOriginUptime
            ))
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        queue.waitUntilAllOperationsAreFinished()
    }
}
