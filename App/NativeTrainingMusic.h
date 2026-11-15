#import <AVFoundation/AVFoundation.h>

@interface RPSTrainingMusic : NSObject <AVAudioPlayerDelegate>
- (instancetype)initWithTracks:(NSArray<NSURL *> *)tracks;
- (void)updateInTrainingRoom:(BOOL)inTrainingRoom foreground:(BOOL)foreground;
@end

@interface RPSTrainingMusic ()
@property(nonatomic, copy) NSArray<NSURL *> *tracks;
@property(nonatomic, strong) AVAudioPlayer *player;
@property(nonatomic) NSUInteger nextTrack;
@property(nonatomic) NSUInteger playbackFailures;
@property(nonatomic) BOOL inTrainingRoom;
@property(nonatomic) BOOL foreground;
@property(nonatomic) BOOL interrupted;
@property(nonatomic) BOOL paused;
@end

@implementation RPSTrainingMusic

- (instancetype)initWithTracks:(NSArray<NSURL *> *)tracks {
    self = [super init];
    if (self) {
        _tracks = [tracks copy];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(audioInterruption:)
                                                   name:AVAudioSessionInterruptionNotification
                                                 object:nil];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_player stop];
}

- (void)updateInTrainingRoom:(BOOL)inTrainingRoom foreground:(BOOL)foreground {
    if (!inTrainingRoom && self.inTrainingRoom) {
        [self stopTrack];
        self.playbackFailures = 0;
    }
    self.inTrainingRoom = inTrainingRoom;
    self.foreground = foreground;
    [self updatePlayback];
}

- (void)updatePlayback {
    if (!self.inTrainingRoom || !self.foreground || self.interrupted) {
        if (self.player && !self.paused) {
            [self.player pause];
            self.paused = YES;
        }
        return;
    }
    if (self.player) {
        if (self.paused) {
            self.paused = NO;
            if (![self.player play]) [self trackEnded:self.player successfully:NO];
        }
        return;
    }
    while (self.playbackFailures < self.tracks.count) {
        NSURL *url = self.tracks[self.nextTrack];
        self.nextTrack = (self.nextTrack + 1) % self.tracks.count;
        AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:NULL];
        if (!player) {
            self.playbackFailures++;
            continue;
        }
        player.delegate = self;
        player.volume = 0;
        self.player = player;
        if ([player play]) {
            [player setVolume:0.65f fadeDuration:0.3];
            return;
        }
        [self stopTrack];
        self.playbackFailures++;
    }
}

- (void)stopTrack {
    self.player.delegate = nil;
    [self.player stop];
    self.player = nil;
    self.paused = NO;
}

- (void)trackEnded:(AVAudioPlayer *)player successfully:(BOOL)success {
    if (!player || self.player != player) return;
    [self stopTrack];
    self.playbackFailures = success ? 0 : self.playbackFailures + 1;
    [self updatePlayback];
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)success {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self trackEnded:player successfully:success];
    });
}

- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)player error:(NSError *)error {
    [self audioPlayerDidFinishPlaying:player successfully:NO];
}

- (void)audioInterruption:(NSNotification *)notification {
    AVAudioSessionInterruptionType type =
        [notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.interrupted = type == AVAudioSessionInterruptionTypeBegan;
        [self updatePlayback];
    });
}

@end
