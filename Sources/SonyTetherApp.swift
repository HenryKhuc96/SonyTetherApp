import SwiftUI
import Photos
import ImageIO
import Network

@main
struct SonyTetherApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

class CameraFTPServerManager: ObservableObject {
    @Published var statusMessage: String = "Đang khởi tạo FTP Server..."
    @Published var isConnected: Bool = false
    @Published var capturedCount: Int = 0
    @Published var lastPhotoPreview: UIImage? = nil
    
    private var listener: NWListener?
    private var activeConnections: [NWConnection] = []
    
    init() {
        requestPhotoLibraryPermission()
        startFTPServer(port: 2121) // Sử dụng port 2121 để tránh xung đột quyền hệ thống
    }
    
    private func requestPhotoLibraryPermission() {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            if status != .authorized && status != .limited {
                DispatchQueue.main.async {
                    self.statusMessage = "⚠️ Cần cấp quyền lưu ảnh vào Photos!"
                }
            }
        }
    }
    
    // MARK: - FTP Server Setup
    private func startFTPServer(port: UInt16) {
        do {
            let port = NWEndpoint.Port(rawValue: port)!
            listener = try NWListener(using: .tcp, on: port)
            
            listener?.stateUpdateHandler = { state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self.isConnected = true
                        self.statusMessage = "✅ FTP Server đang chạy (Cổng \(port)). Sẵn sàng nhận ảnh!"
                    case .failed(let error):
                        self.isConnected = false
                        self.statusMessage = "❌ Lỗi Server: \(error.localizedDescription)"
                    default:
                        break
                    }
                }
            }
            
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }
            
            listener?.start(queue: .global(qos: .background))
        } catch {
            statusMessage = "❌ Không thể khởi tạo Server: \(error.localizedDescription)"
        }
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .background))
        activeConnections.append(connection)
        
        // Gửi phản hồi chào mừng của FTP
        let welcomeMessage = "220 iPad FTP Server Ready\r\n".data(using: .utf8)!
        connection.send(content: welcomeMessage, completion: .contentProcessed({ error in
            if error == nil {
                self.receiveFTPCommands(on: connection)
            }
        }))
    }
    
    private func receiveFTPCommands(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { content, _, isComplete, error in
            if let data = content, let command = String(data: data, encoding: .utf8) {
                // Xử lý các lệnh FTP (USER, PASS, TYPE, PASV, STOR)
                // Lưu ý: Ở đây bạn cần parse lệnh STOR để bắt đầu ghi luồng dữ liệu file (Data Connection) vào thư mục tạm.
                // Khi nhận xong một file từ lệnh STOR, gọi hàm `processReceivedFile(at:)`
                print("Nhận lệnh FTP: \(command)")
                
                // Phản hồi giả lập để giữ kết nối (cần thay thế bằng logic FTP chuẩn)
                let response = "200 Command okay\r\n".data(using: .utf8)!
                connection.send(content: response, completion: .contentProcessed({ _ in
                    if !isComplete { self.receiveFTPCommands(on: connection) }
                }))
            }
        }
    }
    
    // MARK: - Photo Processing
    func processReceivedFile(at fileURL: URL) {
        DispatchQueue.main.async {
            self.statusMessage = "⚡ Đang xử lý ảnh mới..."
        }
        
        if let image = generateFastPreview(from: fileURL, maxPixelSize: 1600) {
            DispatchQueue.main.async {
                self.lastPhotoPreview = image
            }
        }
        
        saveToPhotosLibrary(fileURL: fileURL)
    }
    
    private func generateFastPreview(from fileURL: URL, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions) else {
            return UIImage(contentsOfFile: fileURL.path)
        }
        
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return UIImage(contentsOfFile: fileURL.path)
        }
        return UIImage(cgImage: cgImage)
    }
    
    private func saveToPhotosLibrary(fileURL: URL) {
        PHPhotoLibrary.shared().performChanges({
            let creationRequest = PHAssetCreationRequest.forAsset()
            creationRequest.addResource(with: .photo, fileURL: fileURL, options: nil)
        }) { success, error in
            DispatchQueue.main.async {
                if success {
                    self.capturedCount += 1
                    self.statusMessage = "✅ Đã lưu vào Photos! (Tổng: \(self.capturedCount) tấm)"
                } else {
                    self.statusMessage = "❌ Lỗi lưu Photos: \(error?.localizedDescription ?? "Không rõ")"
                }
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var tetherManager = CameraFTPServerManager()
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                HStack {
                    Circle()
                        .fill(tetherManager.isConnected ? Color.green : Color.red)
                        .frame(width: 14, height: 14)
                    Text(tetherManager.statusMessage)
                        .font(.headline)
                    Spacer()
                    Text("Đã lưu: \(tetherManager.capturedCount)")
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.15))
                        .cornerRadius(8)
                }
                .padding()
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)
                
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.black.opacity(0.9))
                    
                    if let previewImage = tetherManager.lastPhotoPreview {
                        Image(uiImage: previewImage)
                            .resizable()
                            .scaledToFit()
                            .cornerRadius(12)
                            .padding(8)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "network")
                                .font(.system(size: 60))
                                .foregroundColor(.gray)
                            Text("Bật FTP Transfer trên Sony A7 III\nTrỏ về IP của iPad ở cổng 2121")
                                .multilineTextAlignment(.center)
                                .foregroundColor(.gray)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding()
            .navigationTitle("Sony A7 III FTP Tether")
        }
    }
}
