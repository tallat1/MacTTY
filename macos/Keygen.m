/*
 * Keygen.m: MacTTYgen, PuTTY's key generator (PuTTYgen) for macOS.
 *
 * This is a port of windows/puttygen.c. The window has PuTTYgen's
 * three boxes (Key, Actions, Parameters), its menus (File, Key,
 * Conversions) and its messages; key generation, loading, saving,
 * import and export are PuTTY's own code (keygen/, sshpubk.c,
 * import.c). Only the Win32 dialog has been replaced by AppKit.
 *
 * PuTTYgen is not a control box in PuTTY (it is a hand-laid Win32
 * dialog with a progress bar, a multi-line key display and a mouse
 * area, none of which dialog.h describes), so the window is built
 * directly here rather than through the ConfigDialog.m renderer.
 */

#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <stdatomic.h>
#include <sys/time.h>

#include "putty.h"
#include "ssh.h"
#include "sshkeygen.h"
#import "tools.h"

#define TOOLNAME "MacTTYgen"
#define DEFAULT_KEY_BITS 2048
#define DEFAULT_ECCURVE_INDEX 0
#define DEFAULT_EDCURVE_INDEX 0

/*
 * Rate limit for counting mouse movements as entropy, in ms (see the
 * comment on ENTROPY_RATE_LIMIT in windows/puttygen.c: fast pointing
 * devices send strongly correlated samples).
 */
#define ENTROPY_RATE_LIMIT 10

static NSString *const kErrorTitle = @TOOLNAME " Error";
static NSString *const kWarningTitle = @TOOLNAME " Warning";

/* ----------------------------------------------------------------------
 * What the PuTTY core expects from a front end.
 */

void modalfatalbox(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    char *stuff = dupvprintf(fmt, ap);
    va_end(ap);
    mt_error_box(@TOOLNAME " Fatal Error", mt_ns(stuff));
    sfree(stuff);
    exit(1);
}

void nonfatal(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    char *stuff = dupvprintf(fmt, ap);
    va_end(ap);
    mt_error_box(kErrorTitle, mt_ns(stuff));
    sfree(stuff);
}

void old_keyfile_warning(void)
{
    mt_info_box(@"PuTTY Key File Warning",
                @"You are loading an SSH-2 private key which has an "
                "old version of the file format. This means your key "
                "file is not fully tamperproof. Future versions of "
                "PuTTY may stop supporting this private key format, "
                "so we recommend you convert your key to the new "
                "format.\n\n"
                "Once the key is loaded into " TOOLNAME ", you can perform "
                "this conversion simply by saving it again.");
}

void cleanup_exit(int code)
{
    exit(code);
}

/* No GTK and no X resources here (unix/storage.c and buildinfo ask). */
const bool buildinfo_gtk_relevant = false;
char *x_get_default(const char *key) { return NULL; }

/* ----------------------------------------------------------------------
 * ProgressReceiver, as in windows/puttygen.c. It runs on the key
 * generation thread; the main thread reads 'position' on a timer.
 */

struct progressphase {
    double startpoint, total;
    /* For exponential phases */
    double exp_probability, exp_current_value;
};

struct progress {
    size_t nphases, phasessize;
    struct progressphase *phases, *currphase;
    double scale;
    _Atomic double position;           /* 0 .. 1 */
    ProgressReceiver rec;
};

static ProgressPhase mac_progress_add_linear(
    ProgressReceiver *prog, double overall_cost)
{
    struct progress *p = container_of(prog, struct progress, rec);
    sgrowarray(p->phases, p->phasessize, p->nphases);
    int phase = p->nphases++;
    p->phases[phase].total = overall_cost;
    ProgressPhase ph = { .n = phase };
    return ph;
}

static ProgressPhase mac_progress_add_probabilistic(
    ProgressReceiver *prog, double cost_per_attempt, double probability)
{
    struct progress *p = container_of(prog, struct progress, rec);
    sgrowarray(p->phases, p->phasessize, p->nphases);
    int phase = p->nphases++;
    p->phases[phase].exp_probability = 1.0 - probability;
    p->phases[phase].exp_current_value = 1.0;
    /* Expected number of attempts = 1 / probability of attempt succeeding */
    p->phases[phase].total = cost_per_attempt / probability;
    ProgressPhase ph = { .n = phase };
    return ph;
}

static void mac_progress_ready(ProgressReceiver *prog)
{
    struct progress *p = container_of(prog, struct progress, rec);
    double total = 0;
    for (int i = 0; i < p->nphases; i++) {
        p->phases[i].startpoint = total;
        total += p->phases[i].total;
    }
    p->scale = 1.0 / total;
}

static void mac_progress_start_phase(ProgressReceiver *prog,
                                     ProgressPhase phase)
{
    struct progress *p = container_of(prog, struct progress, rec);
    assert(phase.n < p->nphases);
    p->currphase = &p->phases[phase.n];
}

static void mac_progress_update(struct progress *p, double phasepos)
{
    double position = (p->currphase->startpoint +
                       p->currphase->total * phasepos);
    position *= p->scale;
    if (position < 0)
        position = 0;
    if (position > 1)
        position = 1;
    atomic_store(&p->position, position);
}

static void mac_progress_report(ProgressReceiver *prog, double progress)
{
    struct progress *p = container_of(prog, struct progress, rec);
    mac_progress_update(p, progress);
}

static void mac_progress_report_attempt(ProgressReceiver *prog)
{
    struct progress *p = container_of(prog, struct progress, rec);
    p->currphase->exp_current_value *= p->currphase->exp_probability;
    mac_progress_update(p, 1.0 - p->currphase->exp_current_value);
}

static void mac_progress_report_phase_complete(ProgressReceiver *prog)
{
    struct progress *p = container_of(prog, struct progress, rec);
    mac_progress_update(p, 1.0);
}

static const ProgressReceiverVtable mac_progress_vt = {
    .add_linear = mac_progress_add_linear,
    .add_probabilistic = mac_progress_add_probabilistic,
    .ready = mac_progress_ready,
    .start_phase = mac_progress_start_phase,
    .report = mac_progress_report,
    .report_attempt = mac_progress_report_attempt,
    .report_phase_complete = mac_progress_report_phase_complete,
};

/* ----------------------------------------------------------------------
 * Key generation job. Like the Windows version, generation runs on a
 * thread of its own so that the window stays live. Nothing else in
 * this program touches the random pool while it runs: entropy is
 * collected and the pool reseeded before the thread starts, and
 * saving is impossible until it has finished.
 */

typedef enum { RSA, DSA, ECDSA, EDDSA } keytype;

/* The "Type of key to generate" radio buttons and Key menu items. */
enum { KT_RSA, KT_DSA, KT_ECDSA, KT_EDDSA, KT_SSH1, KT_COUNT };

enum { PRIME_PROB, PRIME_MAURER_SIMPLE, PRIME_MAURER_COMPLEX };

struct keygen_job {
    keytype keytype;
    int key_bits, curve_bits;
    const PrimeGenerationPolicy *primepolicy;
    bool rsa_strong;
    struct progress prog;
    union {
        RSAKey *rsakey;
        struct dsa_key *dsakey;
        struct ecdsa_key *eckey;
        struct eddsa_key *edkey;
    };
};

static void run_keygen_job(struct keygen_job *job)
{
    job->prog.nphases = job->prog.phasessize = 0;
    job->prog.phases = job->prog.currphase = NULL;
    job->prog.rec.vt = &mac_progress_vt;
    atomic_store(&job->prog.position, 0.0);

    PrimeGenerationContext *pgc = primegen_new_context(job->primepolicy);

    if (job->keytype == DSA)
        dsa_generate(job->dsakey, job->key_bits, pgc, &job->prog.rec);
    else if (job->keytype == ECDSA)
        ecdsa_generate(job->eckey, job->curve_bits);
    else if (job->keytype == EDDSA)
        eddsa_generate(job->edkey, job->curve_bits);
    else
        rsa_generate(job->rsakey, job->key_bits, job->rsa_strong,
                     pgc, &job->prog.rec);

    primegen_free_context(pgc);
    sfree(job->prog.phases);
}

/* ----------------------------------------------------------------------
 * Initial parameters, from the command line (as in WinMain).
 */

static struct {
    int keybutton;
    int primepolicy;
    bool rsa_strong;
    FingerprintType fptype;
    int keybits;
    int eccurve_index, edcurve_index;
    Filename *keyfile;
} initial;

static ppk_save_parameters save_params;

/* ----------------------------------------------------------------------
 * Views.
 */

@interface MTKGFlippedView : NSView
@end
@implementation MTKGFlippedView
- (BOOL)isFlipped { return YES; }
@end

@class MTKeygen;

/* The window's content view. Its tracking area makes the window
 * server send us mouse movements over the window even while another
 * application is active; they are collected as entropy by an event
 * monitor (see -generate:), which also sees movements that arrive
 * without a window attached. */
@interface MTEntropyView : MTKGFlippedView
@end

/* "Parameters for saving key files" (below). */
@interface MTPPKParams : NSObject
- (BOOL)run;
@end

@interface MTKeygen : NSWindowController <NSWindowDelegate,
    NSTextFieldDelegate, NSMenuItemValidation>
- (void)mouseMovedForEntropy:(NSEvent *)event;
- (void)loadKeyFile:(Filename *)filename wasImport:(BOOL)wasImport;
- (BOOL)isGenerating;
@end

@implementation MTEntropyView
- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        [self addTrackingArea:[[NSTrackingArea alloc]
            initWithRect:NSZeroRect
                 options:(NSTrackingMouseMoved | NSTrackingActiveAlways |
                          NSTrackingInVisibleRect)
                   owner:self userInfo:nil]];
    }
    return self;
}
- (void)mouseMoved:(NSEvent *)event
{
    /* handled by the event monitor */
}
@end

/* The area that stands in for the key while there is none: a dashed
 * outline, as an empty drop target is drawn. */
@interface MTDashedView : MTKGFlippedView
@end
@implementation MTDashedView
- (void)drawRect:(NSRect)r
{
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:
                          NSInsetRect(self.bounds, 1, 1) xRadius:8 yRadius:8];
    CGFloat dash[2] = {6, 4};
    [p setLineDash:dash count:2 phase:0];
    p.lineWidth = 1.5;
    [NSColor.tertiaryLabelColor setStroke];
    [p stroke];
}
@end

static NSColor *group_fill_colour(void)
{
    return [NSColor colorWithName:@"MTGroupFill" dynamicProvider:
        ^NSColor *(NSAppearance *a) {
        BOOL dark = [[a bestMatchFromAppearancesWithNames:
                         @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]]
                        isEqualToString:NSAppearanceNameDarkAqua];
        return dark ? [NSColor colorWithWhite:1 alpha:0.045]
                    : [NSColor colorWithWhite:0 alpha:0.035];
    }];
}

/* ----------------------------------------------------------------------
 * The main window.
 */

static const CGFloat kWinW = 600;
static const CGFloat kMargin = 20;
static const CGFloat kBoxGap = 14;
static const CGFloat kFieldH = 22;
static const CGFloat kButtonW = 140;

@implementation MTKeygen {
    /* MainDlgState */
    BOOL generating;
    BOOL keyExists;
    int entropyGot, entropyRequired;
    strbuf *entropy;
    uint64_t entropyPrevMs;
    int keyBits, curveBits;
    BOOL ssh2;
    keytype keyType;
    const PrimeGenerationPolicy *primePolicy;
    int primePolicyIndex;
    BOOL rsaStrong;
    FingerprintType fptype;
    char **commentptr;                 /* -> key.comment or ssh2key.comment */
    ssh2_userkey ssh2key;
    RSAKey key;                        /* the SSH-1 key */
    int keyButton;
    struct keygen_job *job;
    NSTimer *progressTimer;
    id entropyMonitor;

    /* Key box */
    NSTextField *keyHeader, *statusPill, *progressPercent;
    NSView *stateArea;
    NSButton *copyButton;
    NSString *keyStatus;
    NSTextField *noKeyLabel, *generatingLabel;
    NSProgressIndicator *progress;
    NSTextField *pkLabel;
    NSScrollView *keyScroll;
    NSTextView *keyText;
    NSTextField *certLabel;
    NSButton *certInfoButton;
    NSTextField *fpLabel, *fpField;
    NSTextField *commentLabel, *commentField;
    NSTextField *pass1Label, *pass2Label;
    NSSecureTextField *pass1Field, *pass2Field;

    /* Actions box */
    NSButton *generateButton, *loadButton, *savePubButton, *saveButton;

    /* Parameters box */
    NSMutableArray<NSButton *> *typeRadios;
    NSTextField *bitsLabel, *bitsField;
    NSTextField *ecLabel, *edLabel;
    NSPopUpButton *ecPopup, *edPopup;
}

- (BOOL)isGenerating
{
    return generating;
}

/* -------- construction -------- */

static NSTextField *make_label(NSView *parent, NSString *text, NSRect frame)
{
    NSTextField *l = [NSTextField labelWithString:text];
    l.frame = frame;
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    [parent addSubview:l];
    return l;
}

static NSButton *make_button(NSView *parent, NSString *title, NSRect frame,
                             id target, SEL action)
{
    NSButton *b = [NSButton buttonWithTitle:title target:target
                                     action:action];
    b.frame = frame;
    [parent addSubview:b];
    return b;
}

/* A group of controls at 'top' in the (flipped) window content, its
 * title above it as in macOS settings; returns its flipped content
 * view of the requested inner height. */
static NSView *make_box(NSView *parent, NSString *title, CGFloat top,
                        CGFloat innerH, CGFloat *bottom,
                        NSTextField *__strong *header)
{
    NSTextField *h = [NSTextField labelWithString:title];
    h.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    h.textColor = NSColor.secondaryLabelColor;
    h.frame = NSMakeRect(kMargin + 2, top, ceil(h.fittingSize.width), 16);
    [parent addSubview:h];
    if (header)
        *header = h;
    top += 22;
    NSBox *box = [[NSBox alloc] initWithFrame:
                     NSMakeRect(kMargin, top, kWinW - 2 * kMargin, 100)];
    box.boxType = NSBoxCustom;
    box.titlePosition = NSNoTitle;
    box.cornerRadius = 8;
    box.borderWidth = 1;
    box.borderColor = NSColor.separatorColor;
    box.fillColor = group_fill_colour();
    box.contentViewMargins = NSMakeSize(12, 10);
    CGFloat extra = 100 - box.contentView.frame.size.height;
    box.frame = NSMakeRect(kMargin, top, kWinW - 2 * kMargin,
                           innerH + extra);
    NSView *inner = [[MTKGFlippedView alloc]
                        initWithFrame:box.contentView.frame];
    box.contentView = inner;
    [parent addSubview:box];
    *bottom = top + box.frame.size.height;
    return inner;
}

- (instancetype)init
{
    NSWindow *w = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, kWinW, 500)
                  styleMask:(NSWindowStyleMaskTitled |
                             NSWindowStyleMaskClosable |
                             NSWindowStyleMaskMiniaturizable)
                    backing:NSBackingStoreBuffered defer:NO];
    w.title = @"MacTTY Key Generator";
    w.releasedWhenClosed = NO;
    w.acceptsMouseMovedEvents = YES;
    if (!(self = [super initWithWindow:w]))
        return nil;
    w.delegate = self;

    MTEntropyView *content = [[MTEntropyView alloc]
                                 initWithFrame:NSMakeRect(0, 0, kWinW, 500)];
    w.contentView = content;

    CGFloat y = kMargin, bottom;

    /* ---- Key ---- */
    NSView *kb = make_box(content, @"Key", y, 228, &bottom, &keyHeader);
    CGFloat cw = kb.frame.size.width;

    /* Next to the heading: what the key is and whether it is saved. */
    statusPill = [NSTextField labelWithString:@""];
    statusPill.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    statusPill.textColor = NSColor.controlAccentColor;
    statusPill.wantsLayer = YES;
    statusPill.layer.cornerRadius = 8;
    statusPill.layer.backgroundColor =
        [NSColor.controlAccentColor colorWithAlphaComponent:0.15].CGColor;
    statusPill.alignment = NSTextAlignmentCenter;
    [content addSubview:statusPill];

    /* While there is no key: a dashed area saying what to do, which
     * also shows the progress of generating one. */
    stateArea = [[MTDashedView alloc] initWithFrame:NSMakeRect(0, 0, cw, 228)];
    [kb addSubview:stateArea];
    noKeyLabel = [NSTextField wrappingLabelWithString:
                     @"No key yet.\nGenerate a new key pair, or load an "
                     "existing private key file."];
    noKeyLabel.alignment = NSTextAlignmentCenter;
    noKeyLabel.textColor = NSColor.secondaryLabelColor;
    noKeyLabel.frame = NSMakeRect(24, 88, cw - 48, 44);
    [kb addSubview:noKeyLabel];
    generatingLabel = [NSTextField wrappingLabelWithString:@""];
    generatingLabel.alignment = NSTextAlignmentCenter;
    generatingLabel.frame = NSMakeRect(24, 70, cw - 48, 44);
    [kb addSubview:generatingLabel];
    progress = [[NSProgressIndicator alloc]
                   initWithFrame:NSMakeRect(24, 132, cw - 48 - 52, 20)];
    progress.style = NSProgressIndicatorStyleBar;
    progress.indeterminate = NO;
    [kb addSubview:progress];
    progressPercent = [NSTextField labelWithString:@""];
    progressPercent.alignment = NSTextAlignmentRight;
    progressPercent.font = [NSFont monospacedDigitSystemFontOfSize:
                               NSFont.systemFontSize weight:NSFontWeightRegular];
    progressPercent.frame = NSMakeRect(cw - 24 - 48, 133, 48, 17);
    [kb addSubview:progressPercent];

    pkLabel = make_label(kb, @"", NSMakeRect(0, 2, cw - 80, 17));
    copyButton = make_button(kb, @"Copy", NSMakeRect(cw - 72, -4, 72, 28),
                             self, @selector(copyPublicKey:));
    copyButton.controlSize = NSControlSizeSmall;
    copyButton.toolTip = @"Copy the public key";
    keyScroll = [[NSScrollView alloc]
                    initWithFrame:NSMakeRect(0, 22, cw, 86)];
    keyScroll.borderType = NSBezelBorder;
    keyScroll.hasVerticalScroller = YES;
    keyText = [[NSTextView alloc] initWithFrame:
                  NSMakeRect(0, 0, keyScroll.contentSize.width,
                             keyScroll.contentSize.height)];
    keyText.editable = NO;
    keyText.selectable = YES;
    keyText.richText = NO;
    keyText.font = [NSFont userFixedPitchFontOfSize:11];
    keyText.textContainer.widthTracksTextView = YES;
    keyText.autoresizingMask = NSViewWidthSizable;
    keyText.verticallyResizable = YES;
    keyText.accessibilityLabel =
        @"Public key for pasting into OpenSSH authorized_keys file";
    keyScroll.documentView = keyText;
    [kb addSubview:keyScroll];

    certLabel = make_label(kb, @"", NSMakeRect(0, 2, cw, 17));
    certInfoButton = make_button(kb, @"Certificate info...",
                                 NSMakeRect(-6, 22, 170, 32), self,
                                 @selector(certificateInfo:));

    const CGFloat lw = 150, fx = lw + 6, fw = cw - fx;
    CGFloat ry = 116;
    fpLabel = make_label(kb, @"Key fingerprint:",
                         NSMakeRect(0, ry + 3, lw, 17));
    fpField = [NSTextField textFieldWithString:@""];
    fpField.frame = NSMakeRect(fx, ry, fw, kFieldH);
    fpField.editable = NO;
    fpField.selectable = YES;
    fpField.accessibilityLabel = @"Key fingerprint";
    [kb addSubview:fpField];
    ry += 28;
    commentLabel = make_label(kb, @"Key comment:",
                              NSMakeRect(0, ry + 3, lw, 17));
    commentField = [NSTextField textFieldWithString:@""];
    commentField.frame = NSMakeRect(fx, ry, fw, kFieldH);
    commentField.delegate = self;
    commentField.accessibilityLabel = @"Key comment";
    [kb addSubview:commentField];
    ry += 28;
    pass1Label = make_label(kb, @"Key passphrase:",
                            NSMakeRect(0, ry + 3, lw, 17));
    pass1Field = [[NSSecureTextField alloc]
                     initWithFrame:NSMakeRect(fx, ry, fw, kFieldH)];
    pass1Field.accessibilityLabel = @"Key passphrase";
    [kb addSubview:pass1Field];
    ry += 28;
    pass2Label = make_label(kb, @"Confirm passphrase:",
                            NSMakeRect(0, ry + 3, lw, 17));
    pass2Field = [[NSSecureTextField alloc]
                     initWithFrame:NSMakeRect(fx, ry, fw, kFieldH)];
    pass2Field.accessibilityLabel = @"Confirm passphrase";
    [kb addSubview:pass2Field];

    /* ---- Actions ---- */
    y = bottom + kBoxGap;
    NSView *ab = make_box(content, @"Actions", y, 92, &bottom, NULL);
    CGFloat bx = cw - kButtonW + 6;
    make_label(ab, @"Generate a public/private key pair",
               NSMakeRect(0, 7, cw - kButtonW, 17));
    generateButton = make_button(ab, @"Generate",
                                 NSMakeRect(bx, 0, kButtonW, 32), self,
                                 @selector(generate:));
    make_label(ab, @"Load an existing private key file",
               NSMakeRect(0, 37, cw - kButtonW, 17));
    loadButton = make_button(ab, @"Load", NSMakeRect(bx, 30, kButtonW, 32),
                             self, @selector(loadKey:));
    make_label(ab, @"Save the generated key",
               NSMakeRect(0, 67, cw - 2 * kButtonW, 17));
    savePubButton = make_button(ab, @"Save public key",
                                NSMakeRect(bx - kButtonW - 8, 60, kButtonW, 32),
                                self, @selector(savePublicKey:));
    saveButton = make_button(ab, @"Save private key",
                             NSMakeRect(bx, 60, kButtonW, 32), self,
                             @selector(savePrivateKey:));

    /* ---- Parameters ---- */
    y = bottom + kBoxGap;
    NSView *pb = make_box(content, @"Parameters", y, 78, &bottom, NULL);
    make_label(pb, @"Type of key to generate:", NSMakeRect(0, 2, cw, 17));
    /* The radio buttons get a container of their own, so that AppKit
     * treats them as one group and nothing else joins it. */
    NSView *radios = [[MTKGFlippedView alloc]
                         initWithFrame:NSMakeRect(0, 22, cw, 20)];
    [pb addSubview:radios];
    static NSString *const typeNames[KT_COUNT] = {
        @"RSA", @"DSA", @"ECDSA", @"EdDSA", @"SSH-1 (RSA)" };
    typeRadios = [NSMutableArray array];
    for (int i = 0; i < KT_COUNT; i++) {
        NSButton *r = [NSButton radioButtonWithTitle:typeNames[i]
                                              target:self
                                              action:@selector(typeRadio:)];
        r.tag = i;
        r.frame = NSMakeRect(i * (cw / KT_COUNT), 0, cw / KT_COUNT, 20);
        [radios addSubview:r];
        [typeRadios addObject:r];
    }
    CGFloat pw = 200;
    bitsLabel = make_label(pb, @"Number of bits in a generated key:",
                           NSMakeRect(0, 53, cw - 100, 17));
    bitsField = [NSTextField textFieldWithString:@""];
    bitsField.frame = NSMakeRect(cw - 90, 50, 90, kFieldH);
    bitsField.alignment = NSTextAlignmentRight;
    bitsField.accessibilityLabel = @"Number of bits in a generated key";
    [pb addSubview:bitsField];
    ecLabel = make_label(pb, @"Curve to use for generating this key:",
                         NSMakeRect(0, 53, cw - pw - 10, 17));
    ecPopup = [[NSPopUpButton alloc]
                  initWithFrame:NSMakeRect(cw - pw + 3, 47, pw, 26)
                      pullsDown:NO];
    ecPopup.accessibilityLabel = @"Curve to use for generating this key";
    for (int i = 0; i < n_ec_nist_curve_lengths; i++) {
        const struct ec_curve *curve;
        const ssh_keyalg *alg;
        ec_nist_alg_and_curve_by_bits(ec_nist_curve_lengths[i],
                                      &curve, &alg);
        [ecPopup addItemWithTitle:mt_ns(curve->textname)];
    }
    [pb addSubview:ecPopup];
    edLabel = make_label(pb, @"Curve to use for generating this key:",
                         NSMakeRect(0, 53, cw - pw - 10, 17));
    edPopup = [[NSPopUpButton alloc]
                  initWithFrame:NSMakeRect(cw - pw + 3, 47, pw, 26)
                      pullsDown:NO];
    edPopup.accessibilityLabel = @"Curve to use for generating this key";
    for (int i = 0; i < n_ec_ed_curve_lengths; i++) {
        int bits = ec_ed_curve_lengths[i];
        const struct ec_curve *curve;
        const ssh_keyalg *alg;
        ec_ed_alg_and_curve_by_bits(bits, &curve, &alg);
        [edPopup addItemWithTitle:[NSString stringWithFormat:
                                      @"%s (%d bits)", curve->textname, bits]];
    }
    [pb addSubview:edPopup];

    /* Size the window to the boxes. */
    CGFloat h = bottom + kMargin;
    [w setContentSize:NSMakeSize(kWinW, h)];
    content.frame = NSMakeRect(0, 0, kWinW, h);
    w.initialFirstResponder = generateButton;
    [w center];

    /* Initial state, from the command line. */
    [self setKeyType:initial.keybutton];
    [self setPrimePolicy:initial.primepolicy];
    rsaStrong = initial.rsa_strong;
    fptype = initial.fptype;
    bitsField.stringValue = [NSString stringWithFormat:@"%d",
                             initial.keybits];
    [ecPopup selectItemAtIndex:initial.eccurve_index];
    [edPopup selectItemAtIndex:initial.edcurve_index];
    [self setUIState:0];
    return self;
}

/* -------- state switching (ui_set_state and friends) -------- */

static void hide_views(NSArray<NSView *> *views, BOOL hide)
{
    for (NSView *v in views)
        v.hidden = hide;
}

- (NSArray<NSView *> *)gotKeyViews
{
    return @[fpLabel, fpField, commentLabel, commentField,
             pass1Label, pass1Field, pass2Label, pass2Field];
}

- (NSArray<NSView *> *)gotKeyConditionalViews
{
    return @[pkLabel, keyScroll, copyButton, certLabel, certInfoButton];
}

/* The pill beside "Key": the key's type and what has become of it. */
- (void)updatePill
{
    NSString *text = nil;
    if (keyExists && keyStatus) {
        NSString *alg = @"SSH-1 RSA";
        if (ssh2 && ssh2key.key) {
            char *d = ssh_keyalg_desc(ssh_key_alg(ssh2key.key));
            alg = mt_ns(d);
            sfree(d);
        }
        text = [NSString stringWithFormat:@"%@ · %@", alg, keyStatus];
    } else if ([keyStatus isEqualToString:@"generating"]) {
        text = @"Generating…";
    }
    statusPill.hidden = (text == nil);
    if (!text)
        return;
    statusPill.stringValue = text;
    NSRect h = keyHeader.frame;
    CGFloat w = ceil(statusPill.fittingSize.width) + 16;
    statusPill.frame = NSMakeRect(NSMaxX(h) + 8, h.origin.y, w, 16);
}

/* Return goes to the thing to do next: Generate while there is no key,
 * Save private key while a new one is unsaved. */
- (void)updateDefaultButton
{
    BOOL unsaved = keyExists && [keyStatus isEqualToString:@"not saved"];
    generateButton.keyEquivalent = (!keyExists && !generating) ? @"\r" : @"";
    saveButton.keyEquivalent = unsaved ? @"\r" : @"";
}

- (void)updatePercent
{
    double span = progress.maxValue - progress.minValue;
    double f = span > 0 ? (progress.doubleValue - progress.minValue) / span
                        : 0;
    progressPercent.stringValue = [NSString stringWithFormat:@"%d%%",
                                   (int)lround(MAX(0, MIN(1, f)) * 100)];
}

- (IBAction)copyPublicKey:(id)sender
{
    NSPasteboard *pb = mt_pasteboard();
    [pb clearContents];
    [pb setString:keyText.string forType:NSPasteboardTypeString];
}

/* 0: no key; 1: generating; 2: got a key. Menu items follow in
 * validateMenuItem:. */
- (void)setUIState:(int)status
{
    BOOL busy = (status == 1);
    noKeyLabel.hidden = (status != 0);
    stateArea.hidden = (status == 2);
    hide_views(@[generatingLabel, progress, progressPercent], status != 1);
    if (status != 2)
        keyStatus = (status == 1) ? @"generating" : nil;
    [self updatePill];
    hide_views([self gotKeyViews], status != 2);
    if (status != 2)
        hide_views([self gotKeyConditionalViews], YES);
    /* (status 2: the conditional views are set by setupBigEdit) */
    generateButton.enabled = !busy;
    loadButton.enabled = !busy;
    saveButton.enabled = (status == 2);
    savePubButton.enabled = (status == 2);
    [self updateDefaultButton];
    for (NSButton *r in typeRadios)
        r.enabled = !busy;
    bitsField.enabled = !busy;
}

- (void)updateKeyTypeControls
{
    BOOL bits = (keyButton == KT_SSH1 || keyButton == KT_RSA ||
                 keyButton == KT_DSA);
    hide_views(@[bitsLabel, bitsField], !bits);
    hide_views(@[ecLabel, ecPopup], keyButton != KT_ECDSA);
    hide_views(@[edLabel, edPopup], keyButton != KT_EDDSA);
}

- (void)setKeyType:(int)button
{
    keyButton = button;
    for (NSButton *r in typeRadios)
        r.state = (r.tag == button) ? NSControlStateValueOn
                                    : NSControlStateValueOff;
    [self updateKeyTypeControls];
}

- (void)setPrimePolicy:(int)option
{
    primePolicyIndex = option;
    switch (option) {
      case PRIME_PROB:
        primePolicy = &primegen_probabilistic;
        break;
      case PRIME_MAURER_SIMPLE:
        primePolicy = &primegen_provable_maurer_simple;
        break;
      case PRIME_MAURER_COMPLEX:
        primePolicy = &primegen_provable_maurer_complex;
        break;
    }
}

- (void)setFingerprintType:(FingerprintType)type
{
    fptype = type;
    if (keyExists && ssh2) {
        char *fp = ssh2_fingerprint(ssh2key.key, fptype);
        fpField.stringValue = mt_ns(fp);
        sfree(fp);
    }
}

/* setupbigedit1 / setupbigedit2 */
- (void)setupBigEdit
{
    if (ssh2 && ssh_key_alg(ssh2key.key)->is_certificate) {
        hide_views(@[certLabel, certInfoButton], NO);
        hide_views(@[pkLabel, keyScroll, copyButton], YES);
        certLabel.stringValue =
            @"This public key contains an OpenSSH certificate.";
        return;
    }
    hide_views(@[certLabel, certInfoButton], YES);
    hide_views(@[pkLabel, keyScroll, copyButton], NO);
    char *buffer;
    if (ssh2) {
        pkLabel.stringValue = @"Public key for pasting into OpenSSH "
            "authorized_keys file:";
        buffer = ssh2_pubkey_openssh_str(&ssh2key);
    } else {
        pkLabel.stringValue =
            @"Public key for pasting into authorized_keys file:";
        buffer = ssh1_pubkey_str(&key);
    }
    keyText.string = mt_ns(buffer);
    sfree(buffer);
}

- (void)updateUIAfterSSH2PubkeyChange
{
    char *fp = ssh2_fingerprint(ssh2key.key, fptype);
    fpField.stringValue = mt_ns(fp);
    sfree(fp);
    [self setupBigEdit];
}

/* Throw away the key currently held, if any. */
- (void)discardKey
{
    if (!keyExists)
        return;
    if (ssh2) {
        ssh_key_free(ssh2key.key);
        sfree(ssh2key.comment);
        ssh2key.key = NULL;
        ssh2key.comment = NULL;
    } else {
        freersakey(&key);
    }
    keyExists = NO;
}

/* update_ui_after_load */
- (void)updateUIAfterLoadWithPassphrase:(const char *)passphrase
                                   type:(int)type
                                ssh1Key:(RSAKey *)newkey1
                                ssh2Key:(ssh2_userkey *)newkey2
{
    [self discardKey];
    pass1Field.stringValue = mt_ns(passphrase);
    pass2Field.stringValue = mt_ns(passphrase);

    if (type == SSH_KEYTYPE_SSH1) {
        ssh2 = NO;
        key = *newkey1;                /* structure copy */
        commentptr = &key.comment;

        char *savecomment = key.comment;
        key.comment = NULL;
        char *fingerprint = rsa_ssh1_fingerprint(&key);
        key.comment = savecomment;
        fpField.stringValue = mt_ns(fingerprint);
        sfree(fingerprint);
        [self setupBigEdit];
    } else {
        ssh2 = YES;
        ssh2key = *newkey2;            /* structure copy */
        sfree(newkey2);
        commentptr = &ssh2key.comment;
        [self updateUIAfterSSH2PubkeyChange];
    }
    commentField.stringValue = mt_ns(*commentptr);

    [self setUIState:2];
    keyExists = YES;
    keyStatus = @"loaded";
    [self updatePill];
    [self updateDefaultButton];
}

/* -------- loading (load_key_file) -------- */

- (void)loadKeyFile:(Filename *)filename wasImport:(BOOL)wasImport
{
    char *passphrase = NULL;
    bool needs_pass;
    int type, realtype;
    int ret;
    const char *errmsg = NULL;
    char *comment;
    RSAKey newkey1;
    ssh2_userkey *newkey2 = NULL;

    memset(&newkey1, 0, sizeof(newkey1));
    type = realtype = key_type(filename);
    if (type != SSH_KEYTYPE_SSH1 &&
        type != SSH_KEYTYPE_SSH2 &&
        !import_possible(type)) {
        mt_error_box(kErrorTitle, [NSString stringWithFormat:
            @"Couldn't load private key (%s)", key_type_to_str(type)]);
        return;
    }

    if (type != SSH_KEYTYPE_SSH1 &&
        type != SSH_KEYTYPE_SSH2) {
        realtype = type;
        type = import_target_type(type);
    }

    comment = NULL;
    if (realtype == SSH_KEYTYPE_SSH1)
        needs_pass = rsa1_encrypted_f(filename, &comment);
    else if (realtype == SSH_KEYTYPE_SSH2)
        needs_pass = ppk_encrypted_f(filename, &comment);
    else
        needs_pass = import_encrypted(filename, realtype, &comment);
    do {
        burnstr(passphrase);
        passphrase = NULL;

        if (needs_pass) {
            passphrase = mt_passphrase_prompt(
                @TOOLNAME ": Enter Passphrase",
                @"Enter passphrase for key", comment);
            if (!passphrase) {
                ret = -2;
                break;
            }
        } else
            passphrase = dupstr("");
        if (type == SSH_KEYTYPE_SSH1) {
            if (realtype == type)
                ret = rsa1_load_f(filename, &newkey1, passphrase, &errmsg);
            else
                ret = import_ssh1(filename, realtype, &newkey1,
                                  passphrase, &errmsg);
        } else {
            if (realtype == type)
                newkey2 = ppk_load_f(filename, passphrase, &errmsg);
            else
                newkey2 = import_ssh2(filename, realtype, passphrase,
                                      &errmsg);
            if (newkey2 == SSH2_WRONG_PASSPHRASE)
                ret = -1;
            else if (!newkey2)
                ret = 0;
            else
                ret = 1;
        }
    } while (ret == -1);
    if (comment)
        sfree(comment);
    if (ret == 0) {
        mt_error_box(kErrorTitle, [NSString stringWithFormat:
            @"Couldn't load private key (%s)", errmsg]);
    } else if (ret == 1) {
        [self updateUIAfterLoadWithPassphrase:passphrase type:type
                                      ssh1Key:&newkey1 ssh2Key:newkey2];

        /* Tell the user about a foreign key loaded with Load (but
         * not with Import, where they asked for it). */
        if (realtype != type && !wasImport) {
            mt_info_box(@TOOLNAME " Notice", [NSString stringWithFormat:
                @"Successfully imported foreign key\n(%s).\n"
                "To use this key with PuTTY, you need to\n"
                "use the \"Save private key\" command to\n"
                "save it in PuTTY's own format.",
                key_type_to_str(realtype)]);
        }
    }
    burnstr(passphrase);
}

static Filename *request_file(NSString *message, bool save, bool keyfiles)
{
    NSURL *url = nil;
    if (save) {
        NSSavePanel *p = [NSSavePanel savePanel];
        p.message = message;
        p.canCreateDirectories = YES;
        if (keyfiles) {
            UTType *ppk = [UTType typeWithFilenameExtension:@"ppk"];
            if (ppk)
                p.allowedContentTypes = @[ppk];
            p.allowsOtherFileTypes = YES;
        }
        mt_activate();
        if ([p runModal] == NSModalResponseOK)
            url = p.URL;
    } else {
        NSOpenPanel *p = [NSOpenPanel openPanel];
        p.message = message;
        p.canChooseFiles = YES;
        p.canChooseDirectories = NO;
        p.allowsMultipleSelection = NO;
        /* OpenSSH and ssh.com keys have no fixed extension, so every
         * file can be chosen (as with Windows' "All Files" filter). */
        mt_activate();
        if ([p runModal] == NSModalResponseOK)
            url = p.URL;
    }
    return url ? filename_from_str(url.fileSystemRepresentation) : NULL;
}

- (IBAction)loadKey:(id)sender
{
    if (generating)
        return;
    Filename *fn = request_file(@"Load private key:", false, true);
    if (fn) {
        [self loadKeyFile:fn wasImport:NO];
        filename_free(fn);
    }
}

- (IBAction)importKey:(id)sender
{
    if (generating)
        return;
    Filename *fn = request_file(@"Load private key:", false, false);
    if (fn) {
        [self loadKeyFile:fn wasImport:YES];
        filename_free(fn);
    }
}

/* -------- saving -------- */

/* IDC_SAVE and the Conversions export commands. */
- (void)savePrivateKeyAs:(int)type
{
    if (!keyExists)
        return;
    int realtype = ssh2 ? SSH_KEYTYPE_SSH2 : SSH_KEYTYPE_SSH1;
    if (type == 0)
        type = realtype;

    if (type != realtype && import_target_type(type) != realtype) {
        mt_error_box(kErrorTitle, [NSString stringWithFormat:
            @"Cannot export an SSH-%d key in an SSH-%d format",
            ssh2 ? 2 : 1, ssh2 ? 1 : 2]);
        return;
    }

    char *passphrase = dupstr(pass1Field.stringValue.UTF8String ?: "");
    char *passphrase2 = dupstr(pass2Field.stringValue.UTF8String ?: "");
    if (strcmp(passphrase, passphrase2)) {
        mt_error_box(kErrorTitle,
                     @"The two passphrases given do not match.");
        burnstr(passphrase);
        burnstr(passphrase2);
        return;
    }
    burnstr(passphrase2);
    if (!*passphrase) {
        if (!mt_ask(kWarningTitle,
                    @"Are you sure you want to save this key\n"
                    "without a passphrase to protect it?", @"Yes", @"No")) {
            burnstr(passphrase);
            return;
        }
    }

    /* NSSavePanel has already asked whether to replace an existing
     * file, so there is no second "Overwrite existing file?" here. */
    Filename *fn = request_file(@"Save private key as:", true,
                                type == realtype);
    if (fn) {
        bool ret;
        char *err = NULL;
        if (ssh2) {
            if (type != realtype)
                ret = export_ssh2(fn, type, &ssh2key,
                                  *passphrase ? passphrase : NULL);
            else {
                err = ppk_params_bad(&save_params, *passphrase != '\0',
                                     strlen(passphrase));
                if (err) {
                    char *newerr = dupcat("PPK parameters invalid: ", err);
                    sfree(err);
                    err = newerr;
                    ret = false;
                } else {
                    ret = ppk_save_f(fn, &ssh2key,
                                     *passphrase ? passphrase : NULL,
                                     &save_params);
                }
            }
        } else {
            if (type != realtype)
                ret = export_ssh1(fn, type, &key,
                                  *passphrase ? passphrase : NULL);
            else
                ret = rsa1_save_f(fn, &key,
                                  *passphrase ? passphrase : NULL);
        }
        if (!ret) {
            mt_error_box(kErrorTitle,
                         err ? mt_ns(err) : @"Unable to save key file");
        } else if (type == 0 || type == SSH_KEYTYPE_SSH2 ||
                   type == SSH_KEYTYPE_SSH1) {
            keyStatus = @"saved";
            [self updatePill];
            [self updateDefaultButton];
        }
        sfree(err);
        filename_free(fn);
    }
    burnstr(passphrase);
}

- (IBAction)savePrivateKey:(id)sender
{
    [self savePrivateKeyAs:0];
}

- (IBAction)exportKey:(NSMenuItem *)sender
{
    [self savePrivateKeyAs:(int)sender.tag];
}

- (IBAction)savePublicKey:(id)sender
{
    if (!keyExists)
        return;
    Filename *fn = request_file(@"Save public key as:", true, false);
    if (!fn)
        return;
    FILE *fp = f_open(fn, "w", false);
    if (!fp) {
        mt_error_box(kErrorTitle, @"Unable to open key file");
    } else {
        if (ssh2) {
            strbuf *blob = strbuf_new();
            ssh_key_public_blob(ssh2key.key, BinarySink_UPCAST(blob));
            ssh2_write_pubkey(fp, ssh2key.comment, blob->u, blob->len,
                              SSH_KEYTYPE_SSH2_PUBLIC_RFC4716);
            strbuf_free(blob);
        } else {
            ssh1_write_pubkey(fp, &key);
        }
        if (fclose(fp) < 0)
            mt_error_box(kErrorTitle, @"Unable to save key file");
    }
    filename_free(fn);
}

/* -------- certificates -------- */

- (IBAction)addCertificate:(id)sender
{
    if (!keyExists || generating || !ssh2)
        return;
    Filename *filename = request_file(@"Load certificate:", false, false);
    if (!filename)
        return;

    int type = key_type(filename);
    if (type != SSH_KEYTYPE_SSH2_PUBLIC_RFC4716 &&
        type != SSH_KEYTYPE_SSH2_PUBLIC_OPENSSH) {
        mt_error_box(kErrorTitle, [NSString stringWithFormat:
            @"Couldn't load certificate (%s)", key_type_to_str(type)]);
        filename_free(filename);
        return;
    }

    char *algname = NULL;
    char *comment = NULL;
    const char *error = NULL;
    strbuf *pub = strbuf_new();
    if (!ppk_loadpub_f(filename, &algname, BinarySink_UPCAST(pub), &comment,
                       &error)) {
        mt_error_box(kErrorTitle, [NSString stringWithFormat:
            @"Couldn't load certificate (%s)", error]);
        strbuf_free(pub);
        filename_free(filename);
        return;
    }
    filename_free(filename);
    sfree(comment);

    const ssh_keyalg *alg = find_pubkey_alg(algname);
    if (!alg) {
        mt_error_box(kErrorTitle, [NSString stringWithFormat:
            @"Couldn't load certificate (unsupported algorithm name '%s')",
            algname]);
        sfree(algname);
        strbuf_free(pub);
        return;
    }
    sfree(algname);

    /* Check the two public keys match apart from certificates */
    strbuf *old_basepub = strbuf_new();
    ssh_key_public_blob(ssh_key_base_key(ssh2key.key),
                        BinarySink_UPCAST(old_basepub));

    ssh_key *new_pubkey = ssh_key_new_pub(alg, ptrlen_from_strbuf(pub));
    strbuf *new_basepub = strbuf_new();
    ssh_key_public_blob(ssh_key_base_key(new_pubkey),
                        BinarySink_UPCAST(new_basepub));
    ssh_key_free(new_pubkey);

    bool match = ptrlen_eq_ptrlen(ptrlen_from_strbuf(old_basepub),
                                  ptrlen_from_strbuf(new_basepub));
    strbuf_free(old_basepub);
    strbuf_free(new_basepub);

    if (!match) {
        mt_error_box(kErrorTitle,
                     @"Certificate is for a different public key");
        strbuf_free(pub);
        return;
    }

    strbuf *priv = strbuf_new_nm();
    ssh_key_private_blob(ssh2key.key, BinarySink_UPCAST(priv));
    ssh_key *newkey = ssh_key_new_priv(
        alg, ptrlen_from_strbuf(pub), ptrlen_from_strbuf(priv));
    strbuf_free(pub);
    strbuf_free(priv);

    if (!newkey) {
        mt_error_box(kErrorTitle, @"Couldn't combine certificate with key");
        return;
    }

    ssh_key_free(ssh2key.key);
    ssh2key.key = newkey;

    [self updateUIAfterSSH2PubkeyChange];
    [self setUIState:2];
}

- (IBAction)removeCertificate:(id)sender
{
    if (!keyExists || generating || !ssh2)
        return;
    ssh_key *newkey = ssh_key_clone(ssh_key_base_key(ssh2key.key));
    ssh_key_free(ssh2key.key);
    ssh2key.key = newkey;
    [self updateUIAfterSSH2PubkeyChange];
    [self setUIState:2];
}

- (IBAction)certificateInfo:(id)sender
{
    if (!keyExists || !ssh2 || !ssh2key.key ||
        !ssh_key_alg(ssh2key.key)->is_certificate)
        return;

    SeatDialogText *text = ssh_key_cert_info(ssh2key.key);
    NSMutableString *s = [NSMutableString string];
    const char *k = NULL;
    for (SeatDialogTextItem *item = text->items,
             *end = item + text->nitems; item < end; item++) {
        switch (item->type) {
          case SDT_MORE_INFO_KEY:
            k = item->text;
            break;
          case SDT_MORE_INFO_VALUE_SHORT:
            [s appendFormat:@"%@: %@\n", mt_ns(k), mt_ns(item->text)];
            break;
          case SDT_MORE_INFO_VALUE_BLOB:
            [s appendFormat:@"%@:\n%@\n", mt_ns(k), mt_ns(item->text)];
            break;
          default:
            break;
        }
    }
    seat_dialog_text_free(text);

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @TOOLNAME ": certificate information";
    NSTextView *tv = [[NSTextView alloc] initWithFrame:
                         NSMakeRect(0, 0, 520, 260)];
    tv.string = s;
    tv.editable = NO;
    tv.font = [NSFont userFixedPitchFontOfSize:11];
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:tv.frame];
    sv.documentView = tv;
    sv.hasVerticalScroller = YES;
    sv.borderType = NSBezelBorder;
    alert.accessoryView = sv;
    [alert addButtonWithTitle:@"Close"];
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

/* -------- generation -------- */

- (IBAction)typeRadio:(NSButton *)sender
{
    [self setKeyType:(int)sender.tag];
}

static uint64_t now_ms(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

- (IBAction)generate:(id)sender
{
    if (generating || entropy)
        return;

    /* GetDlgItemInt: digits only, otherwise the default. */
    NSString *bitsText = [bitsField.stringValue
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSScanner *sc = [NSScanner scannerWithString:bitsText];
    int bits;
    if (bitsText.length && [sc scanInt:&bits] && sc.atEnd && bits >= 0)
        keyBits = bits;
    else
        keyBits = DEFAULT_KEY_BITS;
    ssh2 = YES;

    switch (keyButton) {
      case KT_SSH1:
        ssh2 = NO;
        keyType = RSA;
        break;
      case KT_RSA:
        keyType = RSA;
        break;
      case KT_DSA:
        keyType = DSA;
        break;
      case KT_ECDSA:
        keyType = ECDSA;
        curveBits = ec_nist_curve_lengths[ecPopup.indexOfSelectedItem];
        break;
      case KT_EDDSA:
        keyType = EDDSA;
        curveBits = ec_ed_curve_lengths[edPopup.indexOfSelectedItem];
        break;
      default:
        return;
    }

    if ((keyType == RSA || keyType == DSA) && keyBits < 256) {
        if (!mt_ask(kWarningTitle, [NSString stringWithFormat:
                @TOOLNAME " will not generate a key smaller than 256 bits.\n"
                "Key length reset to default %d. Continue?",
                DEFAULT_KEY_BITS], @"OK", @"Cancel"))
            return;
        keyBits = DEFAULT_KEY_BITS;
        bitsField.stringValue = [NSString stringWithFormat:@"%d",
                                 DEFAULT_KEY_BITS];
    } else if ((keyType == RSA || keyType == DSA) &&
               keyBits < DEFAULT_KEY_BITS) {
        if (!mt_ask(kWarningTitle, [NSString stringWithFormat:
                @"Keys shorter than %d bits are not recommended. "
                "Really generate this key?", DEFAULT_KEY_BITS],
                    @"OK", @"Cancel"))
            return;
    }

    unsigned raw_entropy_required;
    if (keyType == RSA || keyType == DSA)
        raw_entropy_required = (keyBits / 2) * 2;
    else
        raw_entropy_required = (curveBits / 2) * 2;

    /* Bound the entropy collection above by the amount of data we can
     * actually fit into the PRNG. */
    if (raw_entropy_required > random_seed_bits())
        raw_entropy_required = random_seed_bits();

    /*
     * The kernel's random number generator first (Windows uses
     * CryptGenRandom here); then, exactly as on Windows, the user
     * still waves the mouse about to add entropy of their own.
     */
    char *raw = get_random_data(raw_entropy_required, NULL);
    if (raw) {
        random_reseed(make_ptrlen(raw, raw_entropy_required));
        smemclr(raw, raw_entropy_required);
        sfree(raw);
    }

    /*
     * Two words of mouse data per movement, counted as 2 bits of
     * entropy (see windows/puttygen.c), so the number of words wanted
     * equals the number of bits wanted.
     */
    entropyRequired = raw_entropy_required;

    [self discardKey];
    [self setUIState:1];
    generatingLabel.stringValue = @"Please generate some randomness by "
        "moving the mouse over the blank area.";

    entropyGot = 0;
    entropy = strbuf_new_nm();
    entropyPrevMs = now_ms();
    __weak MTKeygen *weakSelf = self;
    entropyMonitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:NSEventMaskMouseMoved
                                     handler:^NSEvent *(NSEvent *e) {
        [weakSelf mouseMovedForEntropy:e];
        return e;
    }];

    progress.minValue = 0;
    progress.maxValue = entropyRequired;
    progress.doubleValue = 0;
    [self updatePercent];
}

- (void)mouseMovedForEntropy:(NSEvent *)event
{
    if (!entropy || entropyGot >= entropyRequired)
        return;

    /* Only movements over this window count. */
    NSPoint p = event.locationInWindow;
    if (!event.window)
        p = [self.window convertPointFromScreen:p];
    else if (event.window != self.window)
        return;
    if (!NSPointInRect(p, self.window.contentView.frame))
        return;
    uint64_t msgtime = (uint64_t)(event.timestamp * 1000.0);
    uint64_t wallclock = now_ms();
    put_uint32(entropy, ((uint32_t)(int32_t)p.x & 0xFFFF) |
               (((uint32_t)(int32_t)p.y & 0xFFFF) << 16));
    put_uint32(entropy, (uint32_t)msgtime);
    if (wallclock - entropyPrevMs > ENTROPY_RATE_LIMIT) {
        entropyGot += 2;
        entropyPrevMs = wallclock;
    }
    progress.doubleValue = entropyGot;
    [self updatePercent];
    if (entropyGot >= entropyRequired) {
        /* Seed the entropy pool */
        random_reseed(ptrlen_from_strbuf(entropy));
        strbuf_free(entropy);
        entropy = NULL;
        [NSEvent removeMonitor:entropyMonitor];
        entropyMonitor = nil;
        [self startGeneratingKey];
    }
}

- (void)startGeneratingKey
{
    generatingLabel.stringValue = @"Please wait while a key is generated...";
    progress.minValue = 0;
    progress.maxValue = 1;
    progress.doubleValue = 0;
    [self updatePercent];

    struct keygen_job *j = snew(struct keygen_job);
    memset(j, 0, sizeof(*j));
    j->keytype = keyType;
    j->key_bits = keyBits;
    j->curve_bits = curveBits;
    j->primepolicy = primePolicy;
    j->rsa_strong = rsaStrong;
    switch (keyType) {
      case RSA:
        j->rsakey = snew(RSAKey);
        memset(j->rsakey, 0, sizeof(RSAKey));
        break;
      case DSA:
        j->dsakey = snew(struct dsa_key);
        memset(j->dsakey, 0, sizeof(struct dsa_key));
        break;
      case ECDSA:
        j->eckey = snew(struct ecdsa_key);
        memset(j->eckey, 0, sizeof(struct ecdsa_key));
        break;
      case EDDSA:
        j->edkey = snew(struct eddsa_key);
        memset(j->edkey, 0, sizeof(struct eddsa_key));
        break;
    }
    job = j;
    generating = YES;

    __weak MTKeygen *weakSelf = self;
    progressTimer = [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES
                                                     block:^(NSTimer *t) {
        MTKeygen *s = weakSelf;
        if (s && s->job)
            s->progress.doubleValue = atomic_load(&s->job->prog.position);
            [s updatePercent];
    }];

    NSThread *thread = [[NSThread alloc] initWithBlock:^{
        run_keygen_job(j);
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf keyGenerated:j];
        });
    }];
    /* Prime generation recurses; give it Windows' default stack. */
    thread.stackSize = 8 << 20;
    [thread start];
}

/* WM_DONEKEY */
- (void)keyGenerated:(struct keygen_job *)j
{
    [progressTimer invalidate];
    progressTimer = nil;
    generating = NO;
    job = NULL;
    progress.doubleValue = 1;

    if (ssh2) {
        switch (j->keytype) {
          case DSA: ssh2key.key = &j->dsakey->sshk; break;
          case ECDSA: ssh2key.key = &j->eckey->sshk; break;
          case EDDSA: ssh2key.key = &j->edkey->sshk; break;
          default: ssh2key.key = &j->rsakey->sshk; break;
        }
        ssh2key.comment = NULL;
        commentptr = &ssh2key.comment;
    } else {
        key = *j->rsakey;              /* structure copy */
        sfree(j->rsakey);
        commentptr = &key.comment;
    }
    sfree(j);
    keyExists = YES;

    /*
     * Invent a comment for the key, with the date in it, so ugly
     * that the user will want to change it.
     */
    *commentptr = snewn(30, char);
    struct tm tm = ltime();
    if (keyType == DSA)
        strftime(*commentptr, 30, "dsa-key-%Y%m%d", &tm);
    else if (keyType == ECDSA)
        strftime(*commentptr, 30, "ecdsa-key-%Y%m%d", &tm);
    else if (keyType == EDDSA)
        strftime(*commentptr, 30, "eddsa-key-%Y%m%d", &tm);
    else
        strftime(*commentptr, 30, "rsa-key-%Y%m%d", &tm);

    /* Blank passphrase, initially: saving warns about it. */
    pass1Field.stringValue = @"";
    pass2Field.stringValue = @"";
    commentField.stringValue = mt_ns(*commentptr);

    char *savecomment = *commentptr, *fp;
    *commentptr = NULL;
    if (ssh2)
        fp = ssh2_fingerprint(ssh2key.key, fptype);
    else
        fp = rsa_ssh1_fingerprint(&key);
    fpField.stringValue = mt_ns(fp);
    sfree(fp);
    *commentptr = savecomment;

    [self setupBigEdit];
    [self setUIState:2];
    keyStatus = @"not saved";
    [self updatePill];
    [self updateDefaultButton];
}

/* -------- other commands -------- */

- (void)controlTextDidChange:(NSNotification *)n
{
    if (n.object != commentField || !keyExists)
        return;
    sfree(*commentptr);
    *commentptr = dupstr(commentField.stringValue.UTF8String ?: "");
    [self setupBigEdit];
}

- (IBAction)keyTypeMenu:(NSMenuItem *)sender
{
    [self setKeyType:(int)sender.tag];
}

- (IBAction)primePolicyMenu:(NSMenuItem *)sender
{
    [self setPrimePolicy:(int)sender.tag];
}

- (IBAction)toggleStrongRSA:(id)sender
{
    rsaStrong = !rsaStrong;
}

- (IBAction)fingerprintTypeMenu:(NSMenuItem *)sender
{
    [self setFingerprintType:(FingerprintType)sender.tag];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    SEL a = item.action;
    if (a == @selector(keyTypeMenu:)) {
        item.state = (item.tag == keyButton);
        return !generating;
    }
    if (a == @selector(primePolicyMenu:)) {
        item.state = (item.tag == primePolicyIndex);
        return YES;
    }
    if (a == @selector(toggleStrongRSA:)) {
        item.state = rsaStrong;
        return YES;
    }
    if (a == @selector(fingerprintTypeMenu:)) {
        item.state = (item.tag == fptype);
        return YES;
    }
    if (a == @selector(generate:) || a == @selector(loadKey:) ||
        a == @selector(importKey:))
        return !generating && !entropy;
    if (a == @selector(savePrivateKey:) || a == @selector(savePublicKey:))
        return keyExists && !generating;
    if (a == @selector(exportKey:)) {
        if (!keyExists || generating)
            return NO;
        /* Only the formats that can hold this kind of key. */
        int type = ssh2 ? SSH_KEYTYPE_SSH2 : SSH_KEYTYPE_SSH1;
        return import_target_type((int)item.tag) == type;
    }
    if (a == @selector(addCertificate:) ||
        a == @selector(removeCertificate:)) {
        bool add_cert_allowed = false, rem_cert_allowed = false;
        if (keyExists && !generating && ssh2 && ssh2key.key) {
            const ssh_keyalg *alg = ssh_key_alg(ssh2key.key);
            if (alg->is_certificate) {
                /* If there's a certificate, we can remove it */
                rem_cert_allowed = true;
                /* And reset to the base algorithm for the next check */
                alg = alg->base_alg;
            }
            /* Now, do we have any certified version of this alg? */
            for (size_t i = 0; i < n_keyalgs; i++) {
                if (all_keyalgs[i]->base_alg == alg) {
                    add_cert_allowed = true;
                    break;
                }
            }
        }
        return a == @selector(addCertificate:) ? add_cert_allowed
                                                : rem_cert_allowed;
    }
    return YES;
}

- (IBAction)ppkParameters:(id)sender
{
    [[MTPPKParams new] run];
}

@end

/* ----------------------------------------------------------------------
 * "Parameters for saving key files" (PPKParamsProc).
 */


@implementation MTPPKParams {
    NSPanel *panel;
    NSView *verGroup, *kdfGroup, *autoGroup;
    NSTextField *memField, *timeField, *parField;
    ppk_save_parameters params;
    uint32_t timePasses, timeMs;
    BOOL timeAuto;
}

static NSView *radio_group(NSView *parent, NSRect frame,
                           NSArray<NSString *> *titles, NSInteger selected,
                           CGFloat itemW, id target)
{
    NSView *g = [[MTKGFlippedView alloc] initWithFrame:frame];
    for (NSUInteger i = 0; i < titles.count; i++) {
        NSButton *r = [NSButton radioButtonWithTitle:titles[i] target:target
                                              action:@selector(noop:)];
        r.tag = i;
        r.frame = NSMakeRect(i * itemW, 0, itemW, 20);
        r.state = (i == selected) ? NSControlStateValueOn
                                  : NSControlStateValueOff;
        [g addSubview:r];
    }
    [parent addSubview:g];
    return g;
}

static NSInteger radio_selection(NSView *g)
{
    for (NSButton *r in g.subviews)
        if (r.state == NSControlStateValueOn)
            return r.tag;
    return 0;
}

static NSTextField *number_field(NSView *parent, NSRect frame, uint32_t v)
{
    NSTextField *f = [NSTextField textFieldWithString:
                         [NSString stringWithFormat:@"%u", v]];
    f.frame = frame;
    [parent addSubview:f];
    return f;
}

/* try_get_dlg_item_uint32: leave *out alone unless the field holds a
 * plain decimal number that fits in 32 bits. */
static void try_get_uint32(NSTextField *f, uint32_t *out)
{
    const char *buf = f.stringValue.UTF8String;
    if (!buf || !*buf)
        return;
    char *end;
    unsigned long long val = strtoull(buf, &end, 10);
    if (*end || val > 0xFFFFFFFFULL)
        return;
    *out = (uint32_t)val;
}

- (void)noop:(id)sender
{
    /* Radio buttons need an action to group; the state is read on OK. */
}

- (BOOL)run
{
    params = save_params;
    if (params.argon2_passes_auto) {
        timeMs = params.argon2_milliseconds;
        timePasses = 13;
    } else {
        timeMs = 100;
        timePasses = params.argon2_passes;
    }
    timeAuto = params.argon2_passes_auto;

    const CGFloat W = 470, lw = 230, x2 = lw + 10;
    panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, W, 210)
                                       styleMask:NSWindowStyleMaskTitled
                                         backing:NSBackingStoreBuffered
                                           defer:NO];
    panel.title = @TOOLNAME ": Private Key File Parameters";
    NSView *c = [[MTKGFlippedView alloc] initWithFrame:
                    NSMakeRect(0, 0, W, 210)];
    panel.contentView = c;

    CGFloat y = 16;
    make_label(c, @"PPK file version:", NSMakeRect(16, y, lw, 17));
    verGroup = radio_group(c, NSMakeRect(x2, y - 1, 140, 20), @[@"2", @"3"],
                           params.fmt_version == 2 ? 0 : 1, 50, self);
    y += 28;
    make_label(c, @"Key derivation function:", NSMakeRect(16, y, lw, 17));
    kdfGroup = radio_group(c, NSMakeRect(x2, y - 1, 240, 20),
                           @[@"Argon2id", @"Argon2i", @"Argon2d"],
                           params.argon2_flavour == Argon2id ? 0 :
                           params.argon2_flavour == Argon2i ? 1 : 2, 82, self);
    y += 28;
    make_label(c, @"Memory to use for passphrase hash:",
               NSMakeRect(16, y + 2, lw, 17));
    memField = number_field(c, NSMakeRect(x2, y, 80, 22), params.argon2_mem);
    make_label(c, @"Kbyte", NSMakeRect(x2 + 88, y + 2, 60, 17));
    y += 30;
    make_label(c, @"Time to use for passphrase hash:",
               NSMakeRect(16, y + 2, lw, 17));
    timeField = number_field(c, NSMakeRect(x2, y, 80, 22),
                             timeAuto ? timeMs : timePasses);
    autoGroup = radio_group(c, NSMakeRect(x2 + 88, y + 1, 140, 20),
                            @[@"ms", @"passes"], timeAuto ? 0 : 1, 50, self);
    for (NSButton *r in autoGroup.subviews)
        r.action = @selector(autoChanged:);
    y += 30;
    make_label(c, @"Parallelism for passphrase hash:",
               NSMakeRect(16, y + 2, lw, 17));
    parField = number_field(c, NSMakeRect(x2, y, 80, 22),
                            params.argon2_parallelism);
    y += 40;
    NSButton *ok = make_button(c, @"OK", NSMakeRect(W - 112, y, 100, 32),
                               self, @selector(ok:));
    ok.keyEquivalent = @"\r";
    NSButton *cancel = make_button(c, @"Cancel",
                                   NSMakeRect(W - 212, y, 100, 32), self,
                                   @selector(cancel:));
    cancel.keyEquivalent = @"\e";
    [panel setContentSize:NSMakeSize(W, y + 44)];
    c.frame = NSMakeRect(0, 0, W, y + 44);
    [panel center];

    mt_activate();
    NSModalResponse r = [NSApp runModalForWindow:panel];
    [panel orderOut:nil];
    if (r != NSModalResponseOK)
        return NO;
    if (params.argon2_passes_auto)
        params.argon2_milliseconds = timeMs;
    else
        params.argon2_passes = timePasses;
    save_params = params;
    return YES;
}

/* The time box holds milliseconds or passes depending on the radio
 * button; remember the value of the kind being left. */
- (void)autoChanged:(id)sender
{
    try_get_uint32(timeField, timeAuto ? &timeMs : &timePasses);
    timeAuto = (radio_selection(autoGroup) == 0);
    timeField.stringValue = [NSString stringWithFormat:@"%u",
                             timeAuto ? timeMs : timePasses];
}

- (void)ok:(id)sender
{
    params.fmt_version = radio_selection(verGroup) == 0 ? 2 : 3;
    switch (radio_selection(kdfGroup)) {
      case 0: params.argon2_flavour = Argon2id; break;
      case 1: params.argon2_flavour = Argon2i; break;
      default: params.argon2_flavour = Argon2d; break;
    }
    try_get_uint32(memField, &params.argon2_mem);
    try_get_uint32(timeField, timeAuto ? &timeMs : &timePasses);
    params.argon2_passes_auto = timeAuto;
    try_get_uint32(parField, &params.argon2_parallelism);

    /* Check these parameters for validity before we adopt them. At
     * this stage we don't have the real passphrase length, so make
     * one up. */
    char *err = ppk_params_bad(&params, true, 64);
    if (err) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleCritical;
        alert.messageText = @"Save parameters invalid";
        alert.informativeText = mt_ns(err);
        sfree(err);
        [alert beginSheetModalForWindow:panel completionHandler:nil];
        return;
    }
    [NSApp stopModalWithCode:NSModalResponseOK];
}

- (void)cancel:(id)sender
{
    [NSApp stopModalWithCode:NSModalResponseCancel];
}

@end

/* ----------------------------------------------------------------------
 * Application.
 */

@interface MTKeygenApp : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) MTKeygen *keygen;
@end

@implementation MTKeygenApp {
    NSMutableArray<NSString *> *pendingFiles;
}

- (void)buildMenus
{
    NSEventModifierFlags cmd = NSEventModifierFlagCommand;
    MTKeygen *k = self.keygen;
    NSMenu *bar = [[NSMenu alloc] initWithTitle:@""];

    NSMenu *app = [[NSMenu alloc] initWithTitle:@TOOLNAME];
    mt_add_item(app, @"About " TOOLNAME, @selector(about:), self, nil, 0);
    [app addItem:[NSMenuItem separatorItem]];
    NSMenu *services = [[NSMenu alloc] initWithTitle:@"Services"];
    [app addItemWithTitle:@"Services" action:NULL keyEquivalent:@""]
        .submenu = services;
    NSApp.servicesMenu = services;
    [app addItem:[NSMenuItem separatorItem]];
    mt_add_item(app, @"Hide " TOOLNAME, @selector(hide:), nil, @"h", cmd);
    mt_add_item(app, @"Hide Others", @selector(hideOtherApplications:), nil,
                @"h", cmd | NSEventModifierFlagOption);
    mt_add_item(app, @"Show All", @selector(unhideAllApplications:), nil,
                nil, 0);
    [app addItem:[NSMenuItem separatorItem]];
    mt_add_item(app, @"Quit " TOOLNAME, @selector(terminate:), nil, @"q",
                cmd);
    [bar addItemWithTitle:@"" action:NULL keyEquivalent:@""].submenu = app;

    NSMenu *file = [[NSMenu alloc] initWithTitle:@"File"];
    mt_add_item(file, @"Load private key", @selector(loadKey:), k, @"o", cmd);
    mt_add_item(file, @"Save public key", @selector(savePublicKey:), k,
                @"s", cmd | NSEventModifierFlagShift);
    mt_add_item(file, @"Save private key", @selector(savePrivateKey:), k,
                @"s", cmd);
    [file addItem:[NSMenuItem separatorItem]];
    mt_add_item(file, @"Close", @selector(performClose:), nil, @"w", cmd);
    [bar addItemWithTitle:@"File" action:NULL keyEquivalent:@""]
        .submenu = file;

    [bar addItemWithTitle:@"Edit" action:NULL keyEquivalent:@""]
        .submenu = mt_edit_menu();

    NSMenu *keym = [[NSMenu alloc] initWithTitle:@"Key"];
    mt_add_item(keym, @"Generate key pair", @selector(generate:), k,
                @"g", cmd);
    [keym addItem:[NSMenuItem separatorItem]];
    mt_add_item(keym, @"Add certificate to key", @selector(addCertificate:),
                k, nil, 0);
    mt_add_item(keym, @"Remove certificate from key",
                @selector(removeCertificate:), k, nil, 0);
    [keym addItem:[NSMenuItem separatorItem]];
    static const struct { const char *title; int tag; } types[] = {
        {"SSH-1 key (RSA)", KT_SSH1},
        {"SSH-2 RSA key", KT_RSA},
        {"SSH-2 DSA key", KT_DSA},
        {"SSH-2 ECDSA key", KT_ECDSA},
        {"SSH-2 EdDSA key", KT_EDDSA},
    };
    for (size_t i = 0; i < lenof(types); i++)
        mt_add_item(keym, @(types[i].title), @selector(keyTypeMenu:), k,
                    nil, 0).tag = types[i].tag;
    [keym addItem:[NSMenuItem separatorItem]];
    mt_add_item(keym, @"Use probable primes (fast)",
                @selector(primePolicyMenu:), k, nil, 0).tag = PRIME_PROB;
    mt_add_item(keym, @"Use proven primes (slower)",
                @selector(primePolicyMenu:), k, nil, 0)
        .tag = PRIME_MAURER_SIMPLE;
    mt_add_item(keym, @"Use proven primes with even distribution (slowest)",
                @selector(primePolicyMenu:), k, nil, 0)
        .tag = PRIME_MAURER_COMPLEX;
    [keym addItem:[NSMenuItem separatorItem]];
    mt_add_item(keym, @"Use \"strong\" primes as RSA key factors",
                @selector(toggleStrongRSA:), k, nil, 0);
    [keym addItem:[NSMenuItem separatorItem]];
    mt_add_item(keym, @"Parameters for saving key files...",
                @selector(ppkParameters:), k, nil, 0);
    [keym addItem:[NSMenuItem separatorItem]];
    mt_add_item(keym, @"Show fingerprint as SHA256",
                @selector(fingerprintTypeMenu:), k, nil, 0)
        .tag = SSH_FPTYPE_SHA256;
    mt_add_item(keym, @"Show fingerprint as MD5",
                @selector(fingerprintTypeMenu:), k, nil, 0)
        .tag = SSH_FPTYPE_MD5;
    [bar addItemWithTitle:@"Key" action:NULL keyEquivalent:@""]
        .submenu = keym;

    NSMenu *cvt = [[NSMenu alloc] initWithTitle:@"Conversions"];
    mt_add_item(cvt, @"Import key", @selector(importKey:), k, nil, 0);
    [cvt addItem:[NSMenuItem separatorItem]];
    mt_add_item(cvt, @"Export OpenSSH key", @selector(exportKey:), k,
                nil, 0).tag = SSH_KEYTYPE_OPENSSH_AUTO;
    mt_add_item(cvt, @"Export OpenSSH key (force new file format)",
                @selector(exportKey:), k, nil, 0)
        .tag = SSH_KEYTYPE_OPENSSH_NEW;
    mt_add_item(cvt, @"Export ssh.com key", @selector(exportKey:), k,
                nil, 0).tag = SSH_KEYTYPE_SSHCOM;
    [bar addItemWithTitle:@"Conversions" action:NULL keyEquivalent:@""]
        .submenu = cvt;

    NSMenu *win = [[NSMenu alloc] initWithTitle:@"Window"];
    mt_add_item(win, @"Minimize", @selector(performMiniaturize:), nil,
                @"m", cmd);
    [win addItem:[NSMenuItem separatorItem]];
    mt_add_item(win, @"Bring All to Front", @selector(arrangeInFront:), nil,
                nil, 0);
    [bar addItemWithTitle:@"Window" action:NULL keyEquivalent:@""]
        .submenu = win;
    NSApp.windowsMenu = win;

    NSMenu *help = [[NSMenu alloc] initWithTitle:@"Help"];
    mt_add_item(help, @TOOLNAME " Help", @selector(showHelp:), self,
                @"?", cmd);
    [bar addItemWithTitle:@"Help" action:NULL keyEquivalent:@""]
        .submenu = help;
    NSApp.helpMenu = help;

    NSApp.mainMenu = bar;
}

- (void)about:(id)sender
{
    mt_about_box(TOOLNAME, "PuTTY's key generator (PuTTYgen) for macOS.");
}

- (void)showHelp:(id)sender
{
    mt_open_manual(@"Chapter8.html");
}

- (BOOL)application:(NSApplication *)app openFile:(NSString *)path
{
    if (!self.keygen) {
        if (!pendingFiles)
            pendingFiles = [NSMutableArray array];
        [pendingFiles addObject:path];
        return YES;
    }
    if (self.keygen.isGenerating)
        return NO;
    Filename *fn = filename_from_str(path.fileSystemRepresentation);
    [self.keygen loadKeyFile:fn wasImport:NO];
    filename_free(fn);
    return YES;
}

- (void)applicationDidFinishLaunching:(NSNotification *)n
{
    self.keygen = [[MTKeygen alloc] init];
    [self buildMenus];
    mt_activate();
    [self.keygen.window makeKeyAndOrderFront:nil];

    /* Load a key file if one was provided on the command line. */
    if (initial.keyfile) {
        [self.keygen loadKeyFile:initial.keyfile wasImport:NO];
        filename_free(initial.keyfile);
        initial.keyfile = NULL;
    }
    for (NSString *path in pendingFiles)
        [self application:NSApp openFile:path];
    pendingFiles = nil;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a
{
    return YES;                        /* PuTTYgen is its window */
}

- (void)applicationWillTerminate:(NSNotification *)n
{
    /* The generation thread owns the random pool while it runs. */
    if (!self.keygen.isGenerating)
        random_save_seed();
}

@end

/* ----------------------------------------------------------------------
 * Command line, as in WinMain.
 */

static NORETURN void opt_error(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    char *msg = dupvprintf(fmt, ap);
    va_end(ap);
    fprintf(stderr, "%s: %s", TOOLNAME, msg);
    mt_error_box(@TOOLNAME " command line error", mt_ns(msg));
    exit(1);
}

static void parse_command_line(int argc, char **argv)
{
    int argbits = -1;
    for (int i = 1; i < argc; i++) {
        const char *p = argv[i];
        const char *val = (i + 1 < argc) ? argv[i + 1] : NULL;

        /* Arguments macOS and Xcode add to a GUI launch. */
        if (!strncmp(p, "-psn_", 5))
            continue;
        if (!strncmp(p, "-NS", 3) || !strncmp(p, "-Apple", 6)) {
            i++;
            continue;
        }

#define NEEDS_VAL do { if (!val) opt_error("option '%s' expects a value\n", \
                                            p); i++; } while (0)
        if (p[0] != '-') {
            if (!initial.keyfile)
                initial.keyfile = filename_from_str(p);
            else
                opt_error("unexpected extra argument '%s'\n", p);
        } else if (!strcmp(p, "-pgpfp")) {
            pgp_fingerprints();
            exit(0);
        } else if (!strcmp(p, "-t")) {
            NEEDS_VAL;
            if (!strcmp(val, "rsa") || !strcmp(val, "rsa2")) {
                initial.keybutton = KT_RSA;
            } else if (!strcmp(val, "rsa1")) {
                initial.keybutton = KT_SSH1;
            } else if (!strcmp(val, "dsa") || !strcmp(val, "dss")) {
                initial.keybutton = KT_DSA;
            } else if (!strcmp(val, "ecdsa")) {
                initial.keybutton = KT_ECDSA;
            } else if (!strcmp(val, "eddsa")) {
                initial.keybutton = KT_EDDSA;
            } else if (!strcmp(val, "ed25519")) {
                initial.keybutton = KT_EDDSA;
                argbits = 255;
            } else if (!strcmp(val, "ed448")) {
                initial.keybutton = KT_EDDSA;
                argbits = 448;
            } else {
                opt_error("unknown key type '%s'\n", val);
            }
        } else if (!strcmp(p, "-b")) {
            NEEDS_VAL;
            argbits = atoi(val);
        } else if (!strcmp(p, "-E")) {
            NEEDS_VAL;
            if (!strcmp(val, "md5"))
                initial.fptype = SSH_FPTYPE_MD5;
            else if (!strcmp(val, "sha256"))
                initial.fptype = SSH_FPTYPE_SHA256;
            else
                opt_error("unknown fingerprint type '%s'\n", val);
        } else if (!strcmp(p, "-primes")) {
            NEEDS_VAL;
            if (!strcmp(val, "probable") ||
                !strcmp(val, "probabilistic")) {
                initial.primepolicy = PRIME_PROB;
            } else if (!strcmp(val, "provable") ||
                       !strcmp(val, "proven") ||
                       !strcmp(val, "simple") ||
                       !strcmp(val, "maurer-simple")) {
                initial.primepolicy = PRIME_MAURER_SIMPLE;
            } else if (!strcmp(val, "provable-even") ||
                       !strcmp(val, "proven-even") ||
                       !strcmp(val, "even") ||
                       !strcmp(val, "complex") ||
                       !strcmp(val, "maurer-complex")) {
                initial.primepolicy = PRIME_MAURER_COMPLEX;
            } else {
                opt_error("unrecognised prime-generation mode '%s'\n", val);
            }
        } else if (!strcmp(p, "-strong-rsa")) {
            initial.rsa_strong = true;
        } else if (!strcmp(p, "-ppk-param") || !strcmp(p, "-ppk-params")) {
            NEEDS_VAL;
            char *vals = dupstr(val), *v = vals, *nextval;
            for (; v; v = nextval) {
                nextval = strchr(v, ',');
                if (nextval)
                    *nextval++ = '\0';

                char *optvalue = strchr(v, '=');
                if (!optvalue)
                    opt_error("PPK parameter '%s' expected a value\n", v);
                *optvalue++ = '\0';

                /* Non-numeric options */
                if (!strcmp(v, "kdf")) {
                    if (!strcmp(optvalue, "Argon2id") ||
                        !strcmp(optvalue, "argon2id")) {
                        save_params.argon2_flavour = Argon2id;
                    } else if (!strcmp(optvalue, "Argon2i") ||
                               !strcmp(optvalue, "argon2i")) {
                        save_params.argon2_flavour = Argon2i;
                    } else if (!strcmp(optvalue, "Argon2d") ||
                               !strcmp(optvalue, "argon2d")) {
                        save_params.argon2_flavour = Argon2d;
                    } else {
                        opt_error("unrecognised kdf '%s'\n", optvalue);
                    }
                    continue;
                }

                char *end;
                unsigned long n = strtoul(optvalue, &end, 0);
                if (!*optvalue || *end)
                    opt_error("value '%s' for PPK parameter '%s': expected "
                              "a number\n", optvalue, v);

                if (!strcmp(v, "version")) {
                    save_params.fmt_version = n;
                } else if (!strcmp(v, "memory") || !strcmp(v, "mem")) {
                    save_params.argon2_mem = n;
                } else if (!strcmp(v, "time")) {
                    save_params.argon2_passes_auto = true;
                    save_params.argon2_milliseconds = n;
                } else if (!strcmp(v, "passes")) {
                    save_params.argon2_passes_auto = false;
                    save_params.argon2_passes = n;
                } else if (!strcmp(v, "parallelism") ||
                           !strcmp(v, "parallel")) {
                    save_params.argon2_parallelism = n;
                } else {
                    opt_error("unrecognised PPK parameter '%s'\n", v);
                }
            }
            sfree(vals);
        } else if (!strcmp(p, "--help") || !strcmp(p, "-help") ||
                   !strcmp(p, "--version") || !strcmp(p, "-version")) {
            char *bi = buildinfo("\n");
            printf("%s %s (PuTTY %s)\n%s\n", TOOLNAME,
                   mt_version().UTF8String, ver, bi);
            sfree(bi);
            exit(0);
        } else {
            opt_error("unrecognised option '%s'\n", p);
        }
#undef NEEDS_VAL
    }

    /* Translate argbits into eccurve_index and edcurve_index */
    if (argbits > 0) {
        switch (initial.keybutton) {
          case KT_RSA:
          case KT_SSH1:
          case KT_DSA:
            initial.keybits = argbits;
            break;
          case KT_ECDSA: {
            bool found = false;
            for (int j = 0; j < n_ec_nist_curve_lengths; j++)
                if (argbits == ec_nist_curve_lengths[j]) {
                    initial.eccurve_index = j;
                    found = true;
                    break;
                }
            if (!found)
                opt_error("unsupported ECDSA bit length %d", argbits);
            break;
          }
          case KT_EDDSA: {
            bool found = false;
            for (int j = 0; j < n_ec_ed_curve_lengths; j++)
                if (argbits == ec_ed_curve_lengths[j]) {
                    initial.edcurve_index = j;
                    found = true;
                    break;
                }
            if (!found)
                opt_error("unsupported EDDSA bit length %d", argbits);
            break;
          }
        }
    }
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        enable_dit();

        /* The command line is PuTTYgen's, parsed below; AppKit must
         * not also open its file names as documents. */
        [NSUserDefaults.standardUserDefaults registerDefaults:
            @{@"NSTreatUnknownArgumentsAsOpen": @"NO"}];

        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyRegular;

        initial.keybutton = KT_RSA;
        initial.primepolicy = PRIME_PROB;
        initial.rsa_strong = false;
        initial.fptype = SSH_FPTYPE_DEFAULT;
        initial.keybits = DEFAULT_KEY_BITS;
        initial.eccurve_index = DEFAULT_ECCURVE_INDEX;
        initial.edcurve_index = DEFAULT_EDCURVE_INDEX;
        save_params = ppk_save_default_parameters;
        parse_command_line(argc, argv);

        random_setup_special();

        MTKeygenApp *delegate = [MTKeygenApp new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
