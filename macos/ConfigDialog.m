/*
 * ConfigDialog.m: renders PuTTY's portable control-box descriptions
 * (dialog.h) with AppKit, and implements the dlg_* API that the
 * handlers in config.c call back into.
 *
 * Because the panels come from config.c itself, the configuration box
 * has exactly the categories, controls and behaviour of PuTTY's. The
 * layout mirrors Windows PuTTY: a category tree on the left, the panel
 * on the right, and About / Open / Cancel along the bottom.
 */

#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "putty.h"
#include "dialog.h"
#include "storage.h"
#include "mactty.h"

@class MTControlBox;

struct dlgparam {
    void *box;                         /* MTControlBox *, not retained */
};

static MTControlBox *box_of(dlgparam *dp)
{
    return (__bridge MTControlBox *)dp->box;
}

/* Metrics for small controls, which keep the panels as compact as
 * PuTTY's own. */
static const CGFloat kMargin = 12;
static const CGFloat kTreeWidth = 168;
static const CGFloat kPanelWidth = 410;
static const CGFloat kRowGap = 5;
static const CGFloat kColGap = 10;
static const CGFloat kSetGap = 8;
static const CGFloat kLabelH = 14;
static const CGFloat kFieldH = 19;
static const CGFloat kCheckH = 16;
static const CGFloat kButtonH = 20;
static const CGFloat kListRowH = 16;
static const CGFloat kSideButtonW = 76;

static NSFont *small_font(void)
{
    return [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
}

static NSString *ns_string(const char *s)
{
    if (!s)
        return @"";
    NSString *ret = [NSString stringWithUTF8String:s];
    if (!ret)
        ret = [[NSString alloc] initWithBytes:s length:strlen(s)
                                     encoding:NSISOLatin1StringEncoding];
    return ret ?: @"";
}

@interface MTFlippedView : NSView
@end
@implementation MTFlippedView
- (BOOL)isFlipped { return YES; }
@end

/* ----------------------------------------------------------------------
 * One control: the AppKit views that make it up, plus its state.
 */

@interface MTCtrl : NSObject <NSTextFieldDelegate, NSComboBoxDelegate,
                              NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic) dlgcontrol *ctrl;
@property (nonatomic, unsafe_unretained) MTControlBox *box;
@property (nonatomic) NSInteger panel;   /* -1 for the button bar */
@property (nonatomic, strong) NSTextField *label;
@property (nonatomic, strong) NSView *view;         /* the main widget */
@property (nonatomic, strong) NSMutableArray<NSButton *> *radios;
@property (nonatomic, strong) NSTableView *table;
@property (nonatomic, strong) NSPopUpButton *popup;
@property (nonatomic, strong) NSComboBox *combo;
@property (nonatomic, strong) NSTextField *field;
@property (nonatomic, strong) NSButton *button;
@property (nonatomic, strong) NSMutableArray<NSString *> *items;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *ids;
@property (nonatomic, copy) NSString *fontSpec;
@property (nonatomic) CGFloat top;
@end

@interface MTControlBox : NSWindowController <NSWindowDelegate,
                                              NSOutlineViewDataSource,
                                              NSOutlineViewDelegate>
{
@public
    struct dlgparam dp;
    struct controlbox *ctrlbox;
    void *data;
    dlgcontrol *currfocus, *lastfocus;
    int suppress;
}
- (void)fire:(dlgcontrol *)ctrl event:(int)event;
- (MTCtrl *)uctrl:(dlgcontrol *)ctrl;
- (void)showPanel:(NSInteger)index;
- (void)endWithValue:(int)value;
- (void)beginFileSelectFor:(MTCtrl *)uc;
- (void)beginFontSelectFor:(MTCtrl *)uc;
- (void)noteFocusOn:(dlgcontrol *)ctrl;
@property (nonatomic, readonly) NSInteger currentPanel;
@end

@implementation MTCtrl

- (void)valueChanged:(id)sender
{
    [self.box fire:self.ctrl event:EVENT_VALCHANGE];
}

- (void)buttonPressed:(id)sender
{
    [self.box fire:self.ctrl event:EVENT_ACTION];
}

- (void)radioPressed:(NSButton *)sender
{
    for (NSButton *b in self.radios)
        b.state = (b == sender) ? NSControlStateValueOn
                                : NSControlStateValueOff;
    [self.box fire:self.ctrl event:EVENT_VALCHANGE];
}

- (void)popupChanged:(id)sender
{
    [self.box fire:self.ctrl event:EVENT_SELCHANGE];
}

- (void)browsePressed:(id)sender
{
    [self.box beginFileSelectFor:self];
}

- (void)fontPressed:(id)sender
{
    [self.box beginFontSelectFor:self];
}

- (void)moveSelectedBy:(int)direction
{
    NSInteger row = self.table.selectedRow;
    NSInteger dest = row + direction;
    if (row < 0 || dest < 0 || dest >= (NSInteger)self.items.count) {
        NSBeep();
        return;
    }
    [self.items exchangeObjectAtIndex:row withObjectAtIndex:dest];
    [self.ids exchangeObjectAtIndex:row withObjectAtIndex:dest];
    self.box->suppress++;
    [self.table reloadData];
    [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:dest]
            byExtendingSelection:NO];
    [self.table scrollRowToVisible:dest];
    self.box->suppress--;
    [self.box fire:self.ctrl event:EVENT_VALCHANGE];
}

- (void)upPressed:(id)sender { [self moveSelectedBy:-1]; }
- (void)downPressed:(id)sender { [self moveSelectedBy:+1]; }

- (void)tableDoubleClicked:(id)sender
{
    if (self.table.clickedRow >= 0)
        [self.box fire:self.ctrl event:EVENT_ACTION];
}

/* NSTextFieldDelegate / NSComboBoxDelegate */

- (void)controlTextDidChange:(NSNotification *)n
{
    [self.box fire:self.ctrl event:EVENT_VALCHANGE];
}

- (void)controlTextDidBeginEditing:(NSNotification *)n
{
    [self.box noteFocusOn:self.ctrl];
}

- (void)comboBoxSelectionDidChange:(NSNotification *)n
{
    /* The combo box's text is updated only after this notification. */
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.box fire:self.ctrl event:EVENT_VALCHANGE];
    });
}

/* Table data source / delegate */

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv
{
    return self.items.count;
}

- (id)tableView:(NSTableView *)tv objectValueForTableColumn:(NSTableColumn *)col
            row:(NSInteger)row
{
    NSString *item = self.items[row];
    NSInteger idx = [tv.tableColumns indexOfObject:col];
    if (tv.tableColumns.count == 1)
        return item;
    NSArray *parts = [item componentsSeparatedByString:@"\t"];
    return idx < (NSInteger)parts.count ? parts[idx] : @"";
}

- (void)tableViewSelectionDidChange:(NSNotification *)n
{
    [self.box noteFocusOn:self.ctrl];
    [self.box fire:self.ctrl event:EVENT_SELCHANGE];
}

@end

/* ----------------------------------------------------------------------
 * The tree of panels.
 */

@interface MTPanelNode : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic) NSInteger panel;
@property (nonatomic) int depth;
@property (nonatomic, strong) NSMutableArray<MTPanelNode *> *children;
@property (nonatomic, unsafe_unretained) MTPanelNode *parent;
@end
@implementation MTPanelNode
@end

/* A window that tells the dialog which control has the focus, for
 * dlg_last_focused(). */
@interface MTControlBoxWindow : NSWindow
@property (nonatomic, unsafe_unretained) MTControlBox *box;
@end

static NSMutableSet<MTControlBox *> *open_boxes;

@implementation MTControlBox {
    NSMapTable<NSValue *, MTCtrl *> *uctrls;
    NSMutableArray<NSView *> *panelViews;
    NSMutableArray<NSScrollView *> *panelScrolls;
    NSMutableArray<MTPanelNode *> *roots;
    NSMutableArray<MTPanelNode *> *nodesByPanel;
    NSOutlineView *outline;
    post_dialog_fn_t after;
    void *afterctx;
    int retval;
    BOOL ended, midsession, isConfig;
    MTCtrl *fontCtrl;
    dlgcontrol *colourCtrl;
    int colourR, colourG, colourB;
    BOOL colourOK;
}

@synthesize currentPanel = _currentPanel;

- (MTCtrl *)uctrl:(dlgcontrol *)ctrl
{
    return ctrl ? [uctrls objectForKey:[NSValue valueWithPointer:ctrl]] : nil;
}

- (void)fire:(dlgcontrol *)ctrl event:(int)event
{
    if (suppress || ended || !ctrl || !ctrl->handler)
        return;
    ctrl->handler(ctrl, &dp, data, event);
}

- (void)noteFocusOn:(dlgcontrol *)ctrl
{
    if (ctrl && ctrl != currfocus) {
        lastfocus = currfocus;
        currfocus = ctrl;
    }
}

/* ----------------------------------------------------------------------
 * Creating controls. Each create method places the control at (x, y)
 * with the given width in 'parent' (a flipped view) and returns its
 * height.
 */

- (NSTextField *)makeLabel:(const char *)text
{
    NSTextField *l = [NSTextField labelWithString:ns_string(text)];
    l.font = small_font();
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    return l;
}

- (NSButton *)makeButton:(const char *)title target:(id)target
                  action:(SEL)action
{
    NSButton *b = [NSButton buttonWithTitle:ns_string(title)
                                     target:target action:action];
    b.controlSize = NSControlSizeSmall;
    b.font = small_font();
    b.bezelStyle = NSBezelStyleRounded;
    return b;
}

/* A label and a widget side by side ('pct' percent for the widget), or
 * the label above the widget if pct is 100. */
- (CGFloat)placeLabel:(NSTextField *)label widget:(NSView *)widget
                  pct:(int)pct height:(CGFloat)h
                    x:(CGFloat)x y:(CGFloat)y width:(CGFloat)w
                   in:(NSView *)parent
{
    if (!label) {
        widget.frame = NSMakeRect(x, y, w, h);
        [parent addSubview:widget];
        return h;
    }
    if (pct >= 100 || pct <= 0) {
        label.frame = NSMakeRect(x, y, w, kLabelH);
        widget.frame = NSMakeRect(x, y + kLabelH + 2, w, h);
        [parent addSubview:label];
        [parent addSubview:widget];
        return kLabelH + 2 + h;
    }
    CGFloat ww = floor(w * pct / 100.0);
    label.frame = NSMakeRect(x, y + floor((h - kLabelH) / 2), w - ww - 4,
                             kLabelH);
    widget.frame = NSMakeRect(x + w - ww, y, ww, h);
    [parent addSubview:label];
    [parent addSubview:widget];
    return h;
}

- (CGFloat)createControl:(MTCtrl *)uc x:(CGFloat)x y:(CGFloat)y
                   width:(CGFloat)w in:(NSView *)parent
{
    dlgcontrol *ctrl = uc.ctrl;

    switch (ctrl->type) {
      case CTRL_TEXT: {
        NSTextField *t = [NSTextField wrappingLabelWithString:
                                         ns_string(ctrl->label)];
        t.font = small_font();
        t.selectable = NO;
        NSSize sz = [t.cell cellSizeForBounds:NSMakeRect(0, 0, w, 10000)];
        t.frame = NSMakeRect(x, y, w, ceil(sz.height));
        [parent addSubview:t];
        uc.view = t;
        return ceil(sz.height);
      }

      case CTRL_EDITBOX: {
        NSTextField *label = ctrl->label ? [self makeLabel:ctrl->label] : nil;
        NSTextField *field;
        if (ctrl->editbox.has_list) {
            NSComboBox *combo = [[NSComboBox alloc] initWithFrame:NSZeroRect];
            combo.usesDataSource = NO;
            combo.completes = NO;
            combo.numberOfVisibleItems = 12;
            uc.combo = combo;
            field = combo;
        } else if (ctrl->editbox.password) {
            field = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
        } else {
            field = [[NSTextField alloc] initWithFrame:NSZeroRect];
        }
        field.controlSize = NSControlSizeSmall;
        field.font = small_font();
        field.delegate = uc;
        field.cell.scrollable = YES;
        field.cell.wraps = NO;
        uc.label = label;
        uc.field = field;
        uc.view = field;
        CGFloat h = ctrl->editbox.has_list ? kFieldH + 2 : kFieldH;
        return [self placeLabel:label widget:field
                            pct:ctrl->editbox.percentwidth height:h
                              x:x y:y width:w in:parent];
      }

      case CTRL_RADIO: {
        CGFloat h = 0;
        if (ctrl->label) {
            NSTextField *label = [self makeLabel:ctrl->label];
            label.frame = NSMakeRect(x, y, w, kLabelH);
            [parent addSubview:label];
            uc.label = label;
            h += kLabelH + 2;
        }
        /* Each radio group gets its own container, because AppKit
         * groups radio buttons that share a superview and action. */
        int ncols = ctrl->radio.ncolumns > 0 ? ctrl->radio.ncolumns : 1;
        int nrows = (ctrl->radio.nbuttons + ncols - 1) / ncols;
        MTFlippedView *group = [[MTFlippedView alloc] initWithFrame:
            NSMakeRect(x, y + h, w, nrows * (kCheckH + 2))];
        uc.radios = [NSMutableArray array];
        CGFloat natural[16] = {0};
        if (ncols > 16) ncols = 16;
        for (int i = 0; i < ctrl->radio.nbuttons; i++) {
            NSButton *b = [NSButton radioButtonWithTitle:
                                        ns_string(ctrl->radio.buttons[i])
                                                   target:uc
                                                   action:@selector(radioPressed:)];
            b.controlSize = NSControlSizeSmall;
            b.font = small_font();
            int c = i % ncols;
            natural[c] = MAX(natural[c], ceil(b.fittingSize.width) + 4);
            [uc.radios addObject:b];
        }
        /* Columns of equal width as in PuTTY, unless a label would not
         * fit; then size the columns to their labels and share out
         * what is left. */
        CGFloat colx[17], total = 0;
        for (int c = 0; c < ncols; c++)
            total += natural[c];
        BOOL equal = YES;
        for (int c = 0; c < ncols; c++)
            if (natural[c] > w / ncols)
                equal = NO;
        colx[0] = 0;
        for (int c = 0; c < ncols; c++) {
            CGFloat cw = (equal || total > w) ? w / ncols :
                natural[c] + (w - total) / ncols;
            colx[c + 1] = colx[c] + cw;
        }
        for (int i = 0; i < ctrl->radio.nbuttons; i++) {
            int r = i / ncols, c = i % ncols;
            uc.radios[i].frame = NSMakeRect(colx[c], r * (kCheckH + 2),
                                            colx[c + 1] - colx[c] - 2,
                                            kCheckH);
            [group addSubview:uc.radios[i]];
        }
        [parent addSubview:group];
        uc.view = group;
        return h + nrows * (kCheckH + 2) - 2;
      }

      case CTRL_CHECKBOX: {
        NSButton *b = [NSButton checkboxWithTitle:ns_string(ctrl->label)
                                           target:uc
                                           action:@selector(valueChanged:)];
        b.controlSize = NSControlSizeSmall;
        b.font = small_font();
        b.frame = NSMakeRect(x, y, w, kCheckH);
        [parent addSubview:b];
        uc.button = b;
        uc.view = b;
        return kCheckH;
      }

      case CTRL_BUTTON: {
        NSButton *b = [self makeButton:ctrl->label target:uc
                                action:@selector(buttonPressed:)];
        if (ctrl->button.isdefault)
            b.keyEquivalent = @"\r";
        else if (ctrl->button.iscancel)
            b.keyEquivalent = @"\033";
        b.frame = NSMakeRect(x - 4, y - 1, w + 8, kButtonH + 4);
        [parent addSubview:b];
        uc.button = b;
        uc.view = b;
        return kButtonH;
      }

      case CTRL_LISTBOX: {
        uc.items = [NSMutableArray array];
        uc.ids = [NSMutableArray array];
        if (ctrl->listbox.height == 0) {
            /* A drop-down list. */
            NSTextField *label = ctrl->label ? [self makeLabel:ctrl->label]
                                             : nil;
            NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect
                                                          pullsDown:NO];
            p.controlSize = NSControlSizeSmall;
            p.font = small_font();
            p.target = uc;
            p.action = @selector(popupChanged:);
            uc.popup = p;
            uc.label = label;
            uc.view = p;
            return [self placeLabel:label widget:p
                                pct:ctrl->listbox.percentwidth
                             height:kFieldH + 3 x:x y:y width:w in:parent];
        }

        CGFloat h = 0;
        if (ctrl->label) {
            NSTextField *label = [self makeLabel:ctrl->label];
            label.frame = NSMakeRect(x, y, w, kLabelH);
            [parent addSubview:label];
            uc.label = label;
            h += kLabelH + 2;
        }
        CGFloat listw = ctrl->listbox.draglist ? w - kSideButtonW - 6 : w;
        CGFloat listh = ctrl->listbox.height * kListRowH + 4;
        NSScrollView *sv = [[NSScrollView alloc] initWithFrame:
            NSMakeRect(x, y + h, listw, listh)];
        sv.borderType = NSBezelBorder;
        sv.hasVerticalScroller = YES;
        sv.hasHorizontalScroller = ctrl->listbox.hscroll;
        sv.autohidesScrollers = YES;
        NSTableView *tv = [[NSTableView alloc] initWithFrame:sv.bounds];
        tv.headerView = nil;
        tv.rowHeight = kListRowH - 2;
        tv.intercellSpacing = NSMakeSize(3, 2);
        tv.font = small_font();
        tv.style = NSTableViewStylePlain;
        tv.usesAlternatingRowBackgroundColors = NO;
        tv.allowsMultipleSelection = ctrl->listbox.multisel != 0;
        tv.allowsEmptySelection = YES;
        tv.columnAutoresizingStyle = NSTableViewNoColumnAutoresizing;
        int ncols = ctrl->listbox.ncols > 0 ? ctrl->listbox.ncols : 1;
        CGFloat avail = listw - 20;
        for (int i = 0; i < ncols; i++) {
            NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:
                                      [NSString stringWithFormat:@"%d", i]];
            int pc = (ncols > 1 && ctrl->listbox.percentages) ?
                ctrl->listbox.percentages[i] : 100;
            col.width = floor(avail * pc / 100.0);
            col.editable = NO;
            NSTextFieldCell *cell = [[NSTextFieldCell alloc] init];
            cell.font = small_font();
            cell.lineBreakMode = NSLineBreakByTruncatingTail;
            col.dataCell = cell;
            [tv addTableColumn:col];
        }
        tv.dataSource = uc;
        tv.delegate = uc;
        tv.target = uc;
        tv.doubleAction = @selector(tableDoubleClicked:);
        sv.documentView = tv;
        [parent addSubview:sv];
        uc.table = tv;
        uc.view = tv;

        if (ctrl->listbox.draglist) {
            NSButton *up = [self makeButton:"Up" target:uc
                                     action:@selector(upPressed:)];
            NSButton *down = [self makeButton:"Down" target:uc
                                       action:@selector(downPressed:)];
            up.frame = NSMakeRect(x + w - kSideButtonW - 4, y + h - 1,
                                  kSideButtonW + 8, kButtonH + 4);
            down.frame = NSMakeRect(x + w - kSideButtonW - 4,
                                    y + h + kButtonH + 4,
                                    kSideButtonW + 8, kButtonH + 4);
            [parent addSubview:up];
            [parent addSubview:down];
        }
        return h + listh;
      }

      case CTRL_FILESELECT:
      case CTRL_FONTSELECT: {
        bool font = (ctrl->type == CTRL_FONTSELECT);
        CGFloat h = 0;
        if (ctrl->label) {
            NSTextField *label = [self makeLabel:ctrl->label];
            label.frame = NSMakeRect(x, y, w, kLabelH);
            [parent addSubview:label];
            uc.label = label;
            h += kLabelH + 2;
        }
        NSButton *b = [self makeButton:font ? "Change..." : "Browse..."
                                target:uc
                                action:font ? @selector(fontPressed:)
                                            : @selector(browsePressed:)];
        if (!font && ctrl->fileselect.just_button) {
            b.frame = NSMakeRect(x - 4, y + h - 1, kSideButtonW + 8,
                                 kButtonH + 4);
            [parent addSubview:b];
            uc.button = b;
            uc.view = b;
            return h + kButtonH;
        }
        NSTextField *f = [[NSTextField alloc] initWithFrame:
            NSMakeRect(x, y + h, w - kSideButtonW - 6, kFieldH)];
        f.controlSize = NSControlSizeSmall;
        f.font = small_font();
        f.delegate = uc;
        f.cell.scrollable = YES;
        if (font) {
            f.editable = NO;
            f.selectable = YES;
        }
        b.frame = NSMakeRect(x + w - kSideButtonW - 4, y + h - 1,
                             kSideButtonW + 8, kButtonH + 4);
        [parent addSubview:f];
        [parent addSubview:b];
        uc.field = f;
        uc.button = b;
        uc.view = f;
        return h + kFieldH;
      }
    }
    return 0;
}

/* Lay out one controlset. Returns its height. */
- (CGFloat)layoutSet:(struct controlset *)s in:(NSView *)parent
                   y:(CGFloat)y0 width:(CGFloat)width panel:(NSInteger)panel
{
    if (!s->boxname) {
        /* A panel title, with a rule underneath as in Windows PuTTY. */
        NSTextField *t = [NSTextField labelWithString:ns_string(s->boxtitle)];
        t.font = [NSFont boldSystemFontOfSize:NSFont.smallSystemFontSize];
        t.frame = NSMakeRect(0, y0, width, kLabelH + 2);
        [parent addSubview:t];
        NSBox *rule = [[NSBox alloc] initWithFrame:
            NSMakeRect(0, y0 + kLabelH + 5, width, 1)];
        rule.boxType = NSBoxSeparator;
        [parent addSubview:rule];
        return kLabelH + 8;
    }

    NSView *target = parent;
    CGFloat innerX = 0, innerW = width, y = y0;
    NSBox *frame = nil;
    if (*s->boxname) {
        frame = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, width, 100)];
        frame.titleFont = small_font();
        if (s->boxtitle && *s->boxtitle) {
            frame.title = ns_string(s->boxtitle);
            frame.titlePosition = NSAtTop;
        } else {
            frame.titlePosition = NSNoTitle;
        }
        frame.contentViewMargins = NSMakeSize(8, 6);
        /* Work out how much of the width the frame itself takes. */
        [frame setFrameFromContentFrame:NSMakeRect(0, 0, 100, 100)];
        innerW = width - (frame.frame.size.width - 100);
        target = [[MTFlippedView alloc] initWithFrame:
                     NSMakeRect(0, 0, innerW, 100)];
        y = 0;
    }

    int ncols = 1;
    int pcts[16] = { 100 };
    CGFloat colY[16];
    for (int i = 0; i < 16; i++)
        colY[i] = y;

    for (size_t i = 0; i < s->ncontrols; i++) {
        dlgcontrol *ctrl = s->ctrls[i];
        if (ctrl->type == CTRL_COLUMNS) {
            CGFloat maxy = y;
            for (int c = 0; c < ncols; c++)
                maxy = MAX(maxy, colY[c]);
            ncols = ctrl->columns.ncols;
            if (ncols < 1) ncols = 1;
            if (ncols > 16) ncols = 16;
            for (int c = 0; c < ncols; c++) {
                pcts[c] = (ncols == 1 || !ctrl->columns.percentages) ?
                    100 / ncols : ctrl->columns.percentages[c];
                colY[c] = maxy;
            }
            continue;
        }
        if (ctrl->type == CTRL_TABDELAY)
            continue;

        int start = COLUMN_START(ctrl->column);
        int span = COLUMN_SPAN(ctrl->column);
        if (start >= ncols) start = ncols - 1;
        if (start + span > ncols) span = ncols - start;
        int before = 0, within = 0;
        for (int c = 0; c < start; c++) before += pcts[c];
        for (int c = start; c < start + span; c++) within += pcts[c];
        CGFloat x = innerX + floor(innerW * before / 100.0);
        CGFloat w = floor(innerW * within / 100.0);
        if (start + span < ncols)
            w -= kColGap;

        CGFloat cy = 0;
        for (int c = start; c < start + span; c++)
            cy = MAX(cy, colY[c]);

        MTCtrl *uc = [MTCtrl new];
        uc.ctrl = ctrl;
        uc.box = self;
        uc.panel = panel;
        if (ctrl->align_next_to) {
            MTCtrl *other = [self uctrl:ctrl->align_next_to];
            if (other)
                cy = MAX(cy, other.top);
        }
        uc.top = cy;
        [uctrls setObject:uc forKey:[NSValue valueWithPointer:ctrl]];

        CGFloat h = [self createControl:uc x:x y:cy width:w in:target];
        for (int c = start; c < start + span; c++)
            colY[c] = cy + h + kRowGap;
    }

    CGFloat bottom = y;
    for (int c = 0; c < ncols; c++)
        bottom = MAX(bottom, colY[c]);
    CGFloat h = bottom - y - kRowGap;
    if (h < 0)
        h = 0;

    if (frame) {
        target.frame = NSMakeRect(0, 0, innerW, h);
        frame.contentView = target;
        [frame setFrameFromContentFrame:NSMakeRect(0, 0, innerW, h)];
        NSRect f = frame.frame;
        frame.frame = NSMakeRect(0, y0, width, f.size.height);
        target.frame = NSMakeRect(0, 0, innerW, h);
        [parent addSubview:frame];
        return f.size.height;
    }
    return h;
}

/* ----------------------------------------------------------------------
 * Building the window.
 */

- (instancetype)initWithBox:(struct controlbox *)box
                      title:(const char *)title
                       data:(void *)d
                 midsession:(BOOL)mid
                   withTree:(BOOL)withTree
                     parent:(NSWindow *)parent
                      after:(post_dialog_fn_t)afterfn
                   afterctx:(void *)actx
{
    MTControlBoxWindow *w = [[MTControlBoxWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 600, 480)
                  styleMask:(NSWindowStyleMaskTitled |
                             NSWindowStyleMaskClosable)
                    backing:NSBackingStoreBuffered defer:YES];
    if (!(self = [super initWithWindow:w]))
        return nil;
    w.box = self;
    w.releasedWhenClosed = NO;
    w.delegate = self;
    w.title = ns_string(title);
    w.autorecalculatesKeyViewLoop = YES;
    w.tabbingMode = NSWindowTabbingModeDisallowed;

    dp.box = (__bridge void *)self;
    ctrlbox = box;
    data = d;
    after = afterfn;
    afterctx = actx;
    retval = -1;
    midsession = mid;
    isConfig = withTree;
    uctrls = [NSMapTable strongToStrongObjectsMapTable];
    panelViews = [NSMutableArray array];
    panelScrolls = [NSMutableArray array];
    roots = [NSMutableArray array];
    nodesByPanel = [NSMutableArray array];

    /* Panels, in control-box order. */
    NSMutableArray<NSNumber *> *panelHeights = [NSMutableArray array];
    const char *path = NULL;
    MTPanelNode *levels[8] = {0};
    MTFlippedView *panel = nil;
    CGFloat py = 0;
    struct controlset *buttons = NULL;

    for (size_t i = 0; i < box->nctrlsets; i++) {
        struct controlset *s = box->ctrlsets[i];
        if (!*s->pathname) {
            buttons = s;
            continue;
        }
        int j = path ? ctrl_path_compare(s->pathname, path) : 0;
        if (!panel || (withTree && j != INT_MAX)) {
            if (panel)
                [panelHeights addObject:@(py)];
            panel = [[MTFlippedView alloc] initWithFrame:
                         NSMakeRect(0, 0, kPanelWidth, 100)];
            [panelViews addObject:panel];
            py = 0;
            path = s->pathname;
            if (withTree) {
                const char *c = strrchr(s->pathname, '/');
                c = c ? c + 1 : s->pathname;
                int depth = ctrl_path_elements(s->pathname) - 1;
                if (depth > 7) depth = 7;
                MTPanelNode *node = [MTPanelNode new];
                node.title = ns_string(c);
                node.panel = panelViews.count - 1;
                node.depth = depth;
                node.children = [NSMutableArray array];
                if (depth > 0 && levels[depth - 1]) {
                    node.parent = levels[depth - 1];
                    [levels[depth - 1].children addObject:node];
                } else {
                    [roots addObject:node];
                }
                levels[depth] = node;
                [nodesByPanel addObject:node];
            }
        }
        if (py > 0)
            py += kSetGap;
        py += [self layoutSet:s in:panel y:py width:kPanelWidth
                        panel:panelViews.count - 1];
    }
    if (panel)
        [panelHeights addObject:@(py)];

    CGFloat maxPanelH = 0;
    for (NSNumber *h in panelHeights)
        maxPanelH = MAX(maxPanelH, h.doubleValue);
    NSRect screen = (parent.screen ?: NSScreen.mainScreen).visibleFrame;
    CGFloat panelAreaH = MIN(maxPanelH, screen.size.height - 140);
    if (withTree)
        panelAreaH = MAX(panelAreaH, 360);

    CGFloat treeW = withTree ? kTreeWidth + kMargin : 0;
    CGFloat contentW = kMargin + treeW + kPanelWidth + kMargin;

    /* The button bar along the bottom. */
    MTFlippedView *bar = [[MTFlippedView alloc] initWithFrame:
        NSMakeRect(0, 0, contentW - 2 * kMargin, 40)];
    CGFloat barH = buttons ? [self layoutSet:buttons in:bar y:0
                                       width:contentW - 2 * kMargin
                                       panel:-1] : 0;

    CGFloat contentH = kMargin + panelAreaH + kMargin + barH + kMargin;
    MTFlippedView *content = [[MTFlippedView alloc] initWithFrame:
        NSMakeRect(0, 0, contentW, contentH)];
    w.contentView = content;
    [w setContentSize:NSMakeSize(contentW, contentH)];

    bar.frame = NSMakeRect(kMargin, contentH - kMargin - barH,
                           contentW - 2 * kMargin, barH);
    [content addSubview:bar];

    for (NSUInteger p = 0; p < panelViews.count; p++) {
        NSView *pv = panelViews[p];
        CGFloat ph = [panelHeights[p] doubleValue];
        pv.frame = NSMakeRect(0, 0, kPanelWidth, MAX(ph, panelAreaH));
        NSScrollView *sv = [[NSScrollView alloc] initWithFrame:
            NSMakeRect(kMargin + treeW, kMargin, kPanelWidth + 2,
                       panelAreaH)];
        sv.drawsBackground = NO;
        sv.borderType = NSNoBorder;
        sv.hasVerticalScroller = ph > panelAreaH;
        sv.documentView = pv;
        sv.hidden = withTree && p != 0;
        [content addSubview:sv];
        [panelScrolls addObject:sv];
    }

    if (withTree) {
        NSTextField *cat = [NSTextField labelWithString:@"Category:"];
        cat.font = small_font();
        cat.frame = NSMakeRect(kMargin, kMargin, kTreeWidth, kLabelH);
        [content addSubview:cat];

        NSScrollView *sv = [[NSScrollView alloc] initWithFrame:
            NSMakeRect(kMargin, kMargin + kLabelH + 3, kTreeWidth,
                       panelAreaH - kLabelH - 3)];
        sv.borderType = NSBezelBorder;
        sv.hasVerticalScroller = YES;
        sv.autohidesScrollers = YES;
        outline = [[NSOutlineView alloc] initWithFrame:sv.bounds];
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"t"];
        col.width = kTreeWidth - 4;
        NSTextFieldCell *cell = [NSTextFieldCell new];
        cell.font = small_font();
        col.dataCell = cell;
        [outline addTableColumn:col];
        outline.outlineTableColumn = col;
        outline.headerView = nil;
        outline.style = NSTableViewStylePlain;
        outline.rowHeight = 16;
        outline.indentationPerLevel = 12;
        outline.dataSource = self;
        outline.delegate = self;
        outline.allowsEmptySelection = NO;
        sv.documentView = outline;
        [content addSubview:sv];
        [outline reloadData];
        /* Top-level branches open; deeper ones (SSH, Selection) shut, as
         * in Windows PuTTY. */
        for (MTPanelNode *n in roots)
            [outline expandItem:n];
        [outline selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
             byExtendingSelection:NO];
    }

    dlg_refresh(NULL, &dp);

    if (!open_boxes)
        open_boxes = [NSMutableSet set];
    [open_boxes addObject:self];

    if (parent) {
        NSRect pf = parent.frame;
        NSRect f = w.frame;
        [w setFrameOrigin:NSMakePoint(NSMidX(pf) - f.size.width / 2,
                                      NSMaxY(pf) - f.size.height - 40)];
    } else {
        [w center];
    }
    [w makeKeyAndOrderFront:nil];

    /* Focus the first real control, as PuTTY does (the host name). */
    for (size_t i = 0; i < box->nctrlsets; i++) {
        struct controlset *s = box->ctrlsets[i];
        if (!*s->pathname)
            continue;
        bool done = false;
        for (size_t j = 0; j < s->ncontrols; j++) {
            int t = s->ctrls[j]->type;
            if (t != CTRL_TABDELAY && t != CTRL_COLUMNS && t != CTRL_TEXT) {
                dlg_set_focus(s->ctrls[j], &dp);
                done = true;
                break;
            }
        }
        if (done)
            break;
    }
    return self;
}

- (void)showPanel:(NSInteger)index
{
    if (index < 0 || index >= (NSInteger)panelScrolls.count)
        return;
    for (NSUInteger p = 0; p < panelScrolls.count; p++)
        panelScrolls[p].hidden = ((NSInteger)p != index);
    _currentPanel = index;
    [panelScrolls[index].documentView scrollPoint:NSZeroPoint];
    if (outline && index < (NSInteger)nodesByPanel.count) {
        MTPanelNode *node = nodesByPanel[index];
        for (MTPanelNode *p = node.parent; p; p = p.parent)
            [outline expandItem:p];
        NSInteger row = [outline rowForItem:node];
        if (row >= 0 && row != outline.selectedRow)
            [outline selectRowIndexes:[NSIndexSet indexSetWithIndex:row]
                 byExtendingSelection:NO];
    }
}

/* NSOutlineView */

- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(id)item
{
    return item ? [(MTPanelNode *)item children].count : roots.count;
}

- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)index ofItem:(id)item
{
    return item ? [(MTPanelNode *)item children][index] : roots[index];
}

- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(id)item
{
    return [(MTPanelNode *)item children].count > 0;
}

- (id)outlineView:(NSOutlineView *)ov
    objectValueForTableColumn:(NSTableColumn *)col byItem:(id)item
{
    return [(MTPanelNode *)item title];
}

- (void)outlineViewSelectionDidChange:(NSNotification *)n
{
    MTPanelNode *node = [outline itemAtRow:outline.selectedRow];
    if (node && node.panel != _currentPanel)
        [self showPanel:node.panel];
}

/* ----------------------------------------------------------------------
 * File, font and colour selectors.
 */

- (void)beginFileSelectFor:(MTCtrl *)uc
{
    dlgcontrol *ctrl = uc.ctrl;
    NSSavePanel *panel;
    if (ctrl->fileselect.for_writing) {
        panel = [NSSavePanel savePanel];
    } else {
        NSOpenPanel *op = [NSOpenPanel openPanel];
        op.canChooseFiles = YES;
        op.canChooseDirectories = NO;
        op.allowsMultipleSelection = NO;
        panel = op;
    }
    if (ctrl->fileselect.title)
        panel.message = ns_string(ctrl->fileselect.title);
    switch (ctrl->fileselect.filter) {
      case FILTER_KEY_FILES:
        panel.allowedContentTypes = @[
            [UTType typeWithFilenameExtension:@"ppk"] ?: UTTypeData,
            UTTypeData];
        break;
      case FILTER_SOUND_FILES:
        panel.allowedContentTypes = @[UTTypeAudio];
        break;
      default:
        break;
    }
    panel.showsHiddenFiles = YES;
    if (uc.field.stringValue.length) {
        NSURL *cur = [NSURL fileURLWithPath:uc.field.stringValue];
        panel.directoryURL = cur.URLByDeletingLastPathComponent;
        panel.nameFieldStringValue = cur.lastPathComponent;
    }
    [panel beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK)
            return;
        NSURL *url = [panel isKindOfClass:NSOpenPanel.class] ?
            [(NSOpenPanel *)panel URLs].firstObject : panel.URL;
        if (!url)
            return;
        if (uc.field)
            uc.field.stringValue = url.path;
        else
            uc.fontSpec = url.path;   /* just_button: keep the path here */
        [self fire:ctrl event:EVENT_VALCHANGE];
    }];
}

static CTFontRef font_for_spec(NSString *spec)
{
    NSRange sp = [spec rangeOfString:@" " options:NSBackwardsSearch];
    CGFloat size = 13;
    NSString *name = spec;
    if (sp.location != NSNotFound) {
        double s = [[spec substringFromIndex:sp.location + 1] doubleValue];
        if (s > 0) {
            size = s;
            name = [spec substringToIndex:sp.location];
        }
    }
    return CTFontCreateWithName((__bridge CFStringRef)name, size, NULL);
}

- (void)beginFontSelectFor:(MTCtrl *)uc
{
    fontCtrl = uc;
    NSFontManager *fm = NSFontManager.sharedFontManager;
    CTFontRef ct = font_for_spec(uc.fontSpec ?: @"Menlo-Regular 13");
    NSFont *font = (__bridge_transfer NSFont *)ct;
    fm.target = self;
    fm.action = @selector(changeFont:);
    [fm setSelectedFont:font isMultiple:NO];
    [fm orderFrontFontPanel:self];
}

- (void)changeFont:(id)sender
{
    MTCtrl *uc = fontCtrl;
    if (!uc)
        return;
    CTFontRef ct = font_for_spec(uc.fontSpec ?: @"Menlo-Regular 13");
    NSFont *old = (__bridge_transfer NSFont *)ct;
    NSFont *new = [sender convertFont:old];
    if (!new)
        return;
    uc.fontSpec = [NSString stringWithFormat:@"%@ %g", new.fontName,
                   (double)new.pointSize];
    char *disp = mactty_font_display_name(uc.fontSpec.UTF8String);
    uc.field.stringValue = ns_string(disp);
    sfree(disp);
    [self fire:uc.ctrl event:EVENT_VALCHANGE];
}

- (void)startColourFor:(dlgcontrol *)ctrl r:(int)r g:(int)g b:(int)b
{
    colourCtrl = ctrl;
    colourOK = NO;
    NSColorPanel *cp = NSColorPanel.sharedColorPanel;
    cp.showsAlpha = NO;
    [cp setTarget:nil];
    cp.color = [NSColor colorWithSRGBRed:r/255.0 green:g/255.0 blue:b/255.0
                                   alpha:1];
    [cp setTarget:self];
    [cp setAction:@selector(colourChanged:)];
    cp.continuous = YES;
    [cp makeKeyAndOrderFront:self];
}

- (void)colourChanged:(NSColorPanel *)cp
{
    if (!colourCtrl)
        return;
    NSColor *c = [cp.color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!c)
        return;
    colourR = (int)lround(c.redComponent * 255);
    colourG = (int)lround(c.greenComponent * 255);
    colourB = (int)lround(c.blueComponent * 255);
    colourOK = YES;
    [self fire:colourCtrl event:EVENT_CALLBACK];
}

- (BOOL)colourResultsR:(int *)r g:(int *)g b:(int *)b
{
    if (!colourOK)
        return NO;
    *r = colourR;
    *g = colourG;
    *b = colourB;
    return YES;
}

/* ----------------------------------------------------------------------
 * Ending.
 */

- (void)endWithValue:(int)value
{
    if (ended)
        return;
    /* Like Windows PuTTY, Open does nothing until there is somewhere to
     * connect to. */
    if (isConfig && !midsession && value > 0 && data &&
        !conf_launchable((Conf *)data)) {
        NSBeep();
        return;
    }
    retval = value;
    [self.window close];
}

- (void)windowWillClose:(NSNotification *)n
{
    if (ended)
        return;
    ended = YES;

    NSFontManager *fm = NSFontManager.sharedFontManager;
    if (fm.target == self) {
        fm.target = nil;
        [[fm fontPanel:NO] orderOut:nil];
    }
    if (colourCtrl) {
        NSColorPanel *cp = NSColorPanel.sharedColorPanel;
        [cp setTarget:nil];
        [cp orderOut:nil];
        colourCtrl = NULL;
    }

    /* Run the continuation before the window is really gone, so that a
     * session window it opens keeps the application alive. */
    if (after)
        after(afterctx, retval);
    after = NULL;

    ctrl_free_box(ctrlbox);
    ctrlbox = NULL;
    [uctrls removeAllObjects];
    MTControlBox *keep = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [open_boxes removeObject:keep];
    });
}

@end

@implementation MTControlBoxWindow
- (BOOL)makeFirstResponder:(NSResponder *)responder
{
    BOOL ok = [super makeFirstResponder:responder];
    if (ok && self.box) {
        NSResponder *r = responder;
        if ([r isKindOfClass:NSTextView.class] &&
            [(NSTextView *)r isFieldEditor])
            r = (NSResponder *)[(NSTextView *)r delegate];
        if ([r isKindOfClass:NSView.class]) {
            for (NSView *v = (NSView *)r; v; v = v.superview) {
                for (MTCtrl *uc in [self.box valueForKey:@"allCtrls"]) {
                    if (uc.view == v || uc.field == v || uc.table == v ||
                        uc.button == v || uc.popup == v) {
                        [self.box noteFocusOn:uc.ctrl];
                        return ok;
                    }
                }
            }
        }
    }
    return ok;
}

- (void)cancelOperation:(id)sender
{
    [self.box endWithValue:0];
}
@end

@implementation MTControlBox (Focus)
- (NSArray<MTCtrl *> *)allCtrls
{
    return [uctrls objectEnumerator].allObjects;
}
@end

/* ----------------------------------------------------------------------
 * Entry points.
 */

void *mactty_config_box(const char *title, Conf *conf, bool midsession,
                        int protcfginfo, void *parent,
                        post_dialog_fn_t after, void *afterctx)
{
    struct controlbox *box = ctrl_new_box();
    int protocol = conf_get_int(conf, CONF_protocol);
    setup_config_box(box, midsession, protocol, protcfginfo);
    unix_setup_config_box(box, midsession, protocol);
    mac_setup_config_box(box, midsession, protocol);

    MTControlBox *b = [[MTControlBox alloc]
        initWithBox:box title:title data:conf midsession:midsession
           withTree:YES parent:(__bridge NSWindow *)parent
              after:after afterctx:afterctx];
    return (__bridge void *)b.window;
}

void show_ca_config_box(dlgparam *dp)
{
    for (MTControlBox *b in open_boxes) {
        if (!b->data && [b.window.title hasSuffix:@"certification authorities"]) {
            [b.window makeKeyAndOrderFront:nil];
            return;
        }
    }
    struct controlbox *box = ctrl_new_box();
    setup_ca_config_box(box);
    char *title = dupprintf("%s trusted host certification authorities",
                            appname);
    MTControlBox *parent = dp ? box_of(dp) : nil;
    (void)[[MTControlBox alloc] initWithBox:box title:title data:NULL
                                 midsession:NO withTree:NO
                                     parent:parent.window
                                      after:NULL afterctx:NULL];
    sfree(title);
}

/* ----------------------------------------------------------------------
 * The dlg_* API (dialog.h).
 */

void dlg_radiobutton_set(dlgcontrol *ctrl, dlgparam *dp, int which)
{
    MTCtrl *uc = [box_of(dp) uctrl:ctrl];
    assert(uc && uc.radios);
    for (NSUInteger i = 0; i < uc.radios.count; i++)
        uc.radios[i].state = ((int)i == which) ? NSControlStateValueOn
                                               : NSControlStateValueOff;
}

int dlg_radiobutton_get(dlgcontrol *ctrl, dlgparam *dp)
{
    MTCtrl *uc = [box_of(dp) uctrl:ctrl];
    assert(uc && uc.radios);
    for (NSUInteger i = 0; i < uc.radios.count; i++)
        if (uc.radios[i].state == NSControlStateValueOn)
            return (int)i;
    return 0;
}

void dlg_checkbox_set(dlgcontrol *ctrl, dlgparam *dp, bool checked)
{
    MTCtrl *uc = [box_of(dp) uctrl:ctrl];
    assert(uc && uc.button);
    uc.button.state = checked ? NSControlStateValueOn : NSControlStateValueOff;
}

bool dlg_checkbox_get(dlgcontrol *ctrl, dlgparam *dp)
{
    MTCtrl *uc = [box_of(dp) uctrl:ctrl];
    assert(uc && uc.button);
    return uc.button.state == NSControlStateValueOn;
}

void dlg_editbox_set_utf8(dlgcontrol *ctrl, dlgparam *dp, char const *text)
{
    MTCtrl *uc = [box_of(dp) uctrl:ctrl];
    assert(uc && uc.field);
    NSString *s = ns_string(text);
    if (![uc.field.stringValue isEqualToString:s])
        uc.field.stringValue = s;
}

void dlg_editbox_set(dlgcontrol *ctrl, dlgparam *dp, char const *text)
{
    dlg_editbox_set_utf8(ctrl, dp, text);
}

char *dlg_editbox_get_utf8(dlgcontrol *ctrl, dlgparam *dp)
{
    MTCtrl *uc = [box_of(dp) uctrl:ctrl];
    assert(uc && uc.field);
    const char *s = uc.field.stringValue.UTF8String;
    return dupstr(s ? s : "");
}

char *dlg_editbox_get(dlgcontrol *ctrl, dlgparam *dp)
{
    return dlg_editbox_get_utf8(ctrl, dp);
}

void dlg_editbox_select_range(dlgcontrol *ctrl, dlgparam *dp,
                              size_t start, size_t len)
{
    MTCtrl *uc = [box_of(dp) uctrl:ctrl];
    if (!uc.field)
        return;
    [uc.field.window makeFirstResponder:uc.field];
    NSText *editor = [uc.field currentEditor];
    editor.selectedRange = NSMakeRange(start, len);
}

void dlg_listbox_clear(dlgcontrol *ctrl, dlgparam *dp)
{
    MTCtrl *uc = [box_of(dp) uctrl:ctrl];
    assert(uc);
    box_of(dp)->suppress++;
    [uc.items removeAllObjects];
    [uc.ids removeAllObjects];
    if (uc.popup)
        [uc.popup removeAllItems];
    else if (uc.combo)
        [uc.combo removeAllItems];
    else
        [uc.table reloadData];
    box_of(dp)->suppress--;
}

void dlg_listbox_del(dlgcontrol *ctrl, dlgparam *dp, int index)
{
    MTCtrl *uc = [box_of(dp) uctrl:ctrl];
    assert(uc);
    if (index < 0 || index >= (int)uc.items.count)
        return;
    box_of(dp)->suppress++;
    [uc.items removeObjectAtIndex:index];
    [uc.ids removeObjectAtIndex:index];
    if (uc.popup)
        [uc.popup removeItemAtIndex:index];
    else if (uc.combo)
        [uc.combo removeItemAtIndex:index];
    else
        [uc.table reloadData];
    box_of(dp)->suppress--;
}

void dlg_listbox_addwithid(dlgcontrol *ctrl, dlgparam *dp,
                           char const *text, int id)
{
    MTCtrl *uc = [box_of(dp) uctrl:ctrl];
    assert(uc);
    NSString *s = ns_string(text);
    if (!uc.items) {
        uc.items = [NSMutableArray array];
        uc.ids = [NSMutableArray array];
    }
    box_of(dp)->suppress++;
    [uc.items addObject:s];
    [uc.ids addObject:@(id)];
    if (uc.popup) {
        /* addItemWithTitle: would merge duplicate titles. */
        [uc.popup.menu addItemWithTitle:s action:NULL keyEquivalent:@""];
    } else if (uc.combo) {
        [uc.combo addItemWithObjectValue:s];
    } else {
        [uc.table reloadData];
    }
    box_of(dp)->suppress--;
}

void dlg_listbox_add(dlgcontrol *ctrl, dlgparam *dp, char const *text)
{
    dlg_listbox_addwithid(ctrl, dp, text, 0);
}

int dlg_listbox_getid(dlgcontrol *ctrl, dlgparam *dp, int index)
{
    MTCtrl *uc = [box_of(dp) uctrl:ctrl];
    assert(uc);
    if (index < 0 || index >= (int)uc.ids.count)
        return 0;
    return uc.ids[index].intValue;
}

int dlg_listbox_index(dlgcontrol *ctrl, dlgparam *dp)
{
    MTCtrl *uc = [box_of(dp) uctrl:ctrl];
    assert(uc);
    if (uc.popup)
        return (int)uc.popup.indexOfSelectedItem;
    if (uc.combo)
        return (int)uc.combo.indexOfSelectedItem;
    if (uc.table.numberOfSelectedRows != 1)
        return -1;
    return (int)uc.table.selectedRow;
}

bool dlg_listbox_issel(dlgcontrol *ctrl, dlgparam *dp, int index)
{
    MTCtrl *uc = [box_of(dp) uctrl:ctrl];
    assert(uc);
    if (uc.popup)
        return uc.popup.indexOfSelectedItem == index;
    if (uc.combo)
        return uc.combo.indexOfSelectedItem == index;
    return [uc.table isRowSelected:index];
}

void dlg_listbox_select(dlgcontrol *ctrl, dlgparam *dp, int index)
{
    MTCtrl *uc = [box_of(dp) uctrl:ctrl];
    assert(uc);
    box_of(dp)->suppress++;
    if (uc.popup) {
        [uc.popup selectItemAtIndex:index];
    } else if (uc.combo) {
        if (index >= 0 && index < uc.combo.numberOfItems)
            [uc.combo selectItemAtIndex:index];
    } else if (index >= 0 && index < uc.table.numberOfRows) {
        [uc.table selectRowIndexes:[NSIndexSet indexSetWithIndex:index]
              byExtendingSelection:NO];
        [uc.table scrollRowToVisible:index];
    }
    box_of(dp)->suppress--;
}

void dlg_text_set(dlgcontrol *ctrl, dlgparam *dp, char const *text)
{
    MTCtrl *uc = [box_of(dp) uctrl:ctrl];
    assert(uc && uc.view);
    ((NSTextField *)uc.view).stringValue = ns_string(text);
}

void dlg_label_change(dlgcontrol *ctrl, dlgparam *dp, char const *text)
{
    MTCtrl *uc = [box_of(dp) uctrl:ctrl];
    if (!uc)
        return;
    NSString *s = ns_string(text);
    switch (ctrl->type) {
      case CTRL_BUTTON:
      case CTRL_CHECKBOX:
        uc.button.title = s;
        break;
      default:
        uc.label.stringValue = s;
        break;
    }
}

void dlg_filesel_set(dlgcontrol *ctrl, dlgparam *dp, Filename *fn)
{
    MTCtrl *uc = [box_of(dp) uctrl:ctrl];
    assert(uc);
    if (uc.field)
        uc.field.stringValue = ns_string(fn->path);
    else
        uc.fontSpec = ns_string(fn->path);
}

Filename *dlg_filesel_get(dlgcontrol *ctrl, dlgparam *dp)
{
    MTCtrl *uc = [box_of(dp) uctrl:ctrl];
    assert(uc);
    NSString *s = uc.field ? uc.field.stringValue : uc.fontSpec;
    return filename_from_str(s.UTF8String ? s.UTF8String : "");
}

void dlg_fontsel_set(dlgcontrol *ctrl, dlgparam *dp, FontSpec *fs)
{
    MTCtrl *uc = [box_of(dp) uctrl:ctrl];
    assert(uc && uc.field);
    uc.fontSpec = ns_string(fs->name);
    char *disp = fs->name[0] ? mactty_font_display_name(fs->name)
                             : dupstr("(none)");
    uc.field.stringValue = ns_string(disp);
    sfree(disp);
}

FontSpec *dlg_fontsel_get(dlgcontrol *ctrl, dlgparam *dp)
{
    MTCtrl *uc = [box_of(dp) uctrl:ctrl];
    assert(uc);
    return fontspec_new(uc.fontSpec.UTF8String ?: "");
}

void dlg_update_start(dlgcontrol *ctrl, dlgparam *dp)
{
    /* Nothing to do: AppKit redraws lazily anyway. */
}

void dlg_update_done(dlgcontrol *ctrl, dlgparam *dp)
{
}

void dlg_set_focus(dlgcontrol *ctrl, dlgparam *dp)
{
    MTControlBox *b = box_of(dp);
    MTCtrl *uc = [b uctrl:ctrl];
    if (!uc)
        return;
    if (uc.panel >= 0 && uc.panel != b.currentPanel && b->ctrlbox &&
        b.window.isVisible)
        [b showPanel:uc.panel];
    NSView *v = uc.field ?: uc.table ?: uc.popup ?: uc.button ?:
        (uc.radios.count ? uc.radios[MAX(0, dlg_radiobutton_get(ctrl, dp))]
                         : uc.view);
    [b.window makeFirstResponder:v];
    [b noteFocusOn:ctrl];
}

dlgcontrol *dlg_last_focused(dlgcontrol *ctrl, dlgparam *dp)
{
    MTControlBox *b = box_of(dp);
    return b->currfocus != ctrl ? b->currfocus : b->lastfocus;
}

bool dlg_is_visible(dlgcontrol *ctrl, dlgparam *dp)
{
    MTControlBox *b = box_of(dp);
    MTCtrl *uc = [b uctrl:ctrl];
    return uc && (uc.panel < 0 || uc.panel == b.currentPanel);
}

void dlg_beep(dlgparam *dp)
{
    NSBeep();
}

void dlg_error_msg(dlgparam *dp, const char *msg)
{
    MTControlBox *b = box_of(dp);
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"Error";
    alert.informativeText = ns_string(msg);
    [alert beginSheetModalForWindow:b.window completionHandler:nil];
}

void dlg_end(dlgparam *dp, int value)
{
    MTControlBox *b = box_of(dp);
    /* Defer, because we are inside a handler for one of the controls
     * we are about to destroy. */
    dispatch_async(dispatch_get_main_queue(), ^{
        [b endWithValue:value];
    });
}

void dlg_coloursel_start(dlgcontrol *ctrl, dlgparam *dp, int r, int g, int b)
{
    [box_of(dp) startColourFor:ctrl r:r g:g b:b];
}

bool dlg_coloursel_results(dlgcontrol *ctrl, dlgparam *dp,
                           int *r, int *g, int *b)
{
    return [box_of(dp) colourResultsR:r g:g b:b];
}

void dlg_refresh(dlgcontrol *ctrl, dlgparam *dp)
{
    MTControlBox *b = box_of(dp);
    if (ctrl) {
        if (ctrl->handler)
            ctrl->handler(ctrl, dp, b->data, EVENT_REFRESH);
        return;
    }
    if (!b->ctrlbox)
        return;
    for (size_t i = 0; i < b->ctrlbox->nctrlsets; i++) {
        struct controlset *s = b->ctrlbox->ctrlsets[i];
        for (size_t j = 0; j < s->ncontrols; j++) {
            dlgcontrol *c = s->ctrls[j];
            if (c->handler)
                c->handler(c, dp, b->data, EVENT_REFRESH);
        }
    }
}
