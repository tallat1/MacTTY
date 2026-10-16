/*
 * Session.m: a terminal window and the PuTTY session behind it.
 *
 * Structure and behaviour follow unix/window.c (GtkFrontend), with
 * Windows PuTTY's conventions wherever the two differ.
 */

#import "Session.h"
#import "TerminalView.h"
#import "AppDelegate.h"

#include <wchar.h>

#include "mactty.h"
#include "storage.h"

static NSMutableArray<MTSession *> *all_sessions;

/* A content view that lays out the terminal and its scrollbar. */
@interface MTSessionContentView : NSView
@property (nonatomic, unsafe_unretained) MTSession *session;
@end

/* A window that can ignore Command-W, as PuTTY can ignore Alt-F4. */
@interface MTSessionWindow : NSWindow
@property (nonatomic, unsafe_unretained) MTSession *session;
@end

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

/* ----------------------------------------------------------------------
 * TermWin.
 */

static MTSession *session_from_termwin(TermWin *tw)
{
    return (__bridge MTSession *)
        container_of(tw, MacFrontend, termwin)->session;
}

static bool mac_setup_draw_ctx(TermWin *tw)
{
    return [session_from_termwin(tw).termView setupDrawCtx];
}

static void mac_draw_text(TermWin *tw, int x, int y, wchar_t *text, int len,
                          unsigned long attrs, int lattr, truecolour tc)
{
    [session_from_termwin(tw).termView drawText:text length:len x:x y:y
                                           attr:attrs lattr:lattr
                                     truecolour:tc];
}

static void mac_draw_cursor(TermWin *tw, int x, int y, wchar_t *text,
                            int len, unsigned long attrs, int lattr,
                            truecolour tc)
{
    [session_from_termwin(tw).termView drawCursor:text length:len x:x y:y
                                             attr:attrs lattr:lattr
                                       truecolour:tc];
}

static void mac_draw_trust_sigil(TermWin *tw, int x, int y)
{
    [session_from_termwin(tw).termView drawTrustSigilAtX:x y:y];
}

static int mac_char_width(TermWin *tw, int uc)
{
    /* Every glyph is drawn into the terminal's own character cells. */
    return 1;
}

static void mac_free_draw_ctx(TermWin *tw)
{
    [session_from_termwin(tw).termView freeDrawCtx];
}

static void mac_set_cursor_pos(TermWin *tw, int x, int y)
{
    [session_from_termwin(tw).termView setCursorCellX:x y:y];
}

static void mac_set_raw_mouse_mode(TermWin *tw, bool enable)
{
    session_from_termwin(tw).termView.sendRawMouse = enable;
}

static void mac_set_raw_mouse_mode_pointer(TermWin *tw, bool enable)
{
    session_from_termwin(tw).termView.pointerIndicatesRawMouse = enable;
}

static void mac_set_scrollbar(TermWin *tw, int total, int start, int page)
{
    [session_from_termwin(tw) setScrollbarTotal:total start:start page:page];
}

static void mac_bell(TermWin *tw, int mode)
{
    [session_from_termwin(tw) bell:mode];
}

static void mac_clip_write(TermWin *tw, int clipboard, wchar_t *text,
                           int *attrs, truecolour *colours, int len,
                           bool must_deselect)
{
    if (clipboard != CLIP_SYSTEM)
        return;
    [session_from_termwin(tw) clipWrite:text attrs:attrs colours:colours
                                 length:len];
}

static void mac_clip_request_paste(TermWin *tw, int clipboard)
{
    if (clipboard != CLIP_SYSTEM)
        return;
    [session_from_termwin(tw) pasteFromClipboard];
}

static void mac_refresh(TermWin *tw)
{
    MTSession *s = session_from_termwin(tw);
    if (s->term)
        term_invalidate(s->term);
}

static void mac_request_resize(TermWin *tw, int w, int h)
{
    [session_from_termwin(tw) requestResizeCols:w rows:h];
}

static NSString *string_from_codepage(const char *str, int codepage)
{
    wchar_t *wide = dup_mb_to_wc(codepage, str);
    NSString *ret = [[NSString alloc]
        initWithBytes:wide length:wcslen(wide) * sizeof(wchar_t)
             encoding:NSUTF32LittleEndianStringEncoding];
    sfree(wide);
    return ret ? ret : @"";
}

static void mac_set_title(TermWin *tw, const char *title, int codepage)
{
    session_from_termwin(tw).window.title =
        string_from_codepage(title, codepage);
}

static void mac_set_icon_title(TermWin *tw, const char *title, int codepage)
{
    session_from_termwin(tw).window.miniwindowTitle =
        string_from_codepage(title, codepage);
}

static void mac_set_minimised(TermWin *tw, bool minimised)
{
    NSWindow *w = session_from_termwin(tw).window;
    if (minimised)
        [w miniaturize:nil];
    else
        [w deminiaturize:nil];
}

static void mac_set_maximised(TermWin *tw, bool maximised)
{
    NSWindow *w = session_from_termwin(tw).window;
    if (w.isZoomed != maximised)
        [w zoom:nil];
}

static void mac_move(TermWin *tw, int x, int y)
{
    /* x and y are in pixels from the top-left of the screen. As in
     * Windows PuTTY, a window that sizes its font to fit stays put. */
    MTSession *s = session_from_termwin(tw);
    NSWindow *w = s.window;
    int action = conf_get_int(s->conf, CONF_resize_action);
    if (action == RESIZE_DISABLED || action == RESIZE_FONT || w.isZoomed)
        return;
    NSRect screen = (w.screen ?: NSScreen.mainScreen).frame;
    [w setFrameTopLeftPoint:NSMakePoint(screen.origin.x + x,
                                        NSMaxY(screen) - y)];
}

static void mac_set_zorder(TermWin *tw, bool top)
{
    NSWindow *w = session_from_termwin(tw).window;
    if (top)
        [w orderFront:nil];
    else
        [w orderBack:nil];
}

static void mac_palette_set(TermWin *tw, unsigned start, unsigned ncolours,
                            const rgb *colours)
{
    [session_from_termwin(tw).termView setPaletteFrom:start count:ncolours
                                              colours:colours];
}

static rgb rgb_from_nscolor(NSColor *c)
{
    NSColor *s = [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return (rgb){ (uint8_t)lround(s.redComponent * 255),
                  (uint8_t)lround(s.greenComponent * 255),
                  (uint8_t)lround(s.blueComponent * 255) };
}

static void mac_palette_get_overrides(TermWin *tw, Terminal *term)
{
    MTSession *s = session_from_termwin(tw);
    if (!conf_get_bool(s->conf, CONF_system_colour))
        return;
    /* The equivalent of Windows PuTTY's "Use system colours", following
     * the current light or dark appearance. */
    __block rgb fg, bg, sfg, sbg;
    NSAppearance *appearance = s.window.effectiveAppearance ?:
        NSApp.effectiveAppearance;
    [appearance performAsCurrentDrawingAppearance:^{
        fg = rgb_from_nscolor(NSColor.textColor);
        bg = rgb_from_nscolor(NSColor.textBackgroundColor);
        sfg = rgb_from_nscolor(NSColor.selectedTextColor);
        sbg = rgb_from_nscolor(NSColor.selectedTextBackgroundColor);
    }];
    term_palette_override(term, OSC4_COLOUR_fg, fg);
    term_palette_override(term, OSC4_COLOUR_fg_bold, fg);
    term_palette_override(term, OSC4_COLOUR_bg, bg);
    term_palette_override(term, OSC4_COLOUR_bg_bold, bg);
    term_palette_override(term, OSC4_COLOUR_cursor_fg, sfg);
    term_palette_override(term, OSC4_COLOUR_cursor_bg, sbg);
}

static void mac_unthrottle(TermWin *tw, size_t bufsize)
{
    MTSession *s = session_from_termwin(tw);
    if (s->backend)
        backend_unthrottle(s->backend, bufsize);
}

static const TermWinVtable mac_termwin_vt = {
    .setup_draw_ctx = mac_setup_draw_ctx,
    .draw_text = mac_draw_text,
    .draw_cursor = mac_draw_cursor,
    .draw_trust_sigil = mac_draw_trust_sigil,
    .char_width = mac_char_width,
    .free_draw_ctx = mac_free_draw_ctx,
    .set_cursor_pos = mac_set_cursor_pos,
    .set_raw_mouse_mode = mac_set_raw_mouse_mode,
    .set_raw_mouse_mode_pointer = mac_set_raw_mouse_mode_pointer,
    .set_scrollbar = mac_set_scrollbar,
    .bell = mac_bell,
    .clip_write = mac_clip_write,
    .clip_request_paste = mac_clip_request_paste,
    .refresh = mac_refresh,
    .request_resize = mac_request_resize,
    .set_title = mac_set_title,
    .set_icon_title = mac_set_icon_title,
    .set_minimised = mac_set_minimised,
    .set_maximised = mac_set_maximised,
    .move = mac_move,
    .set_zorder = mac_set_zorder,
    .palette_set = mac_palette_set,
    .palette_get_overrides = mac_palette_get_overrides,
    .unthrottle = mac_unthrottle,
};

/* ----------------------------------------------------------------------
 * Seat.
 */

static size_t mac_seat_output(Seat *seat, SeatOutputType type,
                              const void *data, size_t len)
{
    MTSession *s = session_from_seat(seat);
    return term_data(s->term, data, len);
}

static bool mac_seat_eof(Seat *seat)
{
    return true;   /* do respond to incoming EOF with outgoing */
}

static SeatPromptResult mac_seat_get_userpass_input(Seat *seat,
                                                    prompts_t *p)
{
    MTSession *s = session_from_seat(seat);
    SeatPromptResult spr;
    spr = cmdline_get_passwd_input(p, &s->cmdline_get_passwd_state, true);
    if (spr.kind == SPRK_INCOMPLETE)
        spr = term_get_userpass_input(s->term, p);
    return spr;
}

static void exit_callback(void *vctx)
{
    MacFrontend *fe = (MacFrontend *)vctx;
    [(__bridge MTSession *)fe->session remoteExited];
}

static void mac_seat_notify_remote_exit(Seat *seat)
{
    MTSession *s = session_from_seat(seat);
    queue_toplevel_callback(exit_callback, &s->fe);
}

static void mac_seat_connection_fatal(Seat *seat, const char *msg)
{
    [session_from_seat(seat) connectionFatal:msg];
}

static void mac_seat_nonfatal(Seat *seat, const char *msg)
{
    MTSession *s = session_from_seat(seat);
    char *title = dupcat(appname, " Error");
    mactty_message_box((__bridge void *)s.window, title, msg);
    sfree(title);
}

static void mac_seat_update_specials_menu(Seat *seat)
{
    [session_from_seat(seat) updateSpecials];
}

static char *mac_seat_get_ttymode(Seat *seat, const char *mode)
{
    return term_get_ttymode(session_from_seat(seat)->term, mode);
}

static void mac_seat_set_busy_status(Seat *seat, BusyStatus status)
{
    session_from_seat(seat).termView.busyStatus = status;
}

static bool mac_seat_is_utf8(Seat *seat)
{
    return session_from_seat(seat)->ucsdata.line_codepage == CS_UTF8;
}

static bool mac_seat_get_window_pixel_size(Seat *seat, int *w, int *h)
{
    MTSession *s = session_from_seat(seat);
    NSSize size = s.termView.bounds.size;
    CGFloat scale = s.window.backingScaleFactor;
    *w = (int)(size.width * scale);
    *h = (int)(size.height * scale);
    return true;
}

static StripCtrlChars *mac_seat_stripctrl_new(
    Seat *seat, BinarySink *bs_out, SeatInteractionContext sic)
{
    return stripctrl_new_term(bs_out, false, 0, session_from_seat(seat)->term);
}

static void mac_seat_set_trust_status(Seat *seat, bool trusted)
{
    term_set_trust_status(session_from_seat(seat)->term, trusted);
}

static bool mac_seat_can_set_trust_status(Seat *seat)
{
    return true;
}

static bool mac_seat_get_cursor_position(Seat *seat, int *x, int *y)
{
    MTSession *s = session_from_seat(seat);
    if (s->term) {
        term_get_cursor_position(s->term, x, y);
        return true;
    }
    return false;
}

static const SeatVtable mac_seat_vt = {
    .output = mac_seat_output,
    .eof = mac_seat_eof,
    .sent = nullseat_sent,
    .banner = nullseat_banner_to_stderr,
    .get_userpass_input = mac_seat_get_userpass_input,
    .notify_session_started = nullseat_notify_session_started,
    .notify_remote_exit = mac_seat_notify_remote_exit,
    .notify_remote_disconnect = nullseat_notify_remote_disconnect,
    .connection_fatal = mac_seat_connection_fatal,
    .nonfatal = mac_seat_nonfatal,
    .update_specials_menu = mac_seat_update_specials_menu,
    .get_ttymode = mac_seat_get_ttymode,
    .set_busy_status = mac_seat_set_busy_status,
    .confirm_ssh_host_key = mac_seat_confirm_ssh_host_key,
    .confirm_weak_crypto_primitive = mac_seat_confirm_weak_crypto_primitive,
    .confirm_weak_cached_hostkey = mac_seat_confirm_weak_cached_hostkey,
    .prompt_descriptions = mac_seat_prompt_descriptions,
    .is_utf8 = mac_seat_is_utf8,
    .echoedit_update = nullseat_echoedit_update,
    .get_display = nullseat_get_display,
    .get_windowid = nullseat_get_windowid,
    .get_window_pixel_size = mac_seat_get_window_pixel_size,
    .stripctrl_new = mac_seat_stripctrl_new,
    .set_trust_status = mac_seat_set_trust_status,
    .can_set_trust_status = mac_seat_can_set_trust_status,
    .has_mixed_input_stream = nullseat_has_mixed_input_stream_yes,
    .verbose = nullseat_verbose_yes,
    .interactive = nullseat_interactive_yes,
    .get_cursor_position = mac_seat_get_cursor_position,
};

/* ----------------------------------------------------------------------
 * LogPolicy.
 */

static void mac_eventlog(LogPolicy *lp, const char *string)
{
    MTSession *s = (__bridge MTSession *)
        container_of(lp, MacFrontend, logpolicy)->session;
    [s logEvent:string];
}

static int mac_lp_askappend(LogPolicy *lp, Filename *filename,
                            void (*callback)(void *ctx, int result),
                            void *ctx)
{
    MTSession *s = (__bridge MTSession *)
        container_of(lp, MacFrontend, logpolicy)->session;
    return mac_askappend(s, filename, callback, ctx);
}

static void mac_logging_error(LogPolicy *lp, const char *event)
{
    MTSession *s = (__bridge MTSession *)
        container_of(lp, MacFrontend, logpolicy)->session;
    seat_stderr_pl(&s->fe.seat, ptrlen_from_asciz(event));
    seat_stderr_pl(&s->fe.seat, PTRLEN_LITERAL("\r\n"));
}

static const LogPolicyVtable mac_logpolicy_vt = {
    .eventlog = mac_eventlog,
    .askappend = mac_lp_askappend,
    .logging_error = mac_logging_error,
    .verbose = null_lp_verbose_yes,
};

/* ----------------------------------------------------------------------
 * The session window.
 */

@implementation MTSessionContentView
- (void)resizeSubviewsWithOldSize:(NSSize)oldSize
{
    [self.session layoutContent];
}
@end

@implementation MTSessionWindow
- (void)performClose:(id)sender
{
    /* "Window closes on Command-W" off: ignore the keyboard shortcut,
     * but still let the close button and the menu work. */
    MTSession *s = self.session;
    NSEvent *ev = NSApp.currentEvent;
    if (s && s->conf && !conf_get_bool(s->conf, CONF_alt_f4) &&
        ev.type == NSEventTypeKeyDown &&
        (ev.modifierFlags & NSEventModifierFlagCommand))
        return;
    [super performClose:sender];
}

/* Zooming animates through intermediate frames, which in "Change font
 * size only when maximised" mode must change the font, not the number
 * of rows and columns. The animation is over when super returns. */
- (void)zoom:(id)sender
{
    MTSession *s = self.session;
    [s zoomWillStart];
    [super zoom:sender];
    [s zoomDidEnd];
}
@end

@implementation MTSession {
    MTSessionContentView *container;
    NSScroller *scroller;
    BOOL scrollbarVisible;
    int sbTotal, sbStart, sbPage;
    NSMenu *specialsMenu;
    BOOL hasSpecials;
    void *reconfigWindow;
    BOOL closingConfirmed;
    BOOL inFullScreen;
    BOOL fullScreenTransition, zooming;
    int eventLogDropped;
}

+ (NSArray<MTSession *> *)sessions
{
    return all_sessions ? [all_sessions copy] : @[];
}

+ (void)openSessionWithConf:(Conf *)conf
{
    prepare_session(conf);
    MTSession *s = [[MTSession alloc] initWithConf:conf];
    if (!s)
        return;
    if (!all_sessions)
        all_sessions = [NSMutableArray new];
    [all_sessions addObject:s];
    [s.window makeKeyAndOrderFront:nil];
    [s startBackend];
    if (s->ldisc)
        ldisc_echoedit_update(s->ldisc);
}

- (void)cacheConfValues
{
    bold_style = conf_get_int(conf, CONF_bold_style);
    cursor_type = conf_get_int(conf, CONF_cursor_type);
    option_meta = conf_get_bool(conf, CONF_osx_option_meta);
    command_meta = conf_get_bool(conf, CONF_osx_command_meta);
    [_termView setFontQuality:conf_get_int(conf, CONF_font_quality)];
    _termView.border = conf_get_int(conf, CONF_window_border);
}

- (BOOL)resizeForbidden
{
    const struct BackendVtable *vt = select_backend(conf);
    return (vt && (vt->flags & BACKEND_RESIZE_FORBIDDEN)) ||
        conf_get_int(conf, CONF_resize_action) == RESIZE_DISABLED;
}

- (instancetype)initWithConf:(Conf *)c
{
    MTSessionWindow *w = [[MTSessionWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 640, 400)
                  styleMask:(NSWindowStyleMaskTitled |
                             NSWindowStyleMaskClosable |
                             NSWindowStyleMaskMiniaturizable |
                             NSWindowStyleMaskResizable)
                    backing:NSBackingStoreBuffered defer:NO];
    if (!(self = [super initWithWindow:w]))
        return nil;
    w.session = self;
    w.releasedWhenClosed = NO;
    w.delegate = self;
    w.tabbingMode = NSWindowTabbingModeDisallowed;

    conf = c;
    fe.termwin.vt = &mac_termwin_vt;
    fe.seat.vt = &mac_seat_vt;
    fe.logpolicy.vt = &mac_logpolicy_vt;
    fe.session = (__bridge void *)self;
    _eventLog = [NSMutableArray new];

    _termView = [[MTTerminalView alloc] initWithFrame:NSMakeRect(0, 0, 640, 400)];
    _termView.session = self;
    [self cacheConfValues];

    NSString *err = [_termView setupFontsFromConf:conf];
    if (err) {
        /* Fall back to the default font rather than failing outright. */
        FontSpec *fs = fontspec_new("Menlo-Regular 13");
        Conf *fallback = conf_copy(conf);
        conf_set_fontspec(fallback, CONF_font, fs);
        fontspec_free(fs);
        NSString *err2 = [_termView setupFontsFromConf:fallback];
        conf_free(fallback);
        if (err2) {
            window_setup_error(err.UTF8String);
            conf_free(conf);
            conf = NULL;
            return nil;
        }
        NSLog(@"%@; falling back to the default font", err);
    }
    init_ucs(&ucsdata, conf_get_str(conf, CONF_line_codepage),
             conf_get_bool(conf, CONF_utf8_override), CS_UTF8,
             conf_get_int(conf, CONF_vtmode));

    scroller = [[NSScroller alloc] initWithFrame:NSMakeRect(0, 0, 15, 100)];
    scroller.scrollerStyle = NSScrollerStyleLegacy;
    scroller.target = self;
    scroller.action = @selector(scrollerMoved:);
    scroller.enabled = NO;
    scrollbarVisible = conf_get_bool(conf, CONF_scrollbar);

    container = [[MTSessionContentView alloc] initWithFrame:NSZeroRect];
    container.session = self;
    [container addSubview:_termView];
    [container addSubview:scroller];
    w.contentView = container;
    w.initialFirstResponder = _termView;
    [w makeFirstResponder:_termView];

    int width = conf_get_int(conf, CONF_width);
    int height = conf_get_int(conf, CONF_height);

    term = term_init(conf, &ucsdata, &fe.termwin);
    [self setupClipboards];
    logctx = log_init(&fe.logpolicy, conf);
    term_provide_logctx(term, logctx);
    term_size(term, height, width, conf_get_int(conf, CONF_savelines));

    [self applyWindowGeometryForCols:width rows:height];
    w.backgroundColor = [_termView defaultBackgroundColour];
    if (conf_get_bool(conf, CONF_alwaysontop))
        w.level = NSFloatingWindowLevel;

    /* Cascade from the most recent session window, like new Terminal
     * windows do; the first one is centred. */
    MTSession *last = all_sessions.lastObject;
    if (last && last.window.isVisible) {
        NSPoint tl = NSMakePoint(NSMinX(last.window.frame),
                                 NSMaxY(last.window.frame));
        [w setFrameTopLeftPoint:NSMakePoint(tl.x + 22, tl.y - 22)];
    } else {
        [w center];
    }

    exited = false;
    return self;
}

- (void)setupClipboards
{
    term->n_mouse_select_clipboards = 1;   /* [0] is always CLIP_LOCAL */
    if (conf_get_bool(conf, CONF_mouseautocopy))
        term->mouse_select_clipboards[
            term->n_mouse_select_clipboards++] = CLIP_SYSTEM;
    switch (conf_get_int(conf, CONF_mousepaste)) {
      case CLIPUI_IMPLICIT:
        term->mouse_paste_clipboard = CLIP_LOCAL;
        break;
      case CLIPUI_EXPLICIT:
        term->mouse_paste_clipboard = CLIP_SYSTEM;
        break;
      default:
        term->mouse_paste_clipboard = CLIP_NULL;
        break;
    }
}

/* ----------------------------------------------------------------------
 * Geometry.
 */

- (CGFloat)scrollbarWidth
{
    BOOL show = scrollbarVisible;
    if (inFullScreen && !conf_get_bool(conf, CONF_scrollbar_in_fullscreen))
        show = NO;
    return show ? [NSScroller scrollerWidthForControlSize:NSControlSizeRegular
                                            scrollerStyle:NSScrollerStyleLegacy]
                : 0;
}

/*
 * Whether a change in the window's size changes the font (keeping the
 * rows and columns) rather than the terminal size: always in "Change
 * the size of the font" mode, and only while zoomed or in full screen
 * in "Change font size only when maximised" mode.
 */
- (BOOL)fontFollowsWindow
{
    switch (conf_get_int(conf, CONF_resize_action)) {
      case RESIZE_FONT:
        return YES;
      case RESIZE_EITHER:
        return inFullScreen || fullScreenTransition || zooming ||
            self.window.isZoomed;
      default:
        return NO;
    }
}

- (void)applyWindowGeometryForCols:(int)cols rows:(int)rows
{
    NSWindow *w = self.window;
    BOOL fontmode = conf_get_int(conf, CONF_resize_action) == RESIZE_FONT;
    CGFloat sw = [self scrollbarWidth];

    if ([self resizeForbidden]) {
        w.styleMask &= ~NSWindowStyleMaskResizable;
    } else {
        w.styleMask |= NSWindowStyleMaskResizable;
    }
    if (fontmode) {
        /* Any size will do; just keep the font legible. */
        int b = _termView.border;
        w.contentResizeIncrements = NSMakeSize(1, 1);
        w.contentMinSize = NSMakeSize(cols * 2 + 2 * b + sw, rows * 4 + 2 * b);
    } else {
        NSSize minsize = [_termView sizeForCols:2 rows:1];
        minsize.width += sw;
        w.contentResizeIncrements = NSMakeSize(_termView.fontWidth,
                                               _termView.fontHeight);
        w.contentMinSize = minsize;
    }

    if (term && [self fontFollowsWindow] &&
        (cols != term->cols || rows != term->rows))
        term_size(term, rows, cols, conf_get_int(conf, CONF_savelines));

    if (inFullScreen || fullScreenTransition || zooming || w.isZoomed) {
        /* The window keeps its size: the font or the terminal adapts,
         * as in reset_window() in Windows PuTTY. */
        [self layoutContent];
        [self terminalViewDidChangeSize];
        return;
    }

    NSSize tsize = [_termView sizeForCols:cols rows:rows];
    NSRect frame = w.frame;
    NSRect newframe = [w frameRectForContentRect:
                           NSMakeRect(0, 0, tsize.width + sw, tsize.height)];
    newframe.origin.x = frame.origin.x;
    newframe.origin.y = NSMaxY(frame) - newframe.size.height;
    [w setFrame:newframe display:YES];
    [self layoutContent];
}

- (void)layoutContent
{
    NSRect b = container.bounds;
    CGFloat sw = [self scrollbarWidth];
    BOOL left = conf && conf_get_bool(conf, CONF_scrollbar_on_left);
    scroller.hidden = (sw == 0);
    _termView.frame = NSMakeRect(left ? sw : 0, 0, b.size.width - sw,
                                 b.size.height);
    scroller.frame = NSMakeRect(left ? 0 : b.size.width - sw, 0, sw,
                                b.size.height);
}

- (void)terminalViewDidChangeSize
{
    if (!term)
        return;
    if ([self fontFollowsWindow]) {
        if ([_termView fitFontsFromConf:conf cols:term->cols rows:term->rows])
            term_invalidate(term);
    } else {
        if (_termView.fontsFitted) {
            /* Dragged out of a zoomed window: the configured font, and
             * as many rows and columns of it as fit. */
            [_termView setupFontsFromConf:conf];
            term_invalidate(term);
        }
        int cols, rows;
        [_termView gridForSize:_termView.bounds.size cols:&cols rows:&rows];
        if (cols != term->cols || rows != term->rows)
            term_size(term, rows, cols, conf_get_int(conf, CONF_savelines));
    }
    NSSize px = _termView.bounds.size;
    term_notify_window_size_pixels(term, (int)px.width, (int)px.height);
}

/* After zooming or full screen: in "Change font size only when
 * maximised" mode, back to the configured font and a window that fits
 * it, as reset_window(wgs, 2) does in Windows PuTTY. */
- (void)updateFontFitting
{
    if (term && [self fontFollowsWindow]) {
        [self layoutContent];
        [self terminalViewDidChangeSize];
    } else if (term && _termView.fontsFitted) {
        [_termView setupFontsFromConf:conf];
        [self applyWindowGeometryForCols:term->cols rows:term->rows];
        term_invalidate(term);
    } else {
        [self layoutContent];
    }
}

- (void)requestResizeCols:(int)w rows:(int)h
{
    NSWindow *win = self.window;
    if ([self resizeForbidden] || (w == term->cols && h == term->rows)) {
        /* nothing to do */
    } else if ([self fontFollowsWindow]) {
        /* The window stays as it is and the font changes to fit the new
         * grid (wintw_request_resize in Windows PuTTY). */
        term_size(term, h, w, conf_get_int(conf, CONF_savelines));
        [self terminalViewDidChangeSize];
    } else if (!inFullScreen && !win.isZoomed) {
        [self applyWindowGeometryForCols:w rows:h];
    }
    term_resize_request_completed(term);
}

- (void)zoomWillStart
{
    zooming = YES;
}

- (void)zoomDidEnd
{
    zooming = NO;
    [self updateFontFitting];
}

- (void)windowWillEnterFullScreen:(NSNotification *)n
{
    fullScreenTransition = YES;
}

- (void)windowDidEnterFullScreen:(NSNotification *)n
{
    inFullScreen = YES;
    fullScreenTransition = NO;
    [self updateFontFitting];
}

- (void)windowDidFailToEnterFullScreen:(NSWindow *)window
{
    fullScreenTransition = NO;
    [self updateFontFitting];
}

- (void)windowWillExitFullScreen:(NSNotification *)n
{
    fullScreenTransition = YES;
}

- (void)windowDidExitFullScreen:(NSNotification *)n
{
    inFullScreen = NO;
    fullScreenTransition = NO;
    [self updateFontFitting];
}

- (void)windowDidFailToExitFullScreen:(NSWindow *)window
{
    fullScreenTransition = NO;
    [self updateFontFitting];
}

- (void)windowDidMove:(NSNotification *)n
{
    if (!term)
        return;
    NSRect f = self.window.frame;
    NSRect screen = (self.window.screen ?: NSScreen.mainScreen).frame;
    term_notify_window_pos(term, (int)(f.origin.x - screen.origin.x),
                           (int)(NSMaxY(screen) - NSMaxY(f)));
}

- (void)windowDidMiniaturize:(NSNotification *)n
{
    if (term)
        term_notify_minimised(term, true);
}

- (void)windowDidDeminiaturize:(NSNotification *)n
{
    if (term)
        term_notify_minimised(term, false);
}

- (void)windowDidBecomeKey:(NSNotification *)n
{
    if (term)
        term_set_focus(term, true);
}

- (void)windowDidResignKey:(NSNotification *)n
{
    if (term)
        term_set_focus(term, false);
}

- (void)appearanceChanged
{
    if (term && conf_get_bool(conf, CONF_system_colour))
        term_notify_palette_changed(term);
}

- (void)toggleFullScreenFromKeyboard
{
    [self.window toggleFullScreen:nil];
}

/* ----------------------------------------------------------------------
 * Scrollbar.
 */

- (void)setScrollbarTotal:(int)total start:(int)start page:(int)page
{
    sbTotal = total;
    sbStart = start;
    sbPage = page;
    if (total <= page) {
        scroller.enabled = NO;
        scroller.knobProportion = 1.0;
        scroller.doubleValue = 0;
    } else {
        scroller.enabled = YES;
        scroller.knobProportion = (double)page / total;
        scroller.doubleValue = (double)start / (total - page);
    }
}

- (void)scrollerMoved:(NSScroller *)sender
{
    if (!term)
        return;
    switch (sender.hitPart) {
      case NSScrollerDecrementPage:
        term_scroll(term, 0, -term->rows / 2);
        break;
      case NSScrollerIncrementPage:
        term_scroll(term, 0, +term->rows / 2);
        break;
      case NSScrollerKnob:
      case NSScrollerKnobSlot:
        term_scroll(term, 1,
                    (int)lround(sender.doubleValue * (sbTotal - sbPage)));
        break;
      default:
        break;
    }
}

/* ----------------------------------------------------------------------
 * Bell and clipboard.
 */

- (void)bell:(int)mode
{
    if (mode == BELL_DEFAULT) {
        NSBeep();
    } else if (mode == BELL_WAVEFILE) {
        Filename *fn = conf_get_filename(conf, CONF_bell_wavefile);
        NSSound *snd = [[NSSound alloc]
            initWithContentsOfFile:@(fn->path) byReference:YES];
        if (!snd || ![snd play]) {
            char *msg = dupprintf("Unable to play sound file\n%s\n"
                                  "Using default sound instead",
                                  fn->path);
            char *title = dupcat(appname, " Sound Error");
            mactty_message_box((__bridge void *)self.window, title, msg);
            sfree(title);
            sfree(msg);
            conf_set_int(conf, CONF_beep, BELL_DEFAULT);
            NSBeep();
        }
    }
    /* BELL_VISUAL is done by the terminal itself. */

    if (!NSApp.isActive) {
        switch (conf_get_int(conf, CONF_beep_ind)) {
          case B_IND_FLASH:
            [NSApp requestUserAttention:NSInformationalRequest];
            break;
          case B_IND_STEADY:
            [NSApp requestUserAttention:NSCriticalRequest];
            break;
        }
    }
}

- (NSColor *)colourForIndex:(int)idx truecolour:(optionalrgb)tc
{
    rgb c = tc.enabled ? (rgb){tc.r, tc.g, tc.b} : [_termView paletteColour:idx];
    return [NSColor colorWithSRGBRed:c.r/255.0 green:c.g/255.0
                                blue:c.b/255.0 alpha:1];
}

NSPasteboard *mactty_pasteboard(void)
{
    static NSPasteboard *pb;
    if (!pb) {
        const char *name = getenv("MACTTY_PASTEBOARD");
        pb = (name && *name) ? [NSPasteboard pasteboardWithName:@(name)]
                             : NSPasteboard.generalPasteboard;
    }
    return pb;
}

- (void)clipWrite:(wchar_t *)text attrs:(int *)attrs
          colours:(truecolour *)colours length:(int)len
{
    NSString *str = [[NSString alloc]
        initWithBytes:text length:len * sizeof(wchar_t)
             encoding:NSUTF32LittleEndianStringEncoding];
    if (!str)
        return;
    NSPasteboard *pb = mactty_pasteboard();
    [pb clearContents];

    if (!conf_get_bool(conf, CONF_rtf_paste) || !attrs) {
        [pb setString:str forType:NSPasteboardTypeString];
        return;
    }

    /* Rich text as Windows PuTTY makes it: the terminal font, with
     * foreground and background colours and underlining. */
    FontSpec *fs = conf_get_fontspec(conf, CONF_font);
    char *name = dupstr(fs->name);
    char *sp = strrchr(name, ' ');
    CGFloat size = sp ? atof(sp + 1) : 13;
    if (sp) *sp = '\0';
    NSFont *font = [NSFont fontWithName:@(name) size:size] ?:
        [NSFont userFixedPitchFontOfSize:size];
    sfree(name);
    NSFont *boldfont = [NSFontManager.sharedFontManager
                           convertFont:font toHaveTrait:NSBoldFontMask];

    NSMutableAttributedString *astr = [NSMutableAttributedString new];
    for (int i = 0; i < len; i++) {
        int a = attrs[i];
        int fg = (a & ATTR_FGMASK) >> ATTR_FGSHIFT;
        int bg = (a & ATTR_BGMASK) >> ATTR_BGSHIFT;
        if (a & ATTR_REVERSE) { int t = fg; fg = bg; bg = t; }
        if ((bold_style & BOLD_STYLE_COLOUR) && (a & ATTR_BOLD)) {
            if (fg < 16) fg |= 8;
            else if (fg >= 256) fg |= 1;
        }
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[NSFontAttributeName] =
            ((a & ATTR_BOLD) && (bold_style & BOLD_STYLE_FONT)) ?
            boldfont : font;
        optionalrgb nofg = colours ? colours[i].fg : optionalrgb_none;
        optionalrgb nobg = colours ? colours[i].bg : optionalrgb_none;
        d[NSForegroundColorAttributeName] =
            [self colourForIndex:fg truecolour:nofg];
        d[NSBackgroundColorAttributeName] =
            [self colourForIndex:bg truecolour:nobg];
        if (a & ATTR_UNDER)
            d[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
        [astr appendAttributedString:[[NSAttributedString alloc]
            initWithString:[[NSString alloc]
                initWithBytes:&text[i] length:sizeof(wchar_t)
                     encoding:NSUTF32LittleEndianStringEncoding] ?: @""
                attributes:d]];
    }
    [pb writeObjects:@[astr]];
    [pb setString:str forType:NSPasteboardTypeString];
}

- (void)pasteFromClipboard
{
    NSString *str = [mactty_pasteboard()
                        stringForType:NSPasteboardTypeString];
    if (!str || !term)
        return;
    /* Selections use LF line endings here; text from elsewhere may
     * have CRLF or CR. */
    str = [str stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    str = [str stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSData *d = [str dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    term_do_paste(term, (const wchar_t *)d.bytes, d.length / sizeof(wchar_t));
}

/* ----------------------------------------------------------------------
 * Connection lifecycle.
 */

- (void)startBackend
{
    const struct BackendVtable *vt;
    char *error, *realhost;

    cmdline_get_passwd_state = cmdline_get_passwd_input_state_new;
    vt = select_backend(conf);
    seat_set_trust_status(&fe.seat, true);
    /* Pageant, if it is running, is the agent (as on Windows). */
    mactty_select_agent();
    error = backend_init(vt, &fe.seat, &backend, logctx, conf,
                         conf_get_str(conf, CONF_host),
                         conf_get_int(conf, CONF_port),
                         &realhost,
                         conf_get_bool(conf, CONF_tcp_nodelay),
                         conf_get_bool(conf, CONF_tcp_keepalives));
    if (error) {
        seat_connection_fatal(&fe.seat, "Unable to open connection to %s:\n%s",
                              conf_dest(conf), error);
        sfree(error);
        exited = true;
        return;
    }
    term_setup_window_titles(term, realhost);
    sfree(realhost);
    term_provide_backend(term, backend);
    ldisc = ldisc_create(conf, term, backend, &fe.seat);
}

- (void)destroyConnection
{
    exited = true;
    if (ldisc) {
        ldisc_free(ldisc);
        ldisc = NULL;
    }
    if (backend) {
        backend_free(backend);
        backend = NULL;
    }
    if (term)
        term_provide_backend(term, NULL);
    [self updateSpecials];
}

- (void)remoteExited
{
    int exitcode, close_on_exit;
    if (!exited && backend && (exitcode = backend_exitcode(backend)) >= 0) {
        [self destroyConnection];
        close_on_exit = conf_get_int(conf, CONF_close_on_exit);
        if (close_on_exit == FORCE_ON ||
            (close_on_exit == AUTO && exitcode == 0)) {
            closingConfirmed = YES;
            [self.window close];
        }
    }
}

static void connection_fatal_callback(void *vctx)
{
    MacFrontend *fe = (MacFrontend *)vctx;
    MTSession *s = (__bridge MTSession *)fe->session;
    [s destroyConnection];
}

- (void)connectionFatal:(const char *)msg
{
    BOOL closeAfter = (conf_get_int(conf, CONF_close_on_exit) == FORCE_ON);
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleCritical;
    alert.messageText = [NSString stringWithFormat:@"%s Fatal Error", appname];
    alert.informativeText = @(msg) ?: @"";
    [alert addButtonWithTitle:@"OK"];
    __weak MTSession *weakSelf = self;
    [alert beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse r) {
        MTSession *s = weakSelf;
        if (s && closeAfter) {
            s->closingConfirmed = YES;
            [s.window close];
        }
    }];
    exited = true;   /* suppress normal exit handling */
    queue_toplevel_callback(connection_fatal_callback, &fe);
}

- (void)logEvent:(const char *)string
{
    /* As in Windows PuTTY: keep the start of the log and a rolling
     * window of its end. */
    enum { KEEP_INITIAL = 128, KEEP_RECENT = 1024 };
    char timebuf[40];
    struct tm tm = ltime();
    strftime(timebuf, sizeof(timebuf), "%Y-%m-%d %H:%M:%S", &tm);
    [_eventLog addObject:[NSString stringWithFormat:@"%s\t%s", timebuf,
                          string]];
    if (_eventLog.count > KEEP_INITIAL + KEEP_RECENT) {
        [_eventLog removeObjectAtIndex:KEEP_INITIAL];
        eventLogDropped++;
    }
    mac_event_log_updated(self);
}

/* ----------------------------------------------------------------------
 * Closing.
 */

- (BOOL)windowShouldClose:(NSWindow *)sender
{
    if (closingConfirmed || exited || !conf ||
        !conf_get_bool(conf, CONF_warn_on_close))
        return YES;

    char *additional = NULL;
    if (backend && backend->vt->close_warn_text)
        additional = backend->vt->close_warn_text(backend);
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"%s Exit Confirmation",
                         appname];
    alert.informativeText = [NSString stringWithFormat:
        @"Are you sure you want to close this session?%s%s",
        additional ? "\n" : "", additional ? additional : ""];
    sfree(additional);
    [alert addButtonWithTitle:@"Yes"];
    [alert addButtonWithTitle:@"No"];
    __weak MTSession *weakSelf = self;
    [alert beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse r) {
        MTSession *s = weakSelf;
        if (s && r == NSAlertFirstButtonReturn) {
            s->closingConfirmed = YES;
            [s.window close];
        }
    }];
    return NO;
}

- (void)windowWillClose:(NSNotification *)n
{
    /* The equivalent of delete_inst() in unix/window.c. */
    [self destroyConnection];
    if (term) {
        term_free(term);
        term = NULL;
    }
    if (logctx) {
        log_free(logctx);
        logctx = NULL;
    }
    if (conf) {
        conf_free(conf);
        conf = NULL;
    }
    delete_callbacks_for_context(&fe);
    _termView.session = nil;
    self.window.delegate = nil;
    ((MTSessionWindow *)self.window).session = nil;
    MTSession *keep = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [all_sessions removeObject:keep];
    });
}

/* ----------------------------------------------------------------------
 * Menus. The context menu is Windows PuTTY's system menu.
 */

- (void)updateSpecials
{
    const SessionSpecial *specials = backend ? backend_get_specials(backend)
                                             : NULL;
    if (!specialsMenu)
        specialsMenu = [[NSMenu alloc] initWithTitle:@"Special Command"];
    [specialsMenu removeAllItems];
    hasSpecials = (specials != NULL);
    if (!specials)
        return;

    NSMenu *menu = specialsMenu, *saved = nil;
    int nesting = 1;
    for (int i = 0; nesting > 0; i++) {
        switch (specials[i].code) {
          case SS_SUBMENU: {
            NSMenuItem *item = [[NSMenuItem alloc]
                initWithTitle:@(specials[i].name) action:NULL
                keyEquivalent:@""];
            NSMenu *sub = [[NSMenu alloc] initWithTitle:@(specials[i].name)];
            item.submenu = sub;
            [menu addItem:item];
            saved = menu;
            menu = sub;
            nesting++;
            break;
          }
          case SS_EXITMENU:
            nesting--;
            if (nesting) {
                menu = saved;
                saved = nil;
            }
            break;
          case SS_SEP:
            [menu addItem:[NSMenuItem separatorItem]];
            break;
          default: {
            NSMenuItem *item = [[NSMenuItem alloc]
                initWithTitle:@(specials[i].name)
                       action:@selector(specialCommand:) keyEquivalent:@""];
            item.target = self;
            item.tag = specials[i].code;
            item.representedObject = @(specials[i].arg);
            [menu addItem:item];
            break;
          }
        }
    }
}

- (NSMenu *)specialsMenuCopy
{
    return hasSpecials ? [specialsMenu copy] : nil;
}

- (NSMenu *)contextMenu
{
    NSMenu *m = [[NSMenu alloc] initWithTitle:@""];
    m.autoenablesItems = YES;

#define ITEM(title, sel) do {                                           \
        NSMenuItem *it = [m addItemWithTitle:title action:sel           \
                               keyEquivalent:@""];                      \
        it.target = self;                                               \
    } while (0)

    ITEM(@"Event Log", @selector(showEventLog:));
    if (hasSpecials) {
        NSMenuItem *it = [m addItemWithTitle:@"Special Command"
                                      action:NULL keyEquivalent:@""];
        it.submenu = [self specialsMenuCopy];
    }
    [m addItem:[NSMenuItem separatorItem]];
    {
        NSMenuItem *it = [m addItemWithTitle:@"New Session..."
                                      action:@selector(newSession:)
                               keyEquivalent:@""];
        it.target = NSApp.delegate;
    }
    ITEM(@"Duplicate Session", @selector(duplicateSession:));
    ITEM(@"Restart Session", @selector(restartSession:));
    {
        NSMenuItem *it = [m addItemWithTitle:@"Saved Sessions"
                                      action:NULL keyEquivalent:@""];
        it.submenu = mactty_saved_sessions_menu();
    }
    ITEM(@"Change Settings...", @selector(changeSettings:));
    [m addItem:[NSMenuItem separatorItem]];
    ITEM(@"Copy All to Clipboard", @selector(copyAllToClipboard:));
    ITEM(@"Clear Scrollback", @selector(clearScrollback:));
    ITEM(@"Reset Terminal", @selector(resetTerminal:));
    [m addItem:[NSMenuItem separatorItem]];
    ITEM(@"Full Screen", @selector(toggleFullScreenFromMenu:));
    [m addItem:[NSMenuItem separatorItem]];
    {
        NSMenuItem *it = [m addItemWithTitle:
                              [NSString stringWithFormat:@"About %s", appname]
                                      action:@selector(showAbout:)
                               keyEquivalent:@""];
        it.target = NSApp.delegate;
    }
#undef ITEM
    return m;
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    SEL a = item.action;
    if (a == @selector(restartSession:))
        return backend == NULL && term != NULL;
    if (a == @selector(specialCommand:))
        return backend != NULL;
    if (a == @selector(toggleFullScreenFromMenu:)) {
        item.state = inFullScreen ? NSControlStateValueOn
                                  : NSControlStateValueOff;
        return YES;
    }
    if (a == @selector(copy:) || a == @selector(paste:) ||
        a == @selector(copyAllToClipboard:) ||
        a == @selector(clearScrollback:) || a == @selector(resetTerminal:) ||
        a == @selector(changeSettings:) || a == @selector(duplicateSession:))
        return term != NULL;
    return YES;
}

- (void)specialCommand:(NSMenuItem *)sender
{
    if (backend)
        backend_special(backend, (SessionSpecialCode)sender.tag,
                        [sender.representedObject intValue]);
}

- (IBAction)showEventLog:(id)sender
{
    mac_show_event_log(self);
}

- (IBAction)duplicateSession:(id)sender
{
    if (conf)
        [MTSession openSessionWithConf:conf_copy(conf)];
}

- (IBAction)restartSession:(id)sender
{
    if (!backend && term) {
        logevent(logctx, "----- Session restarted -----");
        term_pwron(term, false);
        [self startBackend];
        if (backend)
            exited = false;
        if (ldisc)
            ldisc_echoedit_update(ldisc);
    }
}

- (IBAction)copy:(id)sender
{
    static const int clips[] = { CLIP_SYSTEM };
    if (term)
        term_request_copy(term, clips, lenof(clips));
}

- (IBAction)paste:(id)sender
{
    if (term)
        term_request_paste(term, CLIP_SYSTEM);
}

- (IBAction)copyAllToClipboard:(id)sender
{
    static const int clips[] = { CLIP_SYSTEM };
    if (term)
        term_copyall(term, clips, lenof(clips));
}

- (IBAction)clearScrollback:(id)sender
{
    if (term)
        term_clrsb(term);
}

- (IBAction)resetTerminal:(id)sender
{
    if (term) {
        term_pwron(term, true);
        if (ldisc)
            ldisc_echoedit_update(ldisc);
    }
}

- (IBAction)toggleFullScreenFromMenu:(id)sender
{
    [self.window toggleFullScreen:nil];
}

/* Command-plus and Command-minus change the font size, like Ctrl-> and
 * Ctrl-< in the GTK front end. */
- (void)changeFontSize:(int)increment
{
    if (!conf)
        return;
    FontSpec *fs = conf_get_fontspec(conf, CONF_font);
    char *name = dupstr(fs->name);
    char *sp = strrchr(name, ' ');
    double size = sp ? atof(sp + 1) : 13;
    if (sp)
        *sp = '\0';
    size += increment;
    if (size < 4 || size > 96) {
        sfree(name);
        return;
    }
    char *newname = dupprintf("%s %g", name, size);
    FontSpec *newfs = fontspec_new(newname);
    FontSpec *oldfs = fontspec_copy(fs);
    conf_set_fontspec(conf, CONF_font, newfs);
    fontspec_free(newfs);
    sfree(newname);
    sfree(name);
    if ([_termView setupFontsFromConf:conf]) {
        conf_set_fontspec(conf, CONF_font, oldfs);
    } else {
        [self applyWindowGeometryForCols:term->cols rows:term->rows];
        term_invalidate(term);
    }
    fontspec_free(oldfs);
}

- (IBAction)biggerFont:(id)sender { [self changeFontSize:+1]; }
- (IBAction)smallerFont:(id)sender { [self changeFontSize:-1]; }

/* ----------------------------------------------------------------------
 * Change Settings.
 */

struct reconfig_ctx {
    void *session;    /* MTSession *, retained */
    Conf *newconf;
};

static void after_change_settings(void *vctx, int retval)
{
    struct reconfig_ctx *ctx = (struct reconfig_ctx *)vctx;
    MTSession *s = (__bridge_transfer MTSession *)ctx->session;
    Conf *newconf = ctx->newconf;
    sfree(ctx);
    s->reconfigWindow = NULL;
    if (retval > 0 && s->conf)
        [s applyNewConf:newconf];
    else
        conf_free(newconf);
}

- (IBAction)changeSettings:(id)sender
{
    if (!conf)
        return;
    if (reconfigWindow) {
        [(__bridge NSWindow *)reconfigWindow makeKeyAndOrderFront:nil];
        return;
    }
    struct reconfig_ctx *ctx = snew(struct reconfig_ctx);
    ctx->session = (__bridge_retained void *)self;
    ctx->newconf = conf_copy(conf);
    term_pre_reconfig(term, ctx->newconf);
    char *title = dupcat(appname, " Reconfiguration");
    reconfigWindow = mactty_config_box(
        title, ctx->newconf, true, backend ? backend_cfg_info(backend) : 0,
        (__bridge void *)self.window, after_change_settings, ctx);
    sfree(title);
}

- (void)applyNewConf:(Conf *)newconf
{
    Conf *oldconf = conf;
    BOOL need_size = NO;
    conf = newconf;

    /* Pass new config data to the logging module */
    log_reconfig(logctx, conf);

    /* Flush the line discipline's edit buffer in the case where local
     * editing has just been disabled. */
    if (ldisc) {
        ldisc_configure(ldisc, conf);
        ldisc_echoedit_update(ldisc);
    }

    /* Pass new config data to the terminal */
    term_reconfig(term, conf);
    [self setupClipboards];

    /* Pass new config data to the back end */
    if (backend)
        backend_reconfig(backend, conf);

    [self cacheConfValues];

    if (conf_get_bool(oldconf, CONF_scrollbar) !=
        conf_get_bool(newconf, CONF_scrollbar)) {
        scrollbarVisible = conf_get_bool(newconf, CONF_scrollbar);
        need_size = YES;
    }
    if (conf_get_bool(oldconf, CONF_alwaysontop) !=
        conf_get_bool(newconf, CONF_alwaysontop))
        self.window.level = conf_get_bool(newconf, CONF_alwaysontop) ?
            NSFloatingWindowLevel : NSNormalWindowLevel;

    if (strcmp(conf_get_fontspec(oldconf, CONF_font)->name,
               conf_get_fontspec(newconf, CONF_font)->name) ||
        strcmp(conf_get_fontspec(oldconf, CONF_boldfont)->name,
               conf_get_fontspec(newconf, CONF_boldfont)->name) ||
        strcmp(conf_get_str(oldconf, CONF_line_codepage),
               conf_get_str(newconf, CONF_line_codepage)) ||
        conf_get_bool(oldconf, CONF_utf8_override) !=
        conf_get_bool(newconf, CONF_utf8_override) ||
        conf_get_int(oldconf, CONF_vtmode) !=
        conf_get_int(newconf, CONF_vtmode) ||
        (_termView.fontsFitted &&
         conf_get_int(oldconf, CONF_resize_action) !=
         conf_get_int(newconf, CONF_resize_action))) {
        NSString *err = [_termView setupFontsFromConf:conf];
        if (err) {
            mactty_message_box((__bridge void *)self.window,
                               "Font setup error", [NSString stringWithFormat:
                @"Could not change fonts in terminal window: %@", err]
                               .UTF8String);
        } else {
            need_size = YES;
        }
        init_ucs(&ucsdata, conf_get_str(conf, CONF_line_codepage),
                 conf_get_bool(conf, CONF_utf8_override), CS_UTF8,
                 conf_get_int(conf, CONF_vtmode));
    }

    if (conf_get_int(oldconf, CONF_width) !=
        conf_get_int(newconf, CONF_width) ||
        conf_get_int(oldconf, CONF_height) !=
        conf_get_int(newconf, CONF_height) ||
        conf_get_int(oldconf, CONF_window_border) !=
        conf_get_int(newconf, CONF_window_border) ||
        conf_get_int(oldconf, CONF_resize_action) !=
        conf_get_int(newconf, CONF_resize_action) ||
        need_size) {
        int w = conf_get_int(newconf, CONF_width);
        int h = conf_get_int(newconf, CONF_height);
        if (conf_get_int(oldconf, CONF_width) == w &&
            conf_get_int(oldconf, CONF_height) == h) {
            /* Only the font or border changed: keep the current grid. */
            w = term->cols;
            h = term->rows;
        }
        [self applyWindowGeometryForCols:w rows:h];
    } else if (conf_get_int(oldconf, CONF_savelines) !=
               conf_get_int(newconf, CONF_savelines)) {
        term_size(term, term->rows, term->cols,
                  conf_get_int(newconf, CONF_savelines));
    }

    term_invalidate(term);
    [_termView setNeedsDisplay:YES];
    conf_free(oldconf);
}

@end
