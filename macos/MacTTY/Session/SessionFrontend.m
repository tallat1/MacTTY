/*
 * SessionFrontend.m: the session as PuTTY sees it. The terminal draws
 * and asks for things through TermWin, the back end talks to the user
 * through Seat, and logging goes through LogPolicy; each callback here
 * finds its MTSession and hands over to it, to the terminal view, or to
 * the session's dialogs. This is the counterpart of the TermWin, Seat
 * and LogPolicy methods in unix/window.c.
 */

#include <wchar.h>

#include "putty.h"
#import "Session/SessionInternal.h"
#import "Session/SecurityPrompt.h"
#import "Terminal/TerminalView.h"
#import "App/alerts.h"

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

const TermWinVtable mac_termwin_vt = {
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

const SeatVtable mac_seat_vt = {
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

const LogPolicyVtable mac_logpolicy_vt = {
    .eventlog = mac_eventlog,
    .askappend = mac_lp_askappend,
    .logging_error = mac_logging_error,
    .verbose = null_lp_verbose_yes,
};
