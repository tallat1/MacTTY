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
    char *name = mactty_config_box_saved_name();
    if (result > 0) {
        /* Remember the session by its saved name if it was loaded from
         * one (and still goes to the same place). */
        NSString *saved = mactty_saved_session_matches(name, conf) ?
            @(name) : nil;
        [MTSession openSessionWithConf:conf savedSession:saved];
    } else {
        conf_free(conf);
    }
    sfree(name);
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
    NSMenu *savedSessionsMenu, *recentMenu;
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
        [MTSession openSessionWithConf:conf savedSession:name];
    else
        open_config_box(conf);
}

- (IBAction)openRecentSession:(NSMenuItem *)sender
{
    NSDictionary *e = sender.representedObject;
    Conf *conf = mactty_conf_for_recent(e);
    if (conf_launchable(conf))
        [MTSession openSessionWithConf:conf savedSession:e[@"saved"]];
    else
        open_config_box(conf);
}

- (IBAction)clearRecentSessions:(id)sender
{
    mactty_clear_recent_sessions();
}

/* The recent sessions, most recent first, as menu items. */
- (NSArray<NSMenuItem *> *)recentSessionItems
{
    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *e in mactty_recent_sessions()) {
        NSMenuItem *it = [[NSMenuItem alloc]
            initWithTitle:mactty_recent_title(e)
                   action:@selector(openRecentSession:) keyEquivalent:@""];
        it.target = self;
        it.representedObject = e;
        NSString *detail = mactty_recent_detail(e);
        if (@available(macOS 14.4, *))
            it.subtitle = detail;
        else
            it.toolTip = detail;
        [items addObject:it];
    }
    return items;
}

static NSMenuItem *section_header(NSString *title)
{
    if (@available(macOS 14.0, *))
        return [NSMenuItem sectionHeaderWithTitle:title];
    NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:title action:NULL
                                         keyEquivalent:@""];
    it.enabled = NO;
    return it;
}

/* The Dock menu: recent and saved sessions, as Windows PuTTY's jump
 * list has them, and the companion tools. */
- (NSMenu *)applicationDockMenu:(NSApplication *)sender
{
    NSMenu *m = [[NSMenu alloc] initWithTitle:@""];
    NSArray *recent = [self recentSessionItems];
    if (recent.count) {
        [m addItem:section_header(@"Recent Sessions")];
        for (NSMenuItem *it in recent)
            [m addItem:it];
        [m addItem:[NSMenuItem separatorItem]];
    }
    NSMenu *saved = mactty_saved_sessions_menu();
    if (saved.numberOfItems && saved.itemArray.firstObject.action) {
        [m addItem:section_header(@"Saved Sessions")];
        for (NSMenuItem *it in [saved.itemArray copy]) {
            [saved removeItem:it];
            [m addItem:it];
        }
        [m addItem:[NSMenuItem separatorItem]];
    }
    [m addItemWithTitle:@"New Session..." action:@selector(newSession:)
          keyEquivalent:@""].target = self;
    [m addItemWithTitle:@"Pageant" action:@selector(openPageant:)
          keyEquivalent:@""].target = self;
    [m addItemWithTitle:@"MacTTYgen" action:@selector(openKeyGenerator:)
          keyEquivalent:@""].target = self;
    return m;
}

- (IBAction)showAbout:(id)sender
{
    mac_about_box();
}

/*
 * The companion tools, PuTTYgen (here MacTTYgen) and Pageant. They are
 * separate applications, as on Windows, kept inside MacTTY.app in
 * Contents/Applications (see targets.cmake).
 */
- (void)openTool:(NSString *)name
{
    NSURL *url = [NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:
        [NSString stringWithFormat:@"Contents/Applications/%@.app", name]];
    NSWorkspaceOpenConfiguration *cfg =
        [NSWorkspaceOpenConfiguration configuration];
    const char *bg = getenv("MACTTY_BACKGROUND");
    cfg.activates = !(bg && *bg && *bg != '0');
    /* Same configuration directory, agent and test settings as ours. */
    cfg.environment = NSProcessInfo.processInfo.environment;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:url configuration:cfg
                                    completionHandler:
        ^(NSRunningApplication *app, NSError *err) {
        if (!err)
            return;
        dispatch_async(dispatch_get_main_queue(), ^{
            char *title = dupcat(appname, " Error");
            char *msg = dupprintf("Unable to start %s:\n%s", name.UTF8String,
                                  err.localizedDescription.UTF8String);
            mactty_message_box(NULL, title, msg);
            sfree(title);
            sfree(msg);
        });
    }];
}

- (IBAction)openKeyGenerator:(id)sender
{
    [self openTool:@"MacTTYgen"];
}

- (IBAction)openPageant:(id)sender
{
    [self openTool:@"Pageant"];
}

/* Pageant's "New Session" and "Saved Sessions" (see Pageant.m). */
- (void)openSessionRequest:(NSNotification *)n
{
    NSNumber *pid = n.userInfo[@"pid"];
    if (![pid isKindOfClass:NSNumber.class] || pid.intValue != getpid())
        return;
    NSString *name = n.userInfo[@"session"];
    if ([name isKindOfClass:NSString.class]) {
        NSMenuItem *it = [[NSMenuItem alloc] init];
        it.representedObject = name;
        [self openSavedSession:it];
    } else {
        [self newSession:nil];
    }
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
    add_item(appMenu, @"MacTTYgen Key Generator",
             @selector(openKeyGenerator:), nil, 0).target = self;
    add_item(appMenu, @"Pageant SSH Agent",
             @selector(openPageant:), nil, 0).target = self;
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
    recentMenu = [[NSMenu alloc] initWithTitle:@"Open Recent"];
    recentMenu.delegate = self;
    [sess addItemWithTitle:@"Open Recent" action:NULL keyEquivalent:@""]
        .submenu = recentMenu;
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
    if (menu == recentMenu) {
        [menu removeAllItems];
        NSArray *items = [self recentSessionItems];
        for (NSMenuItem *it in items)
            [menu addItem:it];
        if (!items.count) {
            NSMenuItem *it = [menu addItemWithTitle:@"(No recent sessions)"
                                             action:NULL keyEquivalent:@""];
            it.enabled = NO;
        } else {
            [menu addItem:[NSMenuItem separatorItem]];
            [menu addItemWithTitle:@"Clear Menu"
                            action:@selector(clearRecentSessions:)
                     keyEquivalent:@""].target = self;
        }
        return;
    }
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
    [NSDistributedNotificationCenter.defaultCenter
        addObserver:self selector:@selector(openSessionRequest:)
               name:@MACTTY_OPEN_SESSION_NOTIFICATION object:nil
 suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];

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
