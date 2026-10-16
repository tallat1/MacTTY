/*
 * agent-socket.h: where Pageant's agent socket lives, and which agent
 * MacTTY's connections use. Used by MacTTY and Pageant.
 */

#ifndef MACTTY_AGENT_SOCKET_H
#define MACTTY_AGENT_SOCKET_H

#include <stdbool.h>

/* The fixed path that links to the live socket: $PUTTYDIR or ~/.putty,
 * then "pageant.sock". */
char *mactty_pageant_link_path(void);
bool mactty_agent_socket_alive(const char *path);
/* The socket of the running Pageant (the link, or where it points if
 * the link is too long to connect to), or NULL. */
char *mactty_pageant_socket(void);
/* Point SSH_AUTH_SOCK at Pageant while it runs, and otherwise back at
 * the agent MacTTY was started with. Called before each connection. */
void mactty_select_agent(void);

#endif
