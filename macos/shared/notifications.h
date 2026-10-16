/*
 * notifications.h: messages between the applications.
 */

#ifndef MACTTY_NOTIFICATIONS_H
#define MACTTY_NOTIFICATIONS_H

/* The distributed notification Pageant posts to open a session in a
 * running MacTTY (userInfo: "pid" of the MacTTY addressed, optional
 * "session" to load). */
#define MACTTY_OPEN_SESSION_NOTIFICATION "org.mactty.MacTTY.OpenSession"

#endif
