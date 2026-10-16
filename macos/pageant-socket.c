/*
 * pageant-socket.c: where Pageant publishes its agent socket, and how
 * MacTTY finds it.
 *
 * Pageant listens on a socket in a private directory under /tmp, made
 * by PuTTY's own platform_make_agent_socket() exactly as Unix Pageant
 * does, and keeps a symbolic link to it at a fixed place in the PuTTY
 * configuration directory, as Unix Pageant's --symlink option does.
 * The fixed name survives Pageant restarts, so it is what MacTTY looks
 * for and what the user gives OpenSSH as SSH_AUTH_SOCK or
 * IdentityAgent.
 */

#include <errno.h>
#include <pwd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include "putty.h"
#include "mactty.h"

char *mactty_pageant_link_path(void)
{
    /* The configuration directory as unix/storage.c sees it by
     * default: $PUTTYDIR, else ~/.putty. */
    const char *dir = getenv("PUTTYDIR");
    if (dir && *dir)
        return dupcat(dir, "/pageant.sock");

    const char *home = getenv("HOME");
    if (!home || !*home) {
        struct passwd *pw = getpwuid(getuid());
        home = (pw && pw->pw_dir) ? pw->pw_dir : "";
    }
    return dupcat(home, "/.putty/pageant.sock");
}

bool mactty_agent_socket_alive(const char *path)
{
    struct sockaddr_un addr;
    if (strlen(path) >= sizeof(addr.sun_path))
        return false;

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0)
        return false;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strcpy(addr.sun_path, path);
    bool alive = connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0;
    close(fd);
    return alive;
}

char *mactty_pageant_socket(void)
{
    char *link = mactty_pageant_link_path();
    if (mactty_agent_socket_alive(link))
        return link;

    /* A link too long for sun_path can still be followed by hand. */
    char target[1024];
    ssize_t n = readlink(link, target, sizeof(target) - 1);
    sfree(link);
    if (n > 0) {
        target[n] = '\0';
        if (mactty_agent_socket_alive(target))
            return dupstr(target);
    }
    return NULL;
}

void mactty_select_agent(void)
{
    /* What we were started with: launchd's ssh-agent, normally. */
    static bool saved;
    static char *inherited;
    if (!saved) {
        const char *env = getenv("SSH_AUTH_SOCK");
        inherited = (env && *env) ? dupstr(env) : NULL;
        saved = true;
    }

    char *pageant = mactty_pageant_socket();
    if (pageant)
        setenv("SSH_AUTH_SOCK", pageant, 1);
    else if (inherited)
        setenv("SSH_AUTH_SOCK", inherited, 1);
    else
        unsetenv("SSH_AUTH_SOCK");
    sfree(pageant);
}
