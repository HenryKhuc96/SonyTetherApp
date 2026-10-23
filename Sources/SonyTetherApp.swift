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
    
    @Published var statusMessage: String = "Đang tìm kiếm Sony A7 III qua cáp USB..."
    @Published var isConnected: Bool = false
    @Published var capturedCount: Int = 0
    @Published var lastPhotoPreview: UIImage? = nil
    
    override init() {
        super.init()
        setupBrowser()
        requestPhotoLibraryPermission()
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
        deviceBrowser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue:
            ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        )!
        deviceBrowser.start()
    }
    
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        DispatchQueue.main.async {
            self.connectedCamera = camera
            self.connectedCamera?.delegate = self
            self.statusMessage = "Đã tìm thấy: \(camera.name ?? "Máy ảnh"). Đang mở phiên..."
            camera.requestOpenSession()
        }
    }
    
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        if device == connectedCamera {
            DispatchQueue.main.async {
                self.isConnected = false
                self.connectedCamera = nil
                self.statusMessage = "Đã ngắt kết nối máy ảnh."
            }
        }
    }
    
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        DispatchQueue.main.async {
            if let error = error {
                self.statusMessage = "Lỗi kết nối: \(error.localizedDescription)"
            } else {
                self.isConnected = true
                self.statusMessage = "✅ Đã kết nối: \(device.name ?? "Sony A7 III"). Sẵn sàng chụp!"
            }
        }
    }
    
    func didRemove(_ device: ICDevice) {
        DispatchQueue.main.async {
            self.isConnected = false
            self.statusMessage = "Máy ảnh đã rút cáp."
        }
    }
    
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        for item in items {
            if let file = item as? ICCameraFile {
                let fileName = file.name ?? ""
                if fileName.uppercased().hasSuffix(".JPG") || fileName.uppercased().hasSuffix(".ARW") {
                    DispatchQueue.main.async {
                        self.statusMessage = "⚡ Đang tải ảnh: \(fileName)..."
                    }
                    downloadFileFromCamera(file)
                }
            }
        }
    }
    
    private func downloadFileFromCamera(_ file: ICCameraFile) {
        let tempDir = FileManager.default.temporaryDirectory
        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: tempDir,
            .saveAsFilename: file.name ?? "Sony_\(UUID().uuidString).JPG",
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
        
        guard let savedFilename = options[ICDownloadOption.savedFilename.rawValue] as? String else { return }
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(savedFilename)
        
        if let data = try? Data(contentsOf: fileURL), let image = UIImage(data: data) {
            DispatchQueue.main.async {
                self.lastPhotoPreview = image
            }
        }
        
        saveToPhotosLibrary(fileURL: fileURL)
    }
    
    private func saveToPhotosLibrary(fileURL: URL) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
        }) { success, error in
            DispatchQueue.main.async {
                if success {
                    self.capturedCount += 1
                    self.statusMessage = "✅ Đã lưu vào Photos! (Tổng: \(self.capturedCount) tấm)"
                    try? FileManager.default.removeItem(at: fileURL)
                } else {
                    self.statusMessage = "❌ Lỗi lưu Photos: \(error?.localizedDescription ?? "Không rõ")"
                }
            }
        }
    }
    
    func triggerShutterFromiPad() {
        guard let camera = connectedCamera, camera.canTakePicture else {
            statusMessage = "⚠️ Hãy bật chế độ PC Remote trên máy ảnh để chụp từ iPad."
            return
        }
        camera.requestTakePicture()
    }
    
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
                            Text("Cắm cáp USB-C từ Sony A7 III vào iPad\nBấm chụp để ảnh tự lưu vào Photos")
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
