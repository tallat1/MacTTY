/*
 * config-mac.h: the Mac-specific panels and controls of the
 * configuration box (the counterpart of windows/config.c).
 */

#ifndef MACTTY_CONFIG_MAC_H
#define MACTTY_CONFIG_MAC_H

#include "putty.h"

/* (dialog.h has no include guard, so it is not included here.) */
struct controlbox;

void mac_setup_config_box(struct controlbox *b, bool midsession,
                          int protocol);

/* A serial line has been plugged in while a configuration box is open.
 * If the configured serial line is not there (as when nothing was
 * plugged in when the box opened, and the default fell back to a name
 * that does not exist), the new line takes its place. Returns whether
 * conf changed. */
bool mac_config_serial_line_added(Conf *conf, const char *path);

#endif
