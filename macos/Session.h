/*
 * Session.h: one terminal window and the PuTTY session behind it.
 *
 * MTSession plays the part of 'struct GtkFrontend' in unix/window.c:
 * it implements TermWin, Seat and LogPolicy for one session and owns
 * the Terminal, Backend, Ldisc and LogContext.
 */

#import <Cocoa/Cocoa.h>

#include "putty.h"
#include "terminal.h"

@class MTTerminalView;

/* The PuTTY-facing trait objects. 'session' leads back to the owning
 * MTSession (not retained: the session outlives them). */
typedef struct MacFrontend {
    TermWin termwin;
    Seat seat;
    LogPolicy logpolicy;
    void *session;
} MacFrontend;

@interface MTSession : NSWindowController <NSWindowDelegate, NSMenuDelegate>
{
@public
    MacFrontend fe;
    Conf *conf;
    Terminal *term;
    Backend *backend;
    Ldisc *ldisc;
    LogContext *logctx;
    struct unicode_data ucsdata;
    bool exited;
    cmdline_get_passwd_input_state cmdline_get_passwd_state;

    /* Cached from conf (cache_conf_values in the GTK front end). */
    int bold_style;
    int cursor_type;
    bool option_meta, command_meta;
}

@property (nonatomic, readonly) MTTerminalView *termView;
@property (nonatomic, readonly) NSMutableArray<NSString *> *eventLog;

/* Opens a session window for 'conf' and starts the connection. Takes
 * ownership of conf. */
+ (void)openSessionWithConf:(Conf *)conf;
/* The same, remembering which saved session conf was loaded from (for
 * the recent sessions list); name may be nil. */
+ (void)openSessionWithConf:(Conf *)conf savedSession:(NSString *)name;
+ (NSArray<MTSession *> *)sessions;

/* PuTTY's "system menu": shown on Ctrl+click in the terminal. */
- (NSMenu *)contextMenu;
/* The back end's special commands (Break, IGNORE, ...) or nil. */
- (NSMenu *)specialsMenuCopy;

/* Called by the terminal view. */
- (void)terminalViewDidChangeSize;
- (void)toggleFullScreenFromKeyboard;
- (void)appearanceChanged;

@end

/* The pasteboard that Copy and Paste use: the general pasteboard, or
 * the one named by the environment variable MACTTY_PASTEBOARD, so that
 * automated tests never touch the user's clipboard. */
NSPasteboard *mactty_pasteboard(void);

/* Dialogs.m: the per-session prompts. */
SeatPromptResult mac_seat_confirm_ssh_host_key(
    Seat *seat, const char *host, int port, const char *keytype,
    char *keystr, SeatDialogText *text, HelpCtx helpctx,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx);
SeatPromptResult mac_seat_confirm_weak_crypto_primitive(
    Seat *seat, SeatDialogText *text,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx);
SeatPromptResult mac_seat_confirm_weak_cached_hostkey(
    Seat *seat, SeatDialogText *text,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx);
const SeatDialogPromptDescriptions *mac_seat_prompt_descriptions(Seat *seat);
int mac_askappend(MTSession *session, Filename *filename,
                  void (*callback)(void *ctx, int result), void *ctx);
void mac_show_event_log(MTSession *session);
void mac_event_log_updated(MTSession *session);
void mac_about_box(void);
NSString *mactty_version(void);

static inline MTSession *session_from_seat(Seat *seat)
{
    return (__bridge MTSession *)container_of(seat, MacFrontend, seat)->session;
}
