// Keeps a patched copy of the user's own Dia in place across updates. The official app stays untouched in
// <support>/pristine; re-signing drops entitlements tied to The Browser Company's profile, or AMFI refuses to launch.

#import <Foundation/Foundation.h>
#include <libproc.h>
#include <mach-o/loader.h>
#include <sys/clonefile.h>
#include <sys/file.h>

#define DYLIB "DiaPatches.dylib"
static NSString *const kFeed = @"https://releases.diabrowser.com/BoostBrowser-updates.xml";
static NSString *const kSparkle = @"http://www.andymatuschak.org/xml-namespaces/sparkle";
static NSString *const kLocalIdentity = @"DiaPatches Local Signing";

static NSString *gHome, *gApp, *gCache, *gPristine, *gStaged;
static const char *gCommand;
static FILE *gLog;

#pragma mark - Output

static BOOL emit(FILE *out, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);
static BOOL emit(FILE *out, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (gLog) {
        char stamp[20];
        time_t now = time(NULL);
        strftime(stamp, sizeof stamp, "%F %T", localtime(&now));
        fprintf(gLog, "%s %s[%d] %s%s\n", stamp, gCommand, getpid(), out == stderr ? "error: " : "", line.UTF8String);
    }
    if (out) fprintf(out, "%s%s\n", out == stderr ? "diapatch: " : "", line.UTF8String);
    return out != stderr;
}

#define note(...) emit(NULL, __VA_ARGS__)   // log only
#define say(...) emit(stdout, __VA_ARGS__)  // returns YES
#define fail(...) emit(stderr, __VA_ARGS__) // returns NO

#pragma mark - Files and tools

static NSString *env(const char *name) {
    const char *value = getenv(name);
    return value && *value ? @(value) : nil;
}

static NSString *inHome(NSString *name) { return [gHome stringByAppendingPathComponent:name]; }

static BOOL exists(NSString *path) { return [NSFileManager.defaultManager fileExistsAtPath:path]; }

static BOOL makeDir(NSString *path) {
    NSError *error;
    return [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&error]
        || fail(@"cannot create %@: %@", path, error.localizedDescription);
}

static BOOL removeTree(NSString *path) {
    NSError *error;
    return [NSFileManager.defaultManager removeItemAtPath:path error:&error] || error.code == NSFileNoSuchFileError
        || fail(@"cannot remove %@: %@", path, error.localizedDescription);
}

static int run(NSArray<NSString *> *argv, NSString **output) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:argv[0]];
    task.arguments = [argv subarrayWithRange:NSMakeRange(1, argv.count - 1)];
    NSPipe *pipe = NSPipe.pipe;
    task.standardOutput = task.standardError = pipe;
    if (![task launchAndReturnError:NULL]) return -1;
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (output) *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return task.terminationStatus;
}

static BOOL check(NSArray<NSString *> *argv) {
    NSString *output;
    int status = run(argv, &output);
    return status == 0
        || fail(@"%@ failed (%d): %@", argv[0].lastPathComponent, status,
                [output stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
}

// Dia's feed server turns away some HTTP clients but accepts curl.
static int fetch(NSString *url, int seconds, NSString *file, NSString **output) {
    NSArray *argv = @[ @"/usr/bin/curl", @"-fsSL", @"--proto", @"=https,file", @"--proto-redir", @"=https", @"--max-time",
                       @(seconds).stringValue, url ];
    return run(file ? [argv arrayByAddingObjectsFromArray:@[ @"-o", file ]] : argv, output);
}

// Extended attributes (Finder info, resource forks) aren't part of the signature, but `codesign --strict`
// rejects them, and copies of Dia made by Finder or some installers carry them.
static BOOL clone(NSString *from, NSString *to) {
    BOOL copied = clonefile(from.fileSystemRepresentation, to.fileSystemRepresentation, 0) == 0
        || ((errno == EXDEV || errno == ENOTSUP) ? check(@[ @"/usr/bin/ditto", from, to ]) : fail(@"cannot clone %@: %s", from, strerror(errno)));
    return copied && check(@[ @"/usr/bin/xattr", @"-cr", to ]);
}

static int place(NSString *from, NSString *to) {
    const char *source = from.fileSystemRepresentation, *target = to.fileSystemRepresentation;
    return (exists(to) ? renamex_np(source, target, RENAME_SWAP) : rename(source, target)) == 0 ? 0 : errno;
}

// Atomic rename, copying onto the destination volume first if needed.
static BOOL moveBundle(NSString *from, NSString *to) {
    NSString *incoming = [to stringByAppendingString:@".incoming"];
    int error = place(from, to);
    if (error == EXDEV) error = removeTree(incoming) && check(@[ @"/usr/bin/ditto", from, incoming ]) ? place(incoming, to) : -1;
    if (error) {
        removeTree(incoming);
        if (error > 0)
            fail(@"cannot move %@ to %@: %s%@", from, to, strerror(error),
                 error == EPERM ? @" (see System Settings > Privacy & Security > App Management)" : @"");
        return NO;
    }
    return removeTree(incoming) && removeTree(from);
}

#pragma mark - Apps

static NSDictionary *infoOf(NSString *app) {
    return [NSDictionary dictionaryWithContentsOfURL:[NSURL fileURLWithPath:[app stringByAppendingPathComponent:@"Contents/Info.plist"]]
                                               error:NULL];
}

static NSString *buildOf(NSString *app) { return infoOf(app)[@"CFBundleVersion"]; }

static NSString *versionOf(NSString *app) {
    NSDictionary *info = infoOf(app);
    return info ? [NSString stringWithFormat:@"%@ (%@)", info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"]] : nil;
}

static BOOL isPatched(NSString *app) { return [infoOf(app)[@"DiaPatches"] boolValue]; }

// What the signature claims, without verifying it; verifyOfficial does that.
static BOOL claimsOfficial(NSString *app) {
    NSString *details;
    return run(@[ @"/usr/bin/codesign", @"-dv", app ], &details) == 0 && [details containsString:@"\nTeamIdentifier=S6N382Y83G\n"];
}

static BOOL verifyOfficial(NSString *app) {
    note(@"verifying %@", app);
    return ([infoOf(app)[@"CFBundleIdentifier"] isEqual:@"company.thebrowser.dia"] || fail(@"%@ is not Dia", app))
        && check(@[ @"/usr/bin/codesign", @"--verify", @"--deep", @"--strict", @"-R",
                    @"=anchor apple generic and certificate leaf[subject.OU] = \"S6N382Y83G\"", app ])
        && check(@[ @"/usr/sbin/spctl", @"--assess", @"--type", @"execute", app ]);
}

static BOOL appRunning(void) {
    char root[PATH_MAX], path[PROC_PIDPATHINFO_MAXSIZE];
    if (!realpath(gApp.fileSystemRepresentation, root)) return NO;
    strlcat(root, "/", sizeof root);
    int capacity = proc_listallpids(NULL, 0) + 64;
    pid_t pids[capacity];
    int count = proc_listallpids(pids, capacity * (int)sizeof *pids);
    for (int i = 0; i < count; i++)
        if (proc_pidpath(pids[i], path, sizeof path) > 0 && strncmp(path, root, strlen(root)) == 0) return YES;
    return NO;
}

static void waitForQuit(pid_t pid) {
    note(@"waiting for %@ to quit", gApp);
    for (int i = 0; i < 240 && ((pid > 0 && kill(pid, 0) == 0) || appRunning()); i++) usleep(250000);
}

#pragma mark - Building

// Weak load command in the padding after the load commands. The dylib lives outside the bundle so updating
// it doesn't change the app's signature, and with it Dia's keychain access.
static BOOL addLoadCommand(NSString *path, NSString *dylib) {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedAlways error:NULL];
    const uint8_t *bytes = data.bytes;
    const struct mach_header_64 *header = data.bytes;
    if (data.length < sizeof *header || header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64)
        return fail(@"%@ is not a thin arm64 executable", path);
    uint64_t end = sizeof *header + header->sizeofcmds, firstSection = data.length;
    for (uint64_t offset = sizeof *header, i = 0; i < header->ncmds; i++, offset += ((const struct load_command *)(bytes + offset))->cmdsize) {
        const struct segment_command_64 *segment = (const void *)(bytes + offset);
        if (end > data.length || offset + sizeof(struct load_command) > end || segment->cmdsize < sizeof(struct load_command)
            || offset + segment->cmdsize > end
            || (segment->cmd == LC_SEGMENT_64 && sizeof *segment + segment->nsects * sizeof(struct section_64) > segment->cmdsize))
            return fail(@"%@ has malformed load commands", path);
        if (segment->cmd != LC_SEGMENT_64 || strncmp(segment->segname, SEG_TEXT, sizeof segment->segname)) continue;
        const struct section_64 *sections = (const void *)(segment + 1);
        for (uint32_t s = 0; s < segment->nsects; s++)
            if (sections[s].size) firstSection = MIN(firstSection, sections[s].offset);
    }
    const char *name = dylib.fileSystemRepresentation;
    uint32_t size = (uint32_t)(sizeof(struct dylib_command) + strlen(name) + 8) & ~7u;
    NSMutableData *command = [NSMutableData dataWithLength:size];
    *(struct dylib_command *)command.mutableBytes = (struct dylib_command){
        .cmd = LC_LOAD_WEAK_DYLIB, .cmdsize = size,
        .dylib = { .name.offset = sizeof(struct dylib_command), .timestamp = 2, .current_version = 0x10000,
                   .compatibility_version = 0x10000 },
    };
    strcpy((char *)command.mutableBytes + sizeof(struct dylib_command), name);
    BOOL room = end + size <= firstSection;
    for (uint64_t i = end; room && i < end + size; i++) room = !bytes[i];
    if (!room) return fail(@"%@ has no room for another load command", path);
    uint32_t counts[2] = { header->ncmds + 1, header->sizeofcmds + size };
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CLOEXEC);
    BOOL written = fd >= 0 && pwrite(fd, command.bytes, size, (off_t)end) == size
        && pwrite(fd, counts, sizeof counts, offsetof(struct mach_header_64, ncmds)) == sizeof counts;
    if (fd >= 0 && close(fd) != 0) written = NO;
    return written || fail(@"cannot write %@: %s", path, strerror(errno));
}

static BOOL configureInfo(NSString *app) {
    NSURL *url = [NSURL fileURLWithPath:[app stringByAppendingPathComponent:@"Contents/Info.plist"]];
    NSError *error;
    NSMutableDictionary *info = [[NSMutableDictionary alloc] initWithContentsOfURL:url error:&error];
    info[@"SUEnableAutomaticChecks"] = info[@"SUAutomaticallyUpdate"] = @NO;
    info[@"DiaPatches"] = @YES;
    [info removeObjectForKey:@"SUFeedURL"];
    return [info writeToURL:url error:&error] || fail(@"cannot update %@: %@", url.path, error.localizedDescription);
}

static NSString *localIdentity(NSString *keychain) {
    NSString *list;
    run(@[ @"/usr/bin/security", @"find-identity", @"-p", @"codesigning", keychain ], &list);
    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"([0-9A-F]{40}) \"DiaPatches Local Signing\""
                                                                             options:0
                                                                               error:NULL];
    NSTextCheckingResult *match = list ? [pattern firstMatchInString:list options:0 range:NSMakeRange(0, list.length)] : nil;
    return match ? [list substringWithRange:[match rangeAtIndex:1]] : nil;
}

// A stable self-signed identity keeps Dia's keychain items readable across builds.
static NSString *createLocalIdentity(NSString *keychain) {
    note(@"creating the signing identity \"%@\" in %@", kLocalIdentity, keychain);
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"diapatch-identity"];
    NSString *config = [dir stringByAppendingPathComponent:@"req.cnf"], *key = [dir stringByAppendingPathComponent:@"key.pem"],
             *cert = [dir stringByAppendingPathComponent:@"cert.pem"], *p12 = [dir stringByAppendingPathComponent:@"id.p12"];
    NSString *request = @"[req]\ndistinguished_name = dn\nprompt = no\nx509_extensions = ext\n[dn]\nCN = DiaPatches Local Signing\n"
                        @"[ext]\nbasicConstraints = critical,CA:FALSE\nkeyUsage = critical,digitalSignature\n"
                        @"extendedKeyUsage = critical,codeSigning\nsubjectKeyIdentifier = hash\n";
    // The p12 only carries the key, which sits unencrypted beside it, into the keychain.
    BOOL ok = removeTree(dir) && makeDir(dir) && [request writeToFile:config atomically:NO encoding:NSUTF8StringEncoding error:NULL]
        && check(@[ @"/usr/bin/openssl", @"req", @"-x509", @"-new", @"-newkey", @"rsa:2048", @"-nodes", @"-sha256", @"-days", @"7300",
                    @"-config", config, @"-keyout", key, @"-out", cert ])
        && check(@[ @"/usr/bin/openssl", @"pkcs12", @"-export", @"-inkey", key, @"-in", cert, @"-name", kLocalIdentity,
                    @"-passout", @"pass:diapatch", @"-out", p12 ])
        && check(@[ @"/usr/bin/security", @"import", p12, @"-k", keychain, @"-f", @"pkcs12", @"-P", @"diapatch", @"-T",
                    @"/usr/bin/codesign" ]);
    removeTree(dir);
    return ok ? localIdentity(keychain) : nil;
}

static BOOL sign(NSString *app) {
    NSString *identity = env("DIAPATCH_IDENTITY")
        ?: [[NSString stringWithContentsOfFile:inHome(@"identity") encoding:NSUTF8StringEncoding error:NULL]
               stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray *codesign = @[ @"/usr/bin/codesign", @"--force", @"--timestamp=none", @"--sign" ];
    if (identity.length) {
        codesign = [codesign arrayByAddingObject:identity];
    } else {
        NSString *keychain = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Keychains/login.keychain-db"];
        identity = localIdentity(keychain) ?: createLocalIdentity(keychain);
        if (identity) codesign = [codesign arrayByAddingObjectsFromArray:@[ identity, @"--keychain", keychain ]];
        else codesign = [codesign arrayByAddingObject:@"-"];
        if (!identity) say(@"warning: signing ad hoc, so Dia will ask for keychain access again after every update");
    }
    NSURL *entitlements = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"diapatch.entitlements"]];
    NSDictionary *granted = @{
        @"com.apple.security.device.audio-input" : @YES,
        @"com.apple.security.device.camera" : @YES,
        @"com.apple.security.personal-information.location" : @YES,
    };
    BOOL ok = ([granted writeToURL:entitlements error:NULL] || fail(@"cannot write %@", entitlements.path))
        && check([codesign arrayByAddingObjectsFromArray:@[ @"--entitlements", entitlements.path, app ]]);
    [NSFileManager.defaultManager removeItemAtURL:entitlements error:NULL];
    if (ok) note(@"signed %@ with %@", app, codesign[4]);
    return ok;
}

static BOOL build(NSString *source) {
    NSString *executable = infoOf(source)[@"CFBundleExecutable"], *dylib = inHome(@DYLIB);
    if (!executable) return fail(@"no official Dia at %@; reinstall Dia from https://www.diabrowser.com", source);
    if (!exists(dylib)) return fail(@"%@ is missing; reinstall DiaPatches", dylib);
    note(@"building patched Dia %@", versionOf(source));
    NSString *work = [gStaged stringByAppendingString:@".building"], *contents = [work stringByAppendingPathComponent:@"Contents"];
    BOOL ok = removeTree(work) && makeDir(gStaged.stringByDeletingLastPathComponent) && clone(source, work)
        && addLoadCommand([contents stringByAppendingPathComponent:[@"MacOS" stringByAppendingPathComponent:executable]], dylib)
        && configureInfo(work) && removeTree([contents stringByAppendingPathComponent:@"embedded.provisionprofile"])
        && sign(work) && moveBundle(work, gStaged);
    if (!ok) removeTree(work);
    return ok;
}

#pragma mark - Updates

@interface Release : NSObject
@property(nonatomic, copy) NSString *build, *version, *url, *channel, *minimumOS;
@end

@implementation Release
@end

static BOOL newer(NSString *a, NSString *b) { return [a compare:b ?: @"" options:NSNumericSearch] == NSOrderedDescending; }

// sparkle:<name> as an attribute of `enclosure`, else as an element of `item`.
static NSString *sparkle(NSXMLElement *item, NSXMLElement *enclosure, NSString *name) {
    NSString *value = [enclosure attributeForLocalName:name URI:kSparkle].stringValue
        ?: [item elementsForLocalName:name URI:kSparkle].firstObject.stringValue;
    value = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return value.length ? value : nil;
}

static NSArray<Release *> *releasesIn(NSXMLDocument *feed) {
    NSMutableArray<Release *> *releases = [NSMutableArray array];
    for (NSXMLElement *item in [feed nodesForXPath:@"/rss/channel/item" error:NULL]) {
        NSXMLElement *enclosure = [item nodesForXPath:@"enclosure[@url and not(@*[local-name()='deltaFrom'])]" error:NULL].firstObject;
        Release *release = [Release new];
        release.url = [enclosure attributeForName:@"url"].stringValue;
        release.build = sparkle(item, enclosure, @"version");
        release.channel = sparkle(item, nil, @"channel");
        release.minimumOS = sparkle(item, nil, @"minimumSystemVersion");
        NSString *shortVersion = sparkle(item, enclosure, @"shortVersionString") ?: @"?";
        NSString *suffix = [NSString stringWithFormat:@" (%@)", release.build];  // Dia's feed already has it
        release.version = [shortVersion hasSuffix:suffix] ? shortVersion : [shortVersion stringByAppendingString:suffix];
        if (release.url && release.build) [releases addObject:release];
    }
    return releases;
}

// Early Birds: the user is in the channel their official build was released in, and gets the newest
// build this Mac can run from that channel or the untagged stable one.
static Release *offer(NSArray<Release *> *releases, NSString **channel) {
    NSString *pristine = buildOf(gPristine);
    *channel = nil;
    for (Release *release in releases) {
        if (![release.build isEqualToString:pristine]) continue;
        *channel = release.channel;
        if (!release.channel) break;  // also released untagged: stable
    }
    NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
    NSString *system = [NSString stringWithFormat:@"%ld.%ld.%ld", os.majorVersion, os.minorVersion, os.patchVersion];
    Release *best;
    for (Release *release in releases)
        if ((!release.channel || [release.channel isEqualToString:*channel]) && !newer(release.minimumOS, system)
            && (!best || newer(release.build, best.build)))
            best = release;
    return best;
}

static Release *latest(int seconds, NSString **channel, NSString **problem) {
    NSString *url = env("DIAPATCH_FEED") ?: kFeed, *output;
    NSError *error;
    NSXMLDocument *feed = fetch(url, seconds, nil, &output) == 0 ? [[NSXMLDocument alloc] initWithXMLString:output options:0 error:&error] : nil;
    Release *release = offer(releasesIn(feed), channel);
    if (!release)
        *problem = [NSString stringWithFormat:@"no update from %@: %@", url,
                                              feed ? @"nothing for this Mac" : error.localizedDescription ?: output];
    return release;
}

#pragma mark - Commands

static BOOL apply(void) {
    if (!exists(gStaged)) return YES;
    if (appRunning()) return fail(@"Dia is running; quit it, then run `diapatch apply`");
    return moveBundle(gStaged, gApp) && say(@"installed patched Dia %@ at %@", versionOf(gApp), gApp);
}

static BOOL install(BOOL relaunch) {
    NSString *identity = env("DIAPATCH_IDENTITY");
    if (!exists(gApp)) return fail(@"Dia is not installed at %@; get it from https://www.diabrowser.com", gApp);
    if (identity && ![identity writeToFile:inHome(@"identity") atomically:YES encoding:NSUTF8StringEncoding error:NULL])
        return fail(@"cannot save the signing identity");
    if (claimsOfficial(gApp) && ![buildOf(gApp) isEqual:buildOf(gPristine)]) {
        NSString *copy = [gPristine stringByAppendingString:@".new"];
        BOOL adopted = removeTree(copy) && makeDir(gPristine.stringByDeletingLastPathComponent) && clone(gApp, copy)
            && verifyOfficial(copy) && moveBundle(copy, gPristine);
        if (!adopted) return removeTree(copy), NO;
    }
    if (!build(gPristine)) return NO;
    if (appRunning() && relaunch) {
        run(@[ @"/usr/bin/osascript", @"-e", @"tell application id \"company.thebrowser.dia\" to quit" ], NULL);
        waitForQuit(0);
    }
    if (!appRunning()) return apply();
    if (isPatched(gApp)) return say(@"patched Dia %@ is staged and replaces Dia when it quits", versionOf(gStaged));
    return say(@"patched Dia %@ is staged: quit Dia, then run \"%@\" apply (or install --relaunch to do both)", versionOf(gStaged),
               inHome(@"bin/diapatch"));
}

static BOOL update(void) {
    NSString *channel, *problem, *output;
    Release *release = latest(60, &channel, &problem);
    if (!release) return say(@"%@", problem);
    if (!newer(release.build, buildOf(gPristine))) {
        if (exists(gStaged)) return say(@"Dia %@ is staged; relaunch Dia or run `diapatch apply` to install it", versionOf(gStaged));
        return say(@"Dia %@ is up to date", release.version);
    }
    NSString *work = [gCache stringByAppendingPathComponent:@"download"];
    NSString *zip = [work stringByAppendingPathComponent:@"Dia.zip"], *app = [work stringByAppendingPathComponent:@"Dia.app"];
    if (!removeTree(work) || !makeDir(work)) return NO;
    note(@"downloading Dia %@ (%@) from %@", release.version, channel ?: @"stable", release.url);
    if (fetch(release.url, 3600, zip, &output) != 0) {
        removeTree(work);
        return say(@"cannot download Dia %@: %@", release.version, output);
    }
    BOOL ok = check(@[ @"/usr/bin/ditto", @"-x", @"-k", zip, work ]) && check(@[ @"/usr/bin/xattr", @"-cr", work ])
        && ([buildOf(app) isEqual:release.build] || fail(@"the download holds build %@, not %@", buildOf(app), release.build))
        && verifyOfficial(app) && build(app) && makeDir(gPristine.stringByDeletingLastPathComponent) && moveBundle(app, gPristine);
    removeTree(work);
    return ok && say(@"Dia %@ is staged; relaunch Dia or run `diapatch apply` to install it", release.version);
}

// Deletes only what DiaPatches creates, in case DIAPATCH_HOME points somewhere shared.
static BOOL purge(void) {
    for (NSString *name in @[ @"bin", @DYLIB, @"pristine", @"staged", @"identity", @"diapatch.log", @"mobile" ])
        if (!removeTree(inHome(name))) return NO;
    if (!removeTree([gCache stringByAppendingPathComponent:@"download"])) return NO;
    rmdir(gCache.fileSystemRepresentation);
    if (rmdir(gHome.fileSystemRepresentation) == 0) return say(@"deleted %@", gHome);
    return say(@"kept %@: it holds files DiaPatches did not create", gHome);
}

static BOOL uninstall(BOOL purgeFiles) {
    if (appRunning()) return fail(@"Dia is running; quit it, then run `diapatch uninstall`");
    if (!claimsOfficial(gApp)) {
        NSString *copy = [gPristine stringByAppendingString:@".restore"];
        if (!exists(gPristine)) return fail(@"no official Dia at %@; reinstall Dia from https://www.diabrowser.com", gPristine);
        if (!removeTree(copy) || !clone(gPristine, copy) || !moveBundle(copy, gApp)) return removeTree(copy), NO;
    }
    say(@"%@ is the official Dia %@", gApp, versionOf(gApp));
    // Phone access's server goes with the patches.
    run(@[ @"/bin/launchctl", @"bootout", [NSString stringWithFormat:@"gui/%d/com.diapatches.mobile", getuid()] ], NULL);
    [NSFileManager.defaultManager removeItemAtPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents/com.diapatches.mobile.plist"] error:nil];
    return removeTree(gStaged) && (!purgeFiles || purge());
}

static BOOL status(BOOL json) {
    NSString *channel, *problem;
    Release *release = latest(15, &channel, &problem);
    NSDictionary *status = @{
        @"official" : versionOf(gPristine) ?: NSNull.null,
        @"installed" : versionOf(gApp) ?: NSNull.null,
        @"patched" : @(isPatched(gApp)),
        @"staged" : versionOf(gStaged) ?: NSNull.null,
        @"feed" : release.version ?: NSNull.null,
        @"channel" : channel ?: @"stable",
    };
    if (json) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:status
                                                       options:NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes
                                                         error:NULL];
        printf("%.*s\n", (int)data.length, (const char *)data.bytes);
        return YES;
    }
    for (NSString *key in @[ @"official", @"installed", @"patched", @"staged", @"feed", @"channel" ]) {
        id value = status[key];
        if (value == NSNull.null) value = [key isEqualToString:@"feed"] ? problem : @"none";
        else if ([key isEqualToString:@"patched"]) value = [value boolValue] ? @"yes" : @"no";
        printf("%-10s%s\n", key.UTF8String, [value UTF8String]);
    }
    return YES;
}

static const char kUsage[] =
    "usage: diapatch <command>\n"
    "  install [--relaunch]\n"
    "                   keep the official Dia as the pristine copy, patch it and put it in place;\n"
    "                   --relaunch quits a running Dia first and reopens it afterwards\n"
    "  build            rebuild the staged patched Dia from the pristine copy\n"
    "  update           download, verify and stage a newer Dia from your channel (stable or Early Birds)\n"
    "  apply [--wait PID] [--relaunch]\n"
    "                   swap the staged build into place once PID and Dia have quit, then reopen Dia\n"
    "  uninstall [--wait PID] [--relaunch] [--purge]\n"
    "                   put the official Dia back; --purge also deletes DiaPatches' files\n"
    "  status [--json]  official, installed, staged and offered versions, and the update channel\n"
    "environment: DIAPATCH_IDENTITY (codesigning identity, remembered by install), DIAPATCH_HOME,\n"
    "  DIAPATCH_APP, DIAPATCH_CACHE, DIAPATCH_FEED\n";

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        gHome = env("DIAPATCH_HOME") ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/DiaPatches"];
        gApp = env("DIAPATCH_APP") ?: @"/Applications/Dia.app";
        gCache = env("DIAPATCH_CACHE") ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/DiaPatches"];
        gPristine = inHome(@"pristine/Dia.app");
        gStaged = inHome(@"staged/Dia.app");

        NSString *command = argc > 1 ? @(argv[1]) : @"";
        NSArray<NSString *> *allowed = @{
            @"install" : @[ @"--relaunch" ], @"build" : @[], @"update" : @[], @"status" : @[ @"--json" ],
            @"apply" : @[ @"--wait", @"--relaunch" ], @"uninstall" : @[ @"--wait", @"--relaunch", @"--purge" ],
        }[command];
        NSMutableSet<NSString *> *flags = [NSMutableSet set];
        pid_t pid = 0;
        for (int i = 2; allowed && i < argc; i++) {
            [flags addObject:@(argv[i])];
            if (![allowed containsObject:@(argv[i])] || (!strcmp(argv[i], "--wait") && (++i == argc || (pid = atoi(argv[i])) <= 0)))
                allowed = nil;
        }
        if (!allowed) {
            BOOL help = argc == 2 && [@[ @"help", @"-h", @"--help" ] containsObject:command];
            fputs(kUsage, help ? stdout : stderr);
            return help ? 0 : 2;
        }
        if ([command isEqualToString:@"status"]) return status([flags containsObject:@"--json"]) ? 0 : 1;

        if (pid) setsid();  // the caller (Dia) is about to quit: leave its process group
        gCommand = argv[1];
        if (!makeDir(gHome)) return 1;
        gLog = fopen(inHome(@"diapatch.log").fileSystemRepresentation, "a");
        if (!gLog) return fail(@"cannot open %@: %s", inHome(@"diapatch.log"), strerror(errno)), 1;
        setvbuf(gLog, NULL, _IOLBF, 0);
        if (pid) waitForQuit(pid);
        if (flock(fileno(gLog), LOCK_EX | LOCK_NB) != 0) {  // the log doubles as the lock: one run at a time
            say(@"waiting for another diapatch run to finish");
            flock(fileno(gLog), LOCK_EX);
        }
        BOOL ok = [command isEqualToString:@"install"] ? install([flags containsObject:@"--relaunch"])
            : [command isEqualToString:@"build"]       ? build(gPristine) && say(@"staged patched Dia %@", versionOf(gStaged))
            : [command isEqualToString:@"update"]      ? update()
            : [command isEqualToString:@"apply"]       ? apply()
                                                       : uninstall([flags containsObject:@"--purge"]);
        if ([flags containsObject:@"--relaunch"]) check(@[ @"/usr/bin/open", gApp ]);
        return ok ? 0 : 1;
    }
}
