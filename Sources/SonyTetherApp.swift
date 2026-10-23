import SwiftUI
import ImageCaptureCore
import Photos

@main
struct SonyTetherApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

class CameraTetherManager: NSObject, ObservableObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate, ICCameraDeviceDownloadDelegate {
    private var deviceBrowser = ICDeviceBrowser()
    private var connectedCamera: ICCameraDevice?
    
    // Cờ kiểm tra đã đọc xong danh sách ảnh cũ trên thẻ nhớ hay chưa
    private var isCatalogReady: Bool = false
    
    @Published var statusMessage: String = "Đang tìm kiếm Sony A7 III qua cáp USB..."
    @Published var isConnected: Bool = false
    @Published var capturedCount: Int = 0
    @Published var lastPhotoPreview: UIImage? = nil
    
    override init() {
        super.init()
        requestPhotoLibraryPermission()
        setupBrowser()
    }
    
    private func requestPhotoLibraryPermission() {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            if status != .authorized && status != .limited {
                DispatchQueue.main.async {
                    self.statusMessage = "⚠️ Cần cấp quyền lưu ảnh vào Photos trong Cài đặt!"
                }
            }
        }
    }
    
    private func setupBrowser() {
        deviceBrowser.delegate = self
        #if os(macOS)
        deviceBrowser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue:
            ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        )!
        #endif
        deviceBrowser.start()
    }
    
    // MARK: - ICDeviceBrowserDelegate
    
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        DispatchQueue.main.async {
            self.connectedCamera = camera
            self.isCatalogReady = false
            self.connectedCamera?.delegate = self
            self.statusMessage = "Đã tìm thấy: \(camera.name ?? "Máy ảnh"). Đang mở phiên..."
            camera.requestOpenSession()
        }
    }
    
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        if device == connectedCamera {
            DispatchQueue.main.async {
                self.isConnected = false
                self.isCatalogReady = false
                self.connectedCamera = nil
                self.statusMessage = "Đã ngắt kết nối máy ảnh."
            }
        }
    }
    
    // MARK: - ICDeviceDelegate & ICCameraDeviceDelegate
    
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        DispatchQueue.main.async {
            if let error = error {
                self.statusMessage = "Lỗi kết nối: \(error.localizedDescription)"
            } else {
                self.isConnected = true
                self.statusMessage = "⏳ Đang đồng bộ danh mục thẻ nhớ..."
            }
        }
    }
    
    // BẮT BUỘC: Đánh dấu máy ảnh đã đọc xong các ảnh cũ trên thẻ nhớ
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        DispatchQueue.main.async {
            self.isCatalogReady = true
            self.statusMessage = "✅ Đã kết nối: \(device.name ?? "Sony A7 III"). Sẵn sàng chụp!"
        }
    }
    
    func didRemove(_ device: ICDevice) {
        DispatchQueue.main.async {
            self.isConnected = false
            self.isCatalogReady = false
            self.connectedCamera = nil
            self.statusMessage = "Máy ảnh đã rút cáp."
        }
    }
    
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        // Bỏ qua toàn bộ ảnh cũ có sẵn trong thẻ nhớ lúc mới cắm cáp
        guard isCatalogReady else { return }
        
        for item in items {
            if let file = item as? ICCameraFile {
                let fileName = file.name ?? ""
                let upperName = fileName.uppercased()
                if upperName.hasSuffix(".JPG") || upperName.hasSuffix(".JPEG") || upperName.hasSuffix(".ARW") {
                    DispatchQueue.main.async {
                        self.statusMessage = "⚡ Đang tải ảnh mới: \(fileName)..."
                    }
                    downloadFileFromCamera(file)
                }
            }
        }
    }
    
    // MARK: - Download & Save
    
    private func downloadFileFromCamera(_ file: ICCameraFile) {
        let tempDir = FileManager.default.temporaryDirectory
        let targetFileName = file.name ?? "Sony_\(UUID().uuidString).JPG"
        
        // Xóa file trùng tên trong thư mục tạm nếu có trước khi tải
        let expectedURL = tempDir.appendingPathComponent(targetFileName)
        try? FileManager.default.removeItem(at: expectedURL)
        
        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: tempDir,
            .saveAsFilename: targetFileName,
            .overwrite: true
        ]
        
        connectedCamera?.requestDownloadFile(
            file,
            options: options,
            downloadDelegate: self,
            didDownloadSelector: #selector(didDownloadFile(_:error:options:contextInfo:)),
            contextInfo: nil
        )
    }
    
    @objc func didDownloadFile(_ file: ICCameraFile, error: Error?, options: [String: Any], contextInfo: UnsafeMutableRawPointer?) {
        if let error = error {
            DispatchQueue.main.async {
                self.statusMessage = "❌ Lỗi tải ảnh: \(error.localizedDescription)"
            }
            return
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let savedFilename = (options[ICDownloadOption.savedFilename.rawValue] as? String) ?? file.name ?? ""
        let fileURL = tempDir.appendingPathComponent(savedFilename)
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            DispatchQueue.main.async {
                self.statusMessage = "❌ Không tìm thấy file sau khi tải."
            }
            return
        }
        
        // Hiển thị preview (ưu tiên JPG hoặc dùng ImageIO để giảm tải RAM)
        if let image = UIImage(contentsOfFile: fileURL.path) {
            DispatchQueue.main.async {
                self.lastPhotoPreview = image
            }
        }
        
        saveToPhotosLibrary(fileURL: fileURL)
    }
    
    private func saveToPhotosLibrary(fileURL: URL) {
        PHPhotoLibrary.shared().performChanges({
            // Dùng PHAssetCreationRequest để hỗ trợ cả file .JPG và .ARW (Sony RAW)
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
                // Dọn dẹp file tạm
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }
    
    func triggerShutterFromiPad() {
        guard let camera = connectedCamera, camera.canTakePicture else {
            statusMessage = "⚠️ Máy ảnh không hỗ trợ bấm chụp qua giao thức hiện tại."
            return
        }
        camera.requestTakePicture()
    }
    
    // MARK: - Các hàm bắt buộc còn lại của ICCameraDeviceDelegate
    
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable : Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
}

struct ContentView: View {
    @StateObject private var tetherManager = CameraTetherManager()
    
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
                            Image(systemName: "camera.metering.center.weighted")
                                .font(.system(size: 60))
                                .foregroundColor(.gray)
                            Text("Cắm cáp USB-C từ Sony A7 III vào iPad\nBấm chụp trên máy ảnh để ảnh tự lưu vào Photos")
                                .multilineTextAlignment(.center)
                                .foregroundColor(.gray)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                Button(action: {
                    tetherManager.triggerShutterFromiPad()
                }) {
                    HStack {
                        Image(systemName: "camera.shutter.button.fill")
                        Text("Bấm Chụp Từ iPad")
                            .fontWeight(.bold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(tetherManager.isConnected ? Color.orange : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(!tetherManager.isConnected)
            }
            .padding()
            .navigationTitle("Sony A7 III Auto-Tether")
        }
    }
}
