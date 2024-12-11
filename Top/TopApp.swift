// 导入必要的框架
import SwiftUI
import AppKit
import ScreenCaptureKit
import CoreGraphics
import ServiceManagement

// 添加私有 API 声明
typealias CGSConnection = UInt32
typealias CGSWindowID = UInt32
typealias CGSWindowCount = UInt32

// 在文件顶部添加枚举定义
enum CGSWindowOrderingMode: Int32 {
    case orderAbove = 1
    case orderBelow = -1
    case orderOut = 0
}

let kCGSOrderAbove: CGSWindowOrderingMode = .orderAbove

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnection

@_silgen_name("CGSSetWindowLevel")
func CGSSetWindowLevel(_ connection: CGSConnection, _ window: CGSWindowID, _ newLevel: Int32) -> CGError

@_silgen_name("CGSOrderWindow")
func CGSOrderWindow(_ connection: CGSConnection, _ window: CGSWindowID, _ place: CGSWindowOrderingMode, _ relativeToWindow: CGSWindowID) -> CGError

@_silgen_name("CGSMoveWindow")
func CGSMoveWindow(_ connection: CGSConnection, _ window: CGSWindowID, _ point: CGPoint) -> CGError

// 在文件顶部添加结构体定义
struct WindowIdentifier: Hashable {
    let pid: pid_t
    let windowID: CGWindowID
}

// 在文件顶部添加 kCGWindowLevel 常量
let kCGWindowLevel = "kCGWindowLevel" as CFString

// 在文件顶部添加常量
let kCGWindowOwnerType = "kCGWindowOwnerType" as CFString

// 添加新的数据结构来表示窗口信息
struct WindowInfo: Identifiable, Hashable {
    let id: WindowIdentifier
    let app: NSRunningApplication
    let windowName: String
    let icon: NSImage?
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id
    }
}

/// 应用程序类，负责管理应用程序窗口的置顶状态和屏幕捕获
final class TopApp: NSObject, ObservableObject {
    // 存储运行中的应用列表及其置顶状态
    @Published var runningApps: [NSRunningApplication] = []
    // 存储是否有辅助功能权限
    @Published var hasAccessibilityPermission: Bool = false
    // 存储已置顶窗口的进程ID集合
    @Published var pinnedWindows: Set<WindowIdentifier> = []
    // 存储屏幕捕获会话
    private var captureSession: SCShareableContent?
    // 存储透明窗口
    private var overlayWindows: [WindowIdentifier: NSWindow] = [:]
    // 存储捕获流
    private var streams: [WindowIdentifier: SCStream] = [:]
    // 存储工作区通知观察者
    private var workspaceNotificationObserver: Any?
    // 存储窗口位置监视器
    private var windowMonitors: [WindowIdentifier: Timer] = [:]
    // 存储窗口列表属性
    @Published var windowList: [WindowInfo] = []
    // 存储开机自启动状态
    @Published var launchAtStartup: Bool = false {
        didSet {
            setLaunchAtStartup(launchAtStartup)
        }
    }
    
    override init() {
        super.init()
        if checkAccessibilityPermission(){
            setupWorkspaceNotifications()
            updateRunningApps()
            checkLaunchAtStartup()
            print("初始化 TopApp")
        }
        
    }
    
    /// 设置屏幕捕获
    private func setupScreenCapture() {
        Task {
            do {
                captureSession = try await SCShareableContent.current
                print("设置屏幕捕获成功")
            } catch {
                print("设置屏幕捕获失败: \(error)")
            }
        }
    }
    
    /// 监听工作区应用变化
    private func setupWorkspaceNotifications() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        
        // 监听应用启动
        notificationCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceNotification),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        
        // 监听应用终止
        notificationCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceNotification),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        
        // 监听应用激活
        workspaceNotificationObserver = notificationCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceNotification),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }
    
    @objc private func handleWorkspaceNotification(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.updateRunningApps()
        }
    }
    
    /// 检查是否有辅助功能权限
    func checkAccessibilityPermission() -> Bool {
        // 检查辅助功能权限
        let accessibilityGranted = AXIsProcessTrusted()
        
        // 检查屏幕录制权限
        let screenCaptureGranted = CGPreflightScreenCaptureAccess()
        
        // 更新权限状态
        hasAccessibilityPermission = accessibilityGranted && screenCaptureGranted
        
        if !accessibilityGranted {
            print("需要辅助功能权限")
            // 请求辅助功能权限
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            AXIsProcessTrustedWithOptions(options as CFDictionary)
        }
        
        if !screenCaptureGranted {
            print("需要屏幕录制权限")
            // 请求屏幕录制权限
            CGRequestScreenCaptureAccess()
        }
        
        // 如果权限都已授予，设置屏幕捕获
        if hasAccessibilityPermission {
            setupScreenCapture()
        }
        
        print("权限状态 - 辅助功能: \(accessibilityGranted), 屏幕录制: \(screenCaptureGranted)")
        return hasAccessibilityPermission
    }
    
    /// 检查屏幕捕获权限
    private func checkScreenCapturePermission() {
        Task {
            do {
                // 尝试获取屏幕内容，这会触发权限检查
                captureSession = try await SCShareableContent.current
                print("成功获取屏幕内容")
                
                // 更新UI状态
                DispatchQueue.main.async { [weak self] in
                    self?.hasAccessibilityPermission = true
                }
            } catch {
                print("获取屏幕内容失败: \(error)")
                DispatchQueue.main.async { [weak self] in
                    self?.hasAccessibilityPermission = false
                }
            }
        }
    }
    
    /// 更新运行中的应用列表
    func updateRunningApps() {
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[CFString: Any]] ?? []
        
        let validWindows = windowList.filter { windowInfo in
            guard let isOnscreen = windowInfo[kCGWindowIsOnscreen as CFString] as? Int,
                  isOnscreen == 1,
                  let ownerName = windowInfo[kCGWindowOwnerName as CFString] as? String,
                  ownerName != "",
                  let bounds = windowInfo[kCGWindowBounds as CFString] as? [String: Any],
                  let width = bounds["Width"] as? CGFloat,
                  let height = bounds["Height"] as? CGFloat,
//                  let windowID = windowInfo[kCGWindowNumber as CFString] as? CGWindowID,
//                  let pid = windowInfo[kCGWindowOwnerPID as CFString] as? pid_t,
                  let layer = windowInfo[kCGWindowLayer as CFString] as? Int32,
                  layer == 0,
                  width >= 250, height >= 250 else {
                return false
            }
            return true
        }
        
        let windowInfos = validWindows.compactMap { windowInfo -> WindowInfo? in
            guard let pid = windowInfo[kCGWindowOwnerPID as CFString] as? pid_t,
                  let windowID = windowInfo[kCGWindowNumber as CFString] as? CGWindowID,
                  let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular else {
                return nil
            }
            
            let windowName = windowInfo[kCGWindowName as CFString] as? String ?? ""
            let identifier = WindowIdentifier(pid: pid, windowID: windowID)
            
            return WindowInfo(
                id: identifier,
                app: app,
                windowName: windowName,
                icon: app.icon
            )
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Only include applications that have windows
            let windowInfos = windowInfos.filter { !$0.windowName.isEmpty }
            
            self.windowList = windowInfos.sorted { ($0.app.localizedName ?? "") < ($1.app.localizedName ?? "") }
            
            // 清理不存在的窗口
            let validIdentifiers = Set(windowInfos.map { $0.id })
            self.pinnedWindows = self.pinnedWindows.filter { validIdentifiers.contains($0) }
            
            // 清理覆盖窗口
            for identifier in self.overlayWindows.keys where !validIdentifiers.contains(identifier) {
                self.unpinWindow(identifier: identifier)
            }
        }
    }
    
    /// 为指定窗口创建透明覆盖层
    private func createOverlayWindow(windowInfo: [CFString: Any], identifier: WindowIdentifier) {
        // 获取目标窗口的位置和大小
        guard let bounds = windowInfo[kCGWindowBounds as CFString] as? [String: Any],
              let x = bounds["X"] as? CGFloat,
              let y = bounds["Y"] as? CGFloat,
              let width = bounds["Width"] as? CGFloat,
              let height = bounds["Height"] as? CGFloat,
              // 在这里检查窗口大小
              width >= 250, height >= 250 else {
            // 使用 windowInfo 来获取尺寸信息
            if let bounds = windowInfo[kCGWindowBounds as CFString] as? [String: Any] {
                print("窗口尺寸不符合要求: width=\(bounds["Width"] ?? 0), height=\(bounds["Height"] ?? 0)")
            } else {
                print("无法获取窗口尺寸信息")
            }
            return
        }
        
        print("目标窗口大小: width=\(width), height=\(height)")
        
        // 转换坐标系统
        let screenFrame = NSScreen.main?.frame ?? .zero
        let adjustedY = screenFrame.height - (y + height)  // 转换 y 坐标
        let frame = NSRect(x: x, y: adjustedY, width: width, height: height)
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // 如果已经存在覆盖窗口，更新其位置和大小
            if let existingWindow = self.overlayWindows[identifier] {
                print("更新现有覆盖窗口")
                existingWindow.setFrame(frame, display: true)
                
                // 更新捕获流配置
                self.updateCaptureStream(for: identifier, width: width, height: height)
                return
            }
            
            print("创建新的覆盖窗口")
            let displayScale = NSScreen.main?.backingScaleFactor ?? 2.0
            
            // 创建覆盖窗口
            let overlayWindow = NSWindow(
                contentRect: frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            
            // 修改窗口层级设置
            // 将覆盖窗口设置在目标窗口的下层
            overlayWindow.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
            
            // 设置窗口属性
            overlayWindow.backgroundColor = .clear
            overlayWindow.isOpaque = false
            overlayWindow.hasShadow = false
            overlayWindow.ignoresMouseEvents = true
            overlayWindow.collectionBehavior = [.canJoinAllSpaces, .stationary]
            
            // 建内容视图
            let contentView = HoverDetectionView(frame: NSRect(origin: .zero, size: frame.size))
            contentView.wantsLayer = true
            contentView.layer?.backgroundColor = NSColor.clear.cgColor
            contentView.layer?.contentsScale = displayScale
            contentView.windowIdentifier = identifier
            contentView.overlayWindow = overlayWindow
            let overlayLevel = Int32(overlayWindow.level.rawValue)
            let targetLevel = overlayLevel - 1


           

            
            // 设置鼠标事件处理
            contentView.onMouseEntered = { [weak self] in
                guard self != nil else { return }
                print("鼠标进入事件触发，窗口ID: \(identifier.windowID)")
                
                let connection = CGSMainConnectionID()
                print("CGS连接ID: \(connection)")
                                
                                // 设置窗口层级
                let result = CGSSetWindowLevel(connection, identifier.windowID, targetLevel)
                print("设置窗口层级结果: \(result)")
                                
                                // 确保窗口在前
                let orderResult = CGSOrderWindow(connection, identifier.windowID, .orderAbove, 0)
                print("排序窗口结果: \(orderResult)")

            }
            
            contentView.onMouseExited = { [weak self] in
                guard self != nil else { return }
                print("鼠标移出事件触发，窗口ID: \(identifier.windowID)")
            }
            
            // 配置屏幕捕获
            Task {
                do {
                    let content = try await SCShareableContent.current
                    guard let window = content.windows.first(where: { $0.windowID == identifier.windowID }) else {
                        print("找不到对应的窗口")
                        return
                    }
                    
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    let configuration = SCStreamConfiguration()
                    
                    // 设置捕获配置
                    configuration.width = Int(width * displayScale)
                    configuration.height = Int(height * displayScale)
                    configuration.scalesToFit = true
                    configuration.queueDepth = 5
                    configuration.pixelFormat = kCVPixelFormatType_32BGRA
                    configuration.showsCursor = false
                    
                    print("设置捕获区域: width=\(configuration.width), height=\(configuration.height)")
                    
                    let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue.global(qos: .userInteractive))
                    try await stream.startCapture()
                    
                    await MainActor.run {
                        self.streams[identifier] = stream
                    }
                    
                    print("屏幕捕获设置成功")
                } catch {
                    print("设置捕获失败: \(error)")
                }
            }
            
            // 存储窗口引用
            self.overlayWindows[identifier] = overlayWindow
            overlayWindow.contentView = contentView
            overlayWindow.makeKeyAndOrderFront(nil)
            
            // 开始监听窗口位置变化
            self.startWindowPositionMonitoring(for: identifier)
        }
    }
    
    /// 添加新方法来更新捕获流
    private func updateCaptureStream(for identifier: WindowIdentifier, width: CGFloat, height: CGFloat) {
        Task {
            // 停止当前的捕获流
            if let currentStream = self.streams[identifier] {
                try? await currentStream.stopCapture()
                self.streams.removeValue(forKey: identifier)
            }
            
            // 获取新的可共享内容
            guard let content = try? await SCShareableContent.current,
                  let window = content.windows.first(where: { $0.windowID == identifier.windowID }) else {
                return
            }
            
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            
            // 设置新的捕获配置
            let displayScale = NSScreen.main?.backingScaleFactor ?? 2.0
            configuration.width = Int(width * displayScale)
            configuration.height = Int(height * displayScale)
            configuration.scalesToFit = true
            configuration.queueDepth = 5
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = false
            
            // 创建新的捕获流
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try? stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue.global(qos: .userInteractive))
            try? await stream.startCapture()
            
            await MainActor.run {
                self.streams[identifier] = stream
            }
        }
    }
    
    /// 监听窗口位置变化
    private func startWindowPositionMonitoring(for identifier: WindowIdentifier) {
        if windowMonitors[identifier] != nil {
            return
        }
        
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            
            // 获取当前窗口信息
            let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[CFString: Any]] ?? []
            let filteredWindows = windowList.filter { windowInfo in
                guard let isOnscreen = windowInfo[kCGWindowIsOnscreen as CFString] as? Int,
                      isOnscreen == 1,
                      let ownerName = windowInfo[kCGWindowOwnerName as CFString] as? String,
                      ownerName != "" else {
                    return false
                }
                return true
            }
            
            // 使用窗口ID查找窗口
            if let windowInfo = filteredWindows.first(where: { ($0[kCGWindowNumber as CFString] as? CGWindowID) == identifier.windowID }) {
                // 检查窗口尺寸
                guard let bounds = windowInfo[kCGWindowBounds as CFString] as? [String: Any],
                      let width = bounds["Width"] as? CGFloat,
                      let height = bounds["Height"] as? CGFloat,
                      width >= 250, height >= 250 else {
                    // 如果窗口尺寸不符合要求，停止监听并取消置顶
                    print("窗口尺寸不符合要求，停止监听")
                    timer.invalidate()
                    self.windowMonitors.removeValue(forKey: identifier)
                    self.unpinWindow(identifier: identifier)
                    return
                }
                

                self.updateOverlayWindow(windowInfo: windowInfo, identifier: identifier)
            } else {
                // 如果找不到窗口，停止监听
                print("找不到窗口，停止监听")
                timer.invalidate()
                self.windowMonitors.removeValue(forKey: identifier)
                self.unpinWindow(identifier: identifier)
            }
        }
        
        windowMonitors[identifier] = timer
    }
    
    /// 更新覆盖窗口位置和大小
    private func updateOverlayWindow(windowInfo: [CFString: Any], identifier: WindowIdentifier) {
        guard let bounds = windowInfo[kCGWindowBounds as CFString] as? [String: Any],
              let x = bounds["X"] as? CGFloat,
              let y = bounds["Y"] as? CGFloat,
              let width = bounds["Width"] as? CGFloat,
              let height = bounds["Height"] as? CGFloat else {
            return
        }
        
        // 检查窗口尺寸是否小于 50x50
        guard width >= 250, height >= 250 else {
            print("窗口尺寸过小，跳过更新: width=", width, "height=", height)
            return
        }

        let screenFrame = NSScreen.main?.frame ?? .zero
        let adjustedY = screenFrame.height - (y + height)
        let newFrame = NSRect(x: x, y: adjustedY, width: width, height: height)
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let overlayWindow = self.overlayWindows[identifier] else {
                return
            }
            
            // 检查窗口信息是否发生变化
            guard overlayWindow.frame != newFrame else {
                return
            }

            // 记录窗口信息更新日志
            print("更新窗口位置和大小: 从 \(overlayWindow.frame) 到 \(newFrame)")

            // 更新窗口位置和大小
            overlayWindow.setFrame(newFrame, display: true)
            
            // 更新屏幕捕获
            Task {
                // 停止当前的捕获流
                if let currentStream = self.streams[identifier] {
                    try? await currentStream.stopCapture()
                    self.streams.removeValue(forKey: identifier)
                }
                
                // 获取新的可共享内容
                guard let content = try? await SCShareableContent.current,
                      let window = content.windows.first(where: { $0.windowID == identifier.windowID }) else {
                    return
                }
                
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let configuration = SCStreamConfiguration()
                
                // 设置新的捕获配置
                let displayScale = NSScreen.main?.backingScaleFactor ?? 2.0
                configuration.width = Int(width * displayScale)
                configuration.height = Int(height * displayScale)
                configuration.scalesToFit = true
                configuration.queueDepth = 5
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.showsCursor = false
                
                // 创建新的捕获流
                let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                try? stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue.global(qos: .userInteractive))
                try? await stream.startCapture()
                
                await MainActor.run {
                    self.streams[identifier] = stream
                }
            }
        }
    }
    
    /// 为指定窗口捕获流
    private func createStreamConfiguration(for window: CGWindowID) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        
        // 设置帧率为 30 FPS
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        
        // 使用默认的视频质量设置
        configuration.queueDepth = 5
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        
        // 获取窗口的实际大小
        if let windowInfo = CGWindowListCreateDescriptionFromArray([window] as CFArray) as? [[CFString: Any]],
           let bounds = windowInfo.first?[kCGWindowBounds as CFString] as? [String: Any],
           let width = bounds["Width"] as? CGFloat,
           let height = bounds["Height"] as? CGFloat {
            // 设置捕获区域大小与窗口大小完全一致
            configuration.width = Int(width)
            configuration.height = Int(height)
            // 禁用缩放以保持原始大小
            configuration.scalesToFit = false
        }
        
        // 其他设置
        configuration.showsCursor = false
        configuration.backgroundColor = .clear
        
        return configuration
    }
    
    /// 切换窗口的置顶状态
    func toggleWindowPin(for app: NSRunningApplication) {
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[CFString: Any]] ?? []
        let appWindows = windowList.filter { windowInfo in
            guard let pid = windowInfo[kCGWindowOwnerPID as CFString] as? pid_t,
                  pid == app.processIdentifier // ,
//                  let windowID = windowInfo[kCGWindowNumber as CFString] as? CGWindowID
            else {
                return false
            }
            return true
        }
        
        if let windowInfo = appWindows.first,
           let windowID = windowInfo[kCGWindowNumber as CFString] as? CGWindowID {
            let identifier = WindowIdentifier(pid: app.processIdentifier, windowID: windowID)
            if pinnedWindows.contains(identifier) {
                unpinWindow(identifier: identifier)
            } else {
                pinWindow(windowInfo: windowInfo, identifier: identifier)
            }
        }
        
        updateRunningApps()
    }
    
    /// 取消窗口置顶
    func unpinWindow(identifier: WindowIdentifier) {
        pinnedWindows.remove(identifier)
        
        if let timer = windowMonitors[identifier] {
            timer.invalidate()
            windowMonitors.removeValue(forKey: identifier)
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if let overlayWindow = self.overlayWindows[identifier] {
                overlayWindow.orderOut(nil)
                self.overlayWindows.removeValue(forKey: identifier)
            }
            
            if let stream = self.streams[identifier] {
                Task {
                    try? await stream.stopCapture()
                    await MainActor.run(resultType: Void.self) {
                        self.streams.removeValue(forKey: identifier)
                    }
                }
            }
        }
    }
    
    /// 设置窗口置顶
    func pinWindow(windowInfo: [CFString: Any], identifier: WindowIdentifier) {
        // 检查窗口尺寸是否符合要求
        guard let bounds = windowInfo[kCGWindowBounds as CFString] as? [String: Any],
              let width = bounds["Width"] as? CGFloat,
              let height = bounds["Height"] as? CGFloat,
              width >= 250, height >= 250 else {
            print("窗口尺寸不符合要求，取消置顶")
            return
        }

        pinnedWindows.insert(identifier)
        createOverlayWindow(windowInfo: windowInfo, identifier: identifier)
        startWindowPositionMonitoring(for: identifier)
    }
    
    /// 清理资源
    func cleanup() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // 停止所有捕获流
            for (identifier, stream) in self.streams {
                Task {
                    do {
                        try await stream.stopCapture()
                        await MainActor.run(resultType: Void.self) {
                            self.streams.removeValue(forKey: identifier)
                        }
                    } catch {
                        print("停止捕获流时出错: \(error)")
                    }
                }
            }
            
            // 关闭所有覆盖窗口
            for (_, window) in self.overlayWindows {
                window.orderOut(nil)
            }
            self.overlayWindows.removeAll()
            
            // 清除所有置顶状态
            self.pinnedWindows.removeAll()
        }
    }
    
    deinit {
        // 移除通知观察者
        if let observer = workspaceNotificationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        cleanup()
    }
    
    private func checkLaunchAtStartup() {
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            launchAtStartup = status == .enabled
        } else {
            let bundleURL = Bundle.main.bundleURL
            let runningApps = NSWorkspace.shared.runningApplications
            
            for app in runningApps {
                if app.bundleURL == bundleURL {
                    launchAtStartup = app.isTerminated == false
                    return
                }
            }
            launchAtStartup = false
        }
    }
    
    private func setLaunchAtStartup(_ enable: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enable {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Failed to set launch at startup: \(error)")
            }
        } else {
            let bundleURL = Bundle.main.bundleURL
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            if enable {
                NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, error in
                    if let error = error {
                        print("Failed to enable launch at startup: \(error)")
                    }
                }
            }
        }
    }
}

extension TopApp: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Stream stopped with error: \(error)")
        
        // 查错误类型
        if let error = error as? SCStreamError {
            switch error.code {
            case .userStopped:
                print("用户停止了流，尝试重新启动...")
                // 获取对应的 pid
                if let identifier = streams.first(where: { $0.value === stream })?.key {
                    // 延迟一秒后重试
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        guard let self = self else { return }
                        // 停止旧的流
                        stream.stopCapture()
                        self.streams.removeValue(forKey: identifier)
                        
                        // 重新创建流
                        Task {
                            await self.setupCaptureForWindow(withWindowID: identifier.windowID)
                        }
                    }
                }
            default:
                print("Stream error: \(error.localizedDescription)")
            }
        }
    }
    
    private func setupCaptureForWindow(withWindowID windowID: CGWindowID) async {
        // 获取窗口信息
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[CFString: Any]] ?? []
        let filteredWindows = windowList.filter { windowInfo in
            guard let isOnscreen = windowInfo[kCGWindowIsOnscreen as CFString] as? Int,
                  isOnscreen == 1,
                  let ownerName = windowInfo[kCGWindowOwnerName as CFString] as? String,
                  ownerName != "" else {
                return false
            }
            return true
        }
        guard let windowInfo = filteredWindows.first(where: { info in
            guard let windowPid = info[kCGWindowOwnerPID as CFString] as? pid_t,
                  windowPid == windowID else { return false }
            return true
        }) else {
            print("无法找到对应的窗口")
            return
        }
        
        do {
            // 获取可共享内容
            guard let shareableContent = try? await SCShareableContent.current else {
                print("无法获取可共享内容")
                return
            }
            
            // 查找对应的 SCWindow
            guard let window = shareableContent.windows.first(where: { window in
                guard let windowPid = windowInfo[kCGWindowOwnerPID as CFString] as? pid_t,
                      windowPid == windowID else { return false }
                return true
            }) else {
                print("无法找到对应的 SCWindow")
                return
            }
            
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.queueDepth = 5
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = false
            configuration.backgroundColor = .clear
            
            // 使用更高质量的彩空间
            if #available(macOS 13.0, *) {
                configuration.colorSpaceName = CGColorSpace.displayP3
            }
            
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            
            // 使用高优先级队列处理捕获
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue.global(qos: .userInteractive))
            try await stream.startCapture()
            
            await MainActor.run {
                self.streams[WindowIdentifier(pid: windowInfo[kCGWindowOwnerPID as CFString] as? pid_t ?? 0, windowID: windowID)] = stream
            }
            
            // 开始监听窗口位置变化
            self.startWindowPositionMonitoring(for: WindowIdentifier(pid: windowInfo[kCGWindowOwnerPID as CFString] as? pid_t ?? 0, windowID: windowID))
        } catch {
            print("新设置捕获失败: \(error)")
        }
    }
    
    private func getWindowForPid(_ pid: pid_t) async -> CGWindowID? {
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[CFString: Any]] ?? []
        let filteredWindows = windowList.filter { windowInfo in
            guard let isOnscreen = windowInfo[kCGWindowIsOnscreen as CFString] as? Int,
                  isOnscreen == 1,
                  let ownerName = windowInfo[kCGWindowOwnerName as CFString] as? String,
                  ownerName != "" else {
                return false
            }
            return true
        }
        return filteredWindows.first { windowInfo in
            guard let windowPid = windowInfo[kCGWindowOwnerPID as CFString] as? pid_t,
                  windowPid == pid
            else { return false }
            return true
        }?.first { $0.key == kCGWindowNumber as CFString }?.value as? CGWindowID
    }
}

extension TopApp: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let imageBuffer = sampleBuffer.imageBuffer else {
            return
        }
        
        // 在后台线程处理图像
        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        
        // 在主线程更新 UI
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let identifier = self.streams.first(where: { $0.value === stream })?.key,
                  let overlayWindow = self.overlayWindows[identifier],
                  overlayWindow.isVisible,
                  let contentView = overlayWindow.contentView else {
                return
            }
            
            // 更新或创建 ImageView
            if let imageView = contentView.subviews.first as? NSImageView {
                if imageView.image?.size != nsImage.size {
                    imageView.frame = contentView.bounds
                }
                imageView.image = nsImage
            } else {
                let imageView = NSImageView(frame: contentView.bounds)
                imageView.imageScaling = .scaleProportionallyUpOrDown
                imageView.image = nsImage
                contentView.addSubview(imageView)
            }
        }
    }
}

/// 应用列表项图
struct AppListItem: View {
    let app: NSRunningApplication
    let isPinned: Bool
    let onToggle: () -> Void
    
    var body: some View {
        Button(action: onToggle) {
            HStack {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                Text(app.localizedName ?? "未知应用")
                Spacer()
                Image(systemName: isPinned ? "pin.fill" : "pin")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 菜单栏视图
struct MenuBarView: View {
    @StateObject private var topApp = TopApp()
    @State private var hasAccessibilityPermission: Bool = false
    @State private var hasScreenRecordingPermission: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            if !hasAccessibilityPermission || !hasScreenRecordingPermission {
                PermissionRequestView(
                    hasAccessibilityPermission: hasAccessibilityPermission,
                    hasScreenRecordingPermission: hasScreenRecordingPermission
                )
            } else {
                VStack {
                    Toggle("开机自启动", isOn: $topApp.launchAtStartup)
                        .padding(.horizontal)
                        .padding(.top, 8)
                    
                    Divider()
                        .padding(.vertical, 4)
                    
                    if topApp.windowList.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "app.dashed")
                                .font(.system(size: 24))
                                .foregroundColor(.gray)
                            Text("没有运行中的窗口")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                    } else {
                        ScrollView(showsIndicators: false) { // 隐藏滚动条
                            LazyVGrid(columns: [
                                GridItem(.flexible(), spacing: 16),
                                GridItem(.flexible(), spacing: 16)
                            ], spacing: 16) {
                                ForEach(topApp.windowList) { window in
                                    WindowGridItem(
                                        window: window,
                                        isPinned: topApp.pinnedWindows.contains(window.id)
                                    ) {
                                        if let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[CFString: Any]],
                                           let info = windowInfo.first(where: { ($0[kCGWindowNumber as CFString] as? CGWindowID) == window.id.windowID }) {
                                            // 直接使用 window.id 来切换置顶状态
                                            if topApp.pinnedWindows.contains(window.id) {
                                                topApp.unpinWindow(identifier: window.id)
                                            } else {
                                                topApp.pinWindow(windowInfo: info, identifier: window.id)
                                            }
                                            // 更新 UI
                                            topApp.objectWillChange.send()
                                        }
                                    }
                                }
                            }
                            .padding(16)
                        }
                    }
                    
                    Divider()
                    
                    HStack {
                        Button("权限设置") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .foregroundColor(hasAccessibilityPermission && hasScreenRecordingPermission ? .green : .red)
                        
                        Spacer()
                        
                        Button("退出") {
                            NSApplication.shared.terminate(nil)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(4)
                    .padding(8)
                }
            }
        }
        .frame(width: 280, height: 400) // 使用固定高度
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            checkPermissions()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            checkPermissions()
        }
        // 添加动画
        .animation(.easeInOut(duration: 0.3), value: topApp.windowList.count)
    }
    
    private func checkPermissions() {
        hasAccessibilityPermission = AXIsProcessTrusted()
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
        
        if hasAccessibilityPermission && hasScreenRecordingPermission {
            topApp.updateRunningApps()
        }
    }
}

struct PermissionRequestView: View {
    let hasAccessibilityPermission: Bool
    let hasScreenRecordingPermission: Bool
    
    var body: some View {
        VStack(spacing: 16) {
            Text("需要权限")
                .font(.headline)
                .padding(.top, 16)
            
            VStack(spacing: 20) {
                // 辅助功能权限
                PermissionItem(
                    title: "辅助功能",
                    description: "用于控制窗口置顶",
                    isGranted: hasAccessibilityPermission,
                    action: {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                )
                
                // 屏幕录制权限
                PermissionItem(
                    title: "录屏与系统录音",
                    description: "用于捕获窗口内容",
                    isGranted: hasScreenRecordingPermission,
                    action: {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                )
            }
            .padding(.horizontal, 16)
            
            Text("请在系统设置中授予权限重启应用")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 16)
        }
    }
}

struct PermissionItem: View {
    let title: String
    let description: String
    let isGranted: Bool
    let action: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(isGranted ? .green : .red)
                
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                
                Spacer()
                
                if !isGranted {
                    Button("授权") {
                        action()
                    }
                    .buttonStyle(PlainButtonStyle())
                    .foregroundColor(.accentColor)
                }
            }
            
            Text(description)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(8)
    }
}


@main
struct TopAppApp: App {
    var body: some Scene {
        MenuBarExtra("窗口置顶", systemImage: "pin.fill") {
            MenuBarView()
        }
        .menuBarExtraStyle(.window)
    }
}

class HoverDetectionView: NSView {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    var windowIdentifier: WindowIdentifier?
    weak var overlayWindow: NSWindow?
    
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        print("鼠标移入覆盖窗口")
        
        if let windowIdentifier = windowIdentifier {
            let connection = CGSMainConnectionID()
            
            // 使用较高的窗口层级，确保窗口在所有空间可见
            let newLevel = Int32(CGWindowLevelForKey(.floatingWindow) + 1) // 使用浮动窗口层级
            
            // 设置窗口层级
            let result = CGSSetWindowLevel(connection, windowIdentifier.windowID, newLevel)
            print("设置目标窗口层级结果: \(result)")
            
            // 尝试使用 AX API 来提升窗口
            if let app = NSRunningApplication(processIdentifier: windowIdentifier.pid) {
                let appRef = AXUIElementCreateApplication(app.processIdentifier)
                
                var windows: CFTypeRef?
                let windowsResult = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windows)
                
                if windowsResult == .success,
                   let windowList = windows as? [AXUIElement],
                   let targetWindow = windowList.first {
                    // 尝试提升窗口
                    AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString)
                    print("使用 AX API 提升窗口")
                }
            }
            
            // 允许鼠标事件穿透覆盖窗口
            overlayWindow?.ignoresMouseEvents = true
            
            // 发送通知让应用程序激活
            if let app = NSRunningApplication(processIdentifier: windowIdentifier.pid) {
                app.activate(options: .activateAllWindows) // 使用 activateAllWindows
            }
        }
        
        onMouseEntered?()
    }
    
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        print("鼠标移出覆盖窗口")
        
        if let windowIdentifier = windowIdentifier {
            let connection = CGSMainConnectionID()
            
            // 修改：恢复到正常层级
            let normalLevel = Int32(CGWindowLevelForKey(.normalWindow))
            let result = CGSSetWindowLevel(connection, windowIdentifier.windowID, normalLevel)
            print("恢复窗口层级结果: \(result)")
            
            // 允许鼠标事件
            overlayWindow?.ignoresMouseEvents = false
        }
        
        onMouseExited?()
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        
        for trackingArea in trackingAreas {
            removeTrackingArea(trackingArea)
        }
        
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways]
        let trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea)
    }
}

// 添加网格项视图
struct WindowGridItem: View {
    let window: WindowInfo
    let isPinned: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                ZStack {
                    if let icon = window.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 48, height: 48) // 稍微增加图标大小
                    }
                    
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.accentColor)
                            .padding(3)
                            .background(Color(NSColor.windowBackgroundColor))
                            .clipShape(Circle())
                            .offset(x: 20, y: -20) // 调整偏移量
                    }
                }
                
                VStack(spacing: 2) {
                    Text(window.app.localizedName ?? "未知应用")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    
                    if !window.windowName.isEmpty {
                        Text(window.windowName)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: 100, height: 100) // 增加整体尺寸
            .contentShape(Rectangle())
            .background(Color(NSColor.controlBackgroundColor).opacity(0.01))
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(isPinned ? 1.03 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isPinned)
    }
}
