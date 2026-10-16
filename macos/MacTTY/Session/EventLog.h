/*
 * EventLog.h: the Event Log window of a session.
 */

#import <Cocoa/Cocoa.h>

@class MTSession;

void mac_show_event_log(MTSession *session);
/* The session logged an event: refresh its window if it is open. */
void mac_event_log_updated(MTSession *session);
