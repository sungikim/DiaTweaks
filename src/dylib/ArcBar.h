// Arc-style sidebar URL bar and command bar, ported from daypatch (see ArcBar.m).
#import <AppKit/AppKit.h>

// Call once on the main thread after launch.
void DPArcBarInstall(void);
// Turns the sidebar URL bar (with back/forward/reload) on or off, whether ⌘T/⌘L open the command bar,
// whether the URL bar ends with the ⋯ extensions button, and whether Dia's downloads button sits at the
// sidebar's bottom right instead of its top.
void DPArcBarConfigure(BOOL sidebarURLBar, BOOL commandBar, BOOL extensionsButton, BOOL downloadsAtBottom);
// Opens the command bar for a new tab, as ⌘T does. NO if the command bar is off.
BOOL DPArcBarOpenNewTab(NSWindow *window);
// A page's favicon from the current profile's Favicons database, or nil.
NSImage *DPArcBarFavicon(NSString *url);
// The name a site's saved icon goes by in DiaPatches/site-icons ("github.com", "localhost_3000"), or nil.
NSString *DPArcBarSiteKey(NSString *url);
// Pops up the extensions menu below `anchor` (in DiaPatches.m).
void DPShowExtensionsMenu(NSView *anchor);
