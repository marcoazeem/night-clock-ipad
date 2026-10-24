#import "NC.h"
#import <AVFoundation/AVFoundation.h>

typedef NS_ENUM(NSInteger, NCScene) { NCSceneNight, NCSceneRain, NCSceneMorning, NCSceneDay, NCSceneEvening };

/// The static sky under the video: a diagonal gradient and soft glows, as
/// in _Backdrop. Shows on its own if a clip is missing.
@interface NCGradientSky : UIView
@property (nonatomic) NCScene scene;
@end

@implementation NCGradientSky

- (void)setScene:(NCScene)scene { _scene = scene; [self setNeedsDisplay]; }

static void glow(CGContextRef ctx, CGSize box, CGFloat ax, CGFloat ay, CGFloat size, uint32_t argb) {
  CGPoint c = CGPointMake((ax + 1) / 2 * box.width, (ay + 1) / 2 * box.height);
  CGFloat radius = 0.5 * MIN(box.width * size, box.height * size);
  UIColor *col = NCRGB(argb);
  CGFloat r, g, b, a;
  [col getRed:&r green:&g blue:&b alpha:&a];
  CGFloat comps[] = {r, g, b, a, r, g, b, 0};
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGGradientRef grad = CGGradientCreateWithColorComponents(space, comps, NULL, 2);
  CGContextDrawRadialGradient(ctx, grad, c, 0, c, radius, 0);
  CGGradientRelease(grad);
  CGColorSpaceRelease(space);
}

- (void)drawRect:(CGRect)rect {
  CGContextRef ctx = UIGraphicsGetCurrentContext();
  CGSize box = self.bounds.size;
  uint32_t sky[3];
  switch (self.scene) {
    case NCSceneNight: sky[0] = 0xFF060818; sky[1] = 0xFF020308; sky[2] = 0xFF000000; break;
    case NCSceneRain: sky[0] = 0xFF1C2636; sky[1] = 0xFF101722; sky[2] = 0xFF0B1A22; break;
    case NCSceneMorning: sky[0] = 0xFF3E1F48; sky[1] = 0xFF1D1638; sky[2] = 0xFF0B1C2E; break;
    case NCSceneEvening: sky[0] = 0xFF241044; sky[1] = 0xFF1A0E2E; sky[2] = 0xFF3A1426; break;
    default: sky[0] = 0xFF0B3A73; sky[1] = 0xFF0B2350; sky[2] = 0xFF06283A; break;
  }
  CGFloat comps[12];
  for (int i = 0; i < 3; i++) {
    comps[i * 4] = ((sky[i] >> 16) & 0xFF) / 255.0;
    comps[i * 4 + 1] = ((sky[i] >> 8) & 0xFF) / 255.0;
    comps[i * 4 + 2] = (sky[i] & 0xFF) / 255.0;
    comps[i * 4 + 3] = 1;
  }
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGGradientRef grad = CGGradientCreateWithColorComponents(space, comps, NULL, 3);
  CGContextDrawLinearGradient(ctx, grad, CGPointZero, CGPointMake(box.width, box.height), 0);
  CGGradientRelease(grad);
  CGColorSpaceRelease(space);
  switch (self.scene) {
    case NCSceneRain:
      glow(ctx, box, -0.8, -1, 1.4, 0x664F7BA8);
      glow(ctx, box, 1.2, 0.6, 1.2, 0x332A9D8F);
      break;
    case NCSceneMorning:
      glow(ctx, box, 1.2, 0.15, 1.2, 0x4D00B8A9);
      glow(ctx, box, -0.6, 1.15, 1.3, 0x47E0457B);
      break;
    case NCSceneEvening:
      glow(ctx, box, -1.1, -0.8, 1.2, 0x596A3DFF);
      glow(ctx, box, 0.6, 1.25, 1.5, 0x73FF7A45);
      glow(ctx, box, -0.8, 1.1, 1.2, 0x59E0457B);
      break;
    case NCSceneDay:
      glow(ctx, box, 1.2, 0.2, 1.2, 0x4D22D3EE);
      glow(ctx, box, -0.7, 1.15, 1.3, 0x408B5CF6);
      break;
    default:
      break;
  }
}

@end

/// One of the user's clips with its dark wash: playing and looping by day,
/// a still after dark (the jump at each restart was distracting at night).
@interface NCClipLayer : CALayer
@property (nonatomic, strong) CALayer *still;
@property (nonatomic, strong) AVPlayerLayer *video;
@property (nonatomic, strong) AVQueuePlayer *player;
@property (nonatomic, strong) AVPlayerLooper *looper;
@property (nonatomic, strong) CAGradientLayer *wash;
@property (nonatomic, copy) NSString *key;
@end

@implementation NCClipLayer
@end

@implementation NCSkyView {
  NCGradientSky *_sky;
  NCClipLayer *_current;
  NSString *_washKey;
  BOOL _paused;
}

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.backgroundColor = UIColor.blackColor;
    self.userInteractionEnabled = NO;
    // Muted anyway, but ambient so it never stops music playing.
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient error:nil];
    _sky = [[NCGradientSky alloc] initWithFrame:self.bounds];
    _sky.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _sky.contentMode = UIViewContentModeRedraw;
    [self addSubview:_sky];
  }
  return self;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  for (CALayer *l in self.layer.sublayers) {
    if (![l isKindOfClass:NCClipLayer.class]) continue;
    NCClipLayer *c = (NCClipLayer *)l;
    c.frame = self.bounds;
    c.still.frame = self.bounds;
    c.video.frame = self.bounds;
    c.wash.frame = self.bounds;
  }
  [CATransaction commit];
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
  NSInteger h = NCHour(now);
  NCScene scene = dark ? NCSceneNight
                : raining ? NCSceneRain
                : NCIsMorning(now) ? NCSceneMorning
                : (h >= 17 && h < 19) ? NCSceneEvening
                : NCSceneDay;
  if (scene != _sky.scene) _sky.scene = scene;

  // The user's clips: rainy whenever it rains (after dark too, much
  // darker), else night after dark and sunny all day. After dark, a still.
  NSString *clip = raining ? @"rainy" : dark ? @"night" : @"sunny";
  BOOL still = dark;
  NSString *key = [clip stringByAppendingString:still ? @".jpg" : @".mp4"];
  BOOL veryDark = dark && raining, dim = night || veryDark;
  NSString *washKey = veryDark ? @"veryDark" : dim ? @"dim" : @"normal";
  if ([key isEqualToString:_current.key]) {
    if (![washKey isEqualToString:_washKey]) [self setWash:washKey on:_current];
    return;
  }

  NSString *path = [[NSBundle mainBundle] pathForResource:clip ofType:still ? @"jpg" : @"mp4"];
  if (!path) return;  // Not in this build: the drawn sky stays.
  NCClipLayer *layer = [NCClipLayer layer];
  layer.key = key;
  layer.frame = self.bounds;
  if (still) {
    UIImage *image = [UIImage imageWithContentsOfFile:path];
    if (!image) return;
    layer.still = [CALayer layer];
    layer.still.contents = (id)image.CGImage;
    layer.still.contentsGravity = kCAGravityResizeAspectFill;
    layer.still.masksToBounds = YES;
    layer.still.frame = self.bounds;
    [layer addSublayer:layer.still];
  } else {
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:path]];
    layer.player = [AVQueuePlayer queuePlayerWithItems:@[]];
    layer.player.muted = YES;
    layer.looper = [AVPlayerLooper playerLooperWithPlayer:layer.player templateItem:item];
    layer.video = [AVPlayerLayer playerLayerWithPlayer:layer.player];
    layer.video.videoGravity = AVLayerVideoGravityResizeAspectFill;
    layer.video.frame = self.bounds;
    [layer addSublayer:layer.video];
    if (!_paused) [layer.player play];
  }
  layer.wash = [CAGradientLayer layer];
  layer.wash.frame = self.bounds;
  [layer addSublayer:layer.wash];
  [self setWash:washKey on:layer];
  layer.opacity = 0;
  [self.layer addSublayer:layer];

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

- (void)setWash:(NSString *)key on:(NCClipLayer *)layer {
  _washKey = key;
  uint32_t c[3];
  if ([key isEqualToString:@"veryDark"]) { c[0] = 0xE0000000; c[1] = 0xCC000000; c[2] = 0xE0000000; }
  else if ([key isEqualToString:@"dim"]) { c[0] = 0xB3000000; c[1] = 0x8C000000; c[2] = 0xB3000000; }
  else { c[0] = 0x99000000; c[1] = 0x59000000; c[2] = 0x80000000; }
  layer.wash.colors = @[(id)NCRGB(c[0]).CGColor, (id)NCRGB(c[1]).CGColor, (id)NCRGB(c[2]).CGColor];
  layer.wash.locations = @[@0, @0.45, @1];
}

- (void)pause { _paused = YES; [_current.player pause]; }
- (void)resume { _paused = NO; [_current.player play]; }

@end
