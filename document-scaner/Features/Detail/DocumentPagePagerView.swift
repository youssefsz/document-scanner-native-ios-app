//
//  DocumentPagePagerView.swift
//  document-scaner
//
//

import AVFoundation
import SwiftUI
import UIKit

struct DocumentPagePagerView: UIViewRepresentable {
    let pageCount: Int
    let snapshots: [Int: DocumentPageSnapshot]
    @Binding var currentPageID: Int?
    let onSingleTap: () -> Void
    let onZoomStateChange: (Int, Bool) -> Void

    func makeUIView(context: Context) -> DocumentPagePagingView {
        DocumentPagePagingView()
    }

    func updateUIView(_ uiView: DocumentPagePagingView, context: Context) {
        let currentPageBinding = $currentPageID

        uiView.configure(
            pageCount: pageCount,
            snapshots: snapshots,
            currentPageID: currentPageBinding.wrappedValue,
            onPageChange: { pageID in
                currentPageBinding.wrappedValue = pageID
            },
            onSingleTap: onSingleTap,
            onZoomStateChange: onZoomStateChange
        )
    }
}

final class DocumentPagePagingView: UIView, UIScrollViewDelegate {
    private let scrollView = UIScrollView()
    private var pageViews: [Int: DocumentPageHostView] = [:]
    private var snapshots: [Int: DocumentPageSnapshot] = [:]
    private var pageCount = 0
    private var currentPageID: Int?
    private var zoomedPageID: Int?
    private var lastLayoutSize: CGSize = .zero

    private var onPageChange: (Int) -> Void = { _ in }
    private var onSingleTap: () -> Void = {}
    private var onZoomStateChange: (Int, Bool) -> Void = { _, _ in }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != .zero, bounds.size != lastLayoutSize else { return }
        lastLayoutSize = bounds.size
        updateContentSize()
        setCurrentPage(id: currentPageID ?? (pageCount > 0 ? 0 : nil), animated: false)
        syncVisiblePageViews()
    }

    func configure(
        pageCount: Int,
        snapshots: [Int: DocumentPageSnapshot],
        currentPageID: Int?,
        onPageChange: @escaping (Int) -> Void,
        onSingleTap: @escaping () -> Void,
        onZoomStateChange: @escaping (Int, Bool) -> Void
    ) {
        self.onPageChange = onPageChange
        self.onSingleTap = onSingleTap
        self.onZoomStateChange = onZoomStateChange
        self.snapshots = snapshots
        if self.pageCount != pageCount {
            self.pageCount = pageCount
            updateContentSize()
        }
        let requestedPageID = currentPageID.flatMap { (0..<pageCount).contains($0) ? $0 : nil }
            ?? (pageCount > 0 ? 0 : nil)

        // A drag updates the SwiftUI binding, which immediately calls configure again.
        // Only reposition for a genuinely external page change; snapping here during
        // an active gesture interrupts UIScrollView's paging animation.
        if requestedPageID != self.currentPageID {
            setCurrentPage(id: requestedPageID, animated: false)
        }
        syncVisiblePageViews()
        scrollView.isScrollEnabled = pageCount > 1 && zoomedPageID == nil
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        syncVisiblePageViews()
        guard let pageID = nearestPageID() else { return }
        guard currentPageID != pageID else { return }

        currentPageID = pageID
        onPageChange(pageID)
    }

    private func configureHierarchy() {
        backgroundColor = .black

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.delegate = self
        scrollView.isPagingEnabled = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceVertical = true
        scrollView.backgroundColor = .black
        scrollView.contentInsetAdjustmentBehavior = .never

        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func updateContentSize() {
        guard scrollView.bounds.height > 0 else { return }
        scrollView.contentSize = CGSize(
            width: scrollView.bounds.width,
            height: scrollView.bounds.height * CGFloat(pageCount)
        )
    }

    private func syncVisiblePageViews() {
        guard pageCount > 0, scrollView.bounds.height > 0 else {
            pageViews.values.forEach { $0.removeFromSuperview() }
            pageViews = [:]
            return
        }
        let center = nearestPageID() ?? 0
        let visibleIndices = Set(max(0, center - 2)...min(pageCount - 1, center + 2))
        for index in Array(pageViews.keys) where !visibleIndices.contains(index) {
            pageViews.removeValue(forKey: index)?.removeFromSuperview()
        }
        for index in visibleIndices.sorted() {
            let pageView: DocumentPageHostView
            if let existing = pageViews[index] {
                pageView = existing
            } else {
                pageView = DocumentPageHostView()
                pageViews[index] = pageView
                scrollView.addSubview(pageView)
            }
            pageView.frame = CGRect(
                x: 0,
                y: CGFloat(index) * scrollView.bounds.height,
                width: scrollView.bounds.width,
                height: scrollView.bounds.height
            )
            pageView.configure(
                page: snapshots[index],
                onSingleTap: onSingleTap,
                onZoomStateChange: { [weak self] isZoomed in
                    self?.handleZoomStateChange(for: index, isZoomed: isZoomed)
                }
            )
        }
    }

    private func handleZoomStateChange(for pageID: Int, isZoomed: Bool) {
        if isZoomed {
            zoomedPageID = pageID
        } else if zoomedPageID == pageID {
            zoomedPageID = nil
        }

        scrollView.isScrollEnabled = pageCount > 1 && zoomedPageID == nil
        onZoomStateChange(pageID, isZoomed)
    }

    private func setCurrentPage(id: Int?, animated: Bool) {
        guard let id, (0..<pageCount).contains(id), scrollView.bounds.height > 0 else { return }

        currentPageID = id
        let targetOffset = CGPoint(x: 0, y: scrollView.bounds.height * CGFloat(id))

        guard scrollView.contentOffset != targetOffset else { return }
        scrollView.setContentOffset(targetOffset, animated: animated)
    }

    private func nearestPageID() -> Int? {
        guard pageCount > 0, scrollView.bounds.height > 0 else { return nil }

        let rawIndex = Int(round(scrollView.contentOffset.y / scrollView.bounds.height))
        return min(max(rawIndex, 0), pageCount - 1)
    }
}

private final class DocumentPageHostView: UIView {
    private let gradientLayer = CAGradientLayer()
    private let pageView = ZoomablePageContainerView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
    }

    func configure(
        page: DocumentPageSnapshot?,
        onSingleTap: @escaping () -> Void,
        onZoomStateChange: @escaping (Bool) -> Void
    ) {
        pageView.configure(
            image: page?.image,
            isPreview: page?.isPreview ?? false,
            pageInsets: UIEdgeInsets(top: 28, left: 20, bottom: 28, right: 20),
            onSingleTap: onSingleTap,
            onZoomStateChange: onZoomStateChange
        )
    }

    private func configureHierarchy() {
        backgroundColor = .black

        gradientLayer.colors = [
            UIColor.black.cgColor,
            UIColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1).cgColor,
            UIColor.black.cgColor,
        ]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(gradientLayer)

        pageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pageView)

        NSLayoutConstraint.activate([
            pageView.topAnchor.constraint(equalTo: topAnchor),
            pageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

private final class ZoomablePageContainerView: UIView, UIScrollViewDelegate {
    private let scrollView = UIScrollView()
    private let pageCanvasView = UIView()
    private let imageView = UIImageView()
    private let pageBackgroundView = UIView()
    private var currentImageIdentifier: ObjectIdentifier?
    private var currentImageIsPreview = false
    private var isZoomed = false
    private var needsInitialPositioning = false
    private var pageInsets: UIEdgeInsets = .zero
    private let shadowPadding: CGFloat = 28

    private var onSingleTap: (() -> Void)?
    private var onZoomStateChange: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        image: UIImage?,
        isPreview: Bool,
        pageInsets: UIEdgeInsets,
        onSingleTap: @escaping () -> Void,
        onZoomStateChange: @escaping (Bool) -> Void
    ) {
        self.onSingleTap = onSingleTap
        self.onZoomStateChange = onZoomStateChange

        let identifier = image.map(ObjectIdentifier.init)
        var needsLayoutUpdate = false

        if self.pageInsets != pageInsets {
            self.pageInsets = pageInsets
            needsLayoutUpdate = true
        }

        if currentImageIdentifier != identifier {
            let isReplacingPreview = currentImageIsPreview && !isPreview && imageView.image != nil
            currentImageIdentifier = identifier
            currentImageIsPreview = isPreview
            if isReplacingPreview, let image {
                UIView.transition(with: imageView, duration: 0.2, options: .transitionCrossDissolve) {
                    self.imageView.image = image
                }
            } else {
                imageView.image = image
                isZoomed = false
                scrollView.panGestureRecognizer.isEnabled = false
                needsInitialPositioning = image != nil
                pageCanvasView.isHidden = true
            }
            needsLayoutUpdate = true
        }

        if needsLayoutUpdate {
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        updateLayoutForCurrentBounds()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        pageCanvasView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateContentInsets()
        let hasZoom = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
        setZoomState(hasZoom)

        if !hasZoom {
            scheduleRecenterAtMinimumZoom()
        }
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        if scale <= scrollView.minimumZoomScale + 0.01 {
            scheduleRecenterAtMinimumZoom()
        }
    }

    private func configureHierarchy() {
        backgroundColor = .clear

        scrollView.delegate = self
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.bounces = false
        scrollView.decelerationRate = .fast
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.panGestureRecognizer.isEnabled = false
        addSubview(scrollView)

        pageCanvasView.backgroundColor = .clear
        pageCanvasView.isHidden = true
        scrollView.addSubview(pageCanvasView)

        pageBackgroundView.backgroundColor = .white
        pageBackgroundView.layer.cornerRadius = 28
        pageBackgroundView.layer.cornerCurve = .continuous
        pageBackgroundView.layer.shadowColor = UIColor.black.cgColor
        pageBackgroundView.layer.shadowOpacity = 0.32
        pageBackgroundView.layer.shadowRadius = 24
        pageBackgroundView.layer.shadowOffset = CGSize(width: 0, height: 14)
        pageBackgroundView.clipsToBounds = false

        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        pageBackgroundView.addSubview(imageView)
        pageCanvasView.addSubview(pageBackgroundView)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        tapGesture.numberOfTapsRequired = 1
        scrollView.addGestureRecognizer(tapGesture)
    }

    private func updateLayoutForCurrentBounds() {
        guard bounds.width > 0, bounds.height > 0, let image = imageView.image else { return }

        let safeBounds = bounds.inset(by: pageInsets)
        let pageRect = AVMakeRect(
            aspectRatio: image.size,
            insideRect: safeBounds.insetBy(dx: shadowPadding, dy: shadowPadding)
        )
        let pageSize = CGSize(
            width: max(pageRect.width.rounded(.down), 1),
            height: max(pageRect.height.rounded(.down), 1)
        )
        let canvasSize = CGSize(
            width: pageSize.width + (shadowPadding * 2),
            height: pageSize.height + (shadowPadding * 2)
        )

        pageCanvasView.frame = CGRect(origin: .zero, size: canvasSize)
        pageBackgroundView.frame = CGRect(
            x: shadowPadding,
            y: shadowPadding,
            width: pageSize.width,
            height: pageSize.height
        )
        pageBackgroundView.layer.shadowPath = UIBezierPath(
            roundedRect: pageBackgroundView.bounds,
            cornerRadius: pageBackgroundView.layer.cornerRadius
        ).cgPath
        imageView.frame = pageBackgroundView.bounds
        scrollView.contentSize = canvasSize
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4

        if scrollView.zoomScale < scrollView.minimumZoomScale || !scrollView.zoomScale.isFinite {
            scrollView.zoomScale = scrollView.minimumZoomScale
        }

        if !isZoomed {
            resetZoom(animated: false, notify: false, recenterImmediately: true)
        } else {
            updateContentInsets()
        }

        if needsInitialPositioning {
            needsInitialPositioning = false
            pageCanvasView.isHidden = false
        }
    }

    private func updateContentInsets() {
        let contentSize = scrollView.contentSize
        let inset = UIEdgeInsets(
            top: max((scrollView.bounds.height - contentSize.height) * 0.5, 0),
            left: max((scrollView.bounds.width - contentSize.width) * 0.5, 0),
            bottom: max((scrollView.bounds.height - contentSize.height) * 0.5, 0),
            right: max((scrollView.bounds.width - contentSize.width) * 0.5, 0)
        )

        if scrollView.contentInset != inset {
            scrollView.contentInset = inset
        }
    }

    private func resetZoom(
        animated: Bool,
        notify: Bool = true,
        recenterImmediately: Bool = false
    ) {
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: animated)
        if recenterImmediately {
            recenterAtMinimumZoom()
        } else {
            scheduleRecenterAtMinimumZoom()
        }
        scrollView.panGestureRecognizer.isEnabled = false
        if notify {
            setZoomState(false)
        } else {
            isZoomed = false
        }
    }

    private func scheduleRecenterAtMinimumZoom() {
        guard scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 else { return }

        DispatchQueue.main.async { [weak self] in
            self?.recenterAtMinimumZoom()
        }
    }

    private func recenterAtMinimumZoom() {
        guard scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 else { return }

        updateContentInsets()
        let centeredOffset = CGPoint(
            x: -scrollView.contentInset.left,
            y: -scrollView.contentInset.top
        )

        if abs(scrollView.contentOffset.x - centeredOffset.x) > 0.5 || abs(scrollView.contentOffset.y - centeredOffset.y) > 0.5 {
            scrollView.setContentOffset(centeredOffset, animated: false)
        }
    }

    private func setZoomState(_ newValue: Bool) {
        guard isZoomed != newValue else { return }
        isZoomed = newValue
        scrollView.panGestureRecognizer.isEnabled = newValue
        onZoomStateChange?(newValue)
    }

    @objc
    private func handleSingleTap() {
        onSingleTap?()
    }
}
