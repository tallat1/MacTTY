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
#include "mactty.h"

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

char **mactty_serial_lines(void)
{
    size_t n = 0, size = 0;
    char **lines = NULL;
    DIR *dir = opendir("/dev");
    struct dirent *de;

    while (dir && (de = readdir(dir)) != NULL) {
        if (strncmp(de->d_name, "cu.", 3) ||
            strstr(de->d_name, "Bluetooth-Incoming-Port") ||
            strstr(de->d_name, "debug-console"))
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
