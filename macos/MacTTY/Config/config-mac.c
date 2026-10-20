/*
 * config-mac.c: the Mac-specific parts of the configuration box.
 *
 * This is the counterpart of windows/config.c. The layout follows
 * Windows PuTTY panel for panel; options that only make sense on
 * Windows are left out or mapped to their Mac equivalent (Alt becomes
 * Option, the taskbar becomes the Dock).
 */

#include <assert.h>
#include <stdlib.h>
#include <sys/stat.h>

#include "putty.h"
#include "dialog.h"
#include "storage.h"
#include "Config/config-mac.h"
#include "Platform/platform-mac.h"
#include "Session/recent-sessions.h"
#include "App/alerts.h"

/* Move the last control of 's' so that it directly follows the
 * checkbox controlling 'conf_key', as windows/config.c does. */
static void move_after_checkbox(struct controlset *s, int conf_key)
{
    for (size_t i = 0; i < s->ncontrols; i++) {
        dlgcontrol *c = s->ctrls[i];
        if (c->type == CTRL_CHECKBOX && c->context.i == conf_key) {
            if (i < s->ncontrols-2) {
                c = s->ctrls[s->ncontrols-1];
                memmove(s->ctrls+i+2, s->ctrls+i+1,
                        (s->ncontrols-i-2)*sizeof(dlgcontrol *));
                s->ctrls[i+1] = c;
            }
            break;
        }
    }
}

/*
 * The host name and port boxes on the Session panel get drop-down
 * lists: for a serial line, the serial ports that are plugged in and
 * the usual speeds; otherwise the hosts connected to recently. The
 * boxes keep config.c's own handlers, which pick their label and text
 * by protocol; these wrappers only add the lists. A list item may be
 * "value\tdescription": the box takes the value.
 */
static handler_fn host_handler_orig, port_handler_orig;

static void host_list_handler(dlgcontrol *ctrl, dlgparam *dlg,
                              void *data, int event)
{
    Conf *conf = (Conf *)data;
    host_handler_orig(ctrl, dlg, data, event);
    if (event != EVENT_REFRESH)
        return;

    dlg_update_start(ctrl, dlg);
    dlg_listbox_clear(ctrl, dlg);
    if (conf_get_int(conf, CONF_protocol) == PROT_SERIAL) {
        char **lines = mactty_serial_lines();
        for (char **p = lines; *p; p++) {
            char *desc = mactty_serial_line_description(*p);
            char *item = desc ? dupprintf("%s\t%s", *p, desc) : dupstr(*p);
            dlg_listbox_add(ctrl, dlg, item);
            sfree(item);
            sfree(desc);
        }
        mactty_free_string_array(lines);
    } else {
        char **hosts = mactty_recent_hosts();
        for (char **p = hosts; *p; p++)
            dlg_listbox_add(ctrl, dlg, *p);
        mactty_free_string_array(hosts);
    }
    dlg_update_done(ctrl, dlg);
}

static void port_list_handler(dlgcontrol *ctrl, dlgparam *dlg,
                              void *data, int event)
{
    static const char *const speeds[] = {
        "9600", "19200", "38400", "57600", "115200", "230400", "460800",
        "921600",
    };
    Conf *conf = (Conf *)data;
    port_handler_orig(ctrl, dlg, data, event);
    if (event != EVENT_REFRESH)
        return;

    dlg_update_start(ctrl, dlg);
    dlg_listbox_clear(ctrl, dlg);
    if (conf_get_int(conf, CONF_protocol) == PROT_SERIAL)
        for (size_t i = 0; i < lenof(speeds); i++)
            dlg_listbox_add(ctrl, dlg, speeds[i]);
    dlg_update_done(ctrl, dlg);
}

bool mac_config_serial_line_added(Conf *conf, const char *path)
{
    const char *line = conf_get_str(conf, CONF_serline);
    struct stat st;
    if (*line && stat(line, &st) == 0)
        return false;               /* the configured line is plugged in */
    conf_set_str(conf, CONF_serline, path);
    return true;
}

void mac_setup_config_box(struct controlbox *b, bool midsession,
                          int protocol)
{
    const struct BackendVtable *backvt;
    bool resize_forbidden = false;
    struct controlset *s;
    dlgcontrol *c;

    if (!midsession) {
        /* The About button sits in the bottom-left corner. */
        s = ctrl_getset(b, "", "", "");
        c = ctrl_pushbutton(s, "About", 'a', HELPCTX(no_help),
                            mactty_about_handler, P(NULL));
        c->column = 0;
    }

    s = ctrl_getset(b, "Window", "scrollback",
                    "Control the scrollback in the window");
    ctrl_checkbox(s, "Display scrollbar in full screen mode", 'i',
                  HELPCTX(window_scrollback),
                  conf_checkbox_handler,
                  I(CONF_scrollbar_in_fullscreen));
    move_after_checkbox(s, CONF_scrollbar);

    /*
     * Option and Command take the place of Windows's Alt and AltGr.
     */
    s = ctrl_getset(b, "Terminal/Keyboard", "meta",
                    "Choose the Meta key:");
    ctrl_checkbox(s, "Option key acts as Meta", 'p',
                  HELPCTX(no_help),
                  conf_checkbox_handler, I(CONF_osx_option_meta));
    ctrl_checkbox(s, "Command key acts as Meta", 'm',
                  HELPCTX(no_help),
                  conf_checkbox_handler, I(CONF_osx_command_meta));

    /*
     * A sound file can be played as the bell, and the Dock icon can
     * bounce where Windows flashes the taskbar.
     */
    s = ctrl_getset(b, "Terminal/Bell", "style", "Set the style of bell");
    for (size_t i = 0; i < s->ncontrols; i++) {
        c = s->ctrls[i];
        if (c->type == CTRL_RADIO && c->context.i == CONF_beep) {
            assert(c->handler == conf_radiobutton_handler);
            c->radio.nbuttons += 1;
            c->radio.buttons =
                sresize(c->radio.buttons, c->radio.nbuttons, char *);
            c->radio.buttons[c->radio.nbuttons-1] =
                dupstr("Play a custom sound file");
            c->radio.buttondata =
                sresize(c->radio.buttondata, c->radio.nbuttons, intorptr);
            c->radio.buttondata[c->radio.nbuttons-1] = I(BELL_WAVEFILE);
            if (c->radio.shortcuts) {
                c->radio.shortcuts =
                    sresize(c->radio.shortcuts, c->radio.nbuttons, char);
                c->radio.shortcuts[c->radio.nbuttons-1] = NO_SHORTCUT;
            }
            break;
        }
    }
    ctrl_filesel(s, "Custom sound file to play as a bell:", NO_SHORTCUT,
                 FILTER_SOUND_FILES, false, "Select bell sound file",
                 HELPCTX(bell_style),
                 conf_filesel_handler, I(CONF_bell_wavefile));
    ctrl_radiobuttons(s, "Dock icon indication on bell:", 'i', 3,
                      HELPCTX(bell_taskbar),
                      conf_radiobutton_handler,
                      I(CONF_beep_ind),
                      "Disabled", I(B_IND_DISABLED),
                      "Bounce once", I(B_IND_FLASH),
                      "Keep bouncing", I(B_IND_STEADY));

    s = ctrl_getset(b, "Window/Appearance", "font", "Font settings");
    ctrl_radiobuttons(s, "Font quality:", 'q', 2,
                      HELPCTX(appearance_font),
                      conf_radiobutton_handler,
                      I(CONF_font_quality),
                      "Antialiased", I(FQ_ANTIALIASED),
                      "Non-Antialiased", I(FQ_NONANTIALIASED),
                      "Default", I(FQ_DEFAULT));

    /*
     * Many Mac applications are started without a UTF-8 locale, so
     * offer the same override as the GTK front end.
     */
    s = ctrl_getset(b, "Window/Translation", "trans",
                    "Character set translation on received data");
    ctrl_checkbox(s, "Override with UTF-8 if locale says so", 'l',
                  HELPCTX(translation_utf8_override),
                  conf_checkbox_handler,
                  I(CONF_utf8_override));

    s = ctrl_getset(b, "Window/Selection/Copy", "format",
                    "Formatting of copied characters");
    ctrl_checkbox(s, "Copy to clipboard in RTF as well as plain text", 'f',
                  HELPCTX(copy_rtf),
                  conf_checkbox_handler, I(CONF_rtf_paste));

    /* Same three mouse models as Windows PuTTY; the first one brings up
     * the session menu on the right button. */
    s = ctrl_getset(b, "Window/Selection", "mouse",
                    "Control use of mouse");
    ctrl_radiobuttons(s, "Action of mouse buttons:", 'm', 1,
                      HELPCTX(selection_buttons),
                      conf_radiobutton_handler,
                      I(CONF_mouse_is_xterm),
                      "macOS (Middle extends, Right brings up menu)", I(2),
                      "Compromise (Middle extends, Right pastes)", I(0),
                      "xterm (Right extends, Middle pastes)", I(1));
    /* This belongs at the top of its box. */
    c = s->ctrls[s->ncontrols-1];
    memmove(s->ctrls+1, s->ctrls, (s->ncontrols-1)*sizeof(dlgcontrol *));
    s->ctrls[0] = c;

    /* System colours follow the macOS appearance (light or dark). */
    s = ctrl_getset(b, "Window/Colours", "general",
                    "General options for colour usage");
    ctrl_checkbox(s, "Use system colours", 's',
                  HELPCTX(colours_system),
                  conf_checkbox_handler, I(CONF_system_colour));

    backvt = backend_vt_from_proto(protocol);
    if (backvt)
        resize_forbidden = (backvt->flags & BACKEND_RESIZE_FORBIDDEN);
    if (!midsession || !resize_forbidden) {
        s = ctrl_getset(b, "Window", "size", "Set the size of the window");
        ctrl_radiobuttons(s, "When window is resized:", 'z', 1,
                          HELPCTX(window_resize),
                          conf_radiobutton_handler,
                          I(CONF_resize_action),
                          "Change the number of rows and columns",
                          I(RESIZE_TERM),
                          "Change the size of the font", I(RESIZE_FONT),
                          "Change font size only when maximised",
                          I(RESIZE_EITHER),
                          "Forbid resizing completely", I(RESIZE_DISABLED));
    }

    s = ctrl_getset(b, "Window/Behaviour", "main", NULL);
    ctrl_checkbox(s, "Window closes on Command-W", '4',
                  HELPCTX(behaviour_altf4),
                  conf_checkbox_handler, I(CONF_alt_f4));
    ctrl_checkbox(s, "Ensure window is always on top", 'e',
                  HELPCTX(behaviour_alwaysontop),
                  conf_checkbox_handler, I(CONF_alwaysontop));
    ctrl_checkbox(s, "Full screen on Option-Return", 'f',
                  HELPCTX(behaviour_altenter),
                  conf_checkbox_handler,
                  I(CONF_fullscreenonaltenter));

    /*
     * Cancel before Open (or Apply): macOS puts the default button
     * rightmost.
     */
    s = ctrl_getset(b, "", "", "");
    for (size_t i = 0; i < s->ncontrols; i++) {
        c = s->ctrls[i];
        if (c->type == CTRL_BUTTON && c->button.isdefault)
            c->column = 4;
        else if (c->type == CTRL_BUTTON && c->button.iscancel)
            c->column = 3;
    }

    if (!midsession) {
        int nedit = 0;
        s = ctrl_getset(b, "Session", "hostport", NULL);
        for (size_t i = 0; i < s->ncontrols && nedit < 2; i++) {
            c = s->ctrls[i];
            if (c->type != CTRL_EDITBOX)
                continue;
            c->editbox.has_list = true;
            if (nedit++ == 0) {
                host_handler_orig = c->handler;
                c->handler = host_list_handler;
            } else {
                port_handler_orig = c->handler;
                c->handler = port_list_handler;
            }
        }
    }
}
