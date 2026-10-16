/*
 * tools.m: helpers shared by MacTTYgen and Pageant (see tools.h).
 */

#import "tools.h"

#include "licence.h"

NSString *mt_ns(const char *s)
{
    if (!s)
        return @"";
    NSString *ret = [NSString stringWithUTF8String:s];
    if (!ret)
        ret = [[NSString alloc] initWithBytes:s length:strlen(s)
                                     encoding:NSISOLatin1StringEncoding];
    return ret ?: @"";
}

bool mt_background_mode(void)
{
    const char *bg = getenv("MACTTY_BACKGROUND");
    return bg && *bg && *bg != '0';
}

void mt_activate(void)
{
    if (!mt_background_mode())
        [NSApp activateIgnoringOtherApps:YES];
}

/* Pageant lives in the menu bar and need not be the active application
 * when it asks something: its dialogs must stay in sight regardless. */
void mt_keep_visible(NSWindow *w)
{
    w.hidesOnDeactivate = NO;
    if (NSApp.activationPolicy != NSApplicationActivationPolicyRegular)
        w.level = NSFloatingWindowLevel;
}

static NSModalResponse run_alert(NSAlert *alert)
{
    mt_activate();
    [alert layout];
    mt_keep_visible(alert.window);
    return [alert runModal];
}

void mt_error_box(NSString *title, NSString *msg)
{
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleCritical;
    alert.messageText = title;
    alert.informativeText = msg ?: @"";
    [alert addButtonWithTitle:@"OK"];
    run_alert(alert);
}

void mt_info_box(NSString *title, NSString *msg)
{
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = title;
    alert.informativeText = msg ?: @"";
    [alert addButtonWithTitle:@"OK"];
    run_alert(alert);
}

bool mt_ask(NSString *title, NSString *msg, NSString *yes, NSString *no)
{
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = title;
    alert.informativeText = msg ?: @"";
    [alert addButtonWithTitle:yes];
    [alert addButtonWithTitle:no];
    return run_alert(alert) == NSAlertFirstButtonReturn;
}

char *mt_passphrase_prompt(NSString *title, NSString *heading,
                           const char *comment)
{
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = heading;
    alert.informativeText = comment ? mt_ns(comment) : @"";
    NSSecureTextField *field = [[NSSecureTextField alloc]
                                   initWithFrame:NSMakeRect(0, 0, 260, 22)];
    alert.accessoryView = field;
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert layout];
    alert.window.title = title;
    alert.window.initialFirstResponder = field;

    NSModalResponse r = run_alert(alert);
    char *ret = NULL;
    if (r == NSAlertFirstButtonReturn)
        ret = dupstr(field.stringValue.UTF8String ?: "");
    field.stringValue = @"";
    return ret;
}

void mt_about_box(const char *toolname, const char *description)
{
    char *bi = buildinfo("\n");
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = mt_ns(toolname);
    alert.informativeText = [NSString stringWithFormat:
        @"%s\n\n%s\n\n%s\n\n"
        "PuTTY is copyright " SHORT_COPYRIGHT_DETAILS ". All rights reserved.",
        description, ver, bi];
    sfree(bi);
    [alert addButtonWithTitle:@"Close"];
    [alert addButtonWithTitle:@"View Licence"];
    [alert addButtonWithTitle:@"Visit Web Site"];
    NSModalResponse r = run_alert(alert);
    if (r == NSAlertSecondButtonReturn) {
        NSAlert *lic = [[NSAlert alloc] init];
        lic.messageText = @"PuTTY Licence";
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
        run_alert(lic);
    } else if (r == NSAlertThirdButtonReturn) {
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:
            @"https://www.chiark.greenend.org.uk/~sgtatham/putty/"]];
    }
}

NSPasteboard *mt_pasteboard(void)
{
    const char *name = getenv("MACTTY_PASTEBOARD");
    return (name && *name) ? [NSPasteboard pasteboardWithName:@(name)]
                           : NSPasteboard.generalPasteboard;
}

void mt_open_manual(NSString *page)
{
    NSString *url = [@"https://the.earth.li/~sgtatham/putty/0.85/htmldoc/"
                     stringByAppendingString:page];
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:url]];
}

NSMenuItem *mt_add_item(NSMenu *m, NSString *title, SEL action, id target,
                        NSString *key, NSEventModifierFlags mods)
{
    NSMenuItem *it = [m addItemWithTitle:title action:action
                           keyEquivalent:key ?: @""];
    if (key)
        it.keyEquivalentModifierMask = mods;
    it.target = target;
    return it;
}

NSMenu *mt_edit_menu(void)
{
    NSEventModifierFlags cmd = NSEventModifierFlagCommand;
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    mt_add_item(edit, @"Undo", @selector(undo:), nil, @"z", cmd);
    mt_add_item(edit, @"Redo", @selector(redo:), nil, @"z",
                cmd | NSEventModifierFlagShift);
    [edit addItem:[NSMenuItem separatorItem]];
    mt_add_item(edit, @"Cut", @selector(cut:), nil, @"x", cmd);
    mt_add_item(edit, @"Copy", @selector(copy:), nil, @"c", cmd);
    mt_add_item(edit, @"Paste", @selector(paste:), nil, @"v", cmd);
    mt_add_item(edit, @"Select All", @selector(selectAll:), nil, @"a", cmd);
    return edit;
}
