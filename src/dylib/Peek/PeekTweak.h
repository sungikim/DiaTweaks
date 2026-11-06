// Peek on Shift-Click, for DiaPatches.m (see Peek.h).
#import <AppKit/AppKit.h>

void DPPeekInstall(void);  // Call from the constructor.
void DPPeekSetOn(BOOL on);
BOOL DPPeekShowingIn(NSWindow *window);
