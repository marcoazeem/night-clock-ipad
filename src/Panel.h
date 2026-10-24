// The dashboard beside / under the clock: header with the GN / GM scenes,
// a square tile per light, a tile per AC. Port of LightsPanel / AcPanel.

#import <UIKit/UIKit.h>

@interface NCPanelView : UIView
/// Builds tiles for every configured light and AC; nil-safe when none.
- (instancetype)initWithFrame:(CGRect)frame;
@property (nonatomic, readonly) BOOL hasDevices;
/// Night mode (23:00–06:00): every colour shifts to deep red.
@property (nonatomic) BOOL night;
/// The panel's height, in units, at its full width of 26 units.
- (CGFloat)heightInUnits;
/// Lays the tiles out for [unit] (the panel is 26 units wide).
- (void)layoutForUnit:(CGFloat)unit;
- (void)startPolling;
- (void)stopPolling;
/// Whether [point] (in this view) is on an AC dial, which owns
/// press-and-hold there instead of the dimmer.
- (BOOL)isDialAt:(CGPoint)point;
@end
