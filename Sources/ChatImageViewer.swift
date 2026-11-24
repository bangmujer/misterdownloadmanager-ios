import Photos
import SwiftUI
import UIKit

/// One image opened in the full-screen viewer. A fresh UUID per tap
/// so reopening the same attachment still presents.
struct ViewableImage: Identifiable {
    let id = UUID()
    let image: UIImage
    let fileName: String
}

/// Full-screen viewer for image attachments in the AI chat: pinch to
/// zoom, double-tap to toggle zoom, save to Photos, share (the share
/// sheet is also where "Save to Files" lives).
struct ChatImageViewer: View {
    let viewable: ViewableImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var saveMessage: String?
    @State private var saveFailed = false
    @State private var isSaving = false
    @State private var showShare = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: viewable.image)
                .resizable().scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = max(1, min(4, baseScale * value))
                        }
                        .onEnded { _ in baseScale = scale }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            guard scale > 1 else { return }
                            offset = CGSize(width: baseOffset.width + value.translation.width,
                                            height: baseOffset.height + value.translation.height)
                        }
                        .onEnded { _ in baseOffset = offset }
                )
                .onTapGesture(count: 2) {
                    withAnimation {
                        if scale > 1 {
                            scale = 1; baseScale = 1; offset = .zero; baseOffset = .zero
                        } else {
                            scale = 2.5; baseScale = 2.5
                        }
                    }
                }
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.headline).padding(10)
                            .background(Color.black.opacity(0.5), in: Circle())
                    }
                    Spacer()
                    Text(viewable.fileName).font(.subheadline).lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.black.opacity(0.5), in: Capsule())
                    Spacer()
                    Button { showShare = true } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.headline).padding(10)
                            .background(Color.black.opacity(0.5), in: Circle())
                    }
                    Button { saveToPhotos() } label: {
                        Image(systemName: isSaving ? "hourglass" : "square.and.arrow.down")
                            .font(.headline).padding(10)
                            .background(Color.black.opacity(0.5), in: Circle())
                    }
                    .disabled(isSaving)
                }
                .foregroundStyle(.white)
                .padding()
                Spacer()
                if let saveMessage {
                    Text(saveMessage)
                        .font(.caption)
                        .foregroundStyle(saveFailed ? .red : .white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.black.opacity(0.6), in: Capsule())
                        .padding(.bottom, 24)
                }
            }
        }
        .sheet(isPresented: $showShare) {
            ActivityView(activityItems: [viewable.image])
        }
    }

    private func saveToPhotos() {
        isSaving = true
        saveMessage = nil
        saveFailed = false
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    isSaving = false
                    saveFailed = true
                    saveMessage = "Izin Foto ditolak. Aktifkan di Pengaturan → app ini → Foto."
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: viewable.image)
            }) { success, error in
                DispatchQueue.main.async {
                    isSaving = false
                    if success {
                        saveMessage = "Tersimpan di Foto."
                    } else {
                        saveFailed = true
                        saveMessage = error?.localizedDescription ?? "Gagal menyimpan gambar."
                    }
                }
            }
        }
    }
}

/// UIKit share sheet, shared by the image viewer, the project
/// library, and the chat export.
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
