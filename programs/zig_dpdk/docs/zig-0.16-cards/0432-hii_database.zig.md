# Migration Card: std.os.uefi.protocol.hii_database

## 1) Concept

This file defines the Zig interface for the UEFI HII Database Protocol, which manages Human Interface Infrastructure (HII) package lists in UEFI firmware. The HII Database is responsible for storing and managing user interface elements like forms, strings, fonts, and images that are used in UEFI setup utilities and drivers.

The key component is the `HiiDatabase` extern struct that wraps the EFI_HII_DATABASE_PROTOCOL, providing methods to manage package lists including removal, updating, listing, and exporting. The struct contains function pointers that map directly to UEFI protocol methods, with Zig error handling wrappers that convert UEFI status codes to Zig error types.

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements**: No allocator dependencies - all operations work with caller-provided buffers. The `listPackageLists` and `exportPackageLists` methods accept slices and return sub-slices of the provided buffers.

**I/O Interface Changes**: Pure UEFI protocol interface - no traditional I/O. Uses UEFI calling convention (`callconv(cc)`) and handles UEFI-specific types like `hii.Handle`, `Guid`, and `hii.PackageList`.

**Error Handling Changes**: Each public method has a dedicated error set that combines UEFI-specific errors with `uefi.UnexpectedError`:
- `RemovePackageListError`: `UnexpectedError || error{NotFound}`
- `UpdatePackageListError`: `UnexpectedError || error{OutOfResources, InvalidParameter, NotFound}`
- `ListPackageListsError`: `UnexpectedError || error{BufferTooSmall, InvalidParameter, NotFound}`
- `ExportPackageListError`: `UnexpectedError || error{BufferTooSmall, InvalidParameter, NotFound}`

**API Structure**: No init/factory patterns - this is an extern struct obtained through UEFI protocol location services. Methods follow UEFI naming conventions with Zig error handling wrappers.

## 3) The Golden Snippet

```zig
const hii_db = // Obtained via UEFI protocol location services
const hii = std.os.uefi.hii;

// List package lists with a buffer
var handles: [10]hii.Handle = undefined;
const active_handles = try hii_db.listPackageLists(0, null, &handles);

// Remove a package list
try hii_db.removePackageList(some_handle);

// Update a package list
try hii_db.updatePackageList(some_handle, &package_list_buffer);

// Export package lists
var packages: [5]hii.PackageList = undefined;
const exported = try hii_db.exportPackageLists(null, &packages);
```

## 4) Dependencies

- `std.os.uefi` (core UEFI types and constants)
- `std.os.uefi.Guid` (GUID handling)
- `std.os.uefi.Status` (UEFI status codes)
- `std.os.uefi.hii` (HII-specific types and handles)
- `std.os.uefi.cc` (UEFI calling convention)