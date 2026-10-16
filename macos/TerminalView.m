/*
 * TerminalView.m: drawing and input for the terminal.
 *
 * Drawing follows the GTK front end: PuTTY's terminal paints changed
 * cells into a backing bitmap (here a CGBitmapContext in points with a
 * top-left origin), and drawRect: only copies that bitmap to the
 * screen. Keyboard translation is a port of key_event() in
 * unix/window.c, using the shared format_*_key helpers from terminal.c.
 */

#import "TerminalView.h"
#import "Session.h"
#import <Carbon/Carbon.h>          /* kVK_* virtual key codes */
#import <CoreText/CoreText.h>

#include "mactty.h"

/* ----------------------------------------------------------------------
 * Font specifications: "<PostScript name> <size>".
 */

static CTFontRef font_from_spec(const char *spec)
{
    char *name = dupstr(spec);
    char *space = strrchr(name, ' ');
    CGFloat size = 0;
    if (space) {
        size = atof(space + 1);
        if (size > 0)
            *space = '\0';
    }
    if (size <= 0)
        size = 13;

    CFStringRef cfname = CFStringCreateWithCString(
        NULL, name, kCFStringEncodingUTF8);
    sfree(name);
    if (!cfname)
        return NULL;
    CTFontRef font = CTFontCreateWithName(cfname, size, NULL);

    /* CTFontCreateWithName substitutes a default font rather than
     * failing; treat a substitution as "not found". */
    CFStringRef got = CTFontCopyPostScriptName(font);
    CFStringRef gotfamily = CTFontCopyFamilyName(font);
    bool ok = (CFStringCompare(got, cfname, kCFCompareCaseInsensitive) ==
               kCFCompareEqualTo ||
               CFStringCompare(gotfamily, cfname,
                               kCFCompareCaseInsensitive) ==
               kCFCompareEqualTo);
    CFRelease(got);
    CFRelease(gotfamily);
    CFRelease(cfname);
    if (!ok) {
        CFRelease(font);
        return NULL;
    }
    return font;
}

char *mactty_font_display_name(const char *spec)
{
    CTFontRef font = font_from_spec(spec);
    if (!font)
        return dupstr(spec);
    NSString *display = CFBridgingRelease(CTFontCopyDisplayName(font));
    char *ret = dupprintf("%s, %g-point", display.UTF8String,
                          (double)CTFontGetSize(font));
    CFRelease(font);
    return ret;
}

/* ---------------------------------------------------------------------- */

@implementation MTTerminalView {
    CTFontRef fonts[2];             /* normal, bold (bold may be NULL) */
    CGFloat fontAscentF;
    int fontAscent;
    int fontQuality;
    CGFloat glyphScaleX;            /* horizontal stretch of fitted fonts */
    int offsetX, offsetY;           /* centring of a fitted grid */

    rgb palette[OSC4_NCOLOURS];

    CGContextRef backing;
    size_t backingPW, backingPH;
    CGFloat backingScale;
    NSRect dirty;

    NSCache<NSNumber *, id> *fallbackFonts;

    /* Text input */
    NSString *markedText;
    BOOL keyHandledByInput;
    NSEvent *currentKeyEvent;
    int cursorX, cursorY;

    /* Mouse */
    int lastButton;
    BOOL mouseHidden;
    CGFloat scrollAccumulator;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        fallbackFonts = [NSCache new];
        markedText = @"";
        _border = 1;
        glyphScaleX = 1;
        for (int i = 0; i < OSC4_NCOLOURS; i++)
            palette[i] = (rgb){0, 0, 0};
        palette[OSC4_COLOUR_fg] = palette[OSC4_COLOUR_fg_bold] =
            (rgb){187, 187, 187};
    }
    return self;
}

- (void)dealloc
{
    for (int i = 0; i < 2; i++)
        if (fonts[i])
            CFRelease(fonts[i]);
    if (backing)
        CGContextRelease(backing);
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isOpaque { return YES; }

/* ----------------------------------------------------------------------
 * Fonts and geometry.
 */

/* Cell width from the advance of a representative glyph. */
static CGFloat font_advance(CTFontRef font)
{
    UniChar ch = 'M';
    CGGlyph glyph;
    CGSize advance = CGSizeZero;
    CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1);
    CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal,
                               &glyph, &advance, 1);
    return advance.width;
}

static int font_cell_height(CTFontRef font)
{
    return (int)ceil(CTFontGetAscent(font)) +
        (int)ceil(CTFontGetDescent(font)) +
        (int)round(CTFontGetLeading(font));
}

/*
 * Loads the fonts named in conf. Given a cell size, the fonts are scaled
 * to fill cells of exactly that size, as init_fonts() in Windows PuTTY
 * does when it is passed a width and height: the point size follows the
 * cell height and the glyphs are stretched horizontally to the width.
 */
- (NSString *)loadFontsFromConf:(Conf *)conf cellWidth:(int)cellw
                         height:(int)cellh
{
    FontSpec *fs = conf_get_fontspec(conf, CONF_font);
    CTFontRef font = font_from_spec(fs->name);
    if (!font)
        return [NSString stringWithFormat:@"unable to load font \"%s\"",
                fs->name];

    int width = (int)ceil(font_advance(font) - 0.01);
    int height = font_cell_height(font);
    CGFloat scale = 1;
    if (cellw > 0 && cellh > 0 && (cellw != width || cellh != height)) {
        CGFloat size = CTFontGetSize(font) * cellh /
            (CTFontGetAscent(font) + CTFontGetDescent(font) +
             CTFontGetLeading(font));
        CTFontRef scaled;
        for (;;) {
            scaled = CTFontCreateCopyWithAttributes(font, size, NULL, NULL);
            if (font_cell_height(scaled) <= cellh || size <= 1)
                break;
            CFRelease(scaled);
            size -= 0.25;
        }
        CFRelease(font);
        font = scaled;
        CGFloat advance = font_advance(font);
        if (advance > 0)
            scale = cellw / advance;
        width = cellw;
        height = cellh;
    }

    CTFontRef bold = NULL;
    FontSpec *bfs = conf_get_fontspec(conf, CONF_boldfont);
    if (bfs->name[0])
        bold = font_from_spec(bfs->name);
    if (bold && scale != 1) {
        CTFontRef scaled = CTFontCreateCopyWithAttributes(
            bold, CTFontGetSize(font), NULL, NULL);
        CFRelease(bold);
        bold = scaled;
    }
    if (!bold)
        bold = CTFontCreateCopyWithSymbolicTraits(
            font, 0, NULL, kCTFontBoldTrait, kCTFontBoldTrait);

    for (int i = 0; i < 2; i++)
        if (fonts[i])
            CFRelease(fonts[i]);
    fonts[0] = font;
    fonts[1] = bold;
    [fallbackFonts removeAllObjects];

    fontAscentF = CTFontGetAscent(font);
    fontAscent = (int)ceil(fontAscentF);
    glyphScaleX = scale;
    _fontWidth = width < 1 ? 1 : width;
    _fontHeight = height < 1 ? 1 : height;
    return nil;
}

- (NSString *)setupFontsFromConf:(Conf *)conf
{
    NSString *err = [self loadFontsFromConf:conf cellWidth:0 height:0];
    if (!err) {
        _fontsFitted = NO;
        offsetX = offsetY = 0;
    }
    return err;
}

- (BOOL)fitFontsFromConf:(Conf *)conf cols:(int)cols rows:(int)rows
{
    /* The equivalent of the font branch of reset_window() in Windows
     * PuTTY: whole cells, the remainder split round the edges. */
    NSSize size = self.bounds.size;
    int cellw = ((int)size.width - 2 * _border) / cols;
    int cellh = ((int)size.height - 2 * _border) / rows;
    if (cellw < 1) cellw = 1;
    if (cellh < 1) cellh = 1;

    BOOL changed = NO;
    if (!_fontsFitted || cellw != _fontWidth || cellh != _fontHeight) {
        if ([self loadFontsFromConf:conf cellWidth:cellw height:cellh])
            return NO;              /* keep the fonts we have */
        _fontsFitted = YES;
        changed = YES;
    }
    int ox = ((int)size.width - 2 * _border - cols * _fontWidth) / 2;
    int oy = ((int)size.height - 2 * _border - rows * _fontHeight) / 2;
    if (ox < 0) ox = 0;
    if (oy < 0) oy = 0;
    if (ox != offsetX || oy != offsetY) {
        offsetX = ox;
        offsetY = oy;
        changed = YES;
    }
    if (changed) {
        /* Cells now cover different pixels: clear what they left. */
        [self fillBackingWithBackground];
        [self setNeedsDisplay:YES];
    }
    return changed;
}

- (void)setFontQuality:(int)quality
{
    fontQuality = quality;
}

- (NSSize)sizeForCols:(int)cols rows:(int)rows
{
    return NSMakeSize(cols * _fontWidth + 2 * _border,
                      rows * _fontHeight + 2 * _border);
}

- (void)gridForSize:(NSSize)size cols:(int *)cols rows:(int *)rows
{
    int w = (int)((size.width - 2 * _border) / _fontWidth);
    int h = (int)((size.height - 2 * _border) / _fontHeight);
    *cols = w < 1 ? 1 : w;
    *rows = h < 1 ? 1 : h;
}

/* ----------------------------------------------------------------------
 * Backing bitmap.
 */

static void set_fill_rgb(CGContextRef ctx, rgb c, bool dim)
{
    CGFloat k = dim ? (2.0/3.0) : 1.0;
    CGContextSetRGBFillColor(ctx, c.r * k / 255.0, c.g * k / 255.0,
                             c.b * k / 255.0, 1.0);
}

static void set_stroke_rgb(CGContextRef ctx, rgb c, bool dim)
{
    CGFloat k = dim ? (2.0/3.0) : 1.0;
    CGContextSetRGBStrokeColor(ctx, c.r * k / 255.0, c.g * k / 255.0,
                               c.b * k / 255.0, 1.0);
}

- (NSColor *)defaultBackgroundColour
{
    rgb c = palette[OSC4_COLOUR_bg];
    return [NSColor colorWithSRGBRed:c.r/255.0 green:c.g/255.0
                                blue:c.b/255.0 alpha:1];
}

- (rgb)paletteColour:(int)index
{
    if (index < 0 || index >= OSC4_NCOLOURS)
        index = OSC4_COLOUR_fg;
    return palette[index];
}

- (void)viewDidChangeEffectiveAppearance
{
    [super viewDidChangeEffectiveAppearance];
    [self.session appearanceChanged];
}

- (void)fillBackingWithBackground
{
    if (!backing)
        return;
    set_fill_rgb(backing, palette[OSC4_COLOUR_bg], false);
    CGContextFillRect(backing, CGRectMake(0, 0, backingPW / backingScale,
                                          backingPH / backingScale));
}

- (BOOL)ensureBacking
{
    NSSize size = self.bounds.size;
    CGFloat scale = self.window ? self.window.backingScaleFactor : 2.0;
    size_t pw = (size_t)ceil(size.width * scale);
    size_t ph = (size_t)ceil(size.height * scale);
    if (pw == 0 || ph == 0)
        return NO;
    if (backing && pw == backingPW && ph == backingPH &&
        scale == backingScale)
        return YES;

    if (backing)
        CGContextRelease(backing);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    backing = CGBitmapContextCreate(
        NULL, pw, ph, 8, 0, cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!backing)
        return NO;
    backingPW = pw;
    backingPH = ph;
    backingScale = scale;

    /* Work in points with a top-left origin, like the terminal does. */
    CGContextTranslateCTM(backing, 0, ph);
    CGContextScaleCTM(backing, scale, -scale);
    [self fillBackingWithBackground];

    MTSession *s = self.session;
    if (s && s->term)
        term_invalidate(s->term);
    [self setNeedsDisplay:YES];
    return YES;
}

- (void)viewDidChangeBackingProperties
{
    [super viewDidChangeBackingProperties];
    [self ensureBacking];
}

- (void)setFrameSize:(NSSize)newSize
{
    [super setFrameSize:newSize];
    [self ensureBacking];
    [self.session terminalViewDidChangeSize];
}

- (void)drawRect:(NSRect)rect
{
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!backing) {
        [[self defaultBackgroundColour] setFill];
        NSRectFill(rect);
        return;
    }
    CGImageRef image = CGBitmapContextCreateImage(backing);
    CGFloat w = backingPW / backingScale, h = backingPH / backingScale;
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, 0, self.bounds.size.height);
    CGContextScaleCTM(ctx, 1, -1);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
    CGContextDrawImage(
        ctx, CGRectMake(0, self.bounds.size.height - h, w, h), image);
    CGContextRestoreGState(ctx);
    CGImageRelease(image);
}

/* ----------------------------------------------------------------------
 * TermWin drawing.
 */

- (BOOL)setupDrawCtx
{
    dirty = NSZeroRect;
    return [self ensureBacking];
}

- (void)freeDrawCtx
{
    if (!NSIsEmptyRect(dirty))
        [self setNeedsDisplayInRect:NSInsetRect(dirty, -1, -1)];
    dirty = NSZeroRect;
}

- (void)markDirty:(CGRect)r
{
    dirty = NSIsEmptyRect(dirty) ? NSRectFromCGRect(r)
                                 : NSUnionRect(dirty, NSRectFromCGRect(r));
}

- (CTFontRef)fontForCharacter:(UTF32Char)c bold:(BOOL)bold
                        glyph:(CGGlyph *)glyph
{
    CTFontRef base = (bold && fonts[1]) ? fonts[1] : fonts[0];
    UniChar u[2];
    CFIndex n = 1;
    if (c > 0xFFFF) {
        c -= 0x10000;
        u[0] = 0xD800 + (c >> 10);
        u[1] = 0xDC00 + (c & 0x3FF);
        n = 2;
    } else {
        u[0] = (UniChar)c;
    }
    CGGlyph g[2] = {0, 0};
    if (CTFontGetGlyphsForCharacters(base, u, g, n) && g[0]) {
        *glyph = g[0];
        return base;
    }

    /* Ask Core Text for a font that has this character. */
    NSNumber *key = @((unsigned)c * 2 + (bold ? 1 : 0));
    id cached = [fallbackFonts objectForKey:key];
    CTFontRef fallback;
    if (cached) {
        if (cached == [NSNull null]) {
            *glyph = 0;
            return base;
        }
        fallback = (__bridge CTFontRef)cached;
    } else {
        CFStringRef str = CFStringCreateWithCharacters(NULL, u, n);
        fallback = CTFontCreateForString(base, str, CFRangeMake(0, n));
        CFRelease(str);
        [fallbackFonts setObject:fallback ? (__bridge_transfer id)fallback
                                          : [NSNull null]
                          forKey:key];
        if (!fallback) {
            *glyph = 0;
            return base;
        }
    }
    if (CTFontGetGlyphsForCharacters(fallback, u, g, n) && g[0]) {
        *glyph = g[0];
        return fallback;
    }
    *glyph = 0;
    return base;
}

/*
 * Draw 'len' characters starting at cell (0,0) of the current
 * coordinate system, each in a cell of 'cellw' points.
 *
 * Core Text draws glyphs upright only in an unflipped coordinate
 * system, and CTFontDrawGlyphs resets the text matrix, so each run is
 * drawn with the y axis flipped back around the baseline.
 */
- (void)drawGlyphs:(const wchar_t *)text length:(int)len
         cellWidth:(CGFloat)cellw bold:(BOOL)bold
{
    CGContextRef ctx = backing;
    CGGlyph glyphs[len > 0 ? len : 1];
    CGPoint positions[len > 0 ? len : 1];
    CTFontRef runfont = NULL;
    int n = 0;
    BOOL shadow = bold && !fonts[1];

    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, 0, fontAscent);
    CGContextScaleCTM(ctx, glyphScaleX, -1);

    for (int i = 0; i <= len; i++) {
        CGGlyph glyph = 0;
        CTFontRef font = NULL;
        CGFloat x = 0;
        if (i < len) {
            UTF32Char c = (UTF32Char)text[i];
            if ((c & CSET_MASK) == CSET_ACP || (c & CSET_MASK) == CSET_OEMCP)
                c &= ~CSET_MASK;   /* never generated with Unicode fonts */
            if (c == ' ' || c == 0 || c == 0xA0 ||
                (c >= 0xD800 && c < 0xE000))
                continue;
            font = [self fontForCharacter:c bold:bold glyph:&glyph];
            if (!glyph)
                continue;
            CGSize adv;
            CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal,
                                       &glyph, &adv, 1);
            CGFloat w = adv.width * glyphScaleX;
            x = i * cellw;
            if (w < cellw - 0.5)
                x += (cellw - w) / 2;          /* centre narrow glyphs */
        }
        if (n > 0 && (i == len || font != runfont)) {
            CTFontDrawGlyphs(runfont, glyphs, positions, n, ctx);
            if (shadow) {
                for (int k = 0; k < n; k++)
                    positions[k].x += 1 / glyphScaleX;
                CTFontDrawGlyphs(runfont, glyphs, positions, n, ctx);
            }
            n = 0;
        }
        if (i == len)
            break;
        runfont = font;
        glyphs[n] = glyph;
        positions[n] = CGPointMake(x / glyphScaleX, 0);
        n++;
    }
    CGContextRestoreGState(ctx);
}

- (void)drawCombining:(const wchar_t *)text count:(int)n
            cellWidth:(CGFloat)cellw bold:(BOOL)bold
{
    NSString *str = [[NSString alloc]
        initWithBytes:text length:n * sizeof(wchar_t)
             encoding:NSUTF32LittleEndianStringEncoding];
    if (!str)
        return;
    CTFontRef font = (bold && fonts[1]) ? fonts[1] : fonts[0];
    NSDictionary *attrs = @{
        (__bridge id)kCTFontAttributeName: (__bridge id)font,
        (__bridge id)kCTForegroundColorFromContextAttributeName: @YES,
    };
    NSAttributedString *astr =
        [[NSAttributedString alloc] initWithString:str attributes:attrs];
    CTLineRef line = CTLineCreateWithAttributedString(
        (__bridge CFAttributedStringRef)astr);
    double width = CTLineGetTypographicBounds(line, NULL, NULL, NULL) *
        glyphScaleX;
    CGFloat x = width < cellw ? (cellw - width) / 2 : 0;
    CGContextSaveGState(backing);
    CGContextTranslateCTM(backing, 0, fontAscent);
    CGContextScaleCTM(backing, glyphScaleX, -1);
    CGContextSetTextMatrix(backing, CGAffineTransformIdentity);
    CGContextSetTextPosition(backing, x / glyphScaleX, 0);
    CTLineDraw(line, backing);
    CGContextRestoreGState(backing);
    CFRelease(line);
}

/* The equivalent of do_text_internal() in unix/window.c. */
- (void)doText:(wchar_t *)text length:(int)len x:(int)x y:(int)y
          attr:(unsigned long)attr lattr:(int)lattr
    truecolour:(truecolour)tc
{
    MTSession *s = self.session;
    Terminal *term = s->term;
    int ncombining, nfg, nbg, widefactor, rlen;
    bool bold;

    if (!backing)
        return;

    if (attr & TATTR_COMBINING) {
        ncombining = len;
        len = 1;
    } else
        ncombining = 1;

    nfg = (int)((attr & ATTR_FGMASK) >> ATTR_FGSHIFT);
    nbg = (int)((attr & ATTR_BGMASK) >> ATTR_BGSHIFT);
    if (attr & ATTR_REVERSE) {
        int t = nfg; nfg = nbg; nbg = t;
        optionalrgb trgb = tc.fg; tc.fg = tc.bg; tc.bg = trgb;
    }
    if ((s->bold_style & BOLD_STYLE_COLOUR) && (attr & ATTR_BOLD)) {
        if (nfg < 16) nfg |= 8;
        else if (nfg >= 256) nfg |= 1;
    }
    if ((s->bold_style & BOLD_STYLE_COLOUR) && (attr & ATTR_BLINK)) {
        if (nbg < 16) nbg |= 8;
        else if (nbg >= 256) nbg |= 1;
    }
    if (attr & ATTR_ACTCURS) {
        tc.fg = tc.bg = optionalrgb_none;
        nfg = OSC4_COLOUR_cursor_fg;
        nbg = OSC4_COLOUR_cursor_bg;
        attr &= ~ATTR_DIM;             /* don't dim the cursor */
    }

    widefactor = (attr & ATTR_WIDE) ? 2 : 1;
    bold = (attr & ATTR_BOLD) && (s->bold_style & BOLD_STYLE_FONT);

    if ((lattr & LATTR_MODE) != LATTR_NORM) {
        x *= 2;
        if (x >= term->cols)
            return;
        if (x + len*2*widefactor > term->cols) {
            len = (term->cols-x)/2/widefactor;  /* trim to LH half */
            if (len == 0)
                return;
        }
        rlen = len * 2;
    } else
        rlen = len;

    CGContextRef ctx = backing;
    CGRect cell = CGRectMake(x * _fontWidth + _border + offsetX,
                             y * _fontHeight + _border + offsetY,
                             rlen * widefactor * _fontWidth, _fontHeight);
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, cell);

    rgb bg = tc.bg.enabled ? (rgb){tc.bg.r, tc.bg.g, tc.bg.b}
                           : palette[nbg];
    rgb fg = tc.fg.enabled ? (rgb){tc.fg.r, tc.fg.g, tc.fg.b}
                           : palette[nfg];
    bool dim = (attr & ATTR_DIM) != 0;

    set_fill_rgb(ctx, bg, dim);
    CGContextFillRect(ctx, cell);

    /* Move to the cell origin; double-width and double-height lines
     * are drawn by scaling around it. */
    CGContextTranslateCTM(ctx, cell.origin.x, cell.origin.y);
    if ((lattr & LATTR_MODE) != LATTR_NORM) {
        if ((lattr & LATTR_MODE) == LATTR_WIDE) {
            CGContextScaleCTM(ctx, 2, 1);
        } else {
            CGContextScaleCTM(ctx, 2, 2);
            if ((lattr & LATTR_MODE) == LATTR_BOT)
                CGContextTranslateCTM(ctx, 0, -_fontHeight / 2.0);
        }
    }

    CGContextSetShouldAntialias(ctx, fontQuality != FQ_NONANTIALIASED);
    set_fill_rgb(ctx, fg, dim);
    CGFloat cellw = _fontWidth * widefactor;
    if (ncombining > 1)
        [self drawCombining:text count:ncombining cellWidth:cellw bold:bold];
    else
        [self drawGlyphs:text length:len cellWidth:cellw bold:bold];

    if (attr & (ATTR_UNDER | ATTR_STRIKE)) {
        set_stroke_rgb(ctx, fg, dim);
        CGContextSetLineWidth(ctx, 1);
        CGContextSetShouldAntialias(ctx, false);
        if (attr & ATTR_UNDER) {
            CGFloat uy = fontAscent + 1;
            if (uy >= _fontHeight)
                uy = _fontHeight - 1;
            CGContextStrokeLineSegments(ctx, (CGPoint[]){
                    {0, uy + 0.5}, {len * cellw, uy + 0.5}}, 2);
        }
        if (attr & ATTR_STRIKE) {
            CGFloat sy = fontAscent - round(CTFontGetXHeight(fonts[0]) / 2);
            CGContextStrokeLineSegments(ctx, (CGPoint[]){
                    {0, sy + 0.5}, {len * cellw, sy + 0.5}}, 2);
        }
    }

    CGContextRestoreGState(ctx);
    [self markDirty:cell];
}

- (void)drawText:(wchar_t *)text length:(int)len x:(int)x y:(int)y
            attr:(unsigned long)attr lattr:(int)lattr
      truecolour:(truecolour)tc
{
    [self doText:text length:len x:x y:y attr:attr lattr:lattr truecolour:tc];
}

- (void)drawCursor:(wchar_t *)text length:(int)len x:(int)x y:(int)y
              attr:(unsigned long)attr lattr:(int)lattr
        truecolour:(truecolour)tc
{
    MTSession *s = self.session;
    bool active, passive;
    int widefactor, cursor_type = s->cursor_type;

    if (attr & ATTR_PASCURS) {
        attr &= ~ATTR_PASCURS;
        passive = true;
    } else
        passive = false;
    if ((attr & ATTR_ACTCURS) && cursor_type != CURSOR_BLOCK) {
        attr &= ~ATTR_ACTCURS;
        active = true;
    } else
        active = false;

    [self doText:text length:len x:x y:y attr:attr lattr:lattr truecolour:tc];

    if (attr & TATTR_COMBINING)
        len = 1;
    widefactor = (attr & ATTR_WIDE) ? 2 : 1;
    if ((lattr & LATTR_MODE) != LATTR_NORM) {
        x *= 2;
        if (x >= s->term->cols)
            return;
        if (x + len*2*widefactor > s->term->cols)
            len = (s->term->cols-x)/2/widefactor;
        len *= 2;
    }

    CGContextRef ctx = backing;
    if (!ctx)
        return;
    CGFloat cx = x * _fontWidth + _border + offsetX;
    CGFloat cy = y * _fontHeight + _border + offsetY;
    CGContextSaveGState(ctx);
    CGContextSetShouldAntialias(ctx, false);
    CGContextSetLineWidth(ctx, 1);
    set_stroke_rgb(ctx, palette[OSC4_COLOUR_cursor_bg], false);

    if (cursor_type == CURSOR_BLOCK) {
        /* An active block cursor was drawn by doText already. */
        if (passive)
            CGContextStrokeRect(ctx, CGRectMake(
                cx + 0.5, cy + 0.5, len * widefactor * _fontWidth - 1,
                _fontHeight - 1));
    } else if (active || passive) {
        int char_width = ((attr & ATTR_WIDE) ||
                          (lattr & LATTR_MODE) != LATTR_NORM) ?
            2 * _fontWidth : _fontWidth;
        if (cursor_type == CURSOR_UNDERLINE) {
            CGFloat uy = fontAscent + 1;
            if (uy >= _fontHeight)
                uy = _fontHeight - 1;
            if (passive) {
                for (int i = 0; i < char_width; i += 2)
                    CGContextFillRect(ctx, CGRectMake(cx + i, cy + uy, 1, 1));
            } else {
                set_fill_rgb(ctx, palette[OSC4_COLOUR_cursor_bg], false);
                CGContextFillRect(ctx, CGRectMake(cx, cy + uy, char_width, 1));
            }
        } else {
            if (passive) {
                for (int i = 0; i < _fontHeight; i += 2)
                    CGContextFillRect(ctx, CGRectMake(cx, cy + i, 1, 1));
            } else {
                set_fill_rgb(ctx, palette[OSC4_COLOUR_cursor_bg], false);
                CGContextFillRect(ctx, CGRectMake(cx, cy, 1, _fontHeight));
            }
        }
    }
    CGContextRestoreGState(ctx);
    [self markDirty:CGRectMake(cx, cy, len * widefactor * _fontWidth,
                               _fontHeight)];
}

- (void)drawTrustSigilAtX:(int)x y:(int)y
{
    if (!backing)
        return;
    CGRect r = CGRectMake(x * _fontWidth + _border + offsetX,
                          y * _fontHeight + _border + offsetY,
                          2 * _fontWidth, _fontHeight);
    CGFloat side = MIN(r.size.width, r.size.height);
    CGRect icon = CGRectMake(r.origin.x + (r.size.width - side) / 2,
                             r.origin.y + (r.size.height - side) / 2,
                             side, side);
    NSGraphicsContext *gc =
        [NSGraphicsContext graphicsContextWithCGContext:backing flipped:YES];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = gc;
    [NSApp.applicationIconImage drawInRect:NSRectFromCGRect(icon)];
    [NSGraphicsContext restoreGraphicsState];
    [self markDirty:r];
}

- (void)setPaletteFrom:(unsigned)start count:(unsigned)n
               colours:(const rgb *)colours
{
    assert(start <= OSC4_NCOLOURS);
    assert(n <= OSC4_NCOLOURS - start);
    for (unsigned i = 0; i < n; i++)
        palette[start + i] = colours[i];
    if (start <= OSC4_COLOUR_bg && OSC4_COLOUR_bg < start + n) {
        /* The border is drawn in the default background. */
        [self fillBackingWithBackground];
        self.window.backgroundColor = [self defaultBackgroundColour];
        MTSession *s = self.session;
        if (s && s->term)
            term_invalidate(s->term);
        [self setNeedsDisplay:YES];
    }
}

- (void)setCursorCellX:(int)x y:(int)y
{
    cursorX = x;
    cursorY = y;
}

/* ----------------------------------------------------------------------
 * Mouse pointer.
 */

- (void)resetCursorRects
{
    NSCursor *c;
    if (self.busyStatus != BUSY_NOT)
        c = NSCursor.operationNotAllowedCursor;
    else if (self.pointerIndicatesRawMouse)
        c = NSCursor.arrowCursor;
    else
        c = NSCursor.IBeamCursor;
    [self addCursorRect:self.bounds cursor:c];
}

- (void)setPointerIndicatesRawMouse:(BOOL)v
{
    _pointerIndicatesRawMouse = v;
    [self.window invalidateCursorRectsForView:self];
}

- (void)setBusyStatus:(BusyStatus)status
{
    _busyStatus = status;
    [self.window invalidateCursorRectsForView:self];
}

- (void)showMousePointer:(BOOL)show
{
    MTSession *s = self.session;
    if (!s || !conf_get_bool(s->conf, CONF_hide_mouseptr))
        show = YES;
    if (show && mouseHidden) {
        [NSCursor setHiddenUntilMouseMoves:NO];
        mouseHidden = NO;
    } else if (!show && !mouseHidden) {
        [NSCursor setHiddenUntilMouseMoves:YES];
        mouseHidden = YES;
    }
}

/* ----------------------------------------------------------------------
 * Keyboard. A port of key_event() in unix/window.c.
 */

static int return_key(Terminal *term, char *output, bool *special)
{
    int end;
    if (term->cr_lf_return) {
        output[1] = '\015';
        output[2] = '\012';
        end = 3;
    } else {
        output[1] = '\015';
        end = 2;
        *special = true;
    }
    return end;
}

static int function_key_number(unsigned short kc)
{
    switch (kc) {
      case kVK_F1: return 1;   case kVK_F2: return 2;
      case kVK_F3: return 3;   case kVK_F4: return 4;
      case kVK_F5: return 5;   case kVK_F6: return 6;
      case kVK_F7: return 7;   case kVK_F8: return 8;
      case kVK_F9: return 9;   case kVK_F10: return 10;
      case kVK_F11: return 11; case kVK_F12: return 12;
      case kVK_F13: return 13; case kVK_F14: return 14;
      case kVK_F15: return 15; case kVK_F16: return 16;
      case kVK_F17: return 17; case kVK_F18: return 18;
      case kVK_F19: return 19; case kVK_F20: return 20;
      default: return 0;
    }
}

/* The Mac keypad has no Num Lock: its Clear key sits where Num Lock
 * is on a PC keypad and is treated as such. */
static char numeric_keypad_key(unsigned short kc, bool *numeric)
{
    *numeric = false;
    switch (kc) {
      case kVK_ANSI_KeypadClear: return 'G';
      case kVK_ANSI_KeypadDivide: return '/';
      case kVK_ANSI_KeypadMultiply: return '*';
      case kVK_ANSI_KeypadMinus: return '-';
      case kVK_ANSI_KeypadPlus: return '+';
      case kVK_ANSI_KeypadEnter: return '\r';
      case kVK_ANSI_Keypad0: *numeric = true; return '0';
      case kVK_ANSI_Keypad1: *numeric = true; return '1';
      case kVK_ANSI_Keypad2: *numeric = true; return '2';
      case kVK_ANSI_Keypad3: *numeric = true; return '3';
      case kVK_ANSI_Keypad4: *numeric = true; return '4';
      case kVK_ANSI_Keypad5: *numeric = true; return '5';
      case kVK_ANSI_Keypad6: *numeric = true; return '6';
      case kVK_ANSI_Keypad7: *numeric = true; return '7';
      case kVK_ANSI_Keypad8: *numeric = true; return '8';
      case kVK_ANSI_Keypad9: *numeric = true; return '9';
      case kVK_ANSI_KeypadDecimal: *numeric = true; return '.';
      default: return 0;
    }
}

- (BOOL)performKeyEquivalent:(NSEvent *)event
{
    /* With "Command key acts as Meta", Command combinations go to the
     * terminal instead of the menus, as in the GTK OS X build. */
    MTSession *s = self.session;
    if (s && s->command_meta && self.window.firstResponder == self &&
        self.window.isKeyWindow &&
        (event.modifierFlags & NSEventModifierFlagCommand)) {
        [self keyDown:event];
        return YES;
    }
    return [super performKeyEquivalent:event];
}

#ifdef MACTTY_TEST_HOOKS
static NSMenuItem *menu_item_for_shortcut(NSMenu *menu, NSEvent *event)
{
    NSEventModifierFlags mods = event.modifierFlags &
        (NSEventModifierFlagCommand | NSEventModifierFlagShift |
         NSEventModifierFlagOption | NSEventModifierFlagControl);
    for (NSMenuItem *item in menu.itemArray) {
        if (item.submenu) {
            NSMenuItem *found = menu_item_for_shortcut(item.submenu, event);
            if (found)
                return found;
        } else if (item.keyEquivalent.length &&
                   item.keyEquivalentModifierMask == mods &&
                   [item.keyEquivalent isEqualToString:
                        event.charactersIgnoringModifiers.lowercaseString]) {
            return item;
        }
    }
    return nil;
}
#endif

- (void)keyDown:(NSEvent *)event
{
    MTSession *s = self.session;
    Terminal *term = s ? s->term : NULL;
    Conf *conf = s ? s->conf : NULL;
    if (!term)
        return;

#ifdef MACTTY_TEST_HOOKS
    /* Test builds: an app in the background has no key window, so its
     * menu shortcuts find no target and reach us as plain key presses.
     * Send the menu item's action up the responder chain from here, as
     * the menu would for the key window. */
    if (!NSApp.isActive && !s->command_meta &&
        (event.modifierFlags & NSEventModifierFlagCommand)) {
        NSMenuItem *item = menu_item_for_shortcut(NSApp.mainMenu, event);
        if (item.action) {
            [self tryToPerform:item.action with:item];
            return;
        }
    }
#endif

    NSEventModifierFlags flags = event.modifierFlags;
    bool shift = flags & NSEventModifierFlagShift;
    bool ctrl = flags & NSEventModifierFlagControl;
    bool option = flags & NSEventModifierFlagOption;
    bool command = flags & NSEventModifierFlagCommand;
    bool meta = (option && s->option_meta) || (command && s->command_meta);
    unsigned short kc = event.keyCode;

    char output[256];
    wchar_t ucsoutput[2];
    int start = 0, end = 0, output_charset = CS_UTF8;
    bool special = false, use_ucsoutput = false;
    bool generated = false;
    char num_keypad_key;
    bool numeric;

    noise_ultralight(NOISE_SOURCE_KEY, kc);

    /* Command combinations that are not Meta belong to the menus. */
    if (command && !s->command_meta) {
        [super keyDown:event];
        return;
    }

    /*
     * Scrollback keys don't generate keystrokes at all.
     */
    if (kc == kVK_PageUp && shift && ctrl) {
        term_scroll(term, 1, 0);
        return;
    }
    if (kc == kVK_PageUp && shift) {
        term_scroll(term, 0, -term->rows / 2);
        return;
    }
    if (kc == kVK_PageUp && ctrl) {
        term_scroll(term, 0, -1);
        return;
    }
    if (kc == kVK_PageDown && shift && ctrl) {
        term_scroll(term, -1, 0);
        return;
    }
    if (kc == kVK_PageDown && shift) {
        term_scroll(term, 0, +term->rows / 2);
        return;
    }
    if (kc == kVK_PageDown && ctrl) {
        term_scroll(term, 0, +1);
        return;
    }

    /* Shift-Ins pastes and Ctrl-Ins copies. Mac keyboards put the
     * Help key where PC keyboards have Insert. */
    if (kc == kVK_Help && shift) {
        if (conf_get_int(conf, CONF_ctrlshiftins) != CLIPUI_NONE) {
            term_request_paste(term, conf_get_int(conf, CONF_ctrlshiftins)
                               == CLIPUI_IMPLICIT ? CLIP_LOCAL : CLIP_SYSTEM);
            return;
        }
    }
    if (kc == kVK_Help && ctrl) {
        if (conf_get_int(conf, CONF_ctrlshiftins) == CLIPUI_EXPLICIT) {
            static const int clips[] = { CLIP_SYSTEM };
            term_request_copy(term, clips, lenof(clips));
            return;
        }
    }

    /* Ctrl-Shift-C and Ctrl-Shift-V. */
    if (shift && ctrl && !option &&
        (kc == kVK_ANSI_C || kc == kVK_ANSI_V)) {
        int cfgval = conf_get_int(conf, CONF_ctrlshiftcv);
        bool paste = (kc == kVK_ANSI_V);
        if (cfgval == CLIPUI_IMPLICIT || cfgval == CLIPUI_EXPLICIT) {
            int clip = (cfgval == CLIPUI_IMPLICIT) ? CLIP_LOCAL : CLIP_SYSTEM;
            if (paste) {
                term_request_paste(term, clip);
            } else if (cfgval == CLIPUI_EXPLICIT) {
                static const int clips[] = { CLIP_SYSTEM };
                term_request_copy(term, clips, lenof(clips));
            }
            return;
        }
    }

    /* Option-Return toggles full screen, if so configured. */
    if (option && (kc == kVK_Return || kc == kVK_ANSI_KeypadEnter) &&
        conf_get_bool(conf, CONF_fullscreenonaltenter)) {
        [s toggleFullScreenFromKeyboard];
        return;
    }

    /* Control-Break (Ctrl-Pause on PC keyboards, F15 on Mac ones)
     * sends a Break special to the back end. */
    if (ctrl && kc == kVK_F15) {
        if (s->backend)
            backend_special(s->backend, SS_BRK, 0);
        return;
    }

    /* ALT+things gives leading Escape. */
    output[0] = '\033';
    output[1] = '\0';

    num_keypad_key = numeric_keypad_key(kc, &numeric);
    bool nethack_mode = conf_get_bool(conf, CONF_nethack_keypad);
    bool app_keypad_mode = (term->app_keypad_keys &&
                            !conf_get_bool(conf, CONF_no_applic_k));
    bool force_format_numeric_keypad =
        (app_keypad_mode && num_keypad_key &&
         (numeric || term->funky_type != FUNKY_XTERM)) ||
        (nethack_mode && num_keypad_key >= '1' && num_keypad_key <= '9');

    int fkey = function_key_number(kc);
    bool is_special_key = fkey || num_keypad_key ||
        kc == kVK_Home || kc == kVK_End || kc == kVK_PageUp ||
        kc == kVK_PageDown || kc == kVK_ForwardDelete || kc == kVK_Help ||
        kc == kVK_UpArrow || kc == kVK_DownArrow || kc == kVK_LeftArrow ||
        kc == kVK_RightArrow || kc == kVK_Return || kc == kVK_Delete ||
        kc == kVK_Tab || kc == kVK_Escape;

    /*
     * Ordinary text keys without Control or Meta go through the input
     * system, which handles dead keys, Option-characters and input
     * methods; it calls back into insertText: below.
     */
    if (!is_special_key && !ctrl && !meta) {
        keyHandledByInput = NO;
        currentKeyEvent = event;
        [self interpretKeyEvents:@[event]];
        currentKeyEvent = nil;
        return;
    }

    /*
     * Work out the text this key would type without the Meta
     * modifier, and without Control (which we apply ourselves below,
     * in the same way as the GTK front end).
     */
    NSEventModifierFlags textmods = flags & NSEventModifierFlagShift;
    if (option && !s->option_meta)
        textmods |= NSEventModifierFlagOption;
    NSString *chars = [event charactersByApplyingModifiers:textmods];
    if (!chars)
        chars = event.charactersIgnoringModifiers;
    {
        const char *utf8 = chars.UTF8String;
        if (!utf8)
            utf8 = "";
        size_t n = strlen(utf8);
        if (n > lenof(output) - 2)
            n = lenof(output) - 2;
        memcpy(output + 1, utf8, n);
        output[1 + n] = '\0';
        end = 1 + (int)n;
    }
    /* Function keys etc. come back as private-use characters. */
    if (is_special_key)
        output[1] = '\0', end = 1;

    start = meta ? 0 : 1;
    if (meta && end == 1)
        end = 0;

    /* Control-` is the same as Control-\ */
    if (ctrl && end == 2 && output[1] == '`')
        output[1] = '\x1C';

    if (ctrl && end == 2) {
        int orig = (unsigned char)output[1], new = orig;
        if (new >= '3' && new <= '7')
            new += '\x1B' - '3';         /* ^3..^7 map to 0x1B..0x1F */
        else if (new == '2' || new == ' ')
            new = '\0';                  /* ^2 and ^Space are ^@ */
        else if (new == '8')
            new = '\x7F';                /* ^8 is DEL */
        else if (new == '/')
            new = '\x1F';                /* ^/ is ^_ */
        else if (new >= 0x40 && new < 0x7F)
            new &= 0x1F;
        output[1] = new;
    }

    /* Control-Shift-Space is 160 (ISO8859 nonbreaking space) */
    if (ctrl && shift && kc == kVK_Space) {
        output[1] = '\240';
        output_charset = CS_ISO8859_1;
        end = 2;
    }

    if (kc == kVK_Return) {
        end = return_key(term, output, &special);
    }

    /* We don't let the keyboard layout decide what Backspace is. */
    if (kc == kVK_Delete) {
        bool bksp_is_delete = conf_get_bool(conf, CONF_bksp_is_delete);
        if (shift)
            bksp_is_delete = !bksp_is_delete;
        output[1] = bksp_is_delete ? '\x7F' : '\x08';
        end = 2;
        special = true;
    }

    if (kc == kVK_Escape) {
        output[1] = '\033';
        end = 2;
    }

    /* Shift-Tab is ESC [ Z */
    if (kc == kVK_Tab) {
        if (shift)
            end = 1 + sprintf(output+1, "\033[Z");
        else {
            output[1] = '\t';
            end = 2;
        }
    }

    if (num_keypad_key && force_format_numeric_keypad) {
        end = 1 + format_numeric_keypad_key(
            output+1, term, num_keypad_key, shift, ctrl);
        goto done;
    }

    if (fkey) {
        bool consumed_meta_key = false;
        end = 1 + format_function_key(output+1, term, fkey, shift, ctrl,
                                      meta, &consumed_meta_key);
        if (consumed_meta_key)
            start = 1;
        goto done;
    }

    {
        int sk = -1;
        switch (kc) {
          case kVK_Home: sk = SKK_HOME; break;
          case kVK_Help: sk = SKK_INSERT; break;
          case kVK_ForwardDelete: sk = SKK_DELETE; break;
          case kVK_End: sk = SKK_END; break;
          case kVK_PageUp: sk = SKK_PGUP; break;
          case kVK_PageDown: sk = SKK_PGDN; break;
        }
        if (sk >= 0) {
            /* These keys don't generate terminal input with Ctrl */
            if (ctrl)
                return;
            bool consumed_meta_key = false;
            end = 1 + format_small_keypad_key(output+1, term, sk, shift,
                                              ctrl, meta,
                                              &consumed_meta_key);
            if (consumed_meta_key)
                start = 1;
            goto done;
        }
    }

    {
        int xkey = 0;
        switch (kc) {
          case kVK_UpArrow: xkey = 'A'; break;
          case kVK_DownArrow: xkey = 'B'; break;
          case kVK_RightArrow: xkey = 'C'; break;
          case kVK_LeftArrow: xkey = 'D'; break;
        }
        if (xkey) {
            bool consumed_meta_key = false;
            end = 1 + format_arrow_key(output+1, term, xkey, shift, ctrl,
                                       meta, &consumed_meta_key);
            if (consumed_meta_key)
                start = 1;
            goto done;
        }
    }

    if (num_keypad_key) {
        end = 1 + format_numeric_keypad_key(output+1, term, num_keypad_key,
                                            shift, ctrl);
        if (end == 1 && num_keypad_key == '\r') {
            /* Keypad Enter, lacking any other translation, is Return. */
            end = return_key(term, output, &special);
        } else if (end == 1 && num_keypad_key != 'G') {
            /* Not in application mode: the key types its character
             * (as on a PC keypad with Num Lock on). */
            output[1] = num_keypad_key;
            end = 2;
        }
        goto done;
    }

  done:
    if (end - start > 0) {
        if (special) {
            output[end] = '\0';
            term_keyinput(term, -1, output + start, -2);
        } else if (!use_ucsoutput) {
            term_keyinput(term, output_charset, output + start, end - start);
        } else {
            term_keyinputw(term, ucsoutput + start, end - start);
        }
        generated = true;
        [self showMousePointer:NO];
    }
    if (generated)
        term_seen_key_event(term);
}

- (void)flagsChanged:(NSEvent *)event
{
    [super flagsChanged:event];
}

/* NSTextInputClient */

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange
{
    MTSession *s = self.session;
    NSString *str = [string isKindOfClass:NSAttributedString.class] ?
        [string string] : string;
    markedText = @"";
    if (s && s->term) {
        term_set_preedit_text(s->term, NULL);
        const char *utf8 = str.UTF8String;
        if (utf8 && *utf8) {
            term_keyinput(s->term, CS_UTF8, utf8, (int)strlen(utf8));
            term_seen_key_event(s->term);
            [self showMousePointer:NO];
        }
    }
    keyHandledByInput = YES;
}

- (void)doCommandBySelector:(SEL)selector
{
    /* Keys that the text system turns into editing commands but which
     * we have not translated ourselves: send what the key types. */
    NSEvent *event = currentKeyEvent;
    MTSession *s = self.session;
    if (!event || !s || !s->term)
        return;
    NSString *chars = event.characters;
    const char *utf8 = chars.UTF8String;
    if (utf8 && *utf8) {
        term_keyinput(s->term, CS_UTF8, utf8, (int)strlen(utf8));
        term_seen_key_event(s->term);
    }
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange
     replacementRange:(NSRange)replacementRange
{
    NSString *str = [string isKindOfClass:NSAttributedString.class] ?
        [string string] : string;
    markedText = [str copy];
    MTSession *s = self.session;
    if (s && s->term) {
        char *utf8 = dupstr(str.UTF8String ? str.UTF8String : "");
        term_set_preedit_text(s->term, *utf8 ? utf8 : NULL);
        sfree(utf8);
    }
}

- (void)unmarkText
{
    markedText = @"";
    MTSession *s = self.session;
    if (s && s->term)
        term_set_preedit_text(s->term, NULL);
}

- (BOOL)hasMarkedText { return markedText.length > 0; }
- (NSRange)markedRange
{
    return markedText.length ? NSMakeRange(0, markedText.length)
                             : NSMakeRange(NSNotFound, 0);
}
- (NSRange)selectedRange { return NSMakeRange(NSNotFound, 0); }
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText
{
    return @[];
}
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range
                                                actualRange:(NSRangePointer)actual
{
    return nil;
}
- (NSUInteger)characterIndexForPoint:(NSPoint)point { return NSNotFound; }

- (NSRect)firstRectForCharacterRange:(NSRange)range
                         actualRange:(NSRangePointer)actual
{
    NSRect r = NSMakeRect(cursorX * _fontWidth + _border + offsetX,
                          cursorY * _fontHeight + _border + offsetY,
                          _fontWidth, _fontHeight);
    r = [self convertRect:r toView:nil];
    return [self.window convertRectToScreen:r];
}

/* ----------------------------------------------------------------------
 * Mouse.
 */

- (void)cellForEvent:(NSEvent *)event x:(int *)x y:(int *)y
{
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    int cx = (int)floor((p.x - _border - offsetX) / _fontWidth);
    int cy = (int)floor((p.y - _border - offsetY) / _fontHeight);
    *x = cx;
    *y = cy;
}

static Mouse_Button translate_button(Conf *conf, Mouse_Button button)
{
    int mode = conf_get_int(conf, CONF_mouse_is_xterm);
    if (button == MBT_LEFT)
        return MBT_SELECT;
    if (button == MBT_MIDDLE)
        return mode == 1 ? MBT_PASTE : MBT_EXTEND;
    if (button == MBT_RIGHT)
        return mode == 1 ? MBT_EXTEND : MBT_PASTE;
    return 0;
}

- (void)mouseEvent:(NSEvent *)event button:(Mouse_Button)button
            action:(Mouse_Action)action
{
    MTSession *s = self.session;
    if (!s || !s->term)
        return;
    NSEventModifierFlags flags = event.modifierFlags;
    int x, y;
    [self cellForEvent:event x:&x y:&y];
    [self showMousePointer:YES];
    term_mouse(s->term, button, translate_button(s->conf, button), action,
               x, y, flags & NSEventModifierFlagShift,
               flags & NSEventModifierFlagControl,
               flags & NSEventModifierFlagOption);
}

static Mouse_Action click_action(NSEvent *event)
{
    switch (event.clickCount) {
      case 2: return MA_2CLK;
      case 3: return MA_3CLK;
      default: return MA_CLICK;
    }
}

#ifdef MACTTY_TEST_HOOKS
/* Test builds (./build.sh test) act on a click while in the background,
 * so that automated tests can post mouse events to this process without
 * activating it and taking the user's keyboard focus. */
- (BOOL)acceptsFirstMouse:(NSEvent *)event
{
    return YES;
}
#endif

- (BOOL)wantsContextMenuForEvent:(NSEvent *)event isRight:(BOOL)right
{
    MTSession *s = self.session;
    /* Ctrl+click always brings up the session menu, as Ctrl+right-click
     * does in Windows PuTTY; plain right-click does in "macOS" mode. */
    if (event.modifierFlags & NSEventModifierFlagControl)
        return YES;
    return right && conf_get_int(s->conf, CONF_mouse_is_xterm) == 2;
}

- (void)mouseDown:(NSEvent *)event
{
    if ([self wantsContextMenuForEvent:event isRight:NO]) {
        [NSMenu popUpContextMenu:[self.session contextMenu]
                       withEvent:event forView:self];
        return;
    }
    lastButton = MBT_LEFT;
    [self mouseEvent:event button:MBT_LEFT action:click_action(event)];
}

- (void)mouseDragged:(NSEvent *)event
{
    [self mouseEvent:event button:MBT_LEFT action:MA_DRAG];
}

- (void)mouseUp:(NSEvent *)event
{
    [self mouseEvent:event button:MBT_LEFT action:MA_RELEASE];
}

- (void)rightMouseDown:(NSEvent *)event
{
    if ([self wantsContextMenuForEvent:event isRight:YES]) {
        [NSMenu popUpContextMenu:[self.session contextMenu]
                       withEvent:event forView:self];
        return;
    }
    [self mouseEvent:event button:MBT_RIGHT action:click_action(event)];
}

- (void)rightMouseDragged:(NSEvent *)event
{
    [self mouseEvent:event button:MBT_RIGHT action:MA_DRAG];
}

- (void)rightMouseUp:(NSEvent *)event
{
    [self mouseEvent:event button:MBT_RIGHT action:MA_RELEASE];
}

- (void)otherMouseDown:(NSEvent *)event
{
    if (event.buttonNumber == 2)
        [self mouseEvent:event button:MBT_MIDDLE action:click_action(event)];
}

- (void)otherMouseDragged:(NSEvent *)event
{
    if (event.buttonNumber == 2)
        [self mouseEvent:event button:MBT_MIDDLE action:MA_DRAG];
}

- (void)otherMouseUp:(NSEvent *)event
{
    if (event.buttonNumber == 2)
        [self mouseEvent:event button:MBT_MIDDLE action:MA_RELEASE];
}

- (void)updateTrackingAreas
{
    [super updateTrackingAreas];
    for (NSTrackingArea *a in self.trackingAreas)
        [self removeTrackingArea:a];
    [self addTrackingArea:[[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:(NSTrackingMouseMoved | NSTrackingActiveInKeyWindow |
                      NSTrackingInVisibleRect)
               owner:self userInfo:nil]];
}

- (void)mouseMoved:(NSEvent *)event
{
    [self showMousePointer:YES];
    /* Mouse movement with no button is reported only in raw mode
     * (xterm's any-event tracking). */
    MTSession *s = self.session;
    if (s && s->term && self.sendRawMouse)
        [self mouseEvent:event button:MBT_NOTHING action:MA_MOVE];
}

- (void)scrollWheel:(NSEvent *)event
{
    MTSession *s = self.session;
    if (!s || !s->term)
        return;
    CGFloat dy = event.hasPreciseScrollingDeltas ?
        event.scrollingDeltaY / _fontHeight : event.scrollingDeltaY;
    scrollAccumulator += dy;
    int lines = (int)scrollAccumulator;
    if (lines == 0)
        return;
    scrollAccumulator -= lines;

    if (self.sendRawMouse &&
        !((event.modifierFlags & NSEventModifierFlagShift) &&
          conf_get_bool(s->conf, CONF_mouse_override))) {
        int x, y;
        [self cellForEvent:event x:&x y:&y];
        Mouse_Button b = lines > 0 ? MBT_WHEEL_UP : MBT_WHEEL_DOWN;
        NSEventModifierFlags f = event.modifierFlags;
        for (int i = abs(lines); i > 0; i--)
            term_mouse(s->term, b, b, MA_CLICK, x, y,
                       f & NSEventModifierFlagShift,
                       f & NSEventModifierFlagControl,
                       f & NSEventModifierFlagOption);
    } else {
        term_scroll(s->term, 0, -lines);
    }
}

/* ----------------------------------------------------------------------
 * Focus.
 */

- (BOOL)becomeFirstResponder
{
    MTSession *s = self.session;
    if (s && s->term)
        term_set_focus(s->term, self.window.isKeyWindow);
    return YES;
}

@end
