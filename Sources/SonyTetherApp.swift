import SwiftUI
import Photos
import CascableCoreSwift

@main
struct SonyTetherApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

class CascableTetherManager: ObservableObject {
    @Published var statusMessage: String = "Đang tìm kiếm Sony qua cáp USB..."
    @Published var isConnected: Bool = false
    @Published var capturedCount: Int = 0
    @Published var lastPhotoPreview: UIImage? = nil
    
    private var activeCamera: Camera?
    private var cameraDiscoveryToken: Any?
    
    init() {
        requestPhotoLibraryPermission()
        setupCascableDiscovery()
    }
    
    private func requestPhotoLibraryPermission() {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
    }
    
    private func setupCascableDiscovery() {
        // Lắng nghe các máy ảnh cắm qua USB hoặc chung mạng Wi-Fi
        cameraDiscoveryToken = CameraDiscovery.shared.addObserver { [weak self] event in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                switch event {
                case .cameraDiscovered(let camera):
                    self.statusMessage = "Đã tìm thấy \(camera.friendlyDisplayName). Đang kết nối..."
                    self.connectToCamera(camera)
                    
                case .cameraLost(let camera):
                    if self.activeCamera?.identifier == camera.identifier {
                        self.resetState(message: "Đã ngắt kết nối máy ảnh.")
                    }
                default:
                    break
                }
            }
        }
        
        CameraDiscovery.shared.start()
    }
    
    private func connectToCamera(_ camera: Camera) {
        // Yêu cầu CascableCore thực hiện quá trình bắt tay PTP đặc quyền
        camera.connect(clientName: "iPad Tether App") { [weak self] error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.statusMessage = "❌ Lỗi kết nối: \(error.localizedDescription)"
                    return
                }
                
                self?.activeCamera = camera
                self?.isConnected = true
                self?.statusMessage = "✅ Đã kết nối: \(camera.friendlyDisplayName). Sẵn sàng chụp!"
                self?.setupFileSystemObserver(for: camera)
            }
        }
    }
    
    private func setupFileSystemObserver(for camera: Camera) {
        // Theo dõi sự kiện khi có file mới được ghi vào bộ nhớ máy ảnh
        camera.fileSystem.addObserver { [weak self] event in
            guard let self = self else { return }
            
            if case .fileAdded(let file) = event {
                // Chỉ tải định dạng ảnh
                let fileName = file.name.uppercased()
                if fileName.hasSuffix(".JPG") || fileName.hasSuffix(".ARW") {
                    self.downloadAndSavePhoto(file: file, from: camera)
                }
            }
        }
    }
    
    private func downloadAndSavePhoto(file: FileSystemItem, from camera: Camera) {
        DispatchQueue.main.async {
            self.statusMessage = "⚡ Đang tải ảnh mới: \(file.name)..."
        }
        
        // Tạo đường dẫn file tạm
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(file.name)
        
        camera.fileSystem.downloadItem(file, to: fileURL) { [weak self] error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.statusMessage = "❌ Lỗi tải ảnh: \(error.localizedDescription)"
                    return
                }
                
                self?.processDownloadedFile(at: fileURL)
            }
        } progress: { progress in
            // Có thể dùng để hiển thị thanh tiến trình nếu cần
        }
    }
    
    private func processDownloadedFile(at fileURL: URL) {
        if let image = UIImage(contentsOfFile: fileURL.path) {
            self.lastPhotoPreview = image
        }
        
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: fileURL, options: nil)
        }) { success, error in
            DispatchQueue.main.async {
                if success {
                    self.capturedCount += 1
                    self.statusMessage = "✅ Đã lưu vào Photos! (Tổng: \(self.capturedCount))"
                } else {
                    self.statusMessage = "❌ Lỗi lưu Photos."
                }
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }
    
    private func resetState(message: String) {
        isConnected = false
        activeCamera = nil
        statusMessage = message
    }
}

struct ContentView: View {
    @StateObject private var tetherManager = CascableTetherManager()
    
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
                            Image(systemName: "camera.on.rectangle")
                                .font(.system(size: 60))
                                .foregroundColor(.gray)
                            Text("Đang chạy lõi CascableCore\nCắm cáp USB-C từ Sony A7 III để kết nối")
                                .multilineTextAlignment(.center)
                                .foregroundColor(.gray)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding()
            .navigationTitle("Sony A7 III Pro Tether")
        }
    }
}
