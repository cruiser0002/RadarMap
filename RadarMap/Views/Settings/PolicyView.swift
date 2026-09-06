import SwiftUI

public struct PolicyView: View {
    public init() {}
    
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Header
                VStack(spacing: 4) {
                    Image(systemName: "hand.raised.shield.fill")
                        .font(.system(size: 26))
                        .foregroundColor(.cyan)
                    
                    Text("Privacy Policy")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
                
                // Summary Card
                VStack(alignment: .leading, spacing: 6) {
                    Text("Overview")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.cyan)
                    
                    Text(AppConstants.Policy.summary)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(Color.white.opacity(0.06))
                .cornerRadius(8)
                
                // Key Data Policies
                VStack(alignment: .leading, spacing: 10) {
                    PolicyItemRow(
                        icon: "location.fill",
                        iconColor: .green,
                        title: "Location Data",
                        description: AppConstants.Policy.locationDataDescription
                    )
                    
                    PolicyItemRow(
                        icon: "heart.fill",
                        iconColor: .red,
                        title: "Health & Biometrics",
                        description: AppConstants.Policy.healthDataDescription
                    )
                    
                    PolicyItemRow(
                        icon: "shield.lefthalf.filled",
                        iconColor: .yellow,
                        title: "Ephemeral Storage",
                        description: AppConstants.Policy.dataRetentionDescription
                    )
                    
                    PolicyItemRow(
                        icon: "battery.50",
                        iconColor: .orange,
                        title: "Battery & Background Use",
                        description: AppConstants.Policy.batteryDisclaimer
                    )
                }
                .padding(8)
                .background(Color.white.opacity(0.06))
                .cornerRadius(8)
                
                // Legal Agreements Section
                VStack(alignment: .leading, spacing: 6) {
                    Text("Legal Agreements")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.cyan)
                    
                    if let url = URL(string: AppConstants.Policy.privacyPolicyURL) {
                        Link(destination: url) {
                            HStack(spacing: 6) {
                                Image(systemName: "safari.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.cyan)
                                
                                Text("Privacy Policy")
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundColor(.cyan)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                
                                Spacer()
                                
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.gray)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .background(Color.cyan.opacity(0.12))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    if let eulaUrl = URL(string: AppConstants.Policy.termsOfServiceURL) {
                        Link(destination: eulaUrl) {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.cyan)
                                
                                Text("Terms of Use (EULA)")
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundColor(.cyan)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                
                                Spacer()
                                
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.gray)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .background(Color.cyan.opacity(0.12))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(Color.white.opacity(0.06))
                .cornerRadius(8)
                
                // Contact Info Section
                VStack(alignment: .leading, spacing: 6) {
                    Text("Contact & Feedback")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.cyan)
                    
                    if let mailUrl = URL(string: "mailto:\(AppConstants.Policy.contactEmail)") {
                        Link(destination: mailUrl) {
                            HStack(spacing: 6) {
                                Image(systemName: "envelope.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.yellow)
                                
                                Text(AppConstants.Policy.contactEmail)
                                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                    .foregroundColor(.yellow)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                
                                Spacer()
                                
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.gray)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .background(Color.yellow.opacity(0.12))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    if let formUrl = URL(string: AppConstants.Policy.contactFormURL) {
                        Link(destination: formUrl) {
                            HStack(spacing: 6) {
                                Image(systemName: "pencil.and.list.clipboard")
                                    .font(.system(size: 11))
                                    .foregroundColor(.cyan)
                                
                                Text("Contact / Feedback Form")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(.cyan)
                                    .lineLimit(1)
                                
                                Spacer()
                                
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.gray)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .background(Color.cyan.opacity(0.12))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(Color.white.opacity(0.06))
                .cornerRadius(8)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 16)
        }
        .navigationTitle("Policy")
        #if os(watchOS) || os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct PolicyItemRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(iconColor)
                    .frame(width: 14)
                
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
            }
            
            Text(description)
                .font(.system(size: 9))
                .foregroundColor(.gray)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
