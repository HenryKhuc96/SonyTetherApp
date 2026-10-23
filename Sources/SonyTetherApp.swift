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

class CascableTetherManager: NSObject, ObservableObject, CBLCameraDiscoveryDelegate {
    @Published var statusMessage: String = "Đang tìm Sony A7 III (Hãy bật PC Remote)..."
    @Published var isConnected: Bool = false
    @Published var capturedCount: Int = 0
    @Published var lastPhotoPreview: UIImage? = nil
    @Published var liveViewImage: UIImage? = nil
    @Published var isLiveViewActive: Bool = false
    
    private var activeCamera: CBLCamera?
    private var transferObserverToken: String?
    
    override init() {
        super.init()
        requestPhotoLibraryPermission()
        setupCascableDiscovery()
    }
    
    private func requestPhotoLibraryPermission() {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
    }
    
    private func setupCascableDiscovery() {
        let discovery = CBLCameraDiscovery.sharedInstance()
        discovery.delegate = self
        discovery.clientName = "iPad Pro Tether"
        // Mặc định beginSearching() đã tự động quét cả USB và Network
        discovery.beginSearching()
    }
    
    // MARK: - CBLCameraDiscoveryDelegate
    
    func cameraDiscovery(_ discovery: CBLCameraDiscovery, didDiscover camera: CBLCamera) {
        guard activeCamera == nil else { return }
        DispatchQueue.main.async {
            self.statusMessage = "Đã thấy \(camera.friendlyDisplayName ?? "Sony"). Đang kết nối..."
            self.connectToCamera(camera)
        }
    }
    
    func cameraDiscovery(_ discovery: CBLCameraDiscovery, didLoseSightOf camera: CBLCamera) {
        guard let active = activeCamera else { return }
        if active.isEqual(camera) {
            DispatchQueue.main.async {
                self.resetState(message: "Đã ngắt kết nối máy ảnh.")
            }
        }
    }
    
    // MARK: - Kết nối & Lắng nghe ảnh chụp từ PC Remote
    
    private func connectToCamera(_ camera: CBLCamera) {
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
                self.setupTetherTransferObserver(for: camera)
            }
        })
    }
    
    private func setupTetherTransferObserver(for camera: CBLCamera) {
        transferObserverToken = camera.addCameraInitiatedTransferObserver({ [weak self] request in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                self.statusMessage = "⚡ Đang nhận ảnh từ bộ nhớ đệm Sony..."
            }
            
            // 1. Lấy ảnh Preview hiển thị nhanh lên iPad
            if request.canProvide(.preview) {
                request.generatePreviewImage({ previewImage, _ in
                    if let previewImage = previewImage {
                        DispatchQueue.main.async {
                            self.lastPhotoPreview = previewImage
                        }
                    }
                })
            }
            
            // 2. Lưu file gốc (Original) về thư mục tạm rồi đẩy vào Photos
            if request.canProvide(.original) {
                let tempDir = FileManager.default.temporaryDirectory
                request.writeOriginalData(toDestinationFolder: tempDir, completionHandler: { savedURL, error in
                    if let savedURL = savedURL, error == nil {
                        self.saveToPhotosLibrary(fileURL: savedURL)
                    } else {
                        DispatchQueue.main.async {
                            self.statusMessage = "❌ Lỗi nhận file gốc: \(error?.localizedDescription ?? "Không rõ")"
                        }
                    }
                })
            }
        })
    }
    
    private func saveToPhotosLibrary(fileURL: URL) {
        if lastPhotoPreview == nil, let img = UIImage(contentsOfFile: fileURL.path) {
            DispatchQueue.main.async {
                self.lastPhotoPreview = img
            }
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
                    self?.statusMessage = "❌ Lỗi lưu Photos: \(error?.localizedDescription ?? "")"
                }
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }
    
    // MARK: - Điều khiển Chụp & Live View từ iPad
    
    func triggerShutter() {
        guard let camera = activeCamera, isConnected else { return }
        statusMessage = "📸 Đang lấy nét và chụp..."
        camera.invokeOneShotShutterExplicitlyEngagingAutoFocus(true, completionCallback: { [weak self] error in
            if let error = error {
                DispatchQueue.main.async {
                    self?.statusMessage = "⚠️ Lỗi bấm cò: \(error.localizedDescription)"
                }
            }
        })
    }
    
    func toggleLiveView() {
        guard let camera = activeCamera, isConnected else { return }
        
        if isLiveViewActive {
            camera.endLiveViewStream()
            isLiveViewActive = false
            liveViewImage = nil
        } else {
            isLiveViewActive = true
            let deliveryHandler: CBLCameraLiveViewFrameDelivery = { [weak self] frame, completionHandler in
                DispatchQueue.main.async {
                    self?.liveViewImage = frame.image
                    completionHandler()
                }
            }
            
            camera.beginLiveViewStream(
                delivery: deliveryHandler,
                deliveryQueue: DispatchQueue.main,
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
        if let camera = activeCamera, let token = transferObserverToken {
            camera.removeCameraInitiatedTransferObserver(withToken: token)
        }
        isConnected = false
        isLiveViewActive = false
        liveViewImage = nil
        activeCamera = nil
        transferObserverToken = nil
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
