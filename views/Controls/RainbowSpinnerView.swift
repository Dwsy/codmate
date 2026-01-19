import SwiftUI
import AppKit

/// CoreAnimation-based rainbow spinner (replaces SwiftUI repeatForever + drawingGroup)
/// Uses CAGradientLayer with conic gradient and CABasicAnimation for rotation
/// Pauses when window is not key or app is not active to reduce GPU usage
struct RainbowSpinnerView: NSViewRepresentable {
    var spins: Bool = true
    var size: CGFloat = 18
    
    func makeNSView(context: Context) -> NSView {
        let containerView = ContainerView(size: size)
        context.coordinator.containerView = containerView
        return containerView
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let containerView = nsView as? ContainerView else { return }
        containerView.setSpinning(spins)
        
        // Update size if changed
        if containerView.frame.size.width != size || containerView.frame.size.height != size {
            containerView.frame = NSRect(x: 0, y: 0, width: size, height: size)
            containerView.needsLayout = true
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator {
        var containerView: ContainerView?
    }
    
    /// Container view that manages the CoreAnimation spinner
    class ContainerView: NSView {
        private var gradientLayer: CAGradientLayer?
        private var rotationAnimation: CABasicAnimation?
        private var isSpinning: Bool = false
        private let size: CGFloat
        
        init(size: CGFloat) {
            self.size = size
            super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
            // Delay gradient setup until layout() when bounds are properly set
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.clear.cgColor
            observeAppState()
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observeWindowState()
            updateAnimationState()
        }
        
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            updateAnimationState()
        }
        
        override func layout() {
            super.layout()
            
            // Setup gradient layer on first layout when bounds are properly set
            if gradientLayer == nil && bounds.width > 0 && bounds.height > 0 {
                setupLayers()
            }
            
            // Update gradient frame if it exists
            if let gradientLayer = gradientLayer {
                gradientLayer.frame = bounds
                // Update center cap and separators when bounds change
                updateGradientSublayers()
            }
        }
        
        private func updateGradientSublayers() {
            guard let gradientLayer = gradientLayer else { return }
            
            // Update center cap frame
            if let centerCap = gradientLayer.sublayers?.first(where: { $0.name == "centerCap" }) {
                centerCap.frame = bounds.insetBy(dx: bounds.width * 0.35, dy: bounds.height * 0.35)
                centerCap.cornerRadius = centerCap.frame.width / 2
            }
            
            // Update separator positions
            if let separators = gradientLayer.sublayers?.filter({ $0.name?.hasPrefix("separator") == true }) {
                for (index, separator) in separators.enumerated() {
                    let separatorWidth: CGFloat = 1.2
                    let separatorHeight: CGFloat = bounds.height * 0.15
                    separator.frame = CGRect(
                        x: (bounds.width - separatorWidth) / 2,
                        y: 0,
                        width: separatorWidth,
                        height: separatorHeight
                    )
                    separator.position = CGPoint(x: bounds.midX, y: bounds.midY)
                    separator.transform = CATransform3DMakeRotation(CGFloat(index) * .pi / 3, 0, 0, 1)
                }
            }
        }
        
        func setSpinning(_ spinning: Bool) {
            guard isSpinning != spinning else { return }
            isSpinning = spinning
            updateAnimationState()
        }
        
        private func setupLayers() {
            guard bounds.width > 0 && bounds.height > 0 else { return }
            guard gradientLayer == nil else { return } // Already setup
            
            // Create conic gradient layer (rainbow colors)
            let gradient = CAGradientLayer()
            gradient.type = .conic
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 0.5, y: 0.0)
            
            // Rainbow colors: red, orange, yellow, green, blue, purple, red
            gradient.colors = [
                NSColor.red.cgColor,
                NSColor.orange.cgColor,
                NSColor.yellow.cgColor,
                NSColor.green.cgColor,
                NSColor.blue.cgColor,
                NSColor.purple.cgColor,
                NSColor.red.cgColor
            ]
            gradient.locations = [0.0, 0.166, 0.333, 0.5, 0.666, 0.833, 1.0]
            gradient.frame = bounds
            gradient.cornerRadius = bounds.width / 2
            
            // White center cap
            let centerCap = CALayer()
            centerCap.name = "centerCap"
            centerCap.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
            centerCap.frame = bounds.insetBy(dx: bounds.width * 0.35, dy: bounds.height * 0.35)
            centerCap.cornerRadius = centerCap.frame.width / 2
            
            // Thin white separators
            for i in 0..<6 {
                let separator = CALayer()
                separator.name = "separator\(i)"
                separator.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
                let separatorWidth: CGFloat = 1.2
                let separatorHeight: CGFloat = bounds.height * 0.15
                separator.frame = CGRect(
                    x: (bounds.width - separatorWidth) / 2,
                    y: 0,
                    width: separatorWidth,
                    height: separatorHeight
                )
                separator.anchorPoint = CGPoint(x: 0.5, y: 1.0)
                separator.position = CGPoint(x: bounds.midX, y: bounds.midY)
                separator.transform = CATransform3DMakeRotation(CGFloat(i) * .pi / 3, 0, 0, 1)
                gradient.addSublayer(separator)
            }
            
            gradient.addSublayer(centerCap)
            layer?.addSublayer(gradient)
            gradientLayer = gradient
        }
        
        private var windowKeyObserver: NSObjectProtocol?
        private var windowResignObserver: NSObjectProtocol?
        
        private func observeAppState() {
            // App activation state
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(applicationDidBecomeActive),
                name: NSApplication.didBecomeActiveNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(applicationDidResignActive),
                name: NSApplication.didResignActiveNotification,
                object: nil
            )
        }
        
        @objc private func applicationDidBecomeActive() {
            updateAnimationState()
        }
        
        @objc private func applicationDidResignActive() {
            updateAnimationState()
        }
        
        private func observeWindowState() {
            guard let window = window else {
                // Clean up observers if window is nil
                windowKeyObserver = nil
                windowResignObserver = nil
                return
            }
            
            // Window key state changes
            windowKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.updateAnimationState()
            }
            
            windowResignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.updateAnimationState()
            }
        }
        
        private func updateAnimationState() {
            guard let gradientLayer = gradientLayer else { return }
            
            let shouldAnimate = isSpinning && isViewVisible()
            
            if shouldAnimate {
                if rotationAnimation == nil {
                    let animation = CABasicAnimation(keyPath: "transform.rotation")
                    animation.fromValue = 0
                    animation.toValue = Double.pi * 2
                    animation.duration = 1.0
                    animation.repeatCount = .greatestFiniteMagnitude
                    animation.isRemovedOnCompletion = false
                    gradientLayer.add(animation, forKey: "rotation")
                    rotationAnimation = animation
                }
            } else {
                if rotationAnimation != nil {
                    gradientLayer.removeAnimation(forKey: "rotation")
                    rotationAnimation = nil
                }
            }
        }
        
        /// Check if view is visible and should animate
        /// Returns true only when:
        /// - View is in window hierarchy
        /// - Window is visible
        /// - App is active
        private func isViewVisible() -> Bool {
            guard let window = window else { return false }
            guard window.isVisible else { return false }
            guard NSApp.isActive else { return false }
            // Check if view is in the window's view hierarchy
            // isDescendant(of:) checks if self is a descendant of the parameter
            // So we check if we are a descendant of the window's content view
            if let contentView = window.contentView {
                return self.isDescendant(of: contentView)
            }
            // Fallback: check if we have a superview (less precise but works)
            return superview != nil
        }
        
        deinit {
            NotificationCenter.default.removeObserver(self)
            if let keyObserver = windowKeyObserver {
                NotificationCenter.default.removeObserver(keyObserver)
            }
            if let resignObserver = windowResignObserver {
                NotificationCenter.default.removeObserver(resignObserver)
            }
        }
    }
}
