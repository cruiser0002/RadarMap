import SwiftUI

public struct PaywallView: View {
    @EnvironmentObject var gameState: GameStateManager
    @Environment(\.dismiss) private var dismiss
    
    public init() {}
    
    @State private var showErrorAlert: Bool = false
    
    public var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                // Header Icon & Title
                VStack(spacing: 3) {
                    Image(systemName: "person.3.sequence.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.yellow)
                    
                    Text("Pro Upgrade")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    
                    Text(gameState.subscriptionManager.localizedPrice)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.yellow)
                    
                    if let promoMessage = gameState.subscriptionManager.promotionalPriceMessage, !promoMessage.isEmpty {
                        Text(promoMessage)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.green)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.top, 4)
                
                Divider()
                
                // Features
                VStack(alignment: .leading, spacing: 6) {
                    FeatureRow(icon: "person.3.fill", text: "Up to \(AppConstants.Subscription.proTierMaxCapacity) players")
                    FeatureRow(icon: "star.fill", text: "Team orders")
                    FeatureRow(icon: "mappin.and.ellipse", text: "POI & environmental markers")
                    FeatureRow(icon: "person.badge.shield.checkmark.fill", text: "Teammates join 100% free")
                }
                .padding(.horizontal, 4)
                
                // Pricing & Purchase Button
                VStack(spacing: 6) {
                    Button(action: {
                        Task {
                            let success = await gameState.subscriptionManager.purchaseLifetimeUnlock()
                            if success {
                                dismiss()
                            } else if gameState.subscriptionManager.errorMessage != nil {
                                showErrorAlert = true
                            }
                        }
                    }) {
                        HStack {
                            if gameState.subscriptionManager.isPurchasing && !gameState.subscriptionManager.isRestoring {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else {
                                Text("Unlock Pro")
                                    .font(.system(size: 12, weight: .bold))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.yellow)
                        .foregroundColor(.black)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(gameState.subscriptionManager.isPurchasing)
                    
                    // Restore Purchases
                    Button(action: {
                        Task {
                            let restored = await gameState.subscriptionManager.restorePurchases()
                            if restored {
                                dismiss()
                            } else if gameState.subscriptionManager.errorMessage != nil {
                                showErrorAlert = true
                            }
                        }
                    }) {
                        HStack(spacing: 4) {
                            if gameState.subscriptionManager.isRestoring {
                                ProgressView()
                                    .scaleEffect(0.6)
                            }
                            Text("Restore Purchases")
                                .font(.system(size: 9))
                                .foregroundColor(.gray)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(gameState.subscriptionManager.isPurchasing)
                    
                    Text("One-time lifetime purchase. No subscriptions.")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                    
                    HStack(spacing: 8) {
                        if let privacyUrl = URL(string: AppConstants.Policy.privacyPolicyURL) {
                            Link("Privacy Policy", destination: privacyUrl)
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(.cyan)
                        }
                        Text("•")
                            .font(.system(size: 8))
                            .foregroundColor(.gray)
                        if let termsUrl = URL(string: AppConstants.Policy.termsOfServiceURL) {
                            Link("Terms of Use (EULA)", destination: termsUrl)
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(.cyan)
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 8)
        }
        .navigationTitle("Upgrade")
        #if os(watchOS) || os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("Purchase Issue", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) {
                gameState.subscriptionManager.errorMessage = nil
            }
        } message: {
            Text(gameState.subscriptionManager.errorMessage ?? "An unexpected error occurred. Please try again.")
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.green)
                .frame(width: 14)
            
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white)
        }
    }
}
