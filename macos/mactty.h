/*
 * mactty.h: declarations shared between the modules of the MacTTY
 * Cocoa front end.
 *
 * The PuTTY core (back ends, terminal emulator, settings, crypto) is
 * used unchanged. This front end supplies what the GTK front end in
 * unix/window.c, unix/dialog.c and unix/gtk-common.c supplies there:
 * TermWin, Seat, LogPolicy, the dialog-box API of dialog.h, and the
 * event-loop hooks (uxsel, timers, toplevel callbacks).
 */

#ifndef MACTTY_H
#define MACTTY_H

#include "putty.h"

/* eventloop.m */
void mactty_eventloop_setup(void);

/* config-mac.c: Mac-specific additions to the configuration box. */
void mac_setup_config_box(struct controlbox *b, bool midsession,
                          int protocol);
/* Handler for the About button, implemented in Dialogs.m. */
void mactty_about_handler(dlgcontrol *ctrl, dlgparam *dp,
                          void *data, int event);

/* ConfigDialog.m: the controlbox renderer. 'parent' is an NSWindow *
 * or NULL; 'after' is called with 1 for Open/Apply and 0 for Cancel.
 * Returns the dialog's NSWindow * (not retained). */
void *mactty_config_box(const char *title, Conf *conf, bool midsession,
                       int protcfginfo, void *parent,
                       post_dialog_fn_t after, void *afterctx);

/* Dialogs.m: simple message boxes. */
void mactty_message_box(void *parent, const char *title, const char *msg);

/* Font specification helpers (TerminalView.m). A FontSpec name is
 * "<PostScript name> <point size>", e.g. "Menlo-Regular 13". */
char *mactty_font_display_name(const char *fontspec_name);

/* Serial line enumeration (platform-mac.m). Returns a NULL-terminated
 * array of /dev/cu.* paths; free with mactty_free_string_array. */
char **mactty_serial_lines(void);
void mactty_free_string_array(char **array);

#endif
