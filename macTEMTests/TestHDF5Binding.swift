//
//  TestHDF5Binding.swift
//  Role: a small libhdf5 binding for TESTS and the sidecar harness only, to plant the files the session sidecar's writer never
//        writes (a foreign HDF5 file, a variable-length string, an array, a space-padded one) and to read back how a file stores
//        an attribute. The app has no HDF5 binding of its own: SessionSidecarFile reads and writes through FormatoHDF5's
//        `HDF5RootAttributes`. This one loads the library by the same candidate list as FormatoKit's loader (FORMATO_HDF5_PATH,
//        the host's Frameworks, FormatoKit's bundled framework, the bare name), so dlopen hands back the one image in the
//        process, and every call runs under FormatoKit's `HDF5Serial` lock. Not part of TEMCore: nothing in the app links it.
//

import Darwin
import Foundation
import FormatoHDF5

nonisolated let h5DefaultProperty: hid_t = 0
nonisolated let h5FileTruncate: UInt32 = 0x0002
nonisolated let h5FileReadOnly: UInt32 = 0x0000
nonisolated let h5ScalarDataspace: Int32 = 0
nonisolated let h5StringClass: Int32 = 3
nonisolated let h5UTF8CharacterSet: Int32 = 1

nonisolated struct TestHDF5Error: Error, CustomStringConvertible {
    let description: String
}

nonisolated struct TestHDF5Library: @unchecked Sendable {
    typealias Create = @convention(c) (UnsafePointer<CChar>?, UInt32, hid_t, hid_t) -> hid_t
    typealias Open = @convention(c) (UnsafePointer<CChar>?, UInt32, hid_t) -> hid_t
    typealias Close = @convention(c) (hid_t) -> herr_t
    typealias GOpen = @convention(c) (hid_t, UnsafePointer<CChar>?, hid_t) -> hid_t
    typealias ScreateSimple = @convention(c) (Int32, UnsafePointer<hsize_t>?, UnsafePointer<hsize_t>?) -> hid_t
    typealias Screate = @convention(c) (Int32) -> hid_t
    typealias Tcopy = @convention(c) (hid_t) -> hid_t
    typealias TsetSize = @convention(c) (hid_t, UInt) -> herr_t
    typealias TsetCset = @convention(c) (hid_t, Int32) -> herr_t
    typealias Acreate2 = @convention(c) (hid_t, UnsafePointer<CChar>?, hid_t, hid_t, hid_t, hid_t) -> hid_t
    typealias Aexists = @convention(c) (hid_t, UnsafePointer<CChar>?) -> Int32
    typealias Aopen = @convention(c) (hid_t, UnsafePointer<CChar>?, hid_t) -> hid_t
    typealias GetHandle = @convention(c) (hid_t) -> hid_t
    typealias Awrite = @convention(c) (hid_t, hid_t, UnsafeRawPointer?) -> herr_t
    typealias Aread = @convention(c) (hid_t, hid_t, UnsafeMutableRawPointer?) -> herr_t
    typealias GetInt = @convention(c) (hid_t) -> Int32
    typealias GetSize = @convention(c) (hid_t) -> Int
    typealias GetPoints = @convention(c) (hid_t) -> Int64

    let handle: UnsafeMutableRawPointer
    let h5fcreate: Create, h5fopen: Open, h5fclose: Close, h5gopen2: GOpen, h5gclose: Close
    let h5screate: Screate, h5screateSimple: ScreateSimple, h5sclose: Close
    let h5tcopy: Tcopy, h5tsetSize: TsetSize, h5tsetCset: TsetCset, h5tclose: Close
    let h5acreate2: Acreate2, h5aexists: Aexists, h5aopen: Aopen, h5aclose: Close
    let h5agetSpace: GetHandle, h5agetType: GetHandle, h5awrite: Awrite, h5aread: Aread
    let h5tgetClass: GetInt, h5tisVariableStr: GetInt, h5tgetSize: GetSize
    let h5sgetSimpleExtentNdims: GetInt, h5sgetSimpleExtentNpoints: GetPoints
    let nativeInt: hid_t, stringC1: hid_t

    /// Runs `body` with the library, under `HDF5Serial`, the load included (`H5open` is an API call).
    static func withLibrary<T>(_ body: (TestHDF5Library) throws -> T) throws -> T {
        try HDF5Serial.run { try body(try load()) }
    }

    private static func load() throws -> TestHDF5Library {
        let candidates = [ProcessInfo.processInfo.environment["FORMATO_HDF5_PATH"],
            Bundle.main.privateFrameworksURL?.appendingPathComponent("libhdf5.dylib").path,
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("../Frameworks/libhdf5.dylib").standardized.path,
            FormatoHDF5Library.bundledLibraryPath, "libhdf5.dylib"].compactMap { $0 }
        var failures: [String] = []
        var found: UnsafeMutableRawPointer?
        for path in candidates where found == nil {
            dlerror()
            found = dlopen(path, RTLD_NOW | RTLD_LOCAL)
            if found == nil { failures.append("\(path): \(dlerror().map { String(cString: $0) } ?? "unknown")") }
        }
        guard let handle = found else { throw TestHDF5Error(description: "libhdf5 did not load: " + failures.joined(separator: "; ")) }
        func symbol<T>(_ name: String, as: T.Type) throws -> T {
            guard let pointer = dlsym(handle, name) else { throw TestHDF5Error(description: "libhdf5 lacks \(name)") }
            return unsafeBitCast(pointer, to: T.self)
        }
        func global(_ name: String) throws -> hid_t {
            guard let pointer = dlsym(handle, name) else { throw TestHDF5Error(description: "libhdf5 lacks \(name)") }
            return pointer.assumingMemoryBound(to: hid_t.self).pointee
        }
        let open = try symbol("H5open", as: (@convention(c) () -> herr_t).self)
        if open() >= 0 { HDF5Serial.installExitBarrier() }     // after H5open, never before (FormatoKit's HDF5Types.swift)
        // A probe that finds nothing is an answer here, not a stack dump on stderr.
        _ = try symbol("H5Eset_auto2", as: (@convention(c) (hid_t, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> herr_t).self)(0, nil, nil)
        return TestHDF5Library(
            handle: handle,
            h5fcreate: try symbol("H5Fcreate", as: Create.self), h5fopen: try symbol("H5Fopen", as: Open.self),
            h5fclose: try symbol("H5Fclose", as: Close.self), h5gopen2: try symbol("H5Gopen2", as: GOpen.self),
            h5gclose: try symbol("H5Gclose", as: Close.self),
            h5screate: try symbol("H5Screate", as: Screate.self), h5screateSimple: try symbol("H5Screate_simple", as: ScreateSimple.self),
            h5sclose: try symbol("H5Sclose", as: Close.self),
            h5tcopy: try symbol("H5Tcopy", as: Tcopy.self), h5tsetSize: try symbol("H5Tset_size", as: TsetSize.self),
            h5tsetCset: try symbol("H5Tset_cset", as: TsetCset.self), h5tclose: try symbol("H5Tclose", as: Close.self),
            h5acreate2: try symbol("H5Acreate2", as: Acreate2.self), h5aexists: try symbol("H5Aexists", as: Aexists.self),
            h5aopen: try symbol("H5Aopen", as: Aopen.self), h5aclose: try symbol("H5Aclose", as: Close.self),
            h5agetSpace: try symbol("H5Aget_space", as: GetHandle.self), h5agetType: try symbol("H5Aget_type", as: GetHandle.self),
            h5awrite: try symbol("H5Awrite", as: Awrite.self), h5aread: try symbol("H5Aread", as: Aread.self),
            h5tgetClass: try symbol("H5Tget_class", as: GetInt.self), h5tisVariableStr: try symbol("H5Tis_variable_str", as: GetInt.self),
            h5tgetSize: try symbol("H5Tget_size", as: GetSize.self),
            h5sgetSimpleExtentNdims: try symbol("H5Sget_simple_extent_ndims", as: GetInt.self),
            h5sgetSimpleExtentNpoints: try symbol("H5Sget_simple_extent_npoints", as: GetPoints.self),
            nativeInt: try global("H5T_NATIVE_INT_g"), stringC1: try global("H5T_C_S1_g"))
    }
}
