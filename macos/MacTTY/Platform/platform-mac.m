/*
 * platform-mac.m: small platform hooks the PuTTY core expects from a
 * GUI front end (the counterparts of the bits of unix/putty.c,
 * unix/window.c and unix/main-gtk-*.c that are not about windows).
 */

#import <Cocoa/Cocoa.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/serial/IOSerialKeys.h>
#include <dirent.h>

#include "putty.h"
#include "Platform/platform-mac.h"
#include "App/alerts.h"

const bool share_can_be_downstream = true;
const bool share_can_be_upstream = true;
const bool buildinfo_gtk_relevant = true;
const bool use_event_log = true, new_session = true, saved_sessions = true;
const bool dup_check_launchable = true;

const unsigned cmdline_tooltype =
    TOOLTYPE_HOST_ARG |
    TOOLTYPE_PORT_ARG |
    TOOLTYPE_NO_VERBOSE_OPTION;

char *buildinfo_gtk_version(void)
{
    return NULL;
}

/* ----------------------------------------------------------------------
 * Defaults which differ by platform. These follow Windows PuTTY, so a
 * fresh MacTTY behaves like a fresh PuTTY.
 */

FontSpec *platform_default_fontspec(const char *name)
{
    if (!strcmp(name, "Font"))
        return fontspec_new("Menlo-Regular 13");
    else
        return fontspec_new_default();
}

Filename *platform_default_filename(const char *name)
{
    if (!strcmp(name, "LogFileName"))
        return filename_from_str("putty.log");
    else
        return filename_from_str("");
}

char *platform_default_s(const char *name)
{
    if (!strcmp(name, "SerialLine")) {
        char **lines = mactty_serial_lines();
        char *ret = dupstr(lines[0] ? lines[0] : "/dev/cu.usbserial");
        mactty_free_string_array(lines);
        return ret;
    }
    return NULL;
}

bool platform_default_b(const char *name, bool def)
{
    return def;
}

int platform_default_i(const char *name, int def)
{
    return def;
}

/* ----------------------------------------------------------------------
 * Serial lines. The call-out devices (/dev/cu.*) are the ones to use
 * for outgoing connections; the Bluetooth and debug pseudo-ports that
 * every Mac has are of no interest.
 */

static int compare_strings(const void *a, const void *b)
{
    return strcmp(*(char *const *)a, *(char *const *)b);
}

/* Whether a /dev entry (or a path to one) is a serial line worth
 * listing. */
static bool interesting_serial_line(const char *name)
{
    const char *base = strrchr(name, '/');
    base = base ? base + 1 : name;
    return !strncmp(base, "cu.", 3) &&
        !strstr(base, "Bluetooth-Incoming-Port") &&
        !strstr(base, "debug-console");
}

char **mactty_serial_lines(void)
{
    size_t n = 0, size = 0;
    char **lines = NULL;
    DIR *dir = opendir("/dev");
    struct dirent *de;

    while (dir && (de = readdir(dir)) != NULL) {
        if (!interesting_serial_line(de->d_name))
            continue;
        sgrowarrayn(lines, size, n, 2);
        lines[n++] = dupcat("/dev/", de->d_name);
    }
    if (dir)
        closedir(dir);

    sgrowarrayn(lines, size, n, 1);
    lines[n] = NULL;
    qsort(lines, n, sizeof(char *), compare_strings);
    return lines;
}

/* The USB device a serial line belongs to, as IOKit names it. */
static NSString *usb_property(io_object_t service, CFStringRef key)
{
    CFTypeRef v = IORegistryEntrySearchCFProperty(
        service, kIOServicePlane, key, kCFAllocatorDefault,
        kIORegistryIterateRecursively | kIORegistryIterateParents);
    if (!v)
        return nil;
    if (CFGetTypeID(v) != CFStringGetTypeID()) {
        CFRelease(v);
        return nil;
    }
    NSString *s = CFBridgingRelease(v);
    s = [s stringByTrimmingCharactersInSet:
             NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return s.length ? s : nil;
}

char *mactty_serial_line_description(const char *path)
{
    io_iterator_t it;
    if (IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching(kIOSerialBSDServiceValue),
            &it) != KERN_SUCCESS)
        return NULL;

    NSString *want = [NSString stringWithUTF8String:path];
    char *ret = NULL;
    io_object_t service;
    while (!ret && (service = IOIteratorNext(it))) {
        CFTypeRef callout = IORegistryEntryCreateCFProperty(
            service, CFSTR(kIOCalloutDeviceKey), kCFAllocatorDefault, 0);
        if (callout && CFGetTypeID(callout) == CFStringGetTypeID() &&
            [(__bridge NSString *)callout isEqualToString:want]) {
            NSString *product = usb_property(service,
                                             CFSTR("USB Product Name"));
            NSString *vendor = usb_property(service,
                                            CFSTR("USB Vendor Name"));
            NSString *desc = product && vendor ?
                [NSString stringWithFormat:@"%@ · %@", product, vendor] :
                (product ?: vendor);
            if (desc)
                ret = dupstr(desc.UTF8String);
        }
        if (callout)
            CFRelease(callout);
        IOObjectRelease(service);
    }
    IOObjectRelease(it);
    return ret;
}

/*
 * Serial lines coming and going. IOKit reports each serial port's
 * service as it appears and as it is terminated; the first batch, the
 * ports already there, is only drained.
 */

NSString *const MTSerialLinesDidChangeNotification =
    @"MTSerialLinesDidChangeNotification";

static IONotificationPortRef serial_notify_port;
static bool serial_watch_armed;

static NSArray<NSString *> *serial_lines_of(io_iterator_t it)
{
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    io_object_t service;
    while ((service = IOIteratorNext(it))) {
        CFTypeRef callout = IORegistryEntryCreateCFProperty(
            service, CFSTR(kIOCalloutDeviceKey), kCFAllocatorDefault, 0);
        if (callout && CFGetTypeID(callout) == CFStringGetTypeID() &&
            interesting_serial_line(
                [(__bridge NSString *)callout UTF8String]))
            [paths addObject:(__bridge NSString *)callout];
        if (callout)
            CFRelease(callout);
        IOObjectRelease(service);
    }
    return paths;
}

static void serial_lines_changed(void *added, io_iterator_t it)
{
    NSArray<NSString *> *paths = serial_lines_of(it);
    if (!serial_watch_armed || !paths.count)
        return;
    NSDictionary *info = added ?
        @{@"added": paths, @"removed": @[]} :
        @{@"added": @[], @"removed": paths};
    /* The /dev nodes of a new port may lag its service a little. */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter
            postNotificationName:MTSerialLinesDidChangeNotification
                          object:nil userInfo:info];
    });
}

void mactty_watch_serial_lines(void)
{
    io_iterator_t it;

    if (serial_notify_port)
        return;
    serial_notify_port = IONotificationPortCreate(kIOMainPortDefault);
    if (!serial_notify_port)
        return;
    CFRunLoopAddSource(CFRunLoopGetMain(),
                       IONotificationPortGetRunLoopSource(serial_notify_port),
                       kCFRunLoopCommonModes);
    /* Each call consumes its matching dictionary. */
    if (IOServiceAddMatchingNotification(
            serial_notify_port, kIOFirstMatchNotification,
            IOServiceMatching(kIOSerialBSDServiceValue),
            serial_lines_changed, (void *)1, &it) == KERN_SUCCESS)
        serial_lines_changed((void *)1, it);
    if (IOServiceAddMatchingNotification(
            serial_notify_port, kIOTerminatedNotification,
            IOServiceMatching(kIOSerialBSDServiceValue),
            serial_lines_changed, NULL, &it) == KERN_SUCCESS)
        serial_lines_changed(NULL, it);
    serial_watch_armed = true;
}

void mactty_free_string_array(char **array)
{
    for (char **p = array; *p; p++)
        sfree(*p);
    sfree(array);
}

/* ----------------------------------------------------------------------
 * X11. There is no X server in a Cocoa application; XQuartz, if
 * installed, publishes its display through $DISPLAY.
 */

char *platform_get_x_display(void)
{
    const char *display = getenv("DISPLAY");
    return display ? dupstr(display) : NULL;
}

char *x_get_default(const char *key)
{
    return NULL;
}

/* ----------------------------------------------------------------------
 * Error reporting.
 */

void nonfatal(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    char *msg = dupvprintf(fmt, ap);
    va_end(ap);
    char *title = dupcat(appname, " Error");
    mactty_message_box(NULL, title, msg);
    sfree(title);
    sfree(msg);
}

void modalfatalbox(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    char *msg = dupvprintf(fmt, ap);
    va_end(ap);

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleCritical;
    alert.messageText = [NSString stringWithFormat:@"%s Fatal Error", appname];
    alert.informativeText = [NSString stringWithUTF8String:msg];
    [alert runModal];
    sfree(msg);
    cleanup_exit(1);
}

void old_keyfile_warning(void)
{
    /* This should never happen on Unix. We hope. */
}

void window_setup_error(const char *errmsg)
{
    mactty_message_box(NULL, "Error creating session window", errmsg);
}

void cleanup_exit(int code)
{
    sk_cleanup();
    random_save_seed();
    exit(code);
}

const struct BackendVtable *select_backend(Conf *conf)
{
    const struct BackendVtable *vt =
        backend_vt_from_proto(conf_get_int(conf, CONF_protocol));
    assert(vt != NULL);
    return vt;
}
