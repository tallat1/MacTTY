/*
 * SessionInternal.h: what Session.m and SessionFrontend.m share and no
 * one else needs: the methods the PuTTY-facing callbacks call, and the
 * callback tables MTSession installs.
 */

#import "Session/Session.h"

@interface MTSession ()
- (void)layoutContent;
- (void)startBackend;
- (void)destroyConnection;
- (void)updateSpecials;
- (void)requestResizeCols:(int)w rows:(int)h;
- (void)setScrollbarTotal:(int)total start:(int)start page:(int)page;
- (void)bell:(int)mode;
- (void)clipWrite:(wchar_t *)text attrs:(int *)attrs
          colours:(truecolour *)colours length:(int)len;
- (void)pasteFromClipboard;
- (void)connectionFatal:(const char *)msg;
- (void)remoteExited;
- (void)logEvent:(const char *)string;
- (void)zoomWillStart;
- (void)zoomDidEnd;
@end

/* SessionFrontend.m: how PuTTY's terminal, back end and logging reach
 * the session (TermWin, Seat and LogPolicy). */
extern const TermWinVtable mac_termwin_vt;
extern const SeatVtable mac_seat_vt;
extern const LogPolicyVtable mac_logpolicy_vt;
