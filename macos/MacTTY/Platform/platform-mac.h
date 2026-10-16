/*
 * platform-mac.h: what MacTTY adds to PuTTY's platform layer — the
 * serial lines of this Mac. (platform-mac.m also implements PuTTY's
 * platform hooks: defaults, nonfatal, cleanup_exit, ...)
 */

#ifndef MACTTY_PLATFORM_MAC_H
#define MACTTY_PLATFORM_MAC_H

/* The /dev/cu.* paths, NULL-terminated; free with
 * mactty_free_string_array. */
char **mactty_serial_lines(void);
void mactty_free_string_array(char **array);
/* What is behind a serial line, e.g. "FT232R USB UART · FTDI", from
 * the USB device it belongs to; NULL if nothing is known. */
char *mactty_serial_line_description(const char *path);

#endif
