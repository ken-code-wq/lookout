#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <unistd.h>
#include "NowPlayingBridge.h"

typedef void (^NPInfoBlock)(CFDictionaryRef);
typedef void (^NPBoolBlock)(Boolean);
typedef void (^NPClientBlock)(id);
typedef void (*NPGetInfo)(dispatch_queue_t, NPInfoBlock);
typedef void (*NPGetIsPlaying)(dispatch_queue_t, NPBoolBlock);
typedef void (*NPGetClient)(dispatch_queue_t, NPClientBlock);
typedef CFStringRef (*NPClientBundle)(id);
typedef Boolean (*NPSendCommand)(int, CFDictionaryRef);
typedef void (*NPSetElapsed)(double);

static void *np_framework(void) {
    static void *handle;
    if (!handle) handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    return handle;
}

/// One snapshot of Now Playing as a JSON-ready dictionary. Artwork is attached by the caller when the track changes.
static NSMutableDictionary *np_snapshot(NSData **artwork) {
    void *mr = np_framework();
    NPGetInfo getInfo = (NPGetInfo)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    NPGetIsPlaying getPlaying = (NPGetIsPlaying)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    NPGetClient getClient = (NPGetClient)dlsym(mr, "MRMediaRemoteGetNowPlayingClient");
    NPClientBundle bundleOf = (NPClientBundle)dlsym(mr, "MRNowPlayingClientGetBundleIdentifier");
    if (!getInfo) return nil;

    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSDictionary *info = nil;
    __block BOOL playing = NO;
    __block NSString *bundle = nil;

    getInfo(queue, ^(CFDictionaryRef dict) { info = [(__bridge NSDictionary *)dict copy]; dispatch_semaphore_signal(done); });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    if (getPlaying) {
        getPlaying(queue, ^(Boolean value) { playing = value; dispatch_semaphore_signal(done); });
        dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    }
    if (getClient && bundleOf) {
        getClient(queue, ^(id client) {
            if (client) bundle = [(__bridge NSString *)bundleOf(client) copy];
            dispatch_semaphore_signal(done);
        });
        dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    }

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
    if (!title.length) return out;
    out[@"title"] = title;
    out[@"artist"] = info[@"kMRMediaRemoteNowPlayingInfoArtist"] ?: @"";
    out[@"album"] = info[@"kMRMediaRemoteNowPlayingInfoAlbum"] ?: @"";
    out[@"duration"] = info[@"kMRMediaRemoteNowPlayingInfoDuration"] ?: @0;
    double elapsed = [info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] doubleValue];
    double rate = [info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] doubleValue];
    NSDate *stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    // Elapsed time is reported as of `stamp`; bring it up to now.
    if (stamp && playing && rate > 0) elapsed += -[stamp timeIntervalSinceNow] * rate;
    out[@"elapsed"] = @(elapsed);
    out[@"playing"] = @(playing);
    out[@"bundle"] = bundle ?: @"";
    if (artwork) *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    return out;
}

static void np_emit(NSDictionary *object) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

void np_stream(void *perl, void *cv) {
    @autoreleasepool {
        NSString *lastKey = nil;
        NSDictionary *lastSent = nil;
        NSDate *lastBeat = [NSDate distantPast];
        while (getppid() != 1) { // parent (the app) gone: exit instead of lingering
            @autoreleasepool {
                NSData *artwork = nil;
                NSMutableDictionary *now = np_snapshot(&artwork);
                NSString *key = [NSString stringWithFormat:@"%@|%@|%@|%@", now[@"bundle"], now[@"title"], now[@"artist"], now[@"album"]];
                BOOL trackChanged = ![key isEqualToString:lastKey];
                NSMutableDictionary *compare = [now mutableCopy];
                [compare removeObjectForKey:@"elapsed"];
                BOOL changed = trackChanged || ![compare isEqual:lastSent];
                // Resync position every few seconds even when nothing else changed (seeking, drift).
                if (changed || -[lastBeat timeIntervalSinceNow] > 4) {
                    if (trackChanged && artwork.length) now[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
                    np_emit(now);
                    lastKey = key;
                    lastSent = compare;
                    lastBeat = [NSDate date];
                }
            }
            usleep(700000);
        }
    }
}

void np_command(void *perl, void *cv) {
    @autoreleasepool {
        void *mr = np_framework();
        const char *seek = getenv("NP_SEEK");
        if (seek) {
            NPSetElapsed setElapsed = (NPSetElapsed)dlsym(mr, "MRMediaRemoteSetElapsedTime");
            if (setElapsed) setElapsed(atof(seek));
        } else {
            const char *command = getenv("NP_COMMAND");
            NPSendCommand send = (NPSendCommand)dlsym(mr, "MRMediaRemoteSendCommand");
            if (send && command) send(atoi(command), NULL);
        }
        usleep(150000); // let the command leave the process before perl exits
    }
}
