/*
 * Dialogs.m: the dialog boxes other than the configuration box —
 * security prompts, the log file prompt, the About box and the Event
 * Log. Texts come from the PuTTY core (SeatDialogText), so the wording
 * is PuTTY's own.
 */

#import <Cocoa/Cocoa.h>

#import "Session.h"
#include "putty.h"
#include "dialog.h"
#include "ssh.h"
#include "storage.h"
#include "licence.h"
#include "mactty.h"

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
 * SeatDialogText.
 */

static NSString *more_info_text(SeatDialogText *text)
{
    NSMutableString *s = [NSMutableString string];
    for (SeatDialogTextItem *item = text->items,
             *end = item + text->nitems; item < end; item++) {
        switch (item->type) {
          case SDT_MORE_INFO_KEY:
            [s appendString:ns(item->text)];
            break;
          case SDT_MORE_INFO_VALUE_SHORT:
            [s appendFormat:@": %@\n", ns(item->text)];
            break;
          case SDT_MORE_INFO_VALUE_BLOB:
            [s appendFormat:@":\n%@\n", ns(item->text)];
            break;
          default:
            break;
        }
    }
    return s;
}

const SeatDialogPromptDescriptions *mac_seat_prompt_descriptions(Seat *seat)
{
    static const SeatDialogPromptDescriptions descs = {
        .hk_accept_action = "press \"Accept\"",
        .hk_connect_once_action = "press \"Connect Once\"",
        .hk_cancel_action = "press \"Cancel\"",
        .hk_cancel_action_Participle = "Pressing \"Cancel\"",
        .weak_accept_action = "press \"Yes\"",
        .weak_cancel_action = "press \"No\"",
    };
    return &descs;
}

/* The prompt's callback must not run once the session has gone, so
 * every prompt checks that its session window is still open. */
static BOOL session_alive(MTSession *s)
{
    return s && s->term != NULL;
}

/*
 * The security prompts. PuTTY's core hands over the text as items:
 * paragraphs, "display" items (the host, the fingerprint) and a "more
 * info" section. They are laid out as such: paragraphs as text, display
 * items in monospaced boxes (a fingerprint with a copy button), the
 * instructions after the last display item in smaller type, and More
 * info opening in place.
 */

@interface MTSecurityPrompt : NSObject
@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic, strong) NSScrollView *moreView;
@property (nonatomic, strong) NSStackView *stack;
@property (nonatomic, copy) void (^done)(NSInteger index);
@end

static NSMutableSet<MTSecurityPrompt *> *live_prompts;

static NSTextField *prompt_label(NSString *text, NSFont *font, NSColor *colour)
{
    NSTextField *l = [NSTextField wrappingLabelWithString:text];
    l.font = font;
    if (colour)
        l.textColor = colour;
    l.selectable = YES;
    l.preferredMaxLayoutWidth = 456;
    [l setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                forOrientation:NSLayoutConstraintOrientationVertical];
    return l;
}

@implementation MTSecurityPrompt

- (void)copyText:(NSButton *)sender
{
    NSPasteboard *pb = mactty_pasteboard();
    [pb clearContents];
    [pb setString:sender.identifier ?: @"" forType:NSPasteboardTypeString];
}

- (NSView *)displayBox:(NSString *)text copyable:(BOOL)copyable
{
    NSView *box = [[NSView alloc] init];
    box.wantsLayer = YES;
    box.layer.cornerRadius = 6;
    box.layer.borderWidth = 1;
    box.layer.borderColor = NSColor.separatorColor.CGColor;
    box.layer.backgroundColor = NSColor.textBackgroundColor.CGColor;
    box.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *t = [NSTextField wrappingLabelWithString:text];
    t.font = [NSFont monospacedSystemFontOfSize:12.5
                                         weight:NSFontWeightRegular];
    t.selectable = YES;
    t.translatesAutoresizingMaskIntoConstraints = NO;
    t.preferredMaxLayoutWidth = copyable ? 400 : 436;
    [box addSubview:t];

    NSMutableArray *c = [NSMutableArray arrayWithArray:@[
        [t.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:10],
        [t.topAnchor constraintEqualToAnchor:box.topAnchor constant:8],
        [t.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-8],
    ]];
    if (copyable) {
        NSButton *b = [NSButton buttonWithImage:
            [NSImage imageWithSystemSymbolName:@"doc.on.doc"
                      accessibilityDescription:@"Copy fingerprint"]
                                         target:self
                                         action:@selector(copyText:)];
        b.bezelStyle = NSBezelStyleAccessoryBarAction;
        b.toolTip = @"Copy fingerprint";
        b.identifier = text;
        b.translatesAutoresizingMaskIntoConstraints = NO;
        [box addSubview:b];
        [c addObjectsFromArray:@[
            [b.trailingAnchor constraintEqualToAnchor:box.trailingAnchor
                                             constant:-6],
            [b.centerYAnchor constraintEqualToAnchor:box.centerYAnchor],
            [t.trailingAnchor constraintLessThanOrEqualToAnchor:b.leadingAnchor
                                                       constant:-6],
        ]];
    } else {
        [c addObject:[t.trailingAnchor constraintLessThanOrEqualToAnchor:
                         box.trailingAnchor constant:-10]];
    }
    [NSLayoutConstraint activateConstraints:c];
    return box;
}

- (void)buttonPressed:(NSButton *)sender
{
    NSWindow *parent = self.panel.sheetParent;
    if (parent)
        [parent endSheet:self.panel returnCode:sender.tag];
}

- (void)toggleMore:(NSButton *)sender
{
    self.moreView.hidden = (sender.state != NSControlStateValueOn);
    [self fitPanel];
}

- (void)fitPanel
{
    [self.stack layoutSubtreeIfNeeded];
    NSSize sz = self.stack.fittingSize;
    NSRect f = self.panel.frame;
    NSRect nf = [self.panel frameRectForContentRect:
                    NSMakeRect(0, 0, 500, sz.height)];
    nf.origin.x = f.origin.x;
    nf.origin.y = NSMaxY(f) - nf.size.height;
    [self.panel setFrame:nf display:YES animate:self.panel.isVisible];
}

+ (void)showOn:(NSWindow *)window text:(SeatDialogText *)text
       buttons:(NSArray<NSString *> *)titles defaultIndex:(NSInteger)def
   cancelIndex:(NSInteger)cancel done:(void (^)(NSInteger index))done
{
    MTSecurityPrompt *p = [MTSecurityPrompt new];
    p.done = done;

    NSString *title = nil, *more = more_info_text(text);
    BOOL scary = NO;
    NSInteger lastDisplay = -1;
    for (int i = 0; i < text->nitems; i++) {
        if (text->items[i].type == SDT_DISPLAY)
            lastDisplay = i;
        if (text->items[i].type == SDT_SCARY_HEADING)
            scary = YES;
        if (text->items[i].type == SDT_TITLE)
            title = ns(text->items[i].text);
    }

    NSStackView *stack = [[NSStackView alloc] init];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 10;
    stack.edgeInsets = NSEdgeInsetsMake(20, 22, 18, 22);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    p.stack = stack;

    /* Heading: a shield (a warning sign for the frightening ones). */
    NSImageView *icon = [NSImageView imageViewWithImage:
        [NSImage imageWithSystemSymbolName:
                     scary ? @"exclamationmark.triangle.fill"
                           : @"exclamationmark.shield"
                  accessibilityDescription:@"Warning"]];
    icon.symbolConfiguration = [NSImageSymbolConfiguration
        configurationWithPointSize:26 weight:NSFontWeightRegular];
    icon.contentTintColor = scary ? NSColor.systemRedColor
                                  : NSColor.systemOrangeColor;
    NSTextField *heading = [NSTextField labelWithString:
        title ?: [NSString stringWithFormat:@"%s Security Alert", appname]];
    heading.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    NSStackView *head = [NSStackView stackViewWithViews:@[icon, heading]];
    head.spacing = 10;
    [stack addArrangedSubview:head];

    for (int i = 0; i < text->nitems; i++) {
        SeatDialogTextItem *item = &text->items[i];
        NSString *t = ns(item->text);
        switch (item->type) {
          case SDT_PARA:
            if (i > lastDisplay && lastDisplay >= 0)
                [stack addArrangedSubview:prompt_label(
                    t, [NSFont systemFontOfSize:NSFont.smallSystemFontSize],
                    NSColor.secondaryLabelColor)];
            else
                [stack addArrangedSubview:prompt_label(
                    t, [NSFont systemFontOfSize:NSFont.systemFontSize], nil)];
            break;
          case SDT_SCARY_HEADING:
            [stack addArrangedSubview:prompt_label(
                t, [NSFont boldSystemFontOfSize:NSFont.systemFontSize],
                NSColor.systemRedColor)];
            break;
          case SDT_DISPLAY: {
            BOOL fp = [t containsString:@"SHA256:"] ||
                [t containsString:@"MD5:"];
            NSView *box = [p displayBox:t copyable:fp];
            [stack addArrangedSubview:box];
            [box.widthAnchor constraintEqualToConstant:456].active = YES;
            break;
          }
          default:
            break;
        }
    }

    NSView *discloseRow = nil;
    if (more.length) {
        NSTextView *tv = [[NSTextView alloc] initWithFrame:
                             NSMakeRect(0, 0, 456, 140)];
        tv.string = more;
        tv.editable = NO;
        tv.font = [NSFont monospacedSystemFontOfSize:11
                                              weight:NSFontWeightRegular];
        tv.textContainerInset = NSMakeSize(4, 4);
        NSScrollView *sv = [[NSScrollView alloc] initWithFrame:tv.frame];
        sv.documentView = tv;
        sv.hasVerticalScroller = YES;
        sv.borderType = NSBezelBorder;
        sv.translatesAutoresizingMaskIntoConstraints = NO;
        [sv.widthAnchor constraintEqualToConstant:456].active = YES;
        [sv.heightAnchor constraintEqualToConstant:140].active = YES;
        sv.hidden = YES;
        [stack addArrangedSubview:sv];
        p.moreView = sv;

        NSButton *disclose = [NSButton buttonWithTitle:@""
                                                target:p
                                                action:@selector(toggleMore:)];
        disclose.bezelStyle = NSBezelStyleDisclosure;
        [disclose setButtonType:NSButtonTypePushOnPushOff];
        disclose.accessibilityLabel = @"More info";
        NSTextField *dl = [NSTextField labelWithString:@"More info"];
        NSStackView *d = [NSStackView stackViewWithViews:@[disclose, dl]];
        d.spacing = 4;
        discloseRow = d;
    }

    NSMutableArray<NSView *> *row = [NSMutableArray array];
    if (discloseRow)
        [row addObject:discloseRow];
    NSView *spacer = [[NSView alloc] init];
    [spacer setContentHuggingPriority:1
                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    [row addObject:spacer];
    for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
        NSButton *b = [NSButton buttonWithTitle:titles[i] target:p
                                         action:@selector(buttonPressed:)];
        b.tag = i;
        if (i == def)
            b.keyEquivalent = @"\r";
        else if (i == cancel)
            b.keyEquivalent = @"\033";
        [row addObject:b];
    }
    NSStackView *buttons = [NSStackView stackViewWithViews:row];
    buttons.spacing = 10;
    [stack addArrangedSubview:buttons];
    [buttons.widthAnchor constraintEqualToConstant:456].active = YES;
    [stack setCustomSpacing:16 afterView:stack.arrangedSubviews[
        stack.arrangedSubviews.count - 2]];

    NSPanel *panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 500, 300)
                  styleMask:NSWindowStyleMaskTitled
                    backing:NSBackingStoreBuffered defer:YES];
    [panel.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:
                                 panel.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:
                                  panel.contentView.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:
                                panel.contentView.bottomAnchor],
    ]];
    [stack.widthAnchor constraintEqualToConstant:500].active = YES;
    p.panel = panel;
    [panel setContentSize:NSMakeSize(500, stack.fittingSize.height)];

    if (!live_prompts)
        live_prompts = [NSMutableSet set];
    [live_prompts addObject:p];
    [window beginSheet:panel completionHandler:^(NSModalResponse r) {
        [live_prompts removeObject:p];
        if (p.done)
            p.done(r);
    }];
}

@end

SeatPromptResult mac_seat_confirm_ssh_host_key(
    Seat *seat, const char *host, int port, const char *keytype,
    char *keystr, SeatDialogText *text, HelpCtx helpctx,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx)
{
    MTSession *s = session_from_seat(seat);
    char *h = dupstr(host), *kt = dupstr(keytype), *ks = dupstr(keystr);
    __weak MTSession *weak = s;
    [MTSecurityPrompt showOn:s.window text:text
                     buttons:@[@"Cancel", @"Connect Once", @"Accept"]
                defaultIndex:2 cancelIndex:0 done:^(NSInteger r) {
        MTSession *ss = weak;
        if (session_alive(ss)) {
            SeatPromptResult result;
            if (r == 2) {
                store_host_key(&ss->fe.seat, h, port, kt, ks);
                result = SPR_OK;
            } else if (r == 1) {
                result = SPR_OK;
            } else {
                result = SPR_USER_ABORT;
            }
            callback(ctx, result);
        }
        sfree(h);
        sfree(kt);
        sfree(ks);
    }];
    return SPR_INCOMPLETE;
}

static SeatPromptResult yes_no_prompt(
    Seat *seat, SeatDialogText *text,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx)
{
    MTSession *s = session_from_seat(seat);
    __weak MTSession *weak = s;
    [MTSecurityPrompt showOn:s.window text:text buttons:@[@"No", @"Yes"]
                defaultIndex:1 cancelIndex:0 done:^(NSInteger r) {
        if (session_alive(weak))
            callback(ctx, r == 1 ? SPR_OK : SPR_USER_ABORT);
    }];
    return SPR_INCOMPLETE;
}

SeatPromptResult mac_seat_confirm_weak_crypto_primitive(
    Seat *seat, SeatDialogText *text,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx)
{
    return yes_no_prompt(seat, text, callback, ctx);
}

SeatPromptResult mac_seat_confirm_weak_cached_hostkey(
    Seat *seat, SeatDialogText *text,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx)
{
    return yes_no_prompt(seat, text, callback, ctx);
}

/* ----------------------------------------------------------------------
 * "The session log file already exists".
 */

int mac_askappend(MTSession *s, Filename *filename,
                  void (*callback)(void *ctx, int result), void *ctx)
{
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"%s Log to File",
                         appname];
    alert.informativeText = [NSString stringWithFormat:
        @"The session log file \"%s\" already exists. You can overwrite "
        "it with a new session log, append your session log to the end "
        "of it, or disable session logging for this session.",
        filename->path];
    [alert addButtonWithTitle:@"Overwrite"];
    [alert addButtonWithTitle:@"Append"];
    [alert addButtonWithTitle:@"Disable"];
    __weak MTSession *weak = s;
    [alert beginSheetModalForWindow:s.window
                  completionHandler:^(NSModalResponse r) {
        if (!session_alive(weak))
            return;
        int result = (r == NSAlertFirstButtonReturn ? 2 :
                      r == NSAlertSecondButtonReturn ? 1 : 0);
        callback(ctx, result);
    }];
    return -1;                         /* dialog still in progress */
}

/* ----------------------------------------------------------------------
 * About box.
 */

void mac_about_box(void)
{
    char *bi = buildinfo("\n");
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"%s", appname];
    alert.informativeText = [NSString stringWithFormat:
        @"A native macOS port of PuTTY.\n\n%s\n\n%s\n\n"
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

/* ----------------------------------------------------------------------
 * Event Log: one window per session, listing the events with their
 * times. Lines can be selected and copied, as in Windows PuTTY.
 */

@interface MTEventLogController : NSWindowController
    <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>
@property (nonatomic, weak) MTSession *session;
@property (nonatomic, strong) NSTableView *table;
- (void)reload;
@end

static NSMapTable<MTSession *, MTEventLogController *> *event_logs;

@implementation MTEventLogController

- (instancetype)initWithSession:(MTSession *)s
{
    NSWindow *w = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 640, 320)
                  styleMask:(NSWindowStyleMaskTitled |
                             NSWindowStyleMaskClosable |
                             NSWindowStyleMaskResizable)
                    backing:NSBackingStoreBuffered defer:YES];
    if (!(self = [super initWithWindow:w]))
        return nil;
    self.session = s;
    w.releasedWhenClosed = NO;
    w.delegate = self;
    w.title = [NSString stringWithFormat:@"%s Event Log", appname];
    w.minSize = NSMakeSize(360, 160);

    NSView *content = w.contentView;
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:
        NSMakeRect(12, 48, 616, 260)];
    sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    sv.borderType = NSBezelBorder;
    sv.hasVerticalScroller = YES;
    sv.hasHorizontalScroller = YES;
    NSTableView *tv = [[NSTableView alloc] initWithFrame:sv.bounds];
    tv.headerView = nil;
    tv.allowsMultipleSelection = YES;
    tv.style = NSTableViewStylePlain;
    tv.rowHeight = 15;
    tv.intercellSpacing = NSMakeSize(8, 1);
    tv.columnAutoresizingStyle = NSTableViewNoColumnAutoresizing;
    NSTableColumn *tcol = [[NSTableColumn alloc] initWithIdentifier:@"time"];
    tcol.width = 130;
    NSTableColumn *ecol = [[NSTableColumn alloc] initWithIdentifier:@"event"];
    ecol.width = 1400;
    for (NSTableColumn *c in @[tcol, ecol]) {
        NSTextFieldCell *cell = [NSTextFieldCell new];
        cell.font = [NSFont userFixedPitchFontOfSize:11];
        c.dataCell = cell;
        c.editable = NO;
        [tv addTableColumn:c];
    }
    tv.dataSource = self;
    tv.delegate = self;
    sv.documentView = tv;
    [content addSubview:sv];
    self.table = tv;

    NSButton *close = [NSButton buttonWithTitle:@"Close" target:self
                                         action:@selector(closeLog:)];
    close.keyEquivalent = @"\033";
    close.frame = NSMakeRect(640 - 12 - 90, 12, 90, 28);
    close.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    NSButton *copy = [NSButton buttonWithTitle:@"Copy" target:self
                                        action:@selector(copy:)];
    copy.frame = NSMakeRect(640 - 12 - 90 - 8 - 90, 12, 90, 28);
    copy.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [content addSubview:close];
    [content addSubview:copy];

    NSWindow *pw = s.window;
    if (pw) {
        NSRect pf = pw.frame;
        [w setFrameTopLeftPoint:NSMakePoint(NSMinX(pf) + 30, NSMaxY(pf) - 30)];
    }
    return self;
}

- (void)reload
{
    NSInteger rows = self.table.numberOfRows;
    BOOL atEnd = rows == 0 ||
        NSMaxY(self.table.visibleRect) >= NSMaxY(self.table.bounds) - 20;
    [self.table reloadData];
    if (atEnd && self.table.numberOfRows > 0)
        [self.table scrollRowToVisible:self.table.numberOfRows - 1];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv
{
    return self.session.eventLog.count;
}

- (id)tableView:(NSTableView *)tv objectValueForTableColumn:(NSTableColumn *)col
            row:(NSInteger)row
{
    NSArray *log = self.session.eventLog;
    if (row >= (NSInteger)log.count)
        return @"";
    NSArray *parts = [log[row] componentsSeparatedByString:@"\t"];
    if ([col.identifier isEqualToString:@"time"])
        return parts.firstObject;
    return parts.count > 1 ? parts[1] : @"";
}

- (void)copy:(id)sender
{
    NSArray *log = self.session.eventLog;
    NSIndexSet *sel = self.table.selectedRowIndexes;
    if (sel.count == 0)
        sel = [NSIndexSet indexSetWithIndexesInRange:
                   NSMakeRange(0, log.count)];
    NSMutableString *s = [NSMutableString string];
    [sel enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
        if (i < log.count)
            [s appendFormat:@"%@\n", log[i]];
    }];
    NSPasteboard *pb = mactty_pasteboard();
    [pb clearContents];
    [pb setString:s forType:NSPasteboardTypeString];
}

- (void)closeLog:(id)sender
{
    [self.window performClose:nil];
}

- (void)windowWillClose:(NSNotification *)n
{
    MTSession *s = self.session;
    if (s)
        [event_logs removeObjectForKey:s];
}

@end

void mac_show_event_log(MTSession *session)
{
    if (!event_logs)
        event_logs = [NSMapTable weakToStrongObjectsMapTable];
    MTEventLogController *c = [event_logs objectForKey:session];
    if (!c) {
        c = [[MTEventLogController alloc] initWithSession:session];
        [event_logs setObject:c forKey:session];
    }
    [c.window makeKeyAndOrderFront:nil];
    [c reload];
    if (c.table.numberOfRows > 0)
        [c.table scrollRowToVisible:c.table.numberOfRows - 1];
}

void mac_event_log_updated(MTSession *session)
{
    MTEventLogController *c = [event_logs objectForKey:session];
    if (c)
        [c reload];
}
