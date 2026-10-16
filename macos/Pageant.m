/*
 * Pageant.m: Pageant, PuTTY's SSH authentication agent, for macOS.
 *
 * The agent itself is PuTTY's (pageant.c), serving the OpenSSH agent
 * protocol on a Unix socket as Unix Pageant does (unix/pageant.c);
 * see pageant-socket.c for where that socket lives. The user
 * interface is a port of Windows Pageant's (windows/pageant.c): the
 * notification-area icon becomes a menu bar item with the same menu,
 * and the key list window has the same list and buttons, plus the
 * socket path to give to other SSH clients.
 */

#import <Cocoa/Cocoa.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <signal.h>

#include "putty.h"
#include "ssh.h"
#include "pageant.h"
#include "storage.h"
#include "mactty.h"
#import "tools.h"

#define APPNAME "Pageant"
#define PAGEANT_DIR_PREFIX "/tmp/pageant"

static NSString *const kErrorTitle = @APPNAME " Error";

static char *socketname;               /* the real socket */
static char *linkpath;                 /* the fixed link to it */
static FingerprintType fptype = SSH_FPTYPE_DEFAULT;

@class MTKeyList;
static MTKeyList *keylist;             /* the key list window, if open */

/* ----------------------------------------------------------------------
 * What the PuTTY core expects from a front end.
 */

void modalfatalbox(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    char *buf = dupvprintf(fmt, ap);
    va_end(ap);
    mt_error_box(@APPNAME " Fatal Error", mt_ns(buf));
    sfree(buf);
    exit(1);
}

void nonfatal(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    char *buf = dupvprintf(fmt, ap);
    va_end(ap);
    mt_error_box(kErrorTitle, mt_ns(buf));
    sfree(buf);
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
                "You can perform this conversion by loading the key "
                "into MacTTYgen and then saving it again.");
}

void cleanup_exit(int code)
{
    exit(code);
}

void cmdline_error(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    char *msg = dupvprintf(fmt, ap);
    va_end(ap);
    fprintf(stderr, "pageant: %s\n", msg);
    mt_error_box(@APPNAME " command line error", mt_ns(msg));
    exit(1);
}

/* Stubs, as in unix/pageant.c: Pageant keeps no random seed file and
 * reads no saved settings. */
void random_save_seed(void) {}
void random_destroy_seed(void) {}
char *platform_default_s(const char *name) { return NULL; }
bool platform_default_b(const char *name, bool def) { return def; }
int platform_default_i(const char *name, int def) { return def; }
FontSpec *platform_default_fontspec(const char *name)
{ return fontspec_new_default(); }
Filename *platform_default_filename(const char *name)
{ return filename_from_str(""); }
char *x_get_default(const char *key) { return NULL; }
const bool buildinfo_gtk_relevant = false;
/* Pageant has no random number generator (see random_read in
 * pageant.c), so the noise the network code collects goes nowhere. */
void random_add_noise(NoiseSourceId source, const void *noise, int length)
{
}

/* ----------------------------------------------------------------------
 * Adding key files (win_add_keyfile, prompt_add_keyfile).
 */

static bool add_keyfile(Filename *filename, bool encrypted)
{
    char *err;
    bool ok = false;

    /*
     * Try loading the key without a passphrase. (Or rather, without
     * a _new_ passphrase; pageant_add_keyfile will take care of
     * trying all the passphrases we've already stored.)
     */
    int ret = pageant_add_keyfile(filename, NULL, &err, encrypted);
    if (ret == PAGEANT_ACTION_OK) {
        ok = true;
        goto done;
    } else if (ret == PAGEANT_ACTION_FAILURE) {
        goto error;
    }

    /*
     * OK, a passphrase is needed, and we've been given the key
     * comment to use in the passphrase prompt.
     */
    while (1) {
        char *passphrase = mt_passphrase_prompt(
            @APPNAME ": Loading Encrypted Key",
            @"Enter passphrase to load key", err);
        if (!passphrase)
            goto done;                 /* operation cancelled */

        sfree(err);
        ret = pageant_add_keyfile(filename, passphrase, &err, encrypted);
        burnstr(passphrase);

        if (ret == PAGEANT_ACTION_OK) {
            ok = true;
            goto done;
        } else if (ret == PAGEANT_ACTION_FAILURE) {
            goto error;
        }
    }

  error:
    mt_error_box(kErrorTitle, mt_ns(err));
  done:
    sfree(err);
    return ok;
}

static void prompt_add_keyfile(bool encrypted)
{
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.message = @"Select Private Key File";
    p.canChooseFiles = YES;
    p.canChooseDirectories = NO;
    p.allowsMultipleSelection = YES;
    mt_keep_visible(p);
    mt_activate();
    if ([p runModal] != NSModalResponseOK)
        return;
    for (NSURL *url in p.URLs) {
        Filename *fn = filename_from_str(url.fileSystemRepresentation);
        add_keyfile(fn, encrypted);
        filename_free(fn);
    }
    keylist_update();
    pageant_forget_passphrases();
}

/* ----------------------------------------------------------------------
 * The passphrase prompt for keys added encrypted, raised when a client
 * first wants to use one (IDD_ONDEMAND_PASSPHRASE). It is not modal:
 * Pageant goes on serving other requests meanwhile.
 */

@interface MTDecryptPrompt : NSObject <NSWindowDelegate>
@end

static MTDecryptPrompt *decrypt_prompt;

@implementation MTDecryptPrompt {
    NSPanel *panel;
    NSSecureTextField *field;
    PageantClientDialogId *dlgid;
}

static NSTextField *centred_label(NSView *parent, NSString *text, CGFloat y,
                                  CGFloat w, BOOL bold)
{
    NSTextField *l = [NSTextField labelWithString:text];
    l.alignment = NSTextAlignmentCenter;
    l.frame = NSMakeRect(16, y, w - 32, 17);
    l.lineBreakMode = NSLineBreakByTruncatingMiddle;
    if (bold)
        l.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
    [parent addSubview:l];
    return l;
}

- (instancetype)initWithDialog:(PageantClientDialogId *)d
                       comment:(const char *)comment
{
    if (!(self = [super init]))
        return nil;
    dlgid = d;

    const CGFloat W = 460, H = 172;
    panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, W, H)
                                       styleMask:(NSWindowStyleMaskTitled |
                                                  NSWindowStyleMaskClosable)
                                         backing:NSBackingStoreBuffered
                                           defer:NO];
    panel.title = @APPNAME ": Decrypting Stored Key";
    panel.releasedWhenClosed = NO;
    panel.delegate = self;
    /* Stay visible above other applications' windows: the request
     * comes from some other program the user is working in. */
    panel.level = NSFloatingWindowLevel;
    panel.hidesOnDeactivate = NO;
    NSView *c = panel.contentView;

    CGFloat y = H - 34;
    centred_label(c, @"A client of Pageant wants to use the following "
                  "encrypted key:", y, W, NO);
    y -= 20;
    centred_label(c, mt_ns(comment), y, W, YES);
    y -= 26;
    centred_label(c, @"If you intended this, click in this box to make "
                  "sure it has", y, W, NO);
    y -= 17;
    centred_label(c, @"input focus, then enter the passphrase to decrypt "
                  "the key.", y, W, NO);
    y -= 30;
    field = [[NSSecureTextField alloc]
                initWithFrame:NSMakeRect(20, y, W - 40, 22)];
    field.accessibilityLabel = @"Passphrase";
    [c addSubview:field];

    NSButton *ok = [NSButton buttonWithTitle:@"OK" target:self
                                      action:@selector(ok:)];
    ok.frame = NSMakeRect(W - 116, 10, 100, 32);
    ok.keyEquivalent = @"\r";
    [c addSubview:ok];
    NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self
                                          action:@selector(cancel:)];
    cancel.frame = NSMakeRect(W - 216, 10, 100, 32);
    cancel.keyEquivalent = @"\e";
    [c addSubview:cancel];
    NSButton *help = [NSButton buttonWithTitle:@"Help" target:self
                                        action:@selector(help:)];
    help.frame = NSMakeRect(14, 10, 100, 32);
    [c addSubview:help];

    panel.initialFirstResponder = field;
    [panel center];
    return self;
}

- (void)show
{
    mt_activate();
    [panel makeKeyAndOrderFront:nil];
    [panel makeFirstResponder:field];
}

/*
 * Take this prompt down before passing the result to the Pageant
 * core: if the passphrase is wrong, the core asks again at once, from
 * inside pageant_passphrase_request_success, and expects the previous
 * prompt to be gone (see end_passphrase_dialog in windows/pageant.c).
 */
- (void)finish:(BOOL)success
{
    PageantClientDialogId *d = dlgid;
    char *passphrase = success ?
        dupstr(field.stringValue.UTF8String ?: "") : NULL;
    field.stringValue = @"";
    panel.delegate = nil;
    [panel orderOut:nil];
    decrypt_prompt = nil;

    if (success) {
        pageant_passphrase_request_success(d, ptrlen_from_asciz(passphrase));
        burnstr(passphrase);
    } else {
        pageant_passphrase_request_refused(d);
    }
}

- (void)ok:(id)sender { [self finish:YES]; }
- (void)cancel:(id)sender { [self finish:NO]; }
- (void)help:(id)sender { mt_open_manual(@"Chapter9.html#pageant-deferred-decryption"); }
- (void)windowWillClose:(NSNotification *)n { [self finish:NO]; }

@end

static bool mac_ask_passphrase(PageantListenerClient *plc,
                               PageantClientDialogId *dlgid,
                               const char *comment)
{
    /* Pageant core should be serialising requests, so we never expect
     * a passphrase prompt to exist already at this point */
    assert(!decrypt_prompt);
    decrypt_prompt = [[MTDecryptPrompt alloc] initWithDialog:dlgid
                                                     comment:comment];
    [decrypt_prompt show];
    return true;
}

static const PageantListenerClientVtable macpgnt_vtable = {
    .log = NULL, /* no logging */
    .ask_passphrase = mac_ask_passphrase,
};

static PageantListenerClient listener_client = {
    .vt = &macpgnt_vtable,
    .suppress_logging = true,
};

/* ----------------------------------------------------------------------
 * The key list window (IDD_KEYLIST).
 */

@interface MTKeyRow : NSObject
@property (nonatomic, copy) NSString *alg, *bits, *fingerprint, *comment, *info;
@property (nonatomic) struct pageant_pubkey *key;
@property (nonatomic) BOOL reencryptable;
@end

@implementation MTKeyRow
- (void)dealloc
{
    if (_key)
        pageant_pubkey_free(_key);
}
@end

@interface MTKeyList : NSWindowController <NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate>
- (void)reload;
@end

/* The number of keys on the menu bar item (MTPageantApp, below). */
static void update_status_item(void);

static NSString *display_path(const char *path)
{
    /* As the user would type it: ~ for the home directory. */
    NSString *p = mt_ns(path);
    NSString *home = NSHomeDirectory();
    const char *env = getenv("HOME");
    if (env && *env)
        home = mt_ns(env);
    if (home.length && [p hasPrefix:[home stringByAppendingString:@"/"]])
        p = [@"~" stringByAppendingString:[p substringFromIndex:home.length]];
    return p;
}

static NSString *shell_quote(NSString *s)
{
    NSCharacterSet *safe = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        "0123456789/._-~"];
    if ([s rangeOfCharacterFromSet:safe.invertedSet].location == NSNotFound)
        return s;
    return [NSString stringWithFormat:@"'%@'",
            [s stringByReplacingOccurrencesOfString:@"'"
                                         withString:@"'\\''"]];
}

/* The path other programs should use: the fixed link if we made it
 * and it is short enough to connect to (sockaddr_un.sun_path). */
static const char *agent_path(void)
{
    struct sockaddr_un addr;
    if (linkpath && strlen(linkpath) < sizeof(addr.sun_path))
        return linkpath;
    return socketname;
}

static NSString *agent_env_command(void)
{
    /* $HOME rather than ~, which the shell does not expand after '=' in
     * every context. */
    NSString *p = display_path(agent_path());
    if ([p hasPrefix:@"~/"])
        p = [@"$HOME" stringByAppendingString:[p substringFromIndex:1]];
    NSString *q = [p hasPrefix:@"$HOME"] ?
        [NSString stringWithFormat:@"\"%@\"", p] : shell_quote(p);
    return [NSString stringWithFormat:@"export SSH_AUTH_SOCK=%@", q];
}

@implementation MTKeyList {
    NSTableView *table;
    NSMutableArray<MTKeyRow *> *rows;
    NSPopUpButton *fpPopup;
    NSButton *removeButton, *reencryptButton;
    NSTextField *socketField;
    NSTextField *emptyHint;
}

static const struct {
    const char *name;
    FingerprintType value;
} fptypes[] = {
    {"SHA256", SSH_FPTYPE_SHA256},
    {"MD5", SSH_FPTYPE_MD5},
    {"SHA256 including certificate", SSH_FPTYPE_SHA256_CERT},
    {"MD5 including certificate", SSH_FPTYPE_MD5_CERT},
};

- (NSTableColumn *)column:(NSString *)ident title:(NSString *)title
                    width:(CGFloat)w
{
    NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:ident];
    c.title = title;
    c.width = w;
    c.minWidth = 30;
    c.editable = NO;
    [table addTableColumn:c];
    return c;
}

- (NSButton *)button:(NSString *)title frame:(NSRect)r action:(SEL)a
              parent:(NSView *)parent
{
    NSButton *b = [NSButton buttonWithTitle:title target:self action:a];
    b.frame = r;
    [parent addSubview:b];
    return b;
}

- (instancetype)init
{
    const CGFloat W = 880, H = 420;
    NSWindow *w = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, W, H)
                  styleMask:(NSWindowStyleMaskTitled |
                             NSWindowStyleMaskClosable |
                             NSWindowStyleMaskMiniaturizable |
                             NSWindowStyleMaskResizable)
                    backing:NSBackingStoreBuffered defer:NO];
    w.title = @APPNAME " Key List";
    w.releasedWhenClosed = NO;
    w.minSize = NSMakeSize(560, 300);
    if (!(self = [super initWithWindow:w]))
        return nil;
    w.delegate = self;
    NSView *c = w.contentView;
    rows = [NSMutableArray array];

    /* Bottom up: Help/Close, the agent socket, the key buttons, the
     * fingerprint type, then the list filling the rest. */
    CGFloat y = 12;
    [self button:@"Help" frame:NSMakeRect(14, y, 100, 32)
          action:@selector(help:) parent:c];
    NSButton *close = [self button:@"Close"
                             frame:NSMakeRect(W - 114, y, 100, 32)
                            action:@selector(performClose:) parent:c];
    close.target = w;
    close.keyEquivalent = @"\r";
    close.autoresizingMask = NSViewMinXMargin;

    y += 42;
    NSTextField *sl = [NSTextField labelWithString:@"SSH_AUTH_SOCK:"];
    sl.frame = NSMakeRect(20, y + 3, 130, 17);
    [c addSubview:sl];
    socketField = [NSTextField textFieldWithString:
                      display_path(agent_path())];
    socketField.editable = NO;
    socketField.selectable = YES;
    socketField.frame = NSMakeRect(150, y, W - 150 - 166 - 196, 22);
    socketField.autoresizingMask = NSViewWidthSizable;
    socketField.accessibilityLabel = @"SSH_AUTH_SOCK";
    socketField.toolTip = @"Give this to other SSH clients (OpenSSH's "
        "ssh, ssh-add, git...) as SSH_AUTH_SOCK, or as IdentityAgent "
        "in ~/.ssh/config. MacTTY uses it automatically.";
    [c addSubview:socketField];
    NSTextField *auto_ = [NSTextField labelWithString:
                             @"MacTTY uses it automatically"];
    auto_.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    auto_.textColor = NSColor.secondaryLabelColor;
    auto_.alignment = NSTextAlignmentRight;
    auto_.frame = NSMakeRect(W - 166 - 190, y + 3, 182, 17);
    auto_.autoresizingMask = NSViewMinXMargin;
    [c addSubview:auto_];
    NSButton *copy = [self button:@"Copy Command"
                            frame:NSMakeRect(W - 158, y - 5, 144, 32)
                           action:@selector(copySocket:) parent:c];
    copy.toolTip = @"Copy \"export SSH_AUTH_SOCK=...\" for a shell";
    copy.autoresizingMask = NSViewMinXMargin;

    y += 40;
    [self button:@"Add Key" frame:NSMakeRect(14, y, 120, 32)
          action:@selector(addKey:) parent:c];
    [self button:@"Add Key (encrypted)" frame:NSMakeRect(142, y, 180, 32)
          action:@selector(addKeyEncrypted:) parent:c];
    reencryptButton = [self button:@"Re-encrypt"
                             frame:NSMakeRect(W - 242, y, 120, 32)
                            action:@selector(reencrypt:) parent:c];
    reencryptButton.autoresizingMask = NSViewMinXMargin;
    removeButton = [self button:@"Remove"
                          frame:NSMakeRect(W - 114, y, 100, 32)
                         action:@selector(removeKeys:) parent:c];
    removeButton.autoresizingMask = NSViewMinXMargin;

    y += 40;
    NSTextField *fl = [NSTextField labelWithString:@"Fingerprint type:"];
    fl.frame = NSMakeRect(20, y + 4, 120, 17);
    [c addSubview:fl];
    fpPopup = [[NSPopUpButton alloc]
                  initWithFrame:NSMakeRect(140, y, 260, 26) pullsDown:NO];
    for (size_t i = 0; i < lenof(fptypes); i++) {
        [fpPopup addItemWithTitle:mt_ns(fptypes[i].name)];
        if (fptype == fptypes[i].value)
            [fpPopup selectItemAtIndex:i];
    }
    fpPopup.target = self;
    fpPopup.action = @selector(fptypeChanged:);
    fpPopup.accessibilityLabel = @"Fingerprint type";
    [c addSubview:fpPopup];

    y += 36;
    NSScrollView *sv = [[NSScrollView alloc]
                           initWithFrame:NSMakeRect(20, y, W - 40, H - y - 16)];
    sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    sv.hasVerticalScroller = YES;
    sv.borderType = NSBezelBorder;
    table = [[NSTableView alloc] initWithFrame:sv.bounds];
    table.allowsMultipleSelection = YES;
    table.usesAlternatingRowBackgroundColors = YES;
    table.columnAutoresizingStyle =
        NSTableViewLastColumnOnlyAutoresizingStyle;
    table.dataSource = self;
    table.delegate = self;
    table.accessibilityLabel = @"Keys";
    [self column:@"alg" title:@"Key type" width:96];
    [self column:@"bits" title:@"Bits" width:44];
    [self column:@"fingerprint" title:@"Fingerprint" width:410];
    [self column:@"comment" title:@"Comment" width:150];
    [self column:@"info" title:@"" width:90];
    sv.documentView = table;
    [c addSubview:sv];

    /* Key files can be dropped on the list. */
    [table registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    [table setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];
    emptyHint = [NSTextField wrappingLabelWithString:
                    @"No keys loaded.\nAdd a key, or drop .ppk key files here."];
    emptyHint.alignment = NSTextAlignmentCenter;
    emptyHint.textColor = NSColor.secondaryLabelColor;
    emptyHint.frame = NSMakeRect(20, y + (H - y - 16) / 2 - 20, W - 40, 40);
    emptyHint.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin |
        NSViewMaxYMargin;
    [c addSubview:emptyHint];

    [w center];
    [self reload];
    return self;
}

/* keylist_update_callback: split the fingerprint into its words. */
static void keylist_callback(void *vctx, char **fingerprints,
                             const char *comment, uint32_t ext_flags,
                             struct pageant_pubkey *key)
{
    NSMutableArray<MTKeyRow *> *rows = (__bridge NSMutableArray *)vctx;
    FingerprintType this_type = ssh2_pick_fingerprint(fingerprints, fptype);
    ptrlen fingerprint = ptrlen_from_asciz(fingerprints[this_type]);
    MTKeyRow *r = [MTKeyRow new];

    switch (key->ssh_version) {
      case 1: {
        /* Two words: bit count and hash. */
        r.alg = @"SSH-1";
        ptrlen bits = ptrlen_get_word(&fingerprint, " ");
        r.bits = [[NSString alloc] initWithBytes:bits.ptr length:bits.len
                                        encoding:NSUTF8StringEncoding];
        break;
      }
      default: {
        /* Three words: algorithm name, bit count, hash. */
        const ssh_keyalg *alg = pubkey_blob_to_alg(
            ptrlen_from_strbuf(key->blob));
        ptrlen keytype_word = ptrlen_get_word(&fingerprint, " ");
        if (alg) {
            char *alg_desc = ssh_keyalg_desc(alg);
            r.alg = mt_ns(alg_desc);
            sfree(alg_desc);
        } else {
            r.alg = [[NSString alloc] initWithBytes:keytype_word.ptr
                                             length:keytype_word.len
                                           encoding:NSUTF8StringEncoding];
        }
        ptrlen bits_word = ptrlen_get_word(&fingerprint, " ");
        if (alg && ssh_keyalg_variable_size(alg))
            r.bits = [[NSString alloc] initWithBytes:bits_word.ptr
                                              length:bits_word.len
                                            encoding:NSUTF8StringEncoding];
        break;
      }
    }
    ptrlen hash = ptrlen_get_word(&fingerprint, " ");
    r.fingerprint = [[NSString alloc] initWithBytes:hash.ptr length:hash.len
                                           encoding:NSUTF8StringEncoding];
    r.comment = mt_ns(comment);

    if (ext_flags & LIST_EXTENDED_FLAG_HAS_NO_CLEARTEXT_KEY) {
        r.info = @"(encrypted)";
    } else if (ext_flags & LIST_EXTENDED_FLAG_HAS_ENCRYPTED_KEY_FILE) {
        r.info = @"(re-encryptable)";
        r.reencryptable = YES;
    }
    r.key = pageant_pubkey_copy(key);
    [rows addObject:r];
}

- (void)reload
{
    [rows removeAllObjects];
    char *errmsg = NULL;
    int status = pageant_enum_keys(keylist_callback,
                                   (__bridge void *)rows, &errmsg);
    assert(status == PAGEANT_ACTION_OK);
    assert(!errmsg);
    (void)status;
    [table reloadData];
    [table deselectAll:nil];

    BOOL reenc = NO;
    for (MTKeyRow *r in rows)
        reenc |= r.reencryptable;
    removeButton.enabled = rows.count > 0;
    reencryptButton.enabled = reenc;
    emptyHint.hidden = rows.count > 0;
}

/* Dropping key files on the list adds them, as Add Key would. */
- (NSDragOperation)tableView:(NSTableView *)tv
                validateDrop:(id<NSDraggingInfo>)info
                 proposedRow:(NSInteger)row
       proposedDropOperation:(NSTableViewDropOperation)op
{
    NSArray *urls = [info.draggingPasteboard
        readObjectsForClasses:@[NSURL.class]
                      options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    if (!urls.count)
        return NSDragOperationNone;
    [tv setDropRow:-1 dropOperation:NSTableViewDropOn];
    return NSDragOperationCopy;
}

- (BOOL)tableView:(NSTableView *)tv acceptDrop:(id<NSDraggingInfo>)info
              row:(NSInteger)row dropOperation:(NSTableViewDropOperation)op
{
    NSArray<NSURL *> *urls = [info.draggingPasteboard
        readObjectsForClasses:@[NSURL.class]
                      options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    for (NSURL *u in urls) {
        Filename *fn = filename_from_str(u.fileSystemRepresentation);
        add_keyfile(fn, false);
        filename_free(fn);
    }
    keylist_update();
    return urls.count > 0;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv
{
    return rows.count;
}

- (id)tableView:(NSTableView *)tv objectValueForTableColumn:(NSTableColumn *)col
            row:(NSInteger)i
{
    return [rows[i] valueForKey:col.identifier] ?: @"";
}

- (void)fptypeChanged:(id)sender
{
    NSInteger i = fpPopup.indexOfSelectedItem;
    if (i >= 0 && (size_t)i < lenof(fptypes)) {
        fptype = fptypes[i].value;
        [self reload];
    }
}

- (void)addKey:(id)sender { prompt_add_keyfile(false); }
- (void)addKeyEncrypted:(id)sender { prompt_add_keyfile(true); }

/* Remove or re-encrypt the selected keys. The list is rebuilt as each
 * key goes (keylist_update), so take copies of the keys first. */
- (void)actOnSelection:(BOOL)remove
{
    NSIndexSet *sel = table.selectedRowIndexes;
    if (!sel.count) {
        NSBeep();
        return;
    }
    NSMutableArray<NSValue *> *keys = [NSMutableArray array];
    [sel enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
        if (remove || rows[i].reencryptable)
            [keys addObject:[NSValue valueWithPointer:
                                pageant_pubkey_copy(rows[i].key)]];
    }];
    for (NSValue *v in keys) {
        struct pageant_pubkey *key = v.pointerValue;
        char *err = NULL;
        if (remove)
            pageant_delete_key(key, &err);
        else
            pageant_reencrypt_key(key, &err);
        sfree(err);
        pageant_pubkey_free(key);
    }
    keylist_update();
}

- (void)removeKeys:(id)sender { [self actOnSelection:YES]; }
- (void)reencrypt:(id)sender { [self actOnSelection:NO]; }

- (void)help:(id)sender
{
    mt_open_manual(@"Chapter9.html#pageant-mainwin");
}

- (void)copySocket:(id)sender
{
    NSPasteboard *pb = mt_pasteboard();
    [pb clearContents];
    [pb setString:agent_env_command() forType:NSPasteboardTypeString];
}

- (void)windowWillClose:(NSNotification *)n
{
    keylist = nil;
}

@end

void keylist_update(void)
{
    [keylist reload];
    update_status_item();
}

static void show_keylist(void)
{
    if (!keylist)
        keylist = [[MTKeyList alloc] init];
    mt_activate();
    [keylist.window makeKeyAndOrderFront:nil];
}

/* ----------------------------------------------------------------------
 * Starting MacTTY from the menu (IDM_PUTTY and the saved sessions).
 */

static NSURL *mactty_url(void)
{
    /* Normally we live inside MacTTY.app/Contents/Applications. */
    NSURL *outer = [[[NSBundle.mainBundle.bundleURL
        URLByDeletingLastPathComponent] URLByDeletingLastPathComponent]
        URLByDeletingLastPathComponent];
    NSBundle *b = [NSBundle bundleWithURL:outer];
    if ([b.bundleIdentifier isEqualToString:@"org.mactty.MacTTY"])
        return outer;
    return [NSWorkspace.sharedWorkspace
               URLForApplicationWithBundleIdentifier:@"org.mactty.MacTTY"];
}

static void start_mactty(NSString *session)
{
    NSRunningApplication *running = [NSRunningApplication
        runningApplicationsWithBundleIdentifier:@"org.mactty.MacTTY"]
        .firstObject;
    if (running) {
        /* One MacTTY process holds all its windows: ask it. */
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        info[@"pid"] = @(running.processIdentifier);
        if (session)
            info[@"session"] = session;
        [NSDistributedNotificationCenter.defaultCenter
            postNotificationName:@MACTTY_OPEN_SESSION_NOTIFICATION
                          object:nil userInfo:info
              deliverImmediately:YES];
        if (!mt_background_mode())
            [running activateWithOptions:0];
        return;
    }

    NSURL *url = mactty_url();
    if (!url) {
        mt_error_box(kErrorTitle, @"Unable to find MacTTY.");
        return;
    }
    NSWorkspaceOpenConfiguration *cfg =
        [NSWorkspaceOpenConfiguration configuration];
    cfg.activates = !mt_background_mode();
    cfg.environment = NSProcessInfo.processInfo.environment;
    if (session)
        cfg.arguments = @[@"-load", session];
    [NSWorkspace.sharedWorkspace openApplicationAtURL:url configuration:cfg
                                    completionHandler:nil];
}

/* ----------------------------------------------------------------------
 * The agent socket.
 */

/* Returns false if another Pageant already answers on the link. */
static bool start_agent(void)
{
    linkpath = mactty_pageant_link_path();
    char *running = mactty_pageant_socket();
    if (running) {
        sfree(linkpath);
        linkpath = running;            /* where to send key files */
        return false;
    }

    pageant_init();

    Plug *pl_plug;
    struct pageant_listen_state *pl =
        pageant_listener_new(&pl_plug, &listener_client);
    char *err;
    Socket *sock = platform_make_agent_socket(pl_plug, PAGEANT_DIR_PREFIX,
                                              &err, &socketname);
    if (!sock) {
        mt_error_box(kErrorTitle, [NSString stringWithFormat:
            @"Unable to open AF_UNIX socket for SSH agent:\n%s", err]);
        exit(1);
    }
    pageant_listener_got_socket(pl, sock);

    /*
     * The fixed link. Replace an old one (left by a Pageant that did
     * not get to clean up), but never anything that is not a link.
     */
    char *dir = dupstr(linkpath);
    char *slash = strrchr(dir, '/');
    if (slash)
        *slash = '\0';
    char *direrr = make_dir_path(dir, 0700);
    sfree(dir);
    struct stat st;
    if (lstat(linkpath, &st) == 0 && S_ISLNK(st.st_mode))
        unlink(linkpath);
    if (direrr || symlink(socketname, linkpath) < 0) {
        fprintf(stderr, "pageant: making symlink %s: %s\n", linkpath,
                direrr ? direrr : strerror(errno));
        sfree(direrr);
        sfree(linkpath);
        linkpath = NULL;
    }
    return true;
}

static void stop_agent(void)
{
    if (linkpath) {
        /* Only our own link: another Pageant may have taken over. */
        char target[1024];
        ssize_t n = readlink(linkpath, target, sizeof(target) - 1);
        if (n > 0) {
            target[n] = '\0';
            if (socketname && !strcmp(target, socketname))
                unlink(linkpath);
        }
    }
    if (socketname)
        unlink(socketname);
}

/* ----------------------------------------------------------------------
 * Application: the menu bar item and its menu (the systray menu).
 */

static bool start_encrypted;
static bool show_keylist_on_startup;
static NSMutableArray<NSString *> *startup_keyfiles;

@interface MTPageantApp : NSObject <NSApplicationDelegate, NSMenuDelegate>
@end

static MTPageantApp *the_app;

@implementation MTPageantApp {
    NSStatusItem *statusItem;
    NSMenu *menu, *sessionMenu;
    NSMenuItem *socketItem;
    NSMutableArray<NSMenuItem *> *keyItems;
}

/* The loaded keys, for the menu and the menu bar item. */
static NSArray<MTKeyRow *> *current_keys(void)
{
    NSMutableArray<MTKeyRow *> *rows = [NSMutableArray array];
    char *errmsg = NULL;
    pageant_enum_keys(keylist_callback, (__bridge void *)rows, &errmsg);
    sfree(errmsg);
    return rows;
}

- (void)updateStatusItem
{
    NSUInteger n = current_keys().count;
    statusItem.button.title = n ? [NSString stringWithFormat:@"%lu",
                                   (unsigned long)n] : @"";
    statusItem.button.imagePosition = n ? NSImageLeft : NSImageOnly;
    statusItem.button.toolTip = [NSString stringWithFormat:
        @"Pageant (PuTTY authentication agent): %lu key%s loaded",
        (unsigned long)n, n == 1 ? "" : "s"];
}

/* The top of the menu: how many keys there are, and which. */
- (void)updateKeyItems
{
    for (NSMenuItem *it in keyItems)
        [menu removeItem:it];
    keyItems = [NSMutableArray array];
    NSArray<MTKeyRow *> *keys = current_keys();
    NSString *head = keys.count == 1 ? @"Pageant · 1 key loaded" :
        [NSString stringWithFormat:@"Pageant · %lu keys loaded",
         (unsigned long)keys.count];
    NSMenuItem *h;
    if (@available(macOS 14.0, *)) {
        h = [NSMenuItem sectionHeaderWithTitle:head];
    } else {
        h = [[NSMenuItem alloc] initWithTitle:head action:NULL
                                keyEquivalent:@""];
        h.enabled = NO;
    }
    [keyItems addObject:h];
    for (MTKeyRow *r in keys) {
        NSString *fp = r.fingerprint.length > 16 ?
            [[r.fingerprint substringToIndex:16]
                stringByAppendingString:@"…"] : r.fingerprint;
        NSMenuItem *it = [[NSMenuItem alloc]
            initWithTitle:r.comment.length ? r.comment : r.alg
                   action:@selector(viewKeys:) keyEquivalent:@""];
        it.target = self;
        NSString *detail = [NSString stringWithFormat:@"%@ · %@", r.alg, fp];
        if (@available(macOS 14.4, *))
            it.subtitle = detail;
        else
            it.toolTip = detail;
        [keyItems addObject:it];
    }
    [keyItems addObject:[NSMenuItem separatorItem]];
    for (NSUInteger i = 0; i < keyItems.count; i++)
        [menu insertItem:keyItems[i] atIndex:i];
}

- (void)buildStatusMenu
{
    menu = [[NSMenu alloc] initWithTitle:@APPNAME];
    menu.delegate = self;
    if (mactty_url()) {
        mt_add_item(menu, @"New Session", @selector(newSession:), self,
                    nil, 0);
        sessionMenu = [[NSMenu alloc] initWithTitle:@"Saved Sessions"];
        sessionMenu.delegate = self;
        [menu addItemWithTitle:@"Saved Sessions" action:NULL
                 keyEquivalent:@""].submenu = sessionMenu;
        [menu addItem:[NSMenuItem separatorItem]];
    }
    mt_add_item(menu, @"View Keys", @selector(viewKeys:), self, nil, 0);
    mt_add_item(menu, @"Add Key...", @selector(addKey:), self, nil, 0);
    mt_add_item(menu, @"Add Key (encrypted)...", @selector(addKeyEncrypted:),
                self, nil, 0);
    [menu addItem:[NSMenuItem separatorItem]];
    mt_add_item(menu, @"Remove All Keys", @selector(removeAll:), self,
                nil, 0);
    mt_add_item(menu, @"Re-encrypt All Keys", @selector(reencryptAll:),
                self, nil, 0);
    [menu addItem:[NSMenuItem separatorItem]];
    socketItem = [menu addItemWithTitle:@"" action:NULL keyEquivalent:@""];
    socketItem.enabled = NO;
    mt_add_item(menu, @"Copy SSH_AUTH_SOCK Command",
                @selector(copySocket:), self, nil, 0);
    [menu addItem:[NSMenuItem separatorItem]];
    mt_add_item(menu, @"Help", @selector(help:), self, nil, 0);
    mt_add_item(menu, @"About " APPNAME, @selector(about:), self, nil, 0);
    [menu addItem:[NSMenuItem separatorItem]];
    mt_add_item(menu, @"Quit " APPNAME, @selector(terminate:), NSApp,
                @"q", NSEventModifierFlagCommand);

    statusItem = [NSStatusBar.systemStatusBar
                     statusItemWithLength:NSSquareStatusItemLength];
    NSImage *icon = [NSImage imageWithSystemSymbolName:@"key.fill"
                              accessibilityDescription:@APPNAME];
    icon.template = YES;
    statusItem.button.image = icon;
    statusItem.button.toolTip = @"Pageant (PuTTY authentication agent)";
    statusItem.menu = menu;
}

/* Key equivalents for the windows (the menu bar is not shown, since
 * Pageant lives in the menu bar item). */
- (void)buildMainMenu
{
    NSEventModifierFlags cmd = NSEventModifierFlagCommand;
    NSMenu *bar = [[NSMenu alloc] initWithTitle:@""];
    NSMenu *app = [[NSMenu alloc] initWithTitle:@APPNAME];
    mt_add_item(app, @"Quit " APPNAME, @selector(terminate:), nil, @"q", cmd);
    [bar addItemWithTitle:@"" action:NULL keyEquivalent:@""].submenu = app;
    [bar addItemWithTitle:@"Edit" action:NULL keyEquivalent:@""]
        .submenu = mt_edit_menu();
    NSMenu *win = [[NSMenu alloc] initWithTitle:@"Window"];
    mt_add_item(win, @"Close", @selector(performClose:), nil, @"w", cmd);
    [bar addItemWithTitle:@"Window" action:NULL keyEquivalent:@""]
        .submenu = win;
    NSApp.mainMenu = bar;
}

- (void)menuNeedsUpdate:(NSMenu *)m
{
    if (m == sessionMenu) {
        [m removeAllItems];
        struct sesslist sl;
        get_sesslist(&sl, true);
        /* Entry 0 is "Default Settings", which is not a session. */
        for (int i = 1; i < sl.nsessions; i++) {
            NSMenuItem *it = [m addItemWithTitle:mt_ns(sl.sessions[i])
                                          action:@selector(openSession:)
                                   keyEquivalent:@""];
            it.target = self;
            it.representedObject = mt_ns(sl.sessions[i]);
        }
        if (sl.nsessions <= 1) {
            NSMenuItem *it = [m addItemWithTitle:@"(No sessions)"
                                          action:NULL keyEquivalent:@""];
            it.enabled = NO;
        }
        get_sesslist(&sl, false);
    } else if (m == menu) {
        [self updateKeyItems];
        socketItem.title = [@"SSH_AUTH_SOCK: "
                            stringByAppendingString:display_path(
                                agent_path())];
    }
}

- (void)newSession:(id)sender { start_mactty(nil); }
- (void)openSession:(NSMenuItem *)sender
{
    start_mactty(sender.representedObject);
}
- (void)viewKeys:(id)sender { show_keylist(); }
- (void)addKey:(id)sender { prompt_add_keyfile(false); }
- (void)addKeyEncrypted:(id)sender { prompt_add_keyfile(true); }

- (void)removeAll:(id)sender
{
    pageant_delete_all();
    keylist_update();
}

- (void)reencryptAll:(id)sender
{
    pageant_reencrypt_all();
    keylist_update();
}

- (void)copySocket:(id)sender
{
    NSPasteboard *pb = mt_pasteboard();
    [pb clearContents];
    [pb setString:agent_env_command() forType:NSPasteboardTypeString];
}

- (void)help:(id)sender { mt_open_manual(@"Chapter9.html"); }

- (void)about:(id)sender
{
    mt_about_box(APPNAME, "PuTTY's SSH authentication agent (Pageant) "
                 "for macOS.");
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    if (item.action == @selector(removeAll:))
        return pageant_count_ssh1_keys() + pageant_count_ssh2_keys() > 0;
    return YES;
}

- (void)applicationDidFinishLaunching:(NSNotification *)n
{
    [self buildMainMenu];

    if (!start_agent()) {
        /*
         * Another Pageant is running. As on Windows, key files on the
         * command line go to that one; otherwise there is nothing for
         * a second Pageant to do.
         */
        if (startup_keyfiles.count) {
            setenv("SSH_AUTH_SOCK", linkpath, 1);
            for (NSString *f in startup_keyfiles) {
                Filename *fn = filename_from_str(f.fileSystemRepresentation);
                add_keyfile(fn, start_encrypted);
                filename_free(fn);
            }
        } else {
            mt_error_box(kErrorTitle, @"Pageant is already running");
        }
        exit(0);
    }

    [self buildStatusMenu];
    the_app = self;

    /* Load any keys provided on the command line. */
    for (NSString *f in startup_keyfiles) {
        Filename *fn = filename_from_str(f.fileSystemRepresentation);
        add_keyfile(fn, start_encrypted);
        filename_free(fn);
    }
    startup_keyfiles = nil;
    pageant_forget_passphrases();
    keylist_update();

    if (show_keylist_on_startup)
        show_keylist();
}

/* Started again (from MacTTY's menu, or the Finder) while running. */
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app
                    hasVisibleWindows:(BOOL)visible
{
    show_keylist();
    return NO;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a
{
    return NO;                         /* the agent outlives its windows */
}

- (void)applicationWillTerminate:(NSNotification *)n
{
    stop_agent();
}

@end

static void update_status_item(void)
{
    [the_app updateStatusItem];
}

/* ----------------------------------------------------------------------
 * Command line, as Windows Pageant's: key files to load, optionally
 * without decrypting them, and -keylist to show the key list.
 */

static void parse_command_line(int argc, char **argv)
{
    startup_keyfiles = [NSMutableArray array];
    for (int i = 1; i < argc; i++) {
        const char *p = argv[i];
        /* Arguments macOS and Xcode add to a GUI launch. */
        if (!strncmp(p, "-psn_", 5))
            continue;
        if (!strncmp(p, "-NS", 3) || !strncmp(p, "-Apple", 6)) {
            i++;
            continue;
        }

        if (p[0] != '-') {
            [startup_keyfiles addObject:@(p)];
        } else if (!strcmp(p, "-pgpfp")) {
            pgp_fingerprints();
            exit(0);
        } else if (!strcmp(p, "-no-decrypt") || !strcmp(p, "-no_decrypt") ||
                   !strcmp(p, "-nodecrypt") || !strcmp(p, "-encrypted") ||
                   !strcmp(p, "--encrypted")) {
            start_encrypted = true;
        } else if (!strcmp(p, "-keylist")) {
            show_keylist_on_startup = true;
        } else if (!strcmp(p, "--help") || !strcmp(p, "-help") ||
                   !strcmp(p, "--version") || !strcmp(p, "-version")) {
            char *bi = buildinfo("\n");
            printf("Pageant %s (PuTTY %s)\n%s\n",
                   mt_version().UTF8String, ver, bi);
            sfree(bi);
            exit(0);
        } else {
            cmdline_error("unrecognised option '%s'", p);
        }
    }
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        enable_dit();

        /* The command line is Pageant's; AppKit must not also open its
         * file names as documents. */
        [NSUserDefaults.standardUserDefaults registerDefaults:
            @{@"NSTreatUnknownArgumentsAsOpen": @"NO"}];

        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        parse_command_line(argc, argv);

        sk_init();
        /* A write to a client that has gone away must not kill us. */
        block_signal(SIGPIPE, true);
        mactty_eventloop_setup();

        /* Quit properly on SIGTERM/SIGINT, so that the socket link is
         * removed (the socket itself is also removed by the clean-up
         * process platform_make_agent_socket starts). */
        static dispatch_source_t sigsrc[2];
        int sigs[2] = { SIGTERM, SIGINT };
        for (int i = 0; i < 2; i++) {
            signal(sigs[i], SIG_IGN);
            sigsrc[i] = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,
                                               sigs[i], 0,
                                               dispatch_get_main_queue());
            dispatch_source_set_event_handler(sigsrc[i], ^{
                [NSApp terminate:nil];
            });
            dispatch_resume(sigsrc[i]);
        }

        MTPageantApp *delegate = [MTPageantApp new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
