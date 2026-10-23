import SwiftUI
import ImageCaptureCore
import Photos
import ImageIO

class CameraTetherManager: NSObject, ObservableObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate, ICCameraDeviceDownloadDelegate {
    private var deviceBrowser = ICDeviceBrowser()
    private var connectedCamera: ICCameraDevice?
    private var isCatalogReady: Bool = false
    
    // Hàng đợi tải tuần tự giúp không bị nghẽn cáp khi chụp liên tục hoặc RAW + JPEG
    private var downloadQueue: [ICCameraFile] = []
    private var isDownloading: Bool = false
    
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
            resetConnectionState(message: "Đã ngắt kết nối máy ảnh.")
        }
    }
    
    private func resetConnectionState(message: String) {
        DispatchQueue.main.async {
            self.isConnected = false
            self.isCatalogReady = false
            self.isDownloading = false
            self.downloadQueue.removeAll()
            self.connectedCamera = nil
            self.statusMessage = message
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
    
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        DispatchQueue.main.async {
            self.isCatalogReady = true
            self.statusMessage = "✅ Đã kết nối: \(device.name ?? "Sony A7 III"). Sẵn sàng chụp!"
        }
    }
    
    func didRemove(_ device: ICDevice) {
        resetConnectionState(message: "Máy ảnh đã rút cáp.")
    }
    
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        guard isCatalogReady else { return }
        
        var addedFiles: [ICCameraFile] = []
        for item in items {
            if let file = item as? ICCameraFile {
                let upperName = (file.name ?? "").uppercased()
                if upperName.hasSuffix(".JPG") || upperName.hasSuffix(".JPEG") || upperName.hasSuffix(".ARW") {
                    addedFiles.append(file)
                }
            }
        }
        
        guard !addedFiles.isEmpty else { return }
        
        DispatchQueue.main.async {
            self.downloadQueue.append(contentsOf: addedFiles)
            self.processNextDownload()
        }
    }
    
    // MARK: - Sequential Download Queue & Fast Preview
    
    private func processNextDownload() {
        guard !isDownloading, !downloadQueue.isEmpty, let camera = connectedCamera else { return }
        
        isDownloading = true
        let nextFile = downloadQueue.removeFirst()
        let fileName = nextFile.name ?? "Sony_\(UUID().uuidString).JPG"
        
        statusMessage = "⚡ Đang tải: \(fileName) (Còn chờ: \(downloadQueue.count))..."
        
        let tempDir = FileManager.default.temporaryDirectory
        let expectedURL = tempDir.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: expectedURL)
        
        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: tempDir,
            .saveAsFilename: fileName,
            .overwrite: true
        ]
        
        camera.requestDownloadFile(
            nextFile,
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
                self.isDownloading = false
                self.processNextDownload()
            }
            return
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let savedFilename = (options[ICDownloadOption.savedFilename.rawValue] as? String) ?? file.name ?? ""
        let fileURL = tempDir.appendingPathComponent(savedFilename)
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            DispatchQueue.main.async {
                self.statusMessage = "❌ Không tìm thấy file sau khi tải."
                self.isDownloading = false
                self.processNextDownload()
            }
            return
        }
        
        // Tạo ảnh Preview nhẹ bằng ImageIO (hỗ trợ cả .ARW và .JPG mà không gây tràn RAM)
        if let preview = generateFastPreview(from: fileURL, maxPixelSize: 1600) {
            DispatchQueue.main.async {
                self.lastPhotoPreview = preview
            }
        }
        
        saveToPhotosLibrary(fileURL: fileURL)
    }
    
    private func generateFastPreview(from fileURL: URL, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions) else { return nil }
        
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
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
                
                // Tiếp tục tải file tiếp theo trong hàng đợi
                self.isDownloading = false
                self.processNextDownload()
            }
        }
    }
    
    func triggerShutterFromiPad() {
        guard let camera = connectedCamera, camera.canTakePicture else {
            statusMessage = "⚠️ Máy ảnh không hỗ trợ bấm chụp qua chế độ USB hiện tại."
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
