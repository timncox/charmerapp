import Foundation
import Vision
import AppKit

enum OrientationDetector {

    /// Detect if an image needs rotation using Vision framework heuristics.
    /// Returns 0, 90, 180, or 270 degrees clockwise rotation needed.
    static func detectRotation(imagePath: String) -> Int {
        guard let image = NSImage(contentsOfFile: imagePath),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return 0
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        // Try face detection first — most reliable signal
        let faceRotation = detectViaFaces(handler: handler, imageWidth: cgImage.width, imageHeight: cgImage.height)
        if faceRotation != nil {
            print("[Orientation] Face-based: \(imagePath) -> \(faceRotation!)°")
            return faceRotation!
        }

        // Try text detection as fallback
        let textRotation = detectViaText(handler: handler, imageWidth: cgImage.width, imageHeight: cgImage.height)
        if textRotation != nil {
            print("[Orientation] Text-based: \(imagePath) -> \(textRotation!)°")
            return textRotation!
        }

        // Try line/edge detection — architectural lines, horizons
        let lineRotation = detectViaLines(handler: handler, imageWidth: cgImage.width, imageHeight: cgImage.height)
        if lineRotation != nil {
            print("[Orientation] Line-based: \(imagePath) -> \(lineRotation!)°")
            return lineRotation!
        }

        // No confident signal — return 0 (user can rotate on site)
        return 0
    }

    // MARK: - Face Detection

    private static func detectViaFaces(handler: VNImageRequestHandler, imageWidth: Int, imageHeight: Int) -> Int? {
        let request = VNDetectFaceRectanglesRequest()

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let faces = request.results, !faces.isEmpty else {
            return nil
        }

        // Analyze face bounding boxes
        // In a correctly oriented landscape image (1440x1080), faces should be upright
        // Face bounding boxes are in normalized coordinates (0-1)
        // A face in a correctly oriented image: width ≈ height or width < height (face is taller than wide)
        // A face in a 90° rotated image: the face appears sideways, so Vision may detect it
        //   with unusual roll angles

        // Use face roll angle if available (VNDetectFaceLandmarksRequest gives more detail)
        let landmarkRequest = VNDetectFaceLandmarksRequest()
        do {
            try handler.perform([landmarkRequest])
        } catch {
            return nil
        }

        guard let detailedFaces = landmarkRequest.results, !detailedFaces.isEmpty else {
            return nil
        }

        // Check roll and yaw of detected faces
        var rollAngles: [CGFloat] = []
        for face in detailedFaces {
            if let roll = face.roll {
                rollAngles.append(CGFloat(truncating: roll))
            }
        }

        guard !rollAngles.isEmpty else { return nil }

        // Average roll angle in radians
        let avgRoll = rollAngles.reduce(0, +) / CGFloat(rollAngles.count)
        let avgRollDegrees = avgRoll * 180.0 / .pi

        // Determine rotation needed based on face roll
        // Roll ~0° = correct orientation
        // Roll ~90° = image needs 270° clockwise rotation (faces are tilted right)
        // Roll ~-90° = image needs 90° clockwise rotation (faces are tilted left)
        // Roll ~180° = image is upside down

        if abs(avgRollDegrees) < 30 {
            return 0
        } else if avgRollDegrees > 60 && avgRollDegrees < 120 {
            return 270
        } else if avgRollDegrees < -60 && avgRollDegrees > -120 {
            return 90
        } else if abs(avgRollDegrees) > 150 {
            return 180
        }

        return nil // Ambiguous
    }

    // MARK: - Text Detection

    private static func detectViaText(handler: VNImageRequestHandler, imageWidth: Int, imageHeight: Int) -> Int? {
        let request = VNDetectTextRectanglesRequest()

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let textObservations = request.results, textObservations.count >= 2 else {
            return nil
        }

        // Analyze text bounding boxes
        // In a correctly oriented image, text lines are wider than tall
        // In a 90° rotated image, text lines appear as tall narrow boxes

        var horizontalCount = 0
        var verticalCount = 0

        for obs in textObservations {
            let box = obs.boundingBox
            let aspectRatio = box.width / box.height

            if aspectRatio > 1.5 {
                horizontalCount += 1  // Text is horizontal (correct)
            } else if aspectRatio < 0.67 {
                verticalCount += 1    // Text is vertical (rotated)
            }
        }

        // If most text is vertical, image is probably rotated 90° or 270°
        // We can't easily distinguish between 90° and 270° from text alone
        // so we'll just flag it needs rotation and default to 90°
        if verticalCount > horizontalCount && verticalCount >= 2 {
            return 90
        }

        if horizontalCount >= 2 {
            return 0 // Text is horizontal, image is correctly oriented
        }

        return nil // Not enough signal
    }

    // MARK: - Line/Edge Detection

    private static func detectViaLines(handler: VNImageRequestHandler, imageWidth: Int, imageHeight: Int) -> Int? {
        // Use horizon detection — if the horizon is near vertical, the image is rotated 90°
        let horizonRequest = VNDetectHorizonRequest()

        do {
            try handler.perform([horizonRequest])
        } catch {
            return nil
        }

        guard let horizon = horizonRequest.results?.first else {
            return nil
        }

        let angleDegrees = horizon.angle * 180.0 / .pi

        // Horizon angle interpretation:
        // ~0° = horizon is horizontal = correct orientation
        // ~90° = horizon is vertical = image rotated 90° (needs 270° clockwise to fix)
        // ~-90° = horizon is vertical other way = image rotated 270° (needs 90° clockwise to fix)
        // ~180° = upside down

        // Only act on strong signals (close to 90° increments)
        if abs(angleDegrees) < 20 {
            return 0 // Horizon is roughly horizontal — correct
        } else if angleDegrees > 70 && angleDegrees < 110 {
            return 270 // Horizon is ~vertical (tilted right) — rotate 270° to fix
        } else if angleDegrees < -70 && angleDegrees > -110 {
            return 90  // Horizon is ~vertical (tilted left) — rotate 90° to fix
        } else if abs(angleDegrees) > 160 {
            return 180 // Upside down
        }

        return nil // Ambiguous angle — don't guess
    }
}
