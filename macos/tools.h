/*
 * tools.h: helpers shared by the two companion applications, MacTTYgen
 * (the counterpart of PuTTYgen) and Pageant. They are separate
 * programs, as on Windows, and use none of the terminal front end.
 */

#import <Cocoa/Cocoa.h>

#include "putty.h"

/* A C string from PuTTY as an NSString (never nil). */
NSString *mt_ns(const char *s);

/* Bring the application to the front, unless MACTTY_BACKGROUND is set
 * (automated tests must not take the keyboard focus from the user). */
void mt_activate(void);
bool mt_background_mode(void);
/* Keep a dialog visible while the application is not active (for
 * Pageant, which has no Dock icon to bring it back). */
void mt_keep_visible(NSWindow *w);

/* Message boxes in the style of PuTTY's MessageBox calls. */
void mt_error_box(NSString *title, NSString *msg);
void mt_info_box(NSString *title, NSString *msg);
/* A warning with two buttons; returns true for the first one. */
bool mt_ask(NSString *title, NSString *msg, NSString *yes, NSString *no);

/* Modal passphrase prompt, as PuTTYgen's and Pageant's "Enter
 * Passphrase" dialog: 'heading' above, the key comment below it.
 * Returns a dynamically allocated passphrase (free with burnstr), or
 * NULL if the user cancelled. */
char *mt_passphrase_prompt(NSString *title, NSString *heading,
                           const char *comment);

/* The About box of a companion tool: name, version, build info,
 * licence and web site, as in PuTTY's About boxes. */
void mt_about_box(const char *toolname, const char *description);

/* The pasteboard to copy to: the general one, or the one named by
 * MACTTY_PASTEBOARD (as in MacTTY, so tests never touch the user's
 * clipboard). */
NSPasteboard *mt_pasteboard(void);

/* Open a chapter of the PuTTY User Manual (e.g. "Chapter8.html"). */
void mt_open_manual(NSString *page);

/* A menu item with an optional key equivalent. */
NSMenuItem *mt_add_item(NSMenu *m, NSString *title, SEL action, id target,
                        NSString *key, NSEventModifierFlags mods);
/* The standard Edit menu (Cut/Copy/Paste/Select All). */
NSMenu *mt_edit_menu(void);
