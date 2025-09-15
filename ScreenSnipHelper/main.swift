//
//  main.swift
//  Screen Snip
//
//  Created by George Babichev on 9/15/25.
//

// Import the Cocoa framework, which provides essential classes for macOS app development
import Cocoa

// Create an instance of the application delegate, which manages app-level behavior
let delegate = LoginItemHelperApp()

// Access the shared NSApplication instance, representing the running app; underscore ignores the unused result
_ = NSApplication.shared

// Enter the main actor context to ensure thread safety for UI-related operations
MainActor.assumeIsolated {
    // Assign the delegate instance to the shared application's delegate property
    NSApplication.shared.delegate = delegate
}

// Start the main application loop, passing command-line arguments; underscore ignores the return value
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
