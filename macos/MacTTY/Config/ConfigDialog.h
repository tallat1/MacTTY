/*
 * ConfigDialog.h: the configuration box. PuTTY's config.c describes
 * the panels as a controlbox (dialog.h); ConfigDialog.m renders it with
 * AppKit and implements the dlg_* API.
 */

#ifndef MACTTY_CONFIG_DIALOG_H
#define MACTTY_CONFIG_DIALOG_H

#include "putty.h"

/* 'parent' is an NSWindow * or NULL; 'after' is called with 1 for
 * Open/Apply and 0 for Cancel. Returns the dialog's NSWindow * (not
 * retained). */
void *mactty_config_box(const char *title, Conf *conf, bool midsession,
                       int protcfginfo, void *parent,
                       post_dialog_fn_t after, void *afterctx);

/* The name in the Saved Sessions box of the last configuration box
 * closed with Open (to be freed), or NULL. */
char *mactty_config_box_saved_name(void);

#endif
