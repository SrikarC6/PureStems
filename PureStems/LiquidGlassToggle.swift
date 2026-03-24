import SwiftUI

struct LiquidGlassToggle: View {
    @Binding var isOn: Bool
    
    var body: some View {
        ZStack {
            Capsule()
                .fill(isOn ? Color.accentColor : Color.white.opacity(0.1))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
            
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                .padding(2)
                .offset(x: isOn ? 10 : -10)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isOn)
        }
        .frame(width: 44, height: 24)
        .onTapGesture { isOn.toggle() }
    }
}
