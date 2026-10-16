/*
 * AppDelegate.h: application start-up, the menu bar, and launching
 * sessions (new, saved, from the command line).
 */

#import <Cocoa/Cocoa.h>

@interface MTAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
- (IBAction)newSession:(id)sender;
- (IBAction)showAbout:(id)sender;
@end

/* A fresh "Saved Sessions" submenu (built when shown). */
NSMenu *mactty_saved_sessions_menu(void);
