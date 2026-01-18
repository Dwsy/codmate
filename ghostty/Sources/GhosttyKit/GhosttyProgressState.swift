//
//  GhosttyProgressState.swift
//  CodMate
//
//  This file is adapted from Aizen (https://github.com/vivy-company/aizen)
//  which provided the initial Ghostty embedding implementation.
//

import Foundation
import CGhostty

enum GhosttyProgressState {
    case remove
    case set
    case error
    case indeterminate
    case pause
    case unknown

    init(cState: ghostty_action_progress_report_state_e) {
        switch cState {
        case GHOSTTY_PROGRESS_STATE_REMOVE: self = .remove
        case GHOSTTY_PROGRESS_STATE_SET: self = .set
        case GHOSTTY_PROGRESS_STATE_ERROR: self = .error
        case GHOSTTY_PROGRESS_STATE_INDETERMINATE: self = .indeterminate
        case GHOSTTY_PROGRESS_STATE_PAUSE: self = .pause
        default: self = .unknown
        }
    }
}
