# Changelog

## [1.5.8] - 2025-10-25

### Added
- Comprehensive logging for POST /data requests (full request details, body size, LTS values)
- Complete HTTP response logging (status, headers, body) for debugging server rejections
- Request duration tracking for performance monitoring
- Response body parsing even on success to capture server-side rejection information

### Changed
- Enhanced debug output to help diagnose lts_mismatch sync failures
- Added correlation timestamps across all sync operations

## [1.4.2] - 2025-01-06

### Added
- Include `app_id` query parameter in all server requests (/data, /events)
- Enables proper multi-tenant isolation on the server side

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