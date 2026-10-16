/*
 * EventLog.m: the Event Log window of a session.
 */

#import <Cocoa/Cocoa.h>

#include "putty.h"
#import "Session/Session.h"
#import "Session/EventLog.h"

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
