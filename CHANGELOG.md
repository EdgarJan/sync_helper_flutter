# Changelog

## [1.4.1] - 2025-01-30

### Added
- `isSyncing` getter to expose full sync status
- Notifies listeners when sync starts and completes

## [1.4.0] - 2025-01-30

### Added
- Automatic client-side pagination for POST requests when sending unsynced data
- More efficient handling of large datasets by processing in batches of 100 rows

### Changed
- `_sendUnsynced` method now processes data in batches using LIMIT/OFFSET
- Updates are now performed on specific IDs rather than all unsynced rows at once
- Improved logging to show batch progress

### Fixed
- Potential issues with sending very large amounts of unsynced data that could exceed server body size limits