//
//  Ghostty-header.h
//  CodMate
//
//  Bridging header to expose Ghostty C API to Swift
//

#ifndef Ghostty_header_h
#define Ghostty_header_h

// Import the main Ghostty C API
// Note: ghostty.h already includes all necessary definitions
// Do NOT include ghostty/vt.h as it causes duplicate enum definitions
// NOTE: This file is excluded from Package.swift and may not be in use.
// The correct path is now ghostty/Vendor/include/ghostty.h
#import "ghostty/Vendor/include/ghostty.h"

#endif /* Ghostty_header_h */
