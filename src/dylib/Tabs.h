// Helpers for Tidy tabs, partly ported from daypatch (see Tabs.m).
#import <AppKit/AppKit.h>

// Call from the constructor, before Dia creates its tabs.
void DPTabsInstall(void);
// Whether Dia's tab-group calls were found.
BOOL DPTabsAvailable(void);
// Makes a folder of the window's tabs open at `urls`; `done` (on the main queue) gets its ID, or nil.
void DPTabsCreateFolder(NSWindow *window, NSArray<NSString *> *urls, NSString *title, void (^done)(NSString *groupId));
// Dia's web contents as tracked so far.
NSArray *DPTabsWebContents(void);
