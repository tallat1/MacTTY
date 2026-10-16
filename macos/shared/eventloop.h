/*
 * eventloop.h: PuTTY's event loop (uxsel, timers, toplevel callbacks)
 * on the Core Foundation run loop. Used by MacTTY and Pageant.
 */

#ifndef MACTTY_EVENTLOOP_H
#define MACTTY_EVENTLOOP_H

/* Hooks PuTTY's uxsel, timer and toplevel-callback machinery into the
 * main run loop. Call once, before the first connection or socket. */
void mactty_eventloop_setup(void);

#endif
