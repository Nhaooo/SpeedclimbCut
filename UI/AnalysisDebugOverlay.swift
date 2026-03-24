import SwiftUI

struct AnalysisDebugOverlay: View {
    var state: ClimbState
    var score: CGFloat
    
    var body: some View {
        VStack(alignment: .leading) {
            Text("State: \(state.rawValue)")
                .font(.caption)
                .foregroundColor(state == .topConfirmed ? .green : .yellow)
                .padding(4)
                .background(Color.black.opacity(0.5))
                .cornerRadius(4)
            
            Text("Target Score: \(String(format: "%.2f", score))")
                .font(.caption)
                .foregroundColor(.white)
                .padding(4)
                .background(Color.black.opacity(0.5))
                .cornerRadius(4)
        }
        .padding()
    }
}
