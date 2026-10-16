/*
 * SecurityPrompt.h: the questions a session asks while connecting.
 * These are the Seat methods that need a dialog; MTSession's Seat
 * hands them over to here.
 */

#import <Cocoa/Cocoa.h>

#include "putty.h"

@class MTSession;

SeatPromptResult mac_seat_confirm_ssh_host_key(
    Seat *seat, const char *host, int port, const char *keytype,
    char *keystr, SeatDialogText *text, HelpCtx helpctx,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx);
SeatPromptResult mac_seat_confirm_weak_crypto_primitive(
    Seat *seat, SeatDialogText *text,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx);
SeatPromptResult mac_seat_confirm_weak_cached_hostkey(
    Seat *seat, SeatDialogText *text,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx);
const SeatDialogPromptDescriptions *mac_seat_prompt_descriptions(Seat *seat);

/* "The session log file already exists": 2 overwrite, 1 append,
 * 0 disable, or -1 while the sheet is up (then 'callback' answers). */
int mac_askappend(MTSession *session, Filename *filename,
                  void (*callback)(void *ctx, int result), void *ctx);
