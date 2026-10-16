/*
 * AppDelegate.m: application start-up, the menu bar, and launching
 * sessions. The flow is PuTTY's: start with the configuration box
 * unless the command line names a host; Open starts a session window;
 * Cancel on the only window quits.
 */

#import "AppDelegate.h"
#import "Session.h"

#include "putty.h"
#include "storage.h"
#include "mactty.h"

static int saved_argc;
static char **saved_argv;

void mactty_set_args(int argc, char **argv)
{
    /* Drop the arguments macOS and Xcode add to a GUI launch. */
    saved_argv = snewn(argc + 1, char *);
    saved_argc = 0;
    for (int i = 0; i < argc; i++) {
        if (i > 0 && !strncmp(argv[i], "-psn_", 5))
            continue;
        if (i > 0 && (!strcmp(argv[i], "-NSDocumentRevisionsDebugMode") ||
                      !strcmp(argv[i], "-ApplePersistenceIgnoreState")) &&
            i + 1 < argc) {
            i++;
            continue;
        }
        saved_argv[saved_argc++] = argv[i];
    }
    saved_argv[saved_argc] = NULL;
}

void cmdline_error(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    char *msg = dupvprintf(fmt, ap);
    va_end(ap);
    fprintf(stderr, "%s: %s\n", appname, msg);
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"%s: command line error",
                         appname];
    alert.informativeText = @(msg) ?: @"";
    [alert runModal];
    sfree(msg);
    exit(1);
}

/* Command-line options: everything cmdline.c understands, plus the
 * window options of the Unix PuTTY. */
static bool do_cmdline(int argc, char **argv, bool do_everything, Conf *conf)
{
    bool err = false;
    CmdlineArgList *arglist = cmdline_arg_list_from_argv(argc, argv);
    size_t pos = 0;

    while (arglist->args[pos]) {
        CmdlineArg *arg = arglist->args[pos++];
        CmdlineArg *nextarg = arglist->args[pos];
        const char *p = cmdline_arg_to_str(arg);
        const char *val = cmdline_arg_to_str(nextarg);
        int ret = cmdline_process_param(arg, nextarg,
                                        do_everything ? 1 : -1, conf);
        if (ret == -2) {
            cmdline_error("option \"%s\" requires an argument", p);
        } else if (ret == 2) {
            pos++;
            continue;
        } else if (ret == 1) {
            continue;
        }

#define EXPECTS_ARG if (!nextarg) {                                     \
            cmdline_error("option \"%s\" requires an argument", p);     \
        } else pos++

        if (!strcmp(p, "-title")) {
            EXPECTS_ARG;
            if (do_everything)
                conf_set_str(conf, CONF_wintitle, val);
        } else if (!strcmp(p, "-log")) {
            EXPECTS_ARG;
            if (do_everything) {
                Filename *fn = cmdline_arg_to_filename(nextarg);
                conf_set_filename(conf, CONF_logfilename, fn);
                conf_set_int(conf, CONF_logtype, LGTYP_DEBUG);
                filename_free(fn);
            }
        } else if (!strcmp(p, "-sl")) {
            EXPECTS_ARG;
            if (do_everything)
                conf_set_int(conf, CONF_savelines, atoi(val));
        } else if (!strcmp(p, "-fn") || !strcmp(p, "-font")) {
            EXPECTS_ARG;
            if (do_everything) {
                FontSpec *fs = fontspec_new(val);
                conf_set_fontspec(conf, CONF_font, fs);
                fontspec_free(fs);
            }
        } else if (!strcmp(p, "-geometry")) {
            EXPECTS_ARG;
            int w, h;
            if (do_everything && sscanf(val, "%dx%d", &w, &h) == 2) {
                conf_set_int(conf, CONF_width, w);
                conf_set_int(conf, CONF_height, h);
            }
        } else if (!strcmp(p, "-help") || !strcmp(p, "--help") ||
                   !strcmp(p, "-version") || !strcmp(p, "--version")) {
            char *bi = buildinfo("\n");
            printf("%s: %s\n%s\n", appname, ver, bi);
            sfree(bi);
            exit(0);
        } else if (!strcmp(p, "-pgpfp")) {
            pgp_fingerprints();
            exit(0);
        } else if (p[0] != '-') {
            if (do_everything) {
                err = true;
                fprintf(stderr, "%s: unexpected non-option argument '%s'\n",
                        appname, p);
            }
        } else {
            err = true;
            fprintf(stderr, "%s: unrecognized option '%s'\n", appname, p);
        }
#undef EXPECTS_ARG
    }
    return err;
}

/* ---------------------------------------------------------------------- */

static void after_initial_config(void *vctx, int result)
{
    Conf *conf = (Conf *)vctx;
    if (result > 0)
        [MTSession openSessionWithConf:conf];
    else
        conf_free(conf);
}

static void open_config_box(Conf *conf)
{
    char *title = dupcat(appname, " Configuration");
    mactty_config_box(title, conf, false, 0, NULL, after_initial_config, conf);
    sfree(title);
}

NSMenu *mactty_saved_sessions_menu(void)
{
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"Saved Sessions"];
    struct sesslist sl;
    get_sesslist(&sl, true);
    /* Entry 0 is "Default Settings", which is not a session to start. */
    for (int i = 1; i < sl.nsessions; i++) {
        NSString *name = @(sl.sessions[i]);
        if (!name)
            continue;
        NSMenuItem *it = [m addItemWithTitle:name
                                      action:@selector(openSavedSession:)
                               keyEquivalent:@""];
        it.target = NSApp.delegate;
        it.representedObject = name;
    }
    if (sl.nsessions <= 1) {
        NSMenuItem *it = [m addItemWithTitle:@"(No saved sessions)"
                                      action:NULL keyEquivalent:@""];
        it.enabled = NO;
    }
    get_sesslist(&sl, false);
    return m;
}

@implementation MTAppDelegate {
    NSMenu *savedSessionsMenu;
    NSMenu *specialsMenu;
    NSMenuItem *specialsItem;
}

- (IBAction)newSession:(id)sender
{
    Conf *conf = conf_new();
    do_defaults(NULL, conf);
    open_config_box(conf);
}

- (IBAction)openSavedSession:(NSMenuItem *)sender
{
    NSString *name = sender.representedObject;
    Conf *conf = conf_new();
    do_defaults(name.UTF8String, conf);
    if (conf_launchable(conf))
        [MTSession openSessionWithConf:conf];
    else
        open_config_box(conf);
}

- (IBAction)showAbout:(id)sender
{
    mac_about_box();
}

- (IBAction)showManual:(id)sender
{
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:
        @"https://the.earth.li/~sgtatham/putty/0.85/htmldoc/"]];
}

/* ----------------------------------------------------------------------
 * Menu bar.
 */

static NSMenuItem *add_item(NSMenu *m, NSString *title, SEL action,
                            NSString *key, NSEventModifierFlags mods)
{
    NSMenuItem *it = [m addItemWithTitle:title action:action
                           keyEquivalent:key ?: @""];
    if (key)
        it.keyEquivalentModifierMask = mods;
    return it;
}

- (void)buildMainMenu
{
    NSString *app = @(appname);
    NSEventModifierFlags cmd = NSEventModifierFlagCommand;
    NSMenu *bar = [[NSMenu alloc] initWithTitle:@""];

    /* Application menu */
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:app];
    add_item(appMenu, [@"About " stringByAppendingString:app],
             @selector(showAbout:), nil, 0).target = self;
    [appMenu addItem:[NSMenuItem separatorItem]];
    NSMenu *services = [[NSMenu alloc] initWithTitle:@"Services"];
    [appMenu addItemWithTitle:@"Services" action:NULL keyEquivalent:@""]
        .submenu = services;
    NSApp.servicesMenu = services;
    [appMenu addItem:[NSMenuItem separatorItem]];
    add_item(appMenu, [@"Hide " stringByAppendingString:app],
             @selector(hide:), @"h", cmd);
    add_item(appMenu, @"Hide Others", @selector(hideOtherApplications:),
             @"h", cmd | NSEventModifierFlagOption);
    add_item(appMenu, @"Show All", @selector(unhideAllApplications:), nil, 0);
    [appMenu addItem:[NSMenuItem separatorItem]];
    add_item(appMenu, [@"Quit " stringByAppendingString:app],
             @selector(terminate:), @"q", cmd);
    [bar addItemWithTitle:app action:NULL keyEquivalent:@""].submenu = appMenu;

    /* Session menu: the session operations of PuTTY's system menu. */
    NSMenu *sess = [[NSMenu alloc] initWithTitle:@"Session"];
    add_item(sess, @"New Session...", @selector(newSession:), @"n", cmd)
        .target = self;
    add_item(sess, @"Duplicate Session", @selector(duplicateSession:),
             @"d", cmd);
    add_item(sess, @"Restart Session", @selector(restartSession:),
             @"r", cmd);
    savedSessionsMenu = [[NSMenu alloc] initWithTitle:@"Saved Sessions"];
    savedSessionsMenu.delegate = self;
    [sess addItemWithTitle:@"Saved Sessions" action:NULL keyEquivalent:@""]
        .submenu = savedSessionsMenu;
    [sess addItem:[NSMenuItem separatorItem]];
    add_item(sess, @"Change Settings...", @selector(changeSettings:),
             @",", cmd);
    [sess addItem:[NSMenuItem separatorItem]];
    add_item(sess, @"Event Log", @selector(showEventLog:), @"l", cmd);
    specialsMenu = [[NSMenu alloc] initWithTitle:@"Special Command"];
    specialsMenu.delegate = self;
    specialsItem = [sess addItemWithTitle:@"Special Command" action:NULL
                            keyEquivalent:@""];
    specialsItem.submenu = specialsMenu;
    [sess addItem:[NSMenuItem separatorItem]];
    add_item(sess, @"Close Window", @selector(performClose:), @"w", cmd);
    [bar addItemWithTitle:@"Session" action:NULL keyEquivalent:@""]
        .submenu = sess;

    /* Edit menu */
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    add_item(edit, @"Undo", @selector(undo:), @"z", cmd);
    add_item(edit, @"Redo", @selector(redo:), @"z",
             cmd | NSEventModifierFlagShift);
    [edit addItem:[NSMenuItem separatorItem]];
    add_item(edit, @"Cut", @selector(cut:), @"x", cmd);
    add_item(edit, @"Copy", @selector(copy:), @"c", cmd);
    add_item(edit, @"Paste", @selector(paste:), @"v", cmd);
    add_item(edit, @"Select All", @selector(selectAll:), @"a", cmd);
    [edit addItem:[NSMenuItem separatorItem]];
    add_item(edit, @"Copy All to Clipboard", @selector(copyAllToClipboard:),
             @"c", cmd | NSEventModifierFlagOption);
    add_item(edit, @"Clear Scrollback", @selector(clearScrollback:),
             @"k", cmd);
    add_item(edit, @"Reset Terminal", @selector(resetTerminal:),
             @"k", cmd | NSEventModifierFlagOption);
    [bar addItemWithTitle:@"Edit" action:NULL keyEquivalent:@""]
        .submenu = edit;

    /* View menu */
    NSMenu *view = [[NSMenu alloc] initWithTitle:@"View"];
    add_item(view, @"Bigger", @selector(biggerFont:), @"+", cmd);
    add_item(view, @"Smaller", @selector(smallerFont:), @"-", cmd);
    [view addItem:[NSMenuItem separatorItem]];
    add_item(view, @"Enter Full Screen", @selector(toggleFullScreen:), @"f",
             cmd | NSEventModifierFlagControl);
    [bar addItemWithTitle:@"View" action:NULL keyEquivalent:@""]
        .submenu = view;

    /* Window menu */
    NSMenu *win = [[NSMenu alloc] initWithTitle:@"Window"];
    add_item(win, @"Minimize", @selector(performMiniaturize:), @"m", cmd);
    add_item(win, @"Zoom", @selector(performZoom:), nil, 0);
    [win addItem:[NSMenuItem separatorItem]];
    add_item(win, @"Bring All to Front", @selector(arrangeInFront:), nil, 0);
    [bar addItemWithTitle:@"Window" action:NULL keyEquivalent:@""]
        .submenu = win;
    NSApp.windowsMenu = win;

    /* Help menu */
    NSMenu *help = [[NSMenu alloc] initWithTitle:@"Help"];
    add_item(help, @"PuTTY User Manual", @selector(showManual:), @"?", cmd)
        .target = self;
    [bar addItemWithTitle:@"Help" action:NULL keyEquivalent:@""]
        .submenu = help;
    NSApp.helpMenu = help;

    NSApp.mainMenu = bar;
}

- (void)menuNeedsUpdate:(NSMenu *)menu
{
    if (menu == savedSessionsMenu) {
        [menu removeAllItems];
        NSMenu *fresh = mactty_saved_sessions_menu();
        for (NSMenuItem *it in [fresh.itemArray copy]) {
            [fresh removeItem:it];
            [menu addItem:it];
        }
    } else if (menu == specialsMenu) {
        [menu removeAllItems];
        id ctl = NSApp.keyWindow.windowController;
        NSMenu *sp = [ctl isKindOfClass:MTSession.class] ?
            [(MTSession *)ctl specialsMenuCopy] : nil;
        for (NSMenuItem *it in [sp.itemArray copy]) {
            [sp removeItem:it];
            [menu addItem:it];
        }
        if (!menu.numberOfItems) {
            NSMenuItem *it = [menu addItemWithTitle:@"(None)" action:NULL
                                      keyEquivalent:@""];
            it.enabled = NO;
        }
    }
}

/* ----------------------------------------------------------------------
 * Application lifecycle.
 */

- (void)applicationDidFinishLaunching:(NSNotification *)n
{
    [self buildMainMenu];

    Conf *conf = conf_new();
    if (do_cmdline(saved_argc, saved_argv, false, conf))
        exit(1);
    do_defaults(NULL, conf);
    if (do_cmdline(saved_argc, saved_argv, true, conf))
        exit(1);
    cmdline_run_saved(conf);

    /* MACTTY_BACKGROUND=1 keeps a launch from taking the keyboard focus
     * away from whatever the user is doing (used by automated tests). */
    const char *bg = getenv("MACTTY_BACKGROUND");
    if (!bg || !*bg || *bg == '0')
        [NSApp activateIgnoringOtherApps:YES];
    if (cmdline_host_ok(conf))
        [MTSession openSessionWithConf:conf];
    else
        open_config_box(conf);
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app
{
    /* As with PuTTY, closing the last window (or cancelling the
     * configuration box) ends the program. */
    return YES;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app
{
    NSUInteger live = 0;
    for (MTSession *s in [MTSession sessions])
        if (s->backend && conf_get_bool(s->conf, CONF_warn_on_close))
            live++;
    if (live == 0)
        return NSTerminateNow;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"%s Exit Confirmation",
                         appname];
    alert.informativeText = live == 1 ?
        @"A session is still open. Are you sure you want to quit?" :
        [NSString stringWithFormat:@"%lu sessions are still open. Are you "
         "sure you want to quit?", (unsigned long)live];
    [alert addButtonWithTitle:@"Quit"];
    [alert addButtonWithTitle:@"Cancel"];
    return [alert runModal] == NSAlertFirstButtonReturn ? NSTerminateNow
                                                        : NSTerminateCancel;
}

- (void)applicationWillTerminate:(NSNotification *)n
{
    random_save_seed();
}

@end
