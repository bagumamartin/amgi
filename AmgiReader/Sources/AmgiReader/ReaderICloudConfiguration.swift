public import Foundation

/// The app-owned iCloud Drive container shared by everything reader-side.
///
/// One container for EPUB books, PDF books and reading progress, so book
/// data has a single sync home — and so none of it ever needs the Anki
/// collection. The container must be registered for the app's Apple Developer
/// team before the capability can be signed; the existing CloudDocuments
/// entitlement already covers it, so no new entitlements are required.
public enum ReaderICloudConfiguration {
    public static let defaultContainerIdentifier = "iCloud.com.bagumamartin.ijuka"
}
