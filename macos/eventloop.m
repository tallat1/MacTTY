/*
 * eventloop.m: integrates PuTTY's event model with the Cocoa run loop.
 *
 * This is the counterpart of unix/gtk-common.c. Everything is attached
 * to the main run loop in kCFRunLoopCommonModes, so that network
 * traffic and timers keep flowing while a menu is tracked, a window is
 * resized or a sheet is shown.
 */

#import <Foundation/Foundation.h>
#include <poll.h>

#include "putty.h"
#include "mactty.h"

/* ----------------------------------------------------------------------
 * File descriptors.
 *
 * CFFileDescriptor rather than a dispatch source: invalidating it is
 * synchronous, so PuTTY may close() the fd straight after uxsel_del(),
 * which is exactly what the network code does.
 */

struct uxsel_id {
    CFFileDescriptorRef cffd;
    CFRunLoopSourceRef source;
    int rwx;
};

static CFOptionFlags callback_types(int rwx)
{
    CFOptionFlags types = 0;
    if (rwx & (SELECT_R | SELECT_X))
        types |= kCFFileDescriptorReadCallBack;
    if (rwx & SELECT_W)
        types |= kCFFileDescriptorWriteCallBack;
    return types;
}

static void fd_callback(CFFileDescriptorRef cffd, CFOptionFlags types,
                        void *info)
{
    uxsel_id *id = (uxsel_id *)info;
    int fd = CFFileDescriptorGetNativeDescriptor(cffd);
    int rwx = id->rwx;   /* id may be freed by the callbacks below */

    CFRetain(cffd);

    if (types & kCFFileDescriptorReadCallBack) {
        /*
         * kqueue does not report TCP urgent data separately, so look
         * for it ourselves; it must be processed before the ordinary
         * data, or we would go straight past the urgent marker.
         */
        if (rwx & SELECT_X) {
            struct pollfd pfd = { .fd = fd, .events = POLLPRI };
            if (poll(&pfd, 1, 0) > 0 && (pfd.revents & POLLPRI))
                select_result(fd, SELECT_X);
        }
        if ((rwx & SELECT_R) && CFFileDescriptorIsValid(cffd))
            select_result(fd, SELECT_R);
    }
    if ((types & kCFFileDescriptorWriteCallBack) &&
        CFFileDescriptorIsValid(cffd))
        select_result(fd, SELECT_W);

    /* CFFileDescriptor callbacks are one-shot. */
    if (CFFileDescriptorIsValid(cffd))
        CFFileDescriptorEnableCallBacks(cffd, callback_types(rwx));
    CFRelease(cffd);

    run_toplevel_callbacks();
}

uxsel_id *uxsel_input_add(int fd, int rwx)
{
    uxsel_id *id = snew(uxsel_id);
    CFFileDescriptorContext ctx = { .info = id };

    id->rwx = rwx;
    id->cffd = CFFileDescriptorCreate(NULL, fd, false, fd_callback, &ctx);
    CFFileDescriptorEnableCallBacks(id->cffd, callback_types(rwx));
    id->source = CFFileDescriptorCreateRunLoopSource(NULL, id->cffd, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), id->source,
                       kCFRunLoopCommonModes);
    return id;
}

void uxsel_input_remove(uxsel_id *id)
{
    CFRunLoopSourceInvalidate(id->source);
    CFRelease(id->source);
    CFFileDescriptorInvalidate(id->cffd);
    CFRelease(id->cffd);
    sfree(id);
}

/* ----------------------------------------------------------------------
 * Timers. PuTTY keeps its own timer list; we only ever need one run
 * loop timer for the earliest of them.
 */

static CFRunLoopTimerRef timer;
static unsigned long timer_when;

static void set_runloop_timer(unsigned long next, long ticks);

static void timer_fired(CFRunLoopTimerRef t, void *info)
{
    unsigned long now = timer_when, next;

    CFRunLoopTimerInvalidate(timer);
    CFRelease(timer);
    timer = NULL;

    /*
     * run_timers() may call timer_change_notify(), in which case a
     * new timer is already set. Otherwise, if more timing is needed,
     * set it up ourselves.
     */
    if (run_timers(now, &next) && !timer) {
        unsigned long then = now;
        long ticks;
        now = GETTICKCOUNT();
        if (now - then > next - then)
            ticks = 0;
        else
            ticks = next - now;
        set_runloop_timer(next, ticks);
    }

    run_toplevel_callbacks();
}

static void set_runloop_timer(unsigned long next, long ticks)
{
    if (timer) {
        CFRunLoopTimerInvalidate(timer);
        CFRelease(timer);
    }
    timer_when = next;
    timer = CFRunLoopTimerCreate(
        NULL, CFAbsoluteTimeGetCurrent() + ticks / (double)TICKSPERSEC,
        0, 0, 0, timer_fired, NULL);
    CFRunLoopAddTimer(CFRunLoopGetMain(), timer, kCFRunLoopCommonModes);
}

void timer_change_notify(unsigned long next)
{
    long ticks = next - GETTICKCOUNT();
    if (ticks <= 0)
        ticks = 1;                     /* just in case */
    set_runloop_timer(next, ticks);
}

/* ----------------------------------------------------------------------
 * Toplevel callbacks: run them from the run loop, never from inside
 * whatever PuTTY code queued them.
 */

static bool callbacks_scheduled;

static void notify_toplevel_callback(void *ctx)
{
    if (callbacks_scheduled)
        return;
    callbacks_scheduled = true;
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
        callbacks_scheduled = false;
        run_toplevel_callbacks();
        if (toplevel_callback_pending())
            notify_toplevel_callback(NULL);
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

void mactty_eventloop_setup(void)
{
    uxsel_init();
    request_callback_notifications(notify_toplevel_callback, NULL);
}
