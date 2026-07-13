/*
 * vphoned_url — URL opening over vsock.
 *
 * Handles open_url using LSApplicationWorkspace.
 */

#pragma once
#import <Foundation/Foundation.h>

/// Hard bound for LSApplicationWorkspace URL opens.
FOUNDATION_EXPORT const NSTimeInterval VPURLCommandTimeoutSeconds;

/// Handle an open_url command. Returns a response dict.
NSDictionary *vp_handle_url_command(NSDictionary *msg);
