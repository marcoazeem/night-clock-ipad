#import "NC.h"
#import "Panel.h"

// The dimmer runs in two stages, as on the phone: the top of the range
// walks the backlight down to its floor, the bottom fades the pixels.
static const CGFloat kPanelFloor = 0.4;
static const CGFloat kMinOpacity = 0.12;

@interface NCClockViewController () <UIGestureRecognizerDelegate>
@end

/// Tells its owner about every touch, before anything handles it — for the
/// walk back to this iPad's own room.
@interface NCTouchView : UIView
@property (nonatomic, copy) void (^onTouch)(void);
@end

@implementation NCTouchView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
  if (event.type == UIEventTypeTouches && self.onTouch) self.onTouch();
  return [super hitTest:point withEvent:event];
}
@end

/// Back to this iPad's own room after this long untouched.
static const NSTimeInterval kIdleReturn = 120;

@implementation NCClockViewController {
  NSArray<NCRoom *> *_rooms;
  NSMutableDictionary<NSNumber *, NCPanelView *> *_pages;  // built on first visit
  NCHomeView *_home;
  UIView<NCPanelPage> *_panel;  // the page on screen
  NSInteger _homeRoom, _room;   // _room -1: the home page
  NSTimer *_idle;
  BOOL _active;
  NCSkyView *_sky;
  NCTouchView *_content;  // everything, faded by the pixel stage of the dimmer
  NCFaceView *_face;
  UILabel *_hint;
  UIView *_dimBadge;
  UILabel *_dimLabel;
  NCWeather *_weather;
  NSTimer *_tick, *_weatherTimer;
  CGFloat _dim, _dimFrom;
  BOOL _adjusting;
  CGFloat _systemBrightness;
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.blackColor;

  _content = [[NCTouchView alloc] initWithFrame:self.view.bounds];
  __weak NCClockViewController *weakSelf = self;
  _content.onTouch = ^{ [weakSelf touched]; };
  _content.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.view addSubview:_content];

  _sky = [[NCSkyView alloc] initWithFrame:_content.bounds];
  _sky.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [_content addSubview:_sky];

  _face = [[NCFaceView alloc] initWithFrame:CGRectZero];
  [_content addSubview:_face];

  _rooms = NCConfiguredRooms();
  _pages = [NSMutableDictionary dictionary];
  _homeRoom = 0;
  NSString *start = [@START_ROOM stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  for (NSUInteger i = 0; i < _rooms.count; i++)
    if (_rooms[i].name && [_rooms[i].name caseInsensitiveCompare:start] == NSOrderedSame) _homeRoom = i;

  _hint = [UILabel new];
  _hint.text = @"press & hold, then slide up / down to dim";
  _hint.textColor = [UIColor colorWithWhite:1 alpha:0.35];
  _hint.font = [UIFont systemFontOfSize:15];
  _hint.textAlignment = NSTextAlignmentCenter;
  [_content addSubview:_hint];
  [self showRoom:_homeRoom];

  _dimBadge = [UIView new];
  _dimBadge.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
  _dimBadge.layer.cornerRadius = 22;
  _dimBadge.layer.borderWidth = 1;
  _dimBadge.layer.borderColor = [UIColor colorWithWhite:0.91 alpha:0.10].CGColor;
  _dimBadge.hidden = YES;
  _dimLabel = [UILabel new];
  _dimLabel.textColor = NCRGB(0xFFE8E8E8);
  _dimLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
  _dimLabel.textAlignment = NSTextAlignmentCenter;
  [_dimBadge addSubview:_dimLabel];
  [_content addSubview:_dimBadge];

  UILongPressGestureRecognizer *press =
      [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onPress:)];
  press.minimumPressDuration = 0.4;
  press.delegate = self;
  [self.view addGestureRecognizer:press];

  NSNumber *saved = [[NSUserDefaults standardUserDefaults] objectForKey:@"dim"];
  _dim = saved ? MAX(0, MIN(1, saved.doubleValue)) : 0.55;
  _systemBrightness = UIScreen.mainScreen.brightness;

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    [UIView animateWithDuration:1 animations:^{ self->_hint.alpha = 0; }];
  });
}

- (BOOL)hasPanel { return _rooms.count > 1 || !_rooms.firstObject.isEmpty; }

/// Shows room [index], or the home page for -1.
- (void)showRoom:(NSInteger)index {
  if (![self hasPanel]) return;
  UIView<NCPanelPage> *page;
  if (index < 0) {
    if (!_home) {
      _home = [[NCHomeView alloc] initWithRooms:_rooms here:_homeRoom];
      __weak NCClockViewController *weak = self;
      _home.onOpen = ^(NSInteger i) { [weak openRoom:i]; };
    }
    page = _home;
  } else {
    page = _pages[@(index)];
    if (!page) {
      NCPanelView *p = [[NCPanelView alloc] initWithRoom:_rooms[index]];
      if (_rooms.count > 1) {
        __weak NCClockViewController *weak = self;
        p.onHome = ^{ [weak showRoom:-1]; };
      }
      _pages[@(index)] = p;
      page = p;
    }
  }
  _room = index;
  BOOL home = index < 0;
  if (home != _sky.home) {
    _sky.home = home;
    [_sky updateForNow:[NSDate date] raining:_weather.raining];
  }
  [self present:page];
}

/// Swaps [page] in under the hint, fading it in.
- (void)present:(UIView<NCPanelPage> *)page {
  if (page == _panel) return;
  [_panel stopPolling];
  [_panel removeFromSuperview];
  _panel = page;
  _panel.night = NCIsNight([NSDate date]);
  [_content insertSubview:_panel belowSubview:_hint];
  _panel.alpha = 0;
  [self.view setNeedsLayout];
  [self.view layoutIfNeeded];
  [UIView animateWithDuration:0.25 animations:^{ self->_panel.alpha = 1; }];
  if (_active) [_panel startPolling];
}

/// From the home page: a locked room (ROOM_PINS) asks for its passcode
/// first, in the panel's place; this iPad's own room never does.
- (void)openRoom:(NSInteger)index {
  NCRoom *room = _rooms[index];
  if (!room.pin.length || index == _homeRoom) {
    [self showRoom:index];
    return;
  }
  NCPinView *pin = [[NCPinView alloc] initWithRoom:room];
  __weak NCClockViewController *weak = self;
  pin.onCancel = ^{ [weak showRoom:-1]; };
  pin.onUnlock = ^{ [weak showRoom:index]; };
  _room = -1;  // still "on the home page" for the idle walk back
  [self present:pin];
}

/// Any touch restarts the walk back to this iPad's own room.
- (void)touched {
  if (_rooms.count < 2) return;
  [_idle invalidate];
  _idle = [NSTimer scheduledTimerWithTimeInterval:kIdleReturn target:self
                                         selector:@selector(goHomeRoom) userInfo:nil repeats:NO];
}

- (void)goHomeRoom {
  if (_room != _homeRoom) [self showRoom:_homeRoom];
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  CGSize size = self.view.bounds.size;
  CGFloat inset = 16;
  CGRect area = CGRectInset(self.view.bounds, inset, inset);
  CGRect clock = area;
  if (_panel) {
    // The panel is 26 units wide; the unit is as big as fits. On its side
    // the panel takes at most half the width, on the right; standing, it
    // goes under the clock and leaves it 0.4 of the width in height.
    BOOL landscape = size.width > size.height;
    CGFloat gap = MIN(size.width, size.height) * 0.04, hu = [_panel heightInUnits];
    CGFloat maxW = landscape ? area.size.width * 0.5 : area.size.width;
    CGFloat maxH = landscape ? area.size.height : area.size.height - gap - area.size.width * 0.4;
    CGFloat u = floor(MIN(maxW / 26, maxH / hu) * 2) / 2;
    CGFloat pw = u * 26, ph = u * hu;
    if (landscape) {
      _panel.frame = CGRectMake(CGRectGetMaxX(area) - pw, CGRectGetMidY(area) - ph / 2, pw, ph);
      clock.size.width -= pw + gap;
    } else {
      _panel.frame = CGRectMake(CGRectGetMidX(area) - pw / 2, CGRectGetMaxY(area) - ph, pw, ph);
      clock.size.height -= ph + gap;
    }
    [_panel layoutForUnit:u];
  }
  // The face fills 90% of what's left, centred.
  CGFloat fw = clock.size.width * 0.9, fh = clock.size.height * 0.9;
  _face.frame = CGRectMake(CGRectGetMidX(clock) - fw / 2, CGRectGetMidY(clock) - fh / 2, fw, fh);
  // Over the clock, clear of the panel's header.
  _hint.frame = CGRectMake(clock.origin.x, clock.origin.y, clock.size.width, 24);
  _hint.adjustsFontSizeToFitWidth = YES;
  _dimBadge.frame = CGRectMake(size.width / 2 - 70, MIN(size.width, size.height) * 0.08, 140, 44);
  _dimLabel.frame = _dimBadge.bounds;
}

// ── Lifecycle ────────────────────────────────────────────────────────────

- (void)appDidBecomeActive {
  [UIApplication sharedApplication].idleTimerDisabled = YES;
  _systemBrightness = UIScreen.mainScreen.brightness;
  [self refreshNow];
  [self scheduleTick];
  [self refreshWeather];
  [_weatherTimer invalidate];
  _weatherTimer = [NSTimer scheduledTimerWithTimeInterval:15 * 60 target:self
                                                 selector:@selector(refreshWeather) userInfo:nil repeats:YES];
  [_sky resume];
  _active = YES;
  [_panel startPolling];
  [self applyDim];
}

- (void)appWillResignActive {
  [_tick invalidate];
  [_weatherTimer invalidate];
  [_sky pause];
  _active = NO;
  [_panel stopPolling];
  // Give the iPad its own brightness back.
  UIScreen.mainScreen.brightness = _systemBrightness;
}

/// Redraw at the next minute boundary — once a minute.
- (void)scheduleTick {
  [_tick invalidate];
  NSDate *now = [NSDate date];
  NSTimeInterval t = now.timeIntervalSinceReferenceDate;
  NSTimeInterval wait = 60 - fmod(t, 60) + 0.05;
  _tick = [NSTimer scheduledTimerWithTimeInterval:wait target:self
                                         selector:@selector(onTick) userInfo:nil repeats:NO];
}

- (void)onTick {
  [self refreshNow];
  [self scheduleTick];
}

- (void)refreshNow {
  NSDate *now = [NSDate date];
  _face.now = now;
  _panel.night = NCIsNight(now);
  [_sky updateForNow:now raining:_weather.raining];
}

- (void)refreshWeather {
  [NCWeather fetch:^(NCWeather *w) {
    if (!w) return;  // Offline: keep the last reading.
    self->_weather = w;
    self->_face.weather = w;
    [self->_sky updateForNow:[NSDate date] raining:w.raining];
  }];
}

// ── Dimmer ───────────────────────────────────────────────────────────────

/// Press-and-hold dims anywhere except on an AC dial, which uses it to set
/// the temperature.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)touch {
  return ![_panel isDialAt:[touch locationInView:_panel]];
}

- (void)applyDim {
  CGFloat panel = _dim <= kPanelFloor ? 0 : (_dim - kPanelFloor) / (1 - kPanelFloor);
  CGFloat pixels = _dim >= kPanelFloor ? 1 : kMinOpacity + (_dim / kPanelFloor) * (1 - kMinOpacity);
  UIScreen.mainScreen.brightness = panel;
  _content.alpha = pixels;
}

- (void)onPress:(UILongPressGestureRecognizer *)g {
  static CGFloat startY;
  CGPoint p = [g locationInView:self.view];
  switch (g.state) {
    case UIGestureRecognizerStateBegan:
      _dimFrom = _dim;
      startY = p.y;
      _dimBadge.hidden = NO;
      break;
    case UIGestureRecognizerStateChanged:
      _dim = MAX(0, MIN(1, _dimFrom - (p.y - startY) / 400));
      [self applyDim];
      break;
    default:
      _dimBadge.hidden = YES;
      [[NSUserDefaults standardUserDefaults] setDouble:_dim forKey:@"dim"];
      return;
  }
  _dimLabel.text = [NSString stringWithFormat:@"☀︎ %ld%%", lround(_dim * 100)];
}

@end
