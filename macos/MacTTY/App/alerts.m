/*
 * alerts.m: application-wide message boxes and the About box.
 */

#import <Cocoa/Cocoa.h>

#include "putty.h"
#include "dialog.h"
#include "licence.h"
#import "App/alerts.h"

static NSString *ns(const char *s)
{
    NSString *r = s ? [NSString stringWithUTF8String:s] : nil;
    return r ?: @"";
}

/* ----------------------------------------------------------------------
 * Simple message boxes.
 */

void mactty_message_box(void *parent, const char *title, const char *msg)
{
    NSWindow *w = (__bridge NSWindow *)parent;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = ns(title);
    alert.informativeText = ns(msg);
    [alert addButtonWithTitle:@"OK"];
    if (w && w.isVisible)
        [alert beginSheetModalForWindow:w completionHandler:nil];
    else
        [alert runModal];
}

void mactty_about_handler(dlgcontrol *ctrl, dlgparam *dp,
                          void *data, int event)
{
    if (event == EVENT_ACTION)
        mac_about_box();
}

/* ----------------------------------------------------------------------
 * About box.
 */

/* MacTTY's own version, from Info.plist (see VERSION); ver[] is the
 * version of PuTTY it is built on. */
NSString *mactty_version(void)
{
    return NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"";
}

void mac_about_box(void)
{
    char *bi = buildinfo("\n");
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"%s %@", appname,
                         mactty_version()];
    alert.informativeText = [NSString stringWithFormat:
        @"A native macOS port of PuTTY.\n\nBased on PuTTY %s\n\n%s\n\n"
        "PuTTY is copyright " SHORT_COPYRIGHT_DETAILS ". All rights reserved.",
        ver, bi];
    sfree(bi);
    [alert addButtonWithTitle:@"Close"];
    [alert addButtonWithTitle:@"View Licence"];
    [alert addButtonWithTitle:@"Visit Web Site"];
    NSModalResponse r = [alert runModal];
    if (r == NSAlertSecondButtonReturn) {
        NSAlert *lic = [[NSAlert alloc] init];
        lic.messageText = [NSString stringWithFormat:@"%s Licence", appname];
        NSTextView *tv = [[NSTextView alloc] initWithFrame:
                             NSMakeRect(0, 0, 460, 300)];
        tv.string = @(LICENCE_TEXT("\n\n"));
        tv.editable = NO;
        NSScrollView *sv = [[NSScrollView alloc] initWithFrame:tv.frame];
        sv.documentView = tv;
        sv.hasVerticalScroller = YES;
        sv.borderType = NSBezelBorder;
        lic.accessoryView = sv;
        [lic addButtonWithTitle:@"OK"];
        [lic runModal];
    } else if (r == NSAlertThirdButtonReturn) {
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:
            @"https://www.chiark.greenend.org.uk/~sgtatham/putty/"]];
    }
}
