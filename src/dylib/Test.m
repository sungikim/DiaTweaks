#import "DiaPatches.h"

// Test mode, for `make test`: with DIAPATCH_TEST=/path/report.json, Dia waits for a browser window, tries patch
// combinations without saving them, runs every patch's verify after each, ends on the saved settings and writes the report.

static const NSTimeInterval DPSettleSeconds = 1;

static NSUInteger DPIndex(DPPatch *patch) {
    for (NSUInteger i = 0; i < DPPatchCount; i++) if (DPPatches[i] == patch) return i;
    abort();
}

static BOOL DPNeeds(DPPatch *patch, DPPatch *other) {
    for (DPPatch *required = patch->requires; required; required = required->requires) if (required == other) return YES;
    return NO;
}

static void DPTurnOn(int8_t *state, DPPatch *patch) {
    for (; patch; patch = patch->requires) state[DPIndex(patch)] = 1;
}

static NSString *DPBits(const int8_t *state) {
    NSMutableString *bits = [NSMutableString string];
    for (NSUInteger i = 0; i < DPPatchCount; i++) [bits appendString:state[i] == 1 ? @"1" : @"0"];
    return bits;
}

static NSUInteger DPPair(NSUInteger i, BOOL a, NSUInteger j, BOOL b) { return ((i * DPPatchCount + j) * 2 + a) * 2 + b; }

// How many uncovered pairs setting patch k would cover, against the patches already decided (state -1: undecided).
static int DPGain(const int8_t *state, const BOOL *uncovered, NSUInteger k, BOOL on) {
    int gain = 0;
    for (NSUInteger m = 0; m < DPPatchCount; m++)
        if (m != k && state[m] >= 0) gain += m < k ? uncovered[DPPair(m, state[m], k, on)] : uncovered[DPPair(k, on, m, state[m])];
    return gain;
}

// [name, one '0' or '1' per patch in DPPatches order]
static NSMutableArray<NSArray<NSString *> *> *DPScenarios(void) {
    NSUInteger n = DPPatchCount;
    NSMutableArray<NSArray<NSString *> *> *scenarios = [NSMutableArray new];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    BOOL (^add)(NSString *, const int8_t *) = ^BOOL(NSString *name, const int8_t *state) {
        NSString *bits = DPBits(state);
        if ([seen containsObject:bits]) return NO;
        [seen addObject:bits];
        [scenarios addObject:@[name, bits]];
        return YES;
    };
    int8_t state[n];
    memset(state, 0, n);
    add(@"all off", state);
    for (NSUInteger i = 0; i < n; i++) state[i] = !DPPatches[i]->unavailable;
    add(@"all on", state);
    for (NSUInteger i = 0; i < n; i++) {
        if (DPPatches[i]->unavailable) continue;
        memset(state, 0, n);
        DPTurnOn(state, DPPatches[i]);
        add([DPPatches[i]->key stringByAppendingString:@" alone"], state);
    }

    // Every two patches, in each on/off combination `requires` allows.
    BOOL uncovered[n * n * 4];
    memset(uncovered, 0, sizeof uncovered);
    for (NSUInteger i = 0; i < n; i++)
        for (NSUInteger j = i + 1; j < n; j++)
            for (int a = 0; a < 2; a++)
                for (int b = 0; b < 2; b++)
                    uncovered[DPPair(i, a, j, b)] = !DPPatches[i]->unavailable && !DPPatches[j]->unavailable
                        && !(a && !b && DPNeeds(DPPatches[i], DPPatches[j])) && !(b && !a && DPNeeds(DPPatches[j], DPPatches[i]));
    // Greedy: start from an uncovered pair, then give each other patch the value that covers the most pairs not seen yet.
    NSUInteger pairwise = 0;
    for (NSUInteger pair = 0; pair < n * n * 4; pair++) {
        if (!uncovered[pair]) continue;
        NSUInteger i = pair / 4 / n, j = pair / 4 % n;
        memset(state, -1, n);
        state[i] = pair / 2 % 2;
        state[j] = pair % 2;
        if (state[i]) DPTurnOn(state, DPPatches[i]);
        if (state[j]) DPTurnOn(state, DPPatches[j]);
        for (NSUInteger k = 0; k < n; k++) {
            if (state[k] >= 0) continue;
            DPPatch *required = DPPatches[k]->requires;
            BOOL canTurnOn = !DPPatches[k]->unavailable && (!required || state[DPIndex(required)] == 1);
            state[k] = canTurnOn && DPGain(state, uncovered, k, YES) >= DPGain(state, uncovered, k, NO);
        }
        for (NSUInteger p = 0; p < n; p++)
            for (NSUInteger q = p + 1; q < n; q++) uncovered[DPPair(p, state[p], q, state[q])] = NO;
        if (add([NSString stringWithFormat:@"pairwise %lu", (unsigned long)pairwise + 1], state)) pairwise++;
    }
    return scenarios;
}

static void DPWriteReport(NSArray<NSDictionary *> *results, NSString *path) {
    NSMutableArray<NSString *> *unavailable = [NSMutableArray new];
    for (NSUInteger i = 0; i < DPPatchCount; i++) if (DPPatches[i]->unavailable) [unavailable addObject:DPPatches[i]->key];
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSDictionary *report = @{
        @"dia": [NSString stringWithFormat:@"%@ (%@)", info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"]],
        @"layout": DPFindViews(NSClassFromString(@"_TtC10TabSidebar26SidebarContainerFooterView")).count ? @"sidebar" : @"top",
        @"safeMode": @(DPSafeMode),
        @"unavailable": unavailable,
        @"scenarios": results,
    };
    [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil]
        writeToFile:path atomically:YES];
}

static void DPRunScenario(NSArray<NSArray<NSString *> *> *scenarios, NSUInteger index, NSMutableArray<NSDictionary *> *results, NSString *path) {
    if (index == scenarios.count) return DPWriteReport(results, path);
    NSString *bits = scenarios[index][1];
    for (NSUInteger i = 0; i < DPPatchCount; i++) DPSetPatch(DPPatches[i], [bits characterAtIndex:i] == '1', NO);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(DPSettleSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSMutableDictionary<NSString *, id> *states = [NSMutableDictionary new], *failures = [NSMutableDictionary new];
        for (NSUInteger i = 0; i < DPPatchCount; i++) {
            DPPatch *patch = DPPatches[i];
            states[patch->key] = @(patch->on);
            NSString *problem = patch->verify && !patch->unavailable ? patch->verify(patch) : nil;
            if (problem) failures[patch->key] = problem;
        }
        [results addObject:@{@"name": scenarios[index][0], @"states": states, @"failures": failures}];
        DPRunScenario(scenarios, index + 1, results, path);
    });
}

void DPRunTests(NSString *path) {
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *_) {
        __block int polls = 0;
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
            // After a minute without a browser window it runs anyway, and the report says what's missing.
            if (!DPFindViews(NSClassFromString(@"_TtC11ContentPane15ContentPaneView")).count && ++polls < 120) return;
            [timer invalidate];
            if (DPSafeMode) return DPWriteReport(@[], path);
            NSMutableArray<NSArray<NSString *> *> *scenarios = DPScenarios();
            int8_t saved[DPPatchCount];
            for (NSUInteger i = 0; i < DPPatchCount; i++) saved[i] = DPSavedOn(DPPatches[i]);
            [scenarios addObject:@[@"saved settings", DPBits(saved)]];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                DPRunScenario(scenarios, 0, [NSMutableArray new], path);
            });
        }];
    }];
}
