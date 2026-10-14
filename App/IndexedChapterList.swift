#if !os(macOS)
import SwiftUI
import UIKit

/// Native list cells and native index tracking. Index entries target rows, so long
/// chapter groups need no artificial sections or custom overlay/drag recognizer.
struct IndexedChapterList: UIViewControllerRepresentable {
    struct Section {
        let id: String
        let indexTitle: String
        let header: AnyView?
        let rows: [String]
    }
    let sections: [Section]
    let row: (String) -> AnyView
    let highlighted: (String) -> Bool
    let reveal: ChapterListReveal?

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.update(self) }

    final class Controller: UICollectionViewController {
        private var content: IndexedChapterList?
        private var source: IndexedSource!
        private var lastReveal: UUID?
        private var pendingRow: String?

        init() {
            super.init(collectionViewLayout: UICollectionViewCompositionalLayout { section, environment in
                var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
                configuration.headerMode = section == 0 ? .none : .firstItemInSection
                return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
            })
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidLoad() {
            super.viewDidLoad()
            collectionView.indexDisplayMode = .automatic
            collectionView.allowsSelection = false
            collectionView.accessibilityIdentifier = "manga.chapters"
            let cells = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
                guard let self, let content else { return }
                if let group = content.sections.first(where: { Self.headerID($0.id) == id }) {
                    cell.contentConfiguration = UIHostingConfiguration { group.header.font(.subheadline) }
                    cell.backgroundConfiguration = .clear()
                } else {
                    cell.contentConfiguration = UIHostingConfiguration { content.row(id).id(id) }
                    var background = UIBackgroundConfiguration.listGroupedCell()
                    if content.highlighted(id) { background.backgroundColor = .tintColor.withAlphaComponent(0.15) }
                    cell.backgroundConfiguration = background
                }
            }
            source = IndexedSource(collectionView: collectionView) { collection, path, id in
                collection.dequeueConfiguredReusableCell(using: cells, for: path, item: id)
            }
        }
        private static func headerID(_ section: String) -> String { "header|" + section }
        func update(_ content: IndexedChapterList) {
            loadViewIfNeeded()
            self.content = content
            source.entries = content.sections.enumerated().flatMap { section, group in
                var entries = [(group.indexTitle, IndexPath(item: 0, section: section))]
                // At most eight interior stops per group; ordinary groups use a dot
                // every 25 rows. These are index entries, never visible list sections.
                let stride = max(25, Int(ceil(Double(group.rows.count) / 9)))
                for item in Swift.stride(from: stride, to: group.rows.count, by: stride) {
                    entries.append(("•", IndexPath(item: item + (group.header == nil ? 0 : 1), section: section)))
                }
                return entries
            }
            let previous = Set(source.snapshot().itemIdentifiers)
            var snapshot = NSDiffableDataSourceSnapshot<String, String>()
            for section in content.sections {
                snapshot.appendSections([section.id])
                snapshot.appendItems((section.header == nil ? [] : [Self.headerID(section.id)]) + section.rows, toSection: section.id)
            }
            snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { previous.contains($0) })
            if let reveal = content.reveal, reveal.id != lastReveal {
                lastReveal = reveal.id; pendingRow = reveal.row
            }
            source.apply(snapshot, animatingDifferences: false) { [weak self] in
                guard let self else { return }
                view.setNeedsLayout()
            }
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            if let pendingRow, let path = source.indexPath(for: pendingRow), collectionView.bounds.height > 0 {
                self.pendingRow = nil
                collectionView.scrollToItem(at: path, at: .centeredVertically, animated: false)
            }
        }
    }
    final class IndexedSource: UICollectionViewDiffableDataSource<String, String> {
        var entries: [(title: String, path: IndexPath)] = []
        override func indexTitles(for collectionView: UICollectionView) -> [String]? { entries.map(\.title) }
        override func collectionView(_ collectionView: UICollectionView, indexPathForIndexTitle title: String, at index: Int) -> IndexPath {
            entries[index].path
        }
    }
}
#endif

import Foundation

struct ChapterListReveal {
    let id = UUID()
    let row: String
}
