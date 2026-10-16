#if os(iOS)
import UIKit

/// One page as the page turner sees it: a card that shows a picture of the
/// page, and — once it is the page being read and the chapter has loaded —
/// the live chapter laid under that picture.
///
/// Turning works on these cards, never on the live web view. A card can be
/// made instantly (a picture from the renderer, or a blank page until it
/// arrives), so a turn never waits for a chapter to load. That waiting is
/// what made fast turning land on the wrong page: each page used to be its
/// own web view that had to load the whole chapter first.
@MainActor
final class EPUBPageSlotController: UIViewController {
    var address: EPUBPageAddress
    private let pictureView = UIImageView()
    private let titleLabel = UILabel()
    private let folioLabel = UILabel()
    /// Centre lines of the title and folio rows, from the top and bottom.
    var furnitureLines: (head: CGFloat, foot: CGFloat) = (40, 32) {
        didSet { view.setNeedsLayout() }
    }
    private(set) weak var surface: EPUBChapterPageController?
    private let pageColor: UIColor

    init(address: EPUBPageAddress, pageColor: UIColor) {
        self.address = address
        self.pageColor = pageColor
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        let view = UIView()
        view.backgroundColor = pageColor
        pictureView.frame = view.bounds
        pictureView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pictureView.contentMode = .scaleToFill
        pictureView.isUserInteractionEnabled = false
        view.addSubview(pictureView)
        // The running head and page number belong to the page: they sit on
        // the card, so they curl with it, forwards and back, the way a
        // printed page carries its own.
        for label in [titleLabel, folioLabel] {
            label.textAlignment = .center
            label.isUserInteractionEnabled = false
            label.isAccessibilityElement = false
            label.adjustsFontForContentSizeCategory = false
            view.addSubview(label)
        }
        titleLabel.font = .systemFont(ofSize: 14, weight: .regular)
        titleLabel.lineBreakMode = .byTruncatingTail
        folioLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        self.view = view
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        let height: CGFloat = 20
        titleLabel.frame = CGRect(x: 64, y: furnitureLines.head - height / 2, width: max(0, bounds.width - 128), height: height)
        folioLabel.frame = CGRect(x: 64, y: bounds.height - furnitureLines.foot - height / 2, width: max(0, bounds.width - 128), height: height)
        // Above the live page too, which sits under the picture.
        view.bringSubviewToFront(titleLabel)
        view.bringSubviewToFront(folioLabel)
    }

    /// The page's own running head and number.
    func setFurniture(title: String, page: Int, color: UIColor) {
        loadViewIfNeeded()
        titleLabel.text = title
        folioLabel.text = page > 0 ? "\(page)" : nil
        titleLabel.textColor = color
        folioLabel.textColor = color
    }

    /// Hidden while the reader's bar is up: it shows the title row and
    /// "X of Y" on these same lines.
    var furnitureHidden: Bool = false {
        didSet {
            guard oldValue != furnitureHidden else { return }
            loadViewIfNeeded()
            UIView.animate(withDuration: 0.18) {
                self.titleLabel.alpha = self.furnitureHidden ? 0 : 1
                self.folioLabel.alpha = self.furnitureHidden ? 0 : 1
            }
        }
    }

    var picture: UIImage? {
        get { pictureView.image }
        set {
            loadViewIfNeeded()
            pictureView.image = newValue
        }
    }

    var hasPicture: Bool { pictureView.image != nil }

    /// Whether the picture covers the live page. It does during a turn and
    /// while the live page is still getting to this page; at rest the live
    /// page shows, so selection, links and marks work.
    var showsPicture: Bool {
        get { !pictureView.isHidden }
        set {
            loadViewIfNeeded()
            pictureView.isHidden = !newValue
        }
    }

    /// Lays the live chapter under the picture.
    func attach(_ surface: EPUBChapterPageController) {
        loadViewIfNeeded()
        guard self.surface !== surface else { return }
        detachSurface()
        surface.willMove(toParent: nil)
        surface.view.removeFromSuperview()
        surface.removeFromParent()
        addChild(surface)
        surface.view.frame = view.bounds
        surface.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(surface.view, belowSubview: pictureView)
        view.bringSubviewToFront(titleLabel)
        view.bringSubviewToFront(folioLabel)
        surface.didMove(toParent: self)
        self.surface = surface
    }

    func detachSurface() {
        guard let surface else { return }
        surface.willMove(toParent: nil)
        surface.view.removeFromSuperview()
        surface.removeFromParent()
        self.surface = nil
    }
}
#endif
