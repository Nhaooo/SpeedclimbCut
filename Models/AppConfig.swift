import Foundation
import CoreGraphics

struct AppConfig {
    static let analysisFPS: Int = 10 // Ultra rapide : 10 FPS suffisent
    static let maxVideoDimension: CGFloat = 80.0 // Traitement sur une grille basse résolution
    
    static let startZoneMaxY: CGFloat = 0.30 // Zone basse (30%)
    static let startVelocityThreshold: CGFloat = 0.005
    static let startConfirmationFrames: Int = 5 // 0.5s maintien = pas un faux départ
    
    static let topZoneMinY: CGFloat = 0.60 // Zone de top (> 60%)
    static let topStabilizationFrames: Int = 3 // 0.3s d'arrêt = buzzer touché
    static let topStabilizationThreshold: CGFloat = 0.01
    
    // Padding around the start/top events for the final trim
    static let preStartTrimMarginSeconds: Double = 1.0
    static let postTopTrimMarginSeconds: Double = 1.0
}
