import SwiftUI
import CoreImage

/// WiFi file sharing sheet (reference: the desktop app's "share over home
/// Wi-Fi" dialogs): a QR code + URL for the LAN file server, so a PC or
/// another phone on the same Wi-Fi can browse and download the Downloads
/// folder. Same listener and pairing token as Remote control;
/// foreground-only, trusted Wi-Fi only.
struct FileSharingView: View {
    @EnvironmentObject var store: DownloadStore
    @Environment(\.dismiss) private var dismiss
    @State private var fileCount = 0
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let address = store.remoteAddress, let filesURL = Self.filesURL(from: address) {
                        if let qr = Self.qrImage(for: filesURL, size: 240) {
                            Image(uiImage: qr)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 240, height: 240)
                                .padding(16)
                                .background(.white, in: RoundedRectangle(cornerRadius: 16))
                        }
                        Text(filesURL)
                            .font(.system(.callout, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                        Button(copied ? "Tersalin" : "Salin URL") {
                            UIPasteboard.general.string = filesURL
                            copied = true
                        }
                        .buttonStyle(.bordered)
                        Text("Pindai kode QR di atas dari perangkat tujuan, atau buka URL di atas dari peramban di perangkat lain yang terhubung ke WiFi yang sama.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Text("\(fileCount) berkas dibagikan dari folder Unduhan.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("Catatan: agar transfer tidak terputus, jangan tutup aplikasi atau mengaktifkan mode tidur di perangkat ini. URL ini memakai token pairing — siapa pun yang memindainya bisa mengunduh berkas.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Image(systemName: "wifi")
                            .font(.largeTitle)
                            .foregroundStyle(Color.mdmAccent)
                        Text("Berbagi berkas via WiFi memakai server yang sama dengan Remote control. Aktifkan untuk menampilkan kode QR dan alamat berbagi.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Button("Aktifkan berbagi berkas") { store.settings.remoteControlEnabled = true }
                            .buttonStyle(.borderedProminent)
                        Text("Hanya WiFi rumah yang dipercaya, dan hanya selama aplikasi terbuka. Setiap request wajib membawa token pairing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
            }
            .background(Color.mdmBackground)
            .navigationTitle("Berbagi via WiFi")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .onAppear {
                fileCount = store.downloadedFiles().filter { $0.pathExtension.lowercased() != "part" }.count
            }
        }
    }

    static func filesURL(from address: String) -> String? {
        if address.contains("/?token=") {
            return address.replacingOccurrences(of: "/?token=", with: "/files?token=")
        }
        return address
    }

    static func qrImage(for string: String, size: CGFloat) -> UIImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
