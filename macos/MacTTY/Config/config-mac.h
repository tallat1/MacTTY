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

#endif
