import UIKit

@MainActor
final class IVLLyricsSurface: UIView, UITableViewDataSource, UITableViewDelegate {
    weak var owner: IVLyricsSpotifyUI?
    let compact: Bool
    private let standalone: Bool
    let table = UITableView(frame: .zero, style: .plain)
    private let titleLabel = UILabel()
    private let providerLabel = UILabel()
    private let statusLabel = UILabel()
    private let options = UIButton(type: .system)
    private let retry = UIButton(type: .system)
    private let emptyStack = UIStackView()
    private let header = UIStackView()
    private var displayLink: CADisplayLink?
    private var previousActive: Int?
    private var resumeFollowingAt: TimeInterval = 0
    private var documentIdentity: [UUID] = []
    private var lastPaintedPosition: Double?
    private var timed = false
    private(set) var activeIndex: Int?
    var clockRunning: Bool { displayLink != nil }

    init(owner: IVLyricsSpotifyUI, compact: Bool, standalone: Bool) {
        self.owner = owner; self.compact = compact; self.standalone = standalone
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        overrideUserInterfaceStyle = .dark
        accessibilityIdentifier = compact ? "ivlyrics.spotify.card" : "ivlyrics.spotify.fullscreen"
        backgroundColor = compact ? UIColor(red: 0.10, green: 0.20, blue: 0.17, alpha: 1) : UIColor(red: 0.055, green: 0.065, blue: 0.06, alpha: 1)
        layer.cornerRadius = compact ? 16 : 0
        clipsToBounds = true

        titleLabel.font = UIFont.preferredFont(forTextStyle: compact ? .headline : .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.numberOfLines = compact ? 1 : 2
        titleLabel.accessibilityIdentifier = "ivlyrics.title"
        providerLabel.font = UIFont.preferredFont(forTextStyle: .caption1)
        providerLabel.adjustsFontForContentSizeCategory = true
        providerLabel.numberOfLines = 2
        providerLabel.textColor = .white.withAlphaComponent(0.65)
        providerLabel.accessibilityIdentifier = "ivlyrics.provider"
        let labels = UIStackView(arrangedSubviews: [titleLabel, providerLabel])
        labels.axis = .vertical; labels.spacing = 4
        options.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
        options.tintColor = .white
        options.accessibilityLabel = IVLUIText.options
        options.accessibilityIdentifier = "ivlyrics.options"
        options.showsMenuAsPrimaryAction = true
        header.axis = .horizontal; header.alignment = .center; header.spacing = 12
        header.addArrangedSubview(labels)
        if compact {
            let expand = UIButton(type: .system)
            expand.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right"), for: .normal)
            expand.tintColor = .white
            expand.accessibilityLabel = IVLUIText.fullLyrics
            expand.accessibilityIdentifier = "ivlyrics.expand"
            expand.addAction(UIAction { [weak self] _ in
                guard let self, let presenter = self.viewController else { return }
                self.owner?.presentFromViewController(presenter)
            }, for: .touchUpInside)
            expand.widthAnchor.constraint(equalToConstant: 44).isActive = true
            expand.heightAnchor.constraint(equalToConstant: 44).isActive = true
            header.addArrangedSubview(expand)
        }
        options.widthAnchor.constraint(equalToConstant: 44).isActive = true
        options.heightAnchor.constraint(equalToConstant: 44).isActive = true
        header.addArrangedSubview(options)
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.showsVerticalScrollIndicator = !compact
        table.contentInset = UIEdgeInsets(top: 12, left: 0, bottom: compact ? 16 : 100, right: 0)
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = compact ? 70 : 110
        table.dataSource = self; table.delegate = self
        table.register(IVLLyricCell.self, forCellReuseIdentifier: "line")
        table.translatesAutoresizingMaskIntoConstraints = false
        table.accessibilityIdentifier = "ivlyrics.lines"
        addSubview(table)

        statusLabel.numberOfLines = 0
        statusLabel.font = UIFont.preferredFont(forTextStyle: .body)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.accessibilityIdentifier = "ivlyrics.status"
        retry.setTitle(IVLUIText.retry, for: .normal)
        retry.tintColor = .systemGreen
        retry.accessibilityIdentifier = "ivlyrics.retry"
        retry.addAction(UIAction { [weak owner] _ in owner?.reload() }, for: .touchUpInside)
        let importButton = UIButton(type: .system)
        importButton.setTitle(IVLUIText.importFile, for: .normal)
        importButton.tintColor = .systemGreen
        importButton.accessibilityIdentifier = "ivlyrics.import"
        importButton.addAction(UIAction { [weak self] _ in
            guard let self, let presenter = self.viewController else { return }
            self.owner?.chooseFile(from: presenter)
        }, for: .touchUpInside)
        emptyStack.axis = .vertical; emptyStack.spacing = 14
        [statusLabel, retry, importButton].forEach { emptyStack.addArrangedSubview($0) }
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyStack)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            table.leadingAnchor.constraint(equalTo: leadingAnchor),
            table.trailingAnchor.constraint(equalTo: trailingAnchor),
            table.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            table.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: table.centerYAnchor),
            emptyStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            emptyStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { displayLink?.invalidate() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.invalidate(); displayLink = nil
        if window != nil {
            let link = CADisplayLink(target: IVLDisplayLinkProxy(self), selector: #selector(IVLDisplayLinkProxy.tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 24)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    func refresh() {
        guard let owner else { return }
        isHidden = !standalone && !owner.hasTrackAndLyrics
        titleLabel.text = owner.track?.title.isEmpty == false ? owner.track?.title : "ivLyrics"
        let provider = owner.result?.providerLabel ?? "ivLyrics"
        providerLabel.text = owner.result == nil ? owner.track?.artist :
            (owner.status.isEmpty ? "ivLyrics · \(provider)" : owner.status)
        statusLabel.text = owner.status
        emptyStack.isHidden = owner.result?.lines.isEmpty == false
        retry.isHidden = owner.track == nil || owner.loading
        emptyStack.arrangedSubviews.last?.isHidden = owner.track == nil
        options.isEnabled = owner.track != nil
        options.menu = UIMenu(children: [
            UIAction(title: IVLUIText.importFile, image: UIImage(systemName: "doc.badge.plus")) { [weak self] _ in
                guard let self, let presenter = self.viewController else { return }
                self.owner?.chooseFile(from: presenter)
            },
            UIAction(title: IVLUIText.remove, image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                guard let self, let presenter = self.viewController else { return }
                self.owner?.confirmRemoval(from: presenter)
            },
            UIAction(title: IVLUIText.retry, image: UIImage(systemName: "arrow.clockwise")) { [weak owner] _ in owner?.reload() }
        ])
        let identity = owner.result?.lines.map(\.id) ?? []
        if identity != documentIdentity {
            documentIdentity = identity
            timed = owner.result?.lines.contains(where: \.isTimed) == true
            lastPaintedPosition = nil
            previousActive = nil; activeIndex = nil; resumeFollowingAt = 0
            table.reloadData()
            table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top), animated: false)
        }
        updatePlayback()
    }

    func updatePlayback() {
        guard window != nil, !isHidden, let owner, let track = owner.track, let result = owner.result else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let position = track.continuousPositionMs(uptime: now)
        if lastPaintedPosition != position {
            let next = Self.activeLine(in: result.lines, position: position)
            let changed = next != activeIndex || lastPaintedPosition == nil
            activeIndex = next
            for case let cell as IVLLyricCell in table.visibleCells {
                guard let path = table.indexPath(for: cell), result.lines.indices.contains(path.row),
                      changed || path.row == activeIndex else { continue }
                cell.configure(result.lines[path.row], compact: compact, active: path.row == activeIndex,
                               position: position, timed: timed)
            }
            lastPaintedPosition = position
        }
        if let activeIndex, !table.isDragging, !table.isDecelerating, now >= resumeFollowingAt,
           (activeIndex != previousActive || resumeFollowingAt != 0) {
            table.scrollToRow(at: IndexPath(row: activeIndex, section: 0), at: .middle,
                              animated: previousActive != nil && !UIAccessibility.isReduceMotionEnabled)
            resumeFollowingAt = 0
        }
        previousActive = activeIndex
    }

    static func activeLine(in lines: [LyricsLine], position: Double) -> Int? {
        // Keep provider ordering, including simultaneous/background vocals.
        // Plain text has no active clock position and must not jump to the end.
        guard lines.contains(where: \.isTimed) else { return nil }
        return lines.indices.last(where: { lines[$0].isTimed && Double(lines[$0].startTimeMs) <= position })
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { owner?.result?.lines.count ?? 0 }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "line", for: indexPath) as! IVLLyricCell
        if let owner, let result = owner.result, result.lines.indices.contains(indexPath.row) {
            cell.configure(result.lines[indexPath.row], compact: compact, active: indexPath.row == activeIndex,
                           position: owner.track?.continuousPositionMs(uptime: ProcessInfo.processInfo.systemUptime) ?? 0,
                           timed: timed)
        }
        cell.accessibilityIdentifier = "ivlyrics.line.\(indexPath.row)"
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let lines = owner?.result?.lines, lines.indices.contains(indexPath.row) else { return }
        let line = lines[indexPath.row]
        guard line.isTimed else { return }
        owner?.seek(to: line.startTimeMs)
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        resumeFollowingAt = ProcessInfo.processInfo.systemUptime + 5
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        resumeFollowingAt = ProcessInfo.processInfo.systemUptime + 5
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        resumeFollowingAt = ProcessInfo.processInfo.systemUptime + 5
    }

    var viewController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }
}

@MainActor private final class IVLDisplayLinkProxy: NSObject {
    weak var surface: IVLLyricsSurface?
    init(_ surface: IVLLyricsSurface) { self.surface = surface }
    @objc func tick() { surface?.updatePlayback() }
}

@MainActor final class IVLLyricCell: UITableViewCell {
    private let lyric = UILabel()
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        lyric.numberOfLines = 0
        lyric.adjustsFontForContentSizeCategory = true
        lyric.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(lyric)
        NSLayoutConstraint.activate([
            lyric.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            lyric.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            lyric.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            lyric.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
        isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ line: LyricsLine, compact: Bool, active: Bool, position: Double, timed: Bool) {
        let font = UIFontMetrics(forTextStyle: compact ? .title2 : .largeTitle)
            .scaledFont(for: .systemFont(ofSize: compact ? 23 : 31, weight: .bold))
        let base = UIColor.white.withAlphaComponent(active || !timed ? 1 : 0.40)
        let text = line.text.isEmpty ? "♪" : line.text
        let rendered = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: base])
        if active, !line.syllables.isEmpty {
            // Match original text in order instead of rebuilding words: preserve
            // whitespace, bidirectional shaping, punctuation and composed chars.
            let ns = text as NSString
            var cursor = 0
            for syllable in line.syllables where !syllable.text.isEmpty {
                let range = ns.range(of: syllable.text, options: [], range: NSRange(location: cursor, length: ns.length - cursor))
                guard range.location != NSNotFound else { continue }
                cursor = NSMaxRange(range)
                let duration = max(1, Double(syllable.endTimeMs - syllable.startTimeMs))
                let progress = max(0, min(1, (position - Double(syllable.startTimeMs)) / duration))
                let color = UIColor(red: 1 - 0.43 * progress, green: 1, blue: 1 - 0.28 * progress, alpha: 1)
                rendered.addAttribute(.foregroundColor, value: color, range: range)
            }
        }
        lyric.attributedText = rendered
        accessibilityLabel = text
        accessibilityTraits = line.isTimed ? [.button] : [.staticText]
        if active { accessibilityTraits.insert(.selected) }
    }
}

@MainActor final class IVLLyricsScreen: UIViewController {
    let owner: IVLyricsSpotifyUI
    init(owner: IVLyricsSpotifyUI) { self.owner = owner; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "ivLyrics"
        view.backgroundColor = .black
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: IVLUIText.done, style: .done, target: self, action: #selector(close))
        let surface = owner.makeSurface(compact: false, standalone: true)
        view.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor), surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            surface.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), surface.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
    @objc private func close() { dismiss(animated: true) }
}
