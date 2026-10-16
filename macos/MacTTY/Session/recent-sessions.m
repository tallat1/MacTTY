/*
 * recent-sessions.m: the sessions MacTTY connected to lately (the
 * counterpart of the jump list Windows PuTTY keeps), and a one-line
 * description of a saved session for the Saved Sessions list.
 *
 * Recent sessions live in the user defaults as small dictionaries: the
 * saved session they came from, if any, otherwise enough of the Conf to
 * open the same connection again (protocol, host, port, user, serial
 * line and speed).
 */

#import <Foundation/Foundation.h>

#include "putty.h"
#include "storage.h"
#import "Session/recent-sessions.h"
#include "Platform/platform-mac.h"

static NSString *const kRecentKey = @"RecentSessions";
enum { MAX_RECENT = 10 };

/* MACTTY_RECENT_SUITE names another defaults domain, so that automated
 * tests do not add to the user's own list. */
static NSUserDefaults *defaults(void)
{
    const char *suite = getenv("MACTTY_RECENT_SUITE");
    if (suite && *suite)
        return [[NSUserDefaults alloc] initWithSuiteName:@(suite)];
    return NSUserDefaults.standardUserDefaults;
}

static NSString *ns(const char *s)
{
    NSString *r = s ? [NSString stringWithUTF8String:s] : nil;
    return r ?: @"";
}

static NSString *protocol_name(int proto)
{
    const struct BackendVtable *vt = backend_vt_from_proto(proto);
    return vt ? ns(vt->displayname_tc) : @"";
}

NSArray<NSDictionary *> *mactty_recent_sessions(void)
{
    NSArray *a = [defaults() arrayForKey:kRecentKey];
    NSMutableArray *ret = [NSMutableArray array];
    for (id e in a)
        if ([e isKindOfClass:NSDictionary.class])
            [ret addObject:e];
    return ret;
}

static BOOL same_target(NSDictionary *a, NSDictionary *b)
{
    if (a[@"saved"] || b[@"saved"])
        return [a[@"saved"] isEqual:b[@"saved"]];
    for (NSString *k in @[@"proto", @"host", @"port", @"user", @"serline"])
        if (!(a[k] == b[k] || [a[k] isEqual:b[k]]))
            return NO;
    return YES;
}

void mactty_note_recent_session(Conf *conf, const char *saved_name)
{
    NSMutableDictionary *e = [NSMutableDictionary dictionary];
    int proto = conf_get_int(conf, CONF_protocol);
    e[@"proto"] = @(proto);
    if (proto == PROT_SERIAL) {
        e[@"serline"] = ns(conf_get_str(conf, CONF_serline));
        e[@"speed"] = @(conf_get_int(conf, CONF_serspeed));
    } else {
        e[@"host"] = ns(conf_get_str(conf, CONF_host));
        e[@"port"] = @(conf_get_int(conf, CONF_port));
        /* (a string that may or may not be UTF-8) */
        const char *user = conf_get_str_ambi(conf, CONF_username, NULL);
        if (user && *user)
            e[@"user"] = ns(user);
    }
    if (saved_name && *saved_name)
        e[@"saved"] = ns(saved_name);
    e[@"when"] = [NSDate date];

    NSMutableArray *list = [mactty_recent_sessions() mutableCopy];
    for (NSInteger i = list.count - 1; i >= 0; i--)
        if (same_target(list[i], e))
            [list removeObjectAtIndex:i];
    [list insertObject:e atIndex:0];
    while (list.count > MAX_RECENT)
        [list removeLastObject];
    [defaults() setObject:list forKey:kRecentKey];
}

void mactty_clear_recent_sessions(void)
{
    [defaults() removeObjectForKey:kRecentKey];
}

NSString *mactty_recent_title(NSDictionary *e)
{
    if (e[@"saved"])
        return e[@"saved"];
    int proto = [e[@"proto"] intValue];
    if (proto == PROT_SERIAL)
        return e[@"serline"] ?: @"";
    NSString *host = e[@"host"] ?: @"";
    if (e[@"user"])
        host = [NSString stringWithFormat:@"%@@%@", e[@"user"], host];
    const struct BackendVtable *vt = backend_vt_from_proto(proto);
    int port = [e[@"port"] intValue];
    if (vt && port && port != vt->default_port)
        host = [NSString stringWithFormat:@"%@:%d", host, port];
    return host;
}

NSString *mactty_recent_detail(NSDictionary *e)
{
    int proto = [e[@"proto"] intValue];
    if (proto == PROT_SERIAL)
        return [NSString stringWithFormat:@"%@ · %@", protocol_name(proto),
                e[@"speed"] ?: @""];
    return protocol_name(proto);
}

Conf *mactty_conf_for_recent(NSDictionary *e)
{
    Conf *conf = conf_new();
    if (e[@"saved"]) {
        do_defaults([e[@"saved"] UTF8String], conf);
        return conf;
    }
    do_defaults(NULL, conf);
    int proto = [e[@"proto"] intValue];
    conf_set_int(conf, CONF_protocol, proto);
    if (proto == PROT_SERIAL) {
        conf_set_str(conf, CONF_serline, [e[@"serline"] UTF8String] ?: "");
        if (e[@"speed"])
            conf_set_int(conf, CONF_serspeed, [e[@"speed"] intValue]);
    } else {
        conf_set_str(conf, CONF_host, [e[@"host"] UTF8String] ?: "");
        if (e[@"port"])
            conf_set_int(conf, CONF_port, [e[@"port"] intValue]);
        if (e[@"user"])
            conf_set_str(conf, CONF_username, [e[@"user"] UTF8String]);
    }
    return conf;
}

char **mactty_recent_hosts(void)
{
    NSMutableOrderedSet<NSString *> *hosts = [NSMutableOrderedSet orderedSet];
    for (NSDictionary *e in mactty_recent_sessions()) {
        NSString *h = e[@"host"];
        if ([e[@"proto"] intValue] != PROT_SERIAL && h.length)
            [hosts addObject:h];
    }
    char **ret = snewn(hosts.count + 1, char *);
    size_t n = 0;
    for (NSString *h in hosts)
        ret[n++] = dupstr(h.UTF8String);
    ret[n] = NULL;
    return ret;
}

/* "SSH · 192.168.1.1", "Serial · 115200": what a saved session connects
 * to, for the Saved Sessions list. NULL if there is nothing to say. */
char *mactty_saved_session_detail(const char *name)
{
    if (!name || !*name || !strcmp(name, "Default Settings"))
        return NULL;
    settings_r *sr = open_settings_r(name);
    if (!sr)
        return NULL;
    char *protoid = read_setting_s(sr, "Protocol");
    const struct BackendVtable *vt = protoid ?
        backend_vt_from_name(protoid) : NULL;
    char *ret = NULL;
    if (vt && vt->protocol == PROT_SERIAL) {
        int speed = read_setting_i(sr, "SerialSpeed", 9600);
        ret = dupprintf("%s · %d", vt->displayname_tc, speed);
    } else {
        char *host = read_setting_s(sr, "HostName");
        const char *pname = vt ? vt->displayname_tc : NULL;
        if (pname && host && *host)
            ret = dupprintf("%s · %s", pname, host);
        else if (pname)
            ret = dupstr(pname);
        else if (host && *host)
            ret = dupstr(host);
        sfree(host);
    }
    sfree(protoid);
    close_settings_r(sr);
    return ret;
}

/* Whether the saved session 'name' connects where conf does, so that a
 * session opened after loading it can be remembered by its name. */
bool mactty_saved_session_matches(const char *name, Conf *conf)
{
    if (!name || !*name || !strcmp(name, "Default Settings"))
        return false;
    Conf *saved = conf_new();
    do_defaults(name, saved);
    int proto = conf_get_int(conf, CONF_protocol);
    bool ret = conf_get_int(saved, CONF_protocol) == proto &&
        (proto == PROT_SERIAL ?
         !strcmp(conf_get_str(saved, CONF_serline),
                 conf_get_str(conf, CONF_serline)) :
         !strcmp(conf_get_str(saved, CONF_host),
                 conf_get_str(conf, CONF_host)));
    conf_free(saved);
    return ret;
}
