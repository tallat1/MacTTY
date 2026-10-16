/*
 * TerminalView.h: the view that draws the terminal and turns keyboard
 * and mouse input into what PuTTY's terminal expects.
 */

#import <Cocoa/Cocoa.h>

#include "putty.h"
#include "terminal.h"

@class MTSession;

@interface MTTerminalView : NSView <NSTextInputClient>

@property (nonatomic, unsafe_unretained) MTSession *session;
@property (nonatomic, readonly) int fontWidth, fontHeight;
@property (nonatomic) int border;
@property (nonatomic) BOOL sendRawMouse;
@property (nonatomic) BOOL pointerIndicatesRawMouse;
@property (nonatomic) BusyStatus busyStatus;

/* Loads the fonts named in conf. Returns nil on success, otherwise a
 * description of the problem (and the old fonts stay in use). */
- (NSString *)setupFontsFromConf:(Conf *)conf;
- (void)setFontQuality:(int)quality;

/* Geometry: the view size for a given grid, and the grid for a size. */
- (NSSize)sizeForCols:(int)cols rows:(int)rows;
- (void)gridForSize:(NSSize)size cols:(int *)cols rows:(int *)rows;

/* TermWin drawing. All draw calls come between setupDrawCtx and
 * freeDrawCtx, exactly as PuTTY's terminal makes them. */
- (BOOL)setupDrawCtx;
- (void)freeDrawCtx;
- (void)drawText:(wchar_t *)text length:(int)len x:(int)x y:(int)y
            attr:(unsigned long)attr lattr:(int)lattr
      truecolour:(truecolour)tc;
- (void)drawCursor:(wchar_t *)text length:(int)len x:(int)x y:(int)y
              attr:(unsigned long)attr lattr:(int)lattr
        truecolour:(truecolour)tc;
- (void)drawTrustSigilAtX:(int)x y:(int)y;
- (void)setPaletteFrom:(unsigned)start count:(unsigned)n
               colours:(const rgb *)colours;
- (NSColor *)defaultBackgroundColour;
- (rgb)paletteColour:(int)index;
- (void)setCursorCellX:(int)x y:(int)y;

- (void)showMousePointer:(BOOL)show;

@end
