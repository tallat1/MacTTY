/*
 * main.m: MacTTY entry point.
 */

#import <Cocoa/Cocoa.h>
#include <locale.h>
#include <langinfo.h>
#include <signal.h>

#import "AppDelegate.h"
#include "putty.h"
#include "ssh.h"
#include "mactty.h"

void mactty_set_args(int argc, char **argv);

int main(int argc, char **argv)
{
    @autoreleasepool {
        /*
         * PuTTY takes the default line character set from the locale.
         * Applications started from the Finder often get the "C"
         * locale, so insist on UTF-8, as every Mac terminal does.
         */
        setlocale(LC_CTYPE, "");
        const char *codeset = nl_langinfo(CODESET);
        if (!codeset || strcmp(codeset, "UTF-8"))
            setlocale(LC_CTYPE, "UTF-8");

        enable_dit();

        /* What setup() does in unix/putty.c. */
        sk_init();
        settings_set_default_protocol(be_default_protocol);
        {
            const struct BackendVtable *vt =
                backend_vt_from_proto(be_default_protocol);
            settings_set_default_port(0); /* illegal */
            if (vt)
                settings_set_default_port(vt->default_port);
        }

        /* A failed write to a closed connection must not kill us. */
        block_signal(SIGPIPE, true);

        mactty_eventloop_setup();
        mactty_set_args(argc, argv);

        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        MTAppDelegate *delegate = [MTAppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
