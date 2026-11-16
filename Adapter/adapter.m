// 제어 센터의 "지금 재생 중" 정보를 읽어 JSON 한 줄씩 stdout으로 내보낸다.
// macOS 15.4부터 일반 앱은 MediaRemote에 접근할 수 없어서, Apple이 서명한
// /usr/bin/perl 안에서 이 라이브러리를 불러 실행한다 (run.pl 참고).
// stdin으로 "toggle", "next", "prev", "seek <초>" 명령을 받는다.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>

typedef void (*MRGetInfo)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRGetIsPlaying)(dispatch_queue_t, void (^)(BOOL));
typedef void (*MRGetClient)(dispatch_queue_t, void (^)(id));
typedef NSString *(*MRClientString)(id);
typedef void (*MRRegister)(dispatch_queue_t);
typedef Boolean (*MRSendCommand)(int, NSDictionary *);
typedef void (*MRSetElapsed)(double);

static MRGetInfo getInfo;
static MRGetIsPlaying getIsPlaying;
static MRGetClient getClient;
static MRClientString clientBundle;
static MRClientString clientParentBundle;
static MRSendCommand sendCommand;
static MRSetElapsed setElapsed;

static dispatch_queue_t queue;
static NSUInteger lastArtHash = 0;
static NSUInteger pendingGeneration = 0;
static NSDictionary *lastEmitted = nil;

static NSString *const K = @"kMRMediaRemoteNowPlayingInfo";

static id value(NSDictionary *info, NSString *key) {
    return info[[K stringByAppendingString:key]];
}

static void writeLine(NSDictionary *object) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void emit(void) {
    getInfo(queue, ^(NSDictionary *info) {
        getIsPlaying(queue, ^(BOOL playing) {
            void (^finish)(id) = ^(id client) {
                NSMutableDictionary *o = [NSMutableDictionary dictionary];
                o[@"title"] = value(info, @"Title") ?: @"";
                o[@"artist"] = value(info, @"Artist") ?: @"";
                o[@"album"] = value(info, @"Album") ?: @"";
                o[@"duration"] = value(info, @"Duration") ?: @0;
                o[@"elapsed"] = value(info, @"ElapsedTime") ?: @0;
                o[@"rate"] = value(info, @"PlaybackRate") ?: @0;
                o[@"playing"] = @(playing);
                NSDate *ts = value(info, @"Timestamp");
                o[@"timestamp"] = @((ts ?: [NSDate date]).timeIntervalSince1970);

                if (client) {
                    NSString *parent = clientParentBundle ? clientParentBundle(client) : nil;
                    NSString *bundle = clientBundle ? clientBundle(client) : nil;
                    if (parent.length) o[@"bundleId"] = parent;
                    else if (bundle.length) o[@"bundleId"] = bundle;
                }

                // 앨범 커버는 바뀌었을 때만 보낸다.
                NSData *art = value(info, @"ArtworkData");
                if (art.length) {
                    NSUInteger h = art.hash ^ art.length;
                    if (h != lastArtHash) {
                        lastArtHash = h;
                        o[@"artwork"] = [art base64EncodedStringWithOptions:0];
                    }
                } else if (lastArtHash != 0) {
                    lastArtHash = 0;
                    o[@"artwork"] = [NSNull null];
                }
                // 바뀐 게 없으면 보내지 않는다. 앱을 깨우지 않으려는 것.
                if ([o isEqualToDictionary:lastEmitted]) return;
                lastEmitted = [o copy];
                writeLine(o);
            };
            if (getClient) getClient(queue, finish);
            else finish(nil);
        });
    });
}

// 알림이 몰려 오면 아주 짧게(25ms) 모아서 한 번만 보낸다.
static void scheduleEmit(void) {
    dispatch_async(queue, ^{
        NSUInteger generation = ++pendingGeneration;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_MSEC), queue, ^{
            if (generation == pendingGeneration) emit();
        });
    });
}

static void readCommands(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char buffer[256];
        while (fgets(buffer, sizeof buffer, stdin)) {
            NSString *line = [[NSString stringWithUTF8String:buffer]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([line isEqualToString:@"toggle"]) sendCommand(2, nil);
            else if ([line isEqualToString:@"next"]) sendCommand(4, nil);
            else if ([line isEqualToString:@"prev"]) sendCommand(5, nil);
            else if ([line hasPrefix:@"seek "] && setElapsed) setElapsed([line substringFromIndex:5].doubleValue);
            // 명령 직후에 바로 읽으면 아직 바뀌기 전 상태가 나온다. 바뀌면 macOS가 알림을 보내 준다.
        }
        // 앱이 꺼져서 stdin이 닫히면 같이 끝난다.
        exit(0);
    });
}

// perl의 DynaLoader::dl_install_xsub로 불리는 입구. 인자는 쓰지 않는다.
void adapter_run(void *perl, void *cv) {
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!mr) {
        fprintf(stderr, "MediaRemote를 열 수 없습니다\n");
        exit(1);
    }
    getInfo = dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    getIsPlaying = dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    getClient = dlsym(mr, "MRMediaRemoteGetNowPlayingClient");
    clientBundle = dlsym(mr, "MRNowPlayingClientGetBundleIdentifier");
    clientParentBundle = dlsym(mr, "MRNowPlayingClientGetParentAppBundleIdentifier");
    sendCommand = dlsym(mr, "MRMediaRemoteSendCommand");
    setElapsed = dlsym(mr, "MRMediaRemoteSetElapsedTime");
    MRRegister registerNotifications = dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!getInfo || !getIsPlaying || !sendCommand || !registerNotifications) {
        fprintf(stderr, "MediaRemote 함수를 찾을 수 없습니다\n");
        exit(1);
    }

    queue = dispatch_queue_create("notchmusic.adapter", DISPATCH_QUEUE_SERIAL);
    registerNotifications(queue);

    NSArray *names = @[
        @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
    ];
    for (NSString *name in names) {
        [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil
                                                      usingBlock:^(NSNotification *note) { scheduleEmit(); }];
    }

    // 알림을 안 보내는 앱(일부 브라우저)을 위해 5초마다 한 번씩도 확인한다.
    // 여유(leeway)를 크게 줘서 macOS가 다른 일과 묶어 깨울 수 있게 한다.
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC, 2 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{ emit(); });
    dispatch_resume(timer);

    readCommands();
    CFRunLoopRun();
}
