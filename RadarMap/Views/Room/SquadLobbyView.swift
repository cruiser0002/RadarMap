import SwiftUI

public struct SquadLobbyView: View {
    @EnvironmentObject var gameState: GameStateManager
    @Environment(\.dismiss) private var dismiss
    
    public init() {}
    
    private var squadMembers: [SquadMember] {
        guard let room = gameState.firebaseManager.activeRoom else { return [] }
        return Array(room.members.values)
    }
    
    public var body: some View {
        NavigationStack {
            List {
                // Room Header
                if let room = gameState.firebaseManager.activeRoom {
                    Section {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(room.name)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.white)
                                Spacer()
                                Text(room.id)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(.green)
                            }
                            
                            HStack {
                                Text("\(room.memberCount)/\(room.maxCapacity) Players")
                                    .font(.system(size: 9))
                                    .foregroundColor(.gray)
                                
                                Spacer()
                                
                                Label("PIN", systemImage: "lock.fill")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundColor(.yellow)
                            }
                        }
                    }
                    
                    // Return to Radar Map Button
                    Section {
                        Button(action: {
                            dismiss()
                        }) {
                            HStack {
                                Image(systemName: "map.fill")
                                    .foregroundColor(.green)
                                Text("Return to Radar Map")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.green)
                            }
                        }
                    }
                    
                    // Members Roster
                    Section(header: Text("Squad Roster (\(room.memberCount))").font(.system(size: 9))) {
                        ForEach(squadMembers) { member in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(member.callsign)
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundColor(member.id == gameState.myMemberId ? .cyan : .white)
                                        
                                        if member.role == .leader {
                                            Text("HOST")
                                                .font(.system(size: 7, weight: .bold))
                                                .padding(.horizontal, 3)
                                                .padding(.vertical, 1)
                                                .background(Color.yellow.opacity(0.3))
                                                .foregroundColor(.yellow)
                                                .cornerRadius(3)
                                        }
                                    }
                                    
                                    Text("Heading: \(Int(member.heading))°")
                                        .font(.system(size: 8))
                                        .foregroundColor(.gray)
                                }
                                
                                Spacer()
                                
                                // Heart Rate Badge
                                HStack(spacing: 2) {
                                    Image(systemName: "heart.fill")
                                        .font(.system(size: 8))
                                        .foregroundColor(member.heartRateZoneColor)
                                    Text("\(Int(member.heartRate))")
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundColor(.white)
                                }
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.6))
                                .cornerRadius(4)
                            }
                        }
                    }
                    
                    // Disband / Leave Room Button
                    Section {
                        Button(role: .destructive, action: {
                            gameState.leaveCurrentRoom()
                            dismiss()
                        }) {
                            HStack {
                                Spacer()
                                Image(systemName: gameState.isCurrentMemberHost ? "xmark.circle.fill" : "rectangle.portrait.and.arrow.right")
                                    .foregroundColor(.red)
                                Text(gameState.isCurrentMemberHost ? "Disband Squad" : "Logout / Leave Squad")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.red)
                                Spacer()
                            }
                        }
                    }
                } else {
                    Text("Not in a room.")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }
            }
            .navigationTitle("Squad Lobby")
            #if os(watchOS) || os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }
}
