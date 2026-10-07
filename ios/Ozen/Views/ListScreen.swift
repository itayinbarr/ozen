import SwiftData
import SwiftUI

struct ListScreen: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \Recording.createdAt, order: .reverse) private var recordings: [Recording]

    private var items: [Recording] {
        recordings.filter { !app.hiddenIDs.contains($0.id) }
    }

    var body: some View {
        @Bindable var app = app
        let items = self.items
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    CircleIconButton(glyph: .chevronBack, lineWidth: 2, label: "חזרה") { app.goHome() }
                    Spacer()
                    if !items.isEmpty {
                        Button {
                            withAnimation(Oz.ease(0.35)) {
                                app.selectMode.toggle()
                                app.selected = []
                            }
                        } label: {
                            Text(app.selectMode ? "סיום" : "בחירה")
                                .font(Oz.rubik(15, .medium))
                                .foregroundStyle(Oz.ink)
                                .padding(.horizontal, 16)
                                .frame(height: 40)
                                .background(Capsule().fill(Oz.card))
                        }
                        .buttonStyle(PressStyle())
                    }
                }
                .padding(.leading, 8)
                .padding(.trailing, 12)
                .frame(height: 52)
                .padding(.top, 8)

                Text("תמלולים")
                    .font(Oz.karantina(54))
                    .frame(height: 54)
                    .padding(.horizontal, 22)
                    .padding(.top, 6)
                    .padding(.bottom, 12)

                if items.isEmpty {
                    EmptyState { app.goHome() }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 150)
                        .transition(.opacity)
                    Spacer(minLength: 0)
                } else {
                    List {
                        ForEach(items) { rec in
                            RecordingRow(rec: rec, selectMode: app.selectMode, isSelected: app.selected.contains(rec.id))
                                .contentShape(Rectangle())
                                .onTapGesture { tap(rec) }
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .listRowBackground(Oz.bg)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    if !app.selectMode {
                                        Button(role: .destructive) {
                                            app.delete([rec.id], label: "התמלול נמחק")
                                        } label: {
                                            Label("מחיקה", systemImage: "trash")
                                        }
                                        .tint(Oz.red)
                                    }
                                }
                        }
                        Color.clear
                            .frame(height: app.selectMode ? 110 : 30)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, 0)
                }
            }

            if app.selectMode {
                SelectBar(count: app.selected.count,
                          deleteSelected: {
                              let n = app.selected.count
                              guard n > 0 else { return }
                              app.delete(app.selected, label: n == 1 ? "התמלול נמחק" : "\(n) תמלולים נמחקו")
                          },
                          deleteAll: { app.present(.deleteAll) })
                    .transition(.move(edge: .bottom))
            }
        }
        .background(Oz.bg)
    }

    private func tap(_ rec: Recording) {
        if app.selectMode {
            withAnimation(.easeOut(duration: 0.2)) {
                if app.selected.contains(rec.id) { app.selected.remove(rec.id) } else { app.selected.insert(rec.id) }
            }
        } else if rec.status == .done {
            app.open(rec.id, from: .list)
        } else if rec.status == .pending {
            app.jobs.enqueue(rec.id)
        }
    }
}

struct RecordingRow: View {
    var rec: Recording
    var selectMode: Bool
    var isSelected: Bool

    var body: some View {
        HStack(spacing: 14) {
            if selectMode {
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? Oz.orange : Oz.sub, lineWidth: 2)
                        .background(Circle().fill(isSelected ? Oz.orange : .clear))
                    if isSelected {
                        Icon(glyph: .check, size: 14, lineWidth: 3.2).foregroundStyle(.white)
                    }
                }
                .frame(width: 26, height: 26)
                .transition(.opacity)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(rec.title)
                        .font(Oz.rubik(17, .semibold))
                        .foregroundStyle(Oz.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(formatClock(rec.duration))
                        .font(Oz.rubik(13))
                        .monospacedDigit()
                        .foregroundStyle(Oz.sub)
                        .fixedSize()
                }
                Text(rec.preview)
                    .font(Oz.rubik(15))
                    .foregroundStyle(Oz.sub)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(HebrewDate.relative(rec.createdAt))
                    if rec.source == .whatsapp {
                        Text("WhatsApp")
                            .font(Oz.rubik(12.5, .medium))
                            .foregroundStyle(Oz.charcoal)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Oz.sage))
                    }
                }
                .font(Oz.rubik(12.5))
                .foregroundStyle(Oz.sub)
            }
        }
        .padding(.vertical, 15)
        .padding(.horizontal, 22)
        .background(Oz.bg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Oz.line).frame(height: 1).padding(.horizontal, 22)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct EmptyState: View {
    var action: () -> Void
    @State private var breathe = false

    var body: some View {
        VStack(spacing: 22) {
            Text("שקט כאן")
                .font(Oz.karantina(44, bold: false))
                .foregroundStyle(Oz.sub)
            Button(action: action) {
                Circle()
                    .fill(Oz.orange)
                    .frame(width: 76, height: 76)
                    .overlay(Circle().fill(Oz.cream).frame(width: 24, height: 24))
                    .shadow(color: Oz.orange.opacity(0.6), radius: 15, y: 14)
                    .scaleEffect(breathe ? 1.045 : 1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("להקלטה חדשה")
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

private struct SelectBar: View {
    var count: Int
    var deleteSelected: () -> Void
    var deleteAll: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: deleteSelected) {
                Text(count > 0 ? "מחיקה (\(count))" : "מחיקה")
                    .font(Oz.rubik(16, .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Capsule().fill(Oz.red))
                    .opacity(count > 0 ? 1 : 0.4)
            }
            .buttonStyle(PressStyle())
            .disabled(count == 0)
            Button(action: deleteAll) {
                Text("מחיקת הכל")
                    .font(Oz.rubik(16, .semibold))
                    .foregroundStyle(Oz.red)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Capsule().strokeBorder(Oz.red, lineWidth: 1.5))
            }
            .buttonStyle(PressStyle())
        }
        .padding(.top, 12)
        .padding(.horizontal, 16)
        .padding(.bottom, 30)
        .background(Oz.bg)
        .overlay(alignment: .top) { Rectangle().fill(Oz.line).frame(height: 1) }
    }
}
