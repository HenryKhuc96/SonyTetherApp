import SwiftUI
import Photos
import CascableCore

@main
struct SonyTetherApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

class CascableTetherManager: NSObject, ObservableObject, CameraDiscoveryDelegate {
    @Published var statusMessage: String = "Đang tìm Sony A7 III (Hãy bật PC Remote)..."
    @Published var isConnected: Bool = false
    @Published var capturedCount: Int = 0
    @Published var lastPhotoPreview: UIImage? = nil
    @Published var liveViewImage: UIImage? = nil
    @Published var isLiveViewActive: Bool = false
    
    private var activeCamera: Camera?
    private var transferObserverToken: Any?
    
    override init() {
        super.init()
        requestPhotoLibraryPermission()
        setupCascableDiscovery()
    }
    
    private func requestPhotoLibraryPermission() {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
    }
    
    private func setupCascableDiscovery() {
        let discovery = CameraDiscovery.sharedInstance()
        discovery.delegate = self
        discovery.clientName = "iPad Pro Tether"
        discovery.beginSearching()
    }
    
    // MARK: - CameraDiscoveryDelegate
    
    func cameraDiscovery(_ discovery: CameraDiscovery, didDiscoverCamera camera: Camera) {
        guard activeCamera == nil else { return }
        DispatchQueue.main.async {
            self.statusMessage = "Đã thấy \(camera.friendlyDisplayName ?? "Sony"). Đang kết nối..."
            self.connectToCamera(camera)
        }
    }
    
    func cameraDiscovery(_ discovery: CameraDiscovery, didLoseSightOfCamera camera: Camera) {
        guard let active = activeCamera else { return }
        if active.isEqual(camera) {
            DispatchQueue.main.async {
                self.resetState(message: "Đã ngắt kết nối máy ảnh.")
            }
        }
    }
    
    // MARK: - Kết nối & Lắng nghe ảnh chụp từ PC Remote
    
    private func connectToCamera(_ camera: Camera) {
        activeCamera = camera
        
        camera.connect(authenticationRequestCallback: { context in
            context.submitCancellation()
        }, authenticationResolvedCallback: {
            // Đã xác thực xong
        }, completionCallback: { [weak self] error, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let error = error {
                    self.resetState(message: "❌ Lỗi kết nối: \(error.localizedDescription)")
                    return
                }
                
                self.isConnected = true
                self.statusMessage = "✅ Đã kết nối: \(camera.friendlyDisplayName ?? "Sony A7 III"). Sẵn sàng chụp!"
                self.setupFileObserver(for: camera)
            }
        })
    }
    
    private func setupFileObserver(for camera: Camera) {
        transferObserverToken = camera.fileSystem.addObserver { [weak self] event in
            guard let self = self else { return }
            if case .fileAdded(let file) = event {
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
        
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(file.name)
        
        camera.fileSystem.downloadItem(file, to: fileURL) { [weak self] error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let error = error {
                    self.statusMessage = "❌ Lỗi tải ảnh: \(error.localizedDescription)"
                    return
                }
                self.processDownloadedFile(at: fileURL)
            }
        } progress: { _ in }
    }
    
    private func processDownloadedFile(at fileURL: URL) {
        if let image = UIImage(contentsOfFile: fileURL.path) {
            self.lastPhotoPreview = image
        }
        
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: fileURL, options: nil)
        }) { [weak self] success, error in
            DispatchQueue.main.async {
                if success {
                    self?.capturedCount += 1
                    self?.statusMessage = "✅ Đã lưu vào Photos! (Tổng: \(self?.capturedCount ?? 0))"
                } else {
                    self?.statusMessage = "❌ Lỗi lưu Photos."
                }
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }
    
    // MARK: - Điều khiển Chụp & Live View
    
    func triggerShutter() {
        guard let camera = activeCamera, isConnected else { return }
        statusMessage = "📸 Đang lấy nét và chụp..."
        
        camera.invokeOneShotShutter(explicitlyEngagingAutoFocus: true) { [weak self] error in
            if let error = error {
                DispatchQueue.main.async {
                    self?.statusMessage = "⚠️ Lỗi bấm cò: \(error.localizedDescription)"
                }
            }
        }
    }
    
    func toggleLiveView() {
        guard let camera = activeCamera, isConnected else { return }
        
        guard let liveView = camera.liveViewStream else {
            statusMessage = "⚠️ Máy ảnh không hỗ trợ Live View."
            return
        }
        
        if isLiveViewActive {
            liveView.endStream()
            isLiveViewActive = false
            liveViewImage = nil
        } else {
            isLiveViewActive = true
            liveView.beginStream(
                delivery: { [weak self] frame, completionHandler in
                    DispatchQueue.main.async {
                        self?.liveViewImage = frame.image
                        completionHandler()
                    }
                },
                deliveryQueue: .main,
                terminationHandler: { [weak self] _, _ in
                    DispatchQueue.main.async {
                        self?.isLiveViewActive = false
                        self?.liveViewImage = nil
                    }
                }
            )
        }
    }
    
    private func resetState(message: String) {
        isConnected = false
        isLiveViewActive = false
        liveViewImage = nil
        activeCamera = nil
        statusMessage = message
    }
}

struct ContentView: View {
    @StateObject private var tetherManager = CascableTetherManager()
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack {
                    Circle()
                        .fill(tetherManager.isConnected ? Color.green : Color.red)
                        .frame(width: 14, height: 14)
                    Text(tetherManager.statusMessage)
                        .font(.headline)
                        .lineLimit(1)
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
                        .fill(Color.black.opacity(0.95))
                    
                    if tetherManager.isLiveViewActive, let liveImg = tetherManager.liveViewImage {
                        Image(uiImage: liveImg)
                            .resizable()
                            .scaledToFit()
                            .overlay(alignment: .topLeading) {
                                Text("LIVE VIEW")
                                    .font(.caption.bold())
                                    .padding(6)
                                    .background(Color.red)
                                    .foregroundColor(.white)
                                    .cornerRadius(6)
                                    .padding(12)
                            }
                    } else if let previewImage = tetherManager.lastPhotoPreview {
                        Image(uiImage: previewImage)
                            .resizable()
                            .scaledToFit()
                            .cornerRadius(12)
                            .padding(8)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "camera.aperture")
                                .font(.system(size: 60))
                                .foregroundColor(.gray)
                            Text("Bật chế độ 'PC Remote' trên Sony A7 III\nCắm cáp USB-C vào iPad để vừa chụp vừa xem ảnh")
                                .multilineTextAlignment(.center)
                                .foregroundColor(.gray)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                HStack(spacing: 16) {
                    Button(action: {
                        tetherManager.toggleLiveView()
                    }) {
                        HStack {
                            Image(systemName: tetherManager.isLiveViewActive ? "video.slash.fill" : "video.fill")
                            Text(tetherManager.isLiveViewActive ? "Tắt Live View" : "Bật Live View")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(tetherManager.isConnected ? Color.purple : Color.gray.opacity(0.4))
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .disabled(!tetherManager.isConnected)
                    
                    Button(action: {
                        tetherManager.triggerShutter()
                    }) {
                        HStack {
                            Image(systemName: "camera.shutter.button.fill")
                            Text("Bấm Chụp")
                                .fontWeight(.bold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(tetherManager.isConnected ? Color.orange : Color.gray.opacity(0.4))
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .disabled(!tetherManager.isConnected)
                }
            }
            .padding()
            .navigationTitle("Sony A7 III PC Remote")
        }
    }
}
