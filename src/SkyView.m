#import "NC.h"
#import <AVFoundation/AVFoundation.h>

// The picture in the clock column (the luxury look, Nov 2026): the user's
// clips, framed — never full screen any more — at 0.8 opacity, fading into
// the black at the top and bottom. By day the clip plays, looping; after
// dark it's a still, in greyscale (the user asked), drifting very slowly.

/// One clip: a playing video, or a still.
@interface NCClipLayer : CALayer
@property (nonatomic, strong) CALayer *still;
@property (nonatomic, strong) AVPlayerLayer *video;
@property (nonatomic, strong) AVQueuePlayer *player;
@property (nonatomic, strong) AVPlayerLooper *looper;
@property (nonatomic, copy) NSString *key;
@end

@implementation NCClipLayer
@end

/// [image] without its colour.
static UIImage *greyscale(UIImage *image) {
  CGImageRef src = image.CGImage;
  size_t w = CGImageGetWidth(src), h = CGImageGetHeight(src);
  CGColorSpaceRef grey = CGColorSpaceCreateDeviceGray();
  CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, grey, kCGImageAlphaNone);
  CGColorSpaceRelease(grey);
  if (!ctx) return image;
  CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), src);
  CGImageRef out = CGBitmapContextCreateImage(ctx);
  CGContextRelease(ctx);
  UIImage *img = [UIImage imageWithCGImage:out];
  CGImageRelease(out);
  return img;
}

@implementation NCSkyView {
  NCClipLayer *_current;
  CAGradientLayer *_mask;
  CALayer *_wash;  // night mode: a little darker
  BOOL _paused;
}

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.backgroundColor = UIColor.clearColor;
    self.userInteractionEnabled = NO;
    self.clipsToBounds = YES;
    self.alpha = 0.8;
    // Muted anyway, but ambient so it never stops music playing.
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient error:nil];
    // Soft edges: clear at the top, solid from 30% to 65%, clear at the foot.
    _mask = [CAGradientLayer layer];
    _mask.colors = @[(id)UIColor.clearColor.CGColor, (id)UIColor.blackColor.CGColor,
                     (id)UIColor.blackColor.CGColor, (id)UIColor.clearColor.CGColor];
    _mask.locations = @[@0, @0.3, @0.65, @1];
    self.layer.mask = _mask;
    _wash = [CALayer layer];
    _wash.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45].CGColor;
    _wash.hidden = YES;
    [self.layer addSublayer:_wash];
  }
  return self;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  _mask.frame = self.bounds;
  _wash.frame = self.bounds;
  for (CALayer *l in self.layer.sublayers) {
    if (![l isKindOfClass:NCClipLayer.class]) continue;
    NCClipLayer *c = (NCClipLayer *)l;
    c.frame = self.bounds;
    c.video.frame = self.bounds;
    if (c.still) {
      c.still.bounds = self.bounds;
      c.still.position = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    }
  }
  [CATransaction commit];
}

/// The mock-up's slow drift on the still: 1.02 → 1.12 and 14 pt left,
/// over 40 s and back.
- (void)drift:(CALayer *)layer {
  CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"transform"];
  a.fromValue = [NSValue valueWithCATransform3D:CATransform3DMakeScale(1.02, 1.02, 1)];
  CATransform3D to = CATransform3DMakeTranslation(-14, 0, 0);
  a.toValue = [NSValue valueWithCATransform3D:CATransform3DScale(to, 1.12, 1.12, 1)];
  a.duration = 40;
  a.autoreverses = YES;
  a.repeatCount = HUGE_VALF;
  a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
  a.removedOnCompletion = NO;
  [layer addAnimation:a forKey:@"drift"];
}

/// Freezes (or thaws) a layer's animations where they are.
static void freeze(CALayer *layer, BOOL frozen) {
  if (!layer) return;
  if (frozen && layer.speed != 0) {
    CFTimeInterval t = [layer convertTime:CACurrentMediaTime() fromLayer:nil];
    layer.speed = 0;
    layer.timeOffset = t;
  } else if (!frozen && layer.speed == 0) {
    CFTimeInterval paused = layer.timeOffset;
    layer.speed = 1;
    layer.timeOffset = 0;
    layer.beginTime = 0;
    layer.beginTime = [layer convertTime:CACurrentMediaTime() fromLayer:nil] - paused;
  }
}

- (void)updateForNow:(NSDate *)now raining:(BOOL)raining {
#if FORCE_RAIN
  raining = YES;
#endif
#if FORCE_CLEAR
  raining = NO;
#endif
  BOOL night = NCIsNight(now);
  BOOL dark = night || NCIsDark(now);
  _wash.hidden = !night;
  // Rainy whenever it rains, else the night clip after dark and the sunny
  // one by day. After dark, a greyscale still.
  NSString *clip = raining ? @"rainy" : dark ? @"night" : @"sunny";
  BOOL still = dark;
  NSString *key = [clip stringByAppendingString:still ? @".jpg" : @".mp4"];
  if ([key isEqualToString:_current.key]) return;

  NSString *path = [[NSBundle mainBundle] pathForResource:clip ofType:still ? @"jpg" : @"mp4"];
  if (!path) return;  // Not in this build: black.
  NCClipLayer *layer = [NCClipLayer layer];
  layer.key = key;
  layer.frame = self.bounds;
  layer.masksToBounds = YES;
  if (still) {
    UIImage *image = [UIImage imageWithContentsOfFile:path];
    if (!image) return;
    layer.still = [CALayer layer];
    layer.still.contents = (id)greyscale(image).CGImage;
    layer.still.contentsGravity = kCAGravityResizeAspectFill;
    layer.still.bounds = self.bounds;
    layer.still.position = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    [layer addSublayer:layer.still];
    [self drift:layer.still];
    if (_standby || _paused) freeze(layer.still, YES);
  } else {
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:path]];
    layer.player = [AVQueuePlayer queuePlayerWithItems:@[]];
    layer.player.muted = YES;
    layer.looper = [AVPlayerLooper playerLooperWithPlayer:layer.player templateItem:item];
    layer.video = [AVPlayerLayer playerLayerWithPlayer:layer.player];
    layer.video.videoGravity = AVLayerVideoGravityResizeAspectFill;
    layer.video.frame = self.bounds;
    [layer addSublayer:layer.video];
    if (!_paused && !_standby) [layer.player play];
  }
  layer.opacity = 0;
  [self.layer insertSublayer:layer below:_wash];

  // Fade the new one in over 3 s, then drop the old one.
  NCClipLayer *old = _current;
  _current = layer;
  [CATransaction begin];
  [CATransaction setAnimationDuration:3];
  [CATransaction setCompletionBlock:^{
    [old.looper disableLooping];
    [old.player pause];
    [old removeFromSuperlayer];
  }];
  layer.opacity = 1;
  [CATransaction commit];
}

- (void)pause {
  _paused = YES;
  [_current.player pause];
  freeze(_current.still, YES);
}

- (void)resume {
  _paused = NO;
  if (_standby) return;
  [_current.player play];
  freeze(_current.still, NO);
}

/// Standby: the clip stops where it is (a still) — decoding video is most
/// of what the old iPad spends in a day — and the drift holds.
- (void)setStandby:(BOOL)standby {
  if (standby == _standby) return;
  _standby = standby;
  if (standby) {
    [_current.player pause];
    freeze(_current.still, YES);
  } else if (!_paused) {
    [_current.player play];
    freeze(_current.still, NO);
  }
}

@end
