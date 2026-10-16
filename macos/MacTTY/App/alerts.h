/*
 * alerts.h: application-wide message boxes and the About box.
 */

#ifndef MACTTY_ALERTS_H
#define MACTTY_ALERTS_H

#include "putty.h"

/* A message box with an OK button: a sheet on 'parent' (an NSWindow *)
 * if it is visible, otherwise application-modal. */
void mactty_message_box(void *parent, const char *title, const char *msg);

void mac_about_box(void);
/* The About button of the configuration box. */
void mactty_about_handler(dlgcontrol *ctrl, dlgparam *dp,
                          void *data, int event);

#ifdef __OBJC__
@class NSString;
/* MacTTY's own version, from Info.plist (see VERSION). */
NSString *mactty_version(void);
#endif

#endif
