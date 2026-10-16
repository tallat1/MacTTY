/*
 * recent-sessions.h: the sessions MacTTY connected to lately (Open
 * Recent, the Dock menu, the host list), and one-line summaries of
 * saved sessions.
 */

#ifndef MACTTY_RECENT_SESSIONS_H
#define MACTTY_RECENT_SESSIONS_H

#include "putty.h"

void mactty_note_recent_session(Conf *conf, const char *saved_name);
void mactty_clear_recent_sessions(void);
/* NULL-terminated, to be freed with mactty_free_string_array. */
char **mactty_recent_hosts(void);
/* "SSH · host", "Serial · 115200": what a saved session connects to,
 * or NULL. */
char *mactty_saved_session_detail(const char *name);
/* Whether saved session 'name' connects where conf does. */
bool mactty_saved_session_matches(const char *name, Conf *conf);

#ifdef __OBJC__
@class NSArray, NSDictionary, NSString;
NSArray *mactty_recent_sessions(void);
NSString *mactty_recent_title(NSDictionary *entry);
NSString *mactty_recent_detail(NSDictionary *entry);
Conf *mactty_conf_for_recent(NSDictionary *entry);
#endif

#endif
