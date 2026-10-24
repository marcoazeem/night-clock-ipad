// The dashboard beside / under the clock. The house is split into rooms
// (ROOMS in lights.json): a home page lists them, and each room has its
// own panel — header with the GN / GM scenes, a square tile per light, a
// tile per AC, the TV card. Port of HomePanel / LightsPanel / AcPanel.

#import <UIKit/UIKit.h>

@class NCLight, NCGreeAc, NCHisenseTv, NCTvBox;

/// One room and the devices in it.
@interface NCRoom : NSObject
@property (nonatomic, copy) NSString *name;
/// What it's also called ("Master Bedroom"), shown under its name.
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSArray<NCLight *> *lights;
@property (nonatomic, copy) NSArray<NCGreeAc *> *acs;
@property (nonatomic, copy) NSArray<NCHisenseTv *> *tvs;
@property (nonatomic, copy) NSArray<NCTvBox *> *boxes;
/// A passcode to open it from the home page (ROOM_PINS), or nil.
@property (nonatomic, copy) NSString *pin;
@property (nonatomic, readonly) BOOL isEmpty;
/// "2 lights · 2 ACs · 1 TV", or "No devices yet".
@property (nonatomic, readonly) NSString *summary;
@end

/// The rooms from ROOMS ("Bedroom (Master)=Bed,Desk; Kitchen="). Without
/// it, one unnamed room holding everything (and no home page).
NSArray<NCRoom *> *NCConfiguredRooms(void);

/// What the clock screen needs from either page.
@protocol NCPanelPage <NSObject>
/// Night mode (23:00–06:00): every colour shifts to deep red.
@property (nonatomic) BOOL night;
/// The page's height, in units, at its full width of 26 units.
- (CGFloat)heightInUnits;
/// Lays the page out for [unit] (it's 26 units wide).
- (void)layoutForUnit:(CGFloat)unit;
- (void)startPolling;
- (void)stopPolling;
/// Whether [point] (in this view) is on an AC dial, which owns
/// press-and-hold there instead of the dimmer.
- (BOOL)isDialAt:(CGPoint)point;
@end

/// One room's controls.
@interface NCPanelView : UIView <NCPanelPage>
/// [room]'s name heads the panel; a nil name shows "ROOM DASHBOARD".
- (instancetype)initWithRoom:(NCRoom *)room;
@property (nonatomic) BOOL night;
/// The header's house icon: back to the home page. Nil with one room.
@property (nonatomic, copy) void (^onHome)(void);
@end

/// A locked room's passcode pad, shown in place of the home page.
@interface NCPinView : UIView <NCPanelPage>
- (instancetype)initWithRoom:(NCRoom *)room;
@property (nonatomic) BOOL night;
/// The house icon: back to the home page.
@property (nonatomic, copy) void (^onCancel)(void);
/// The right code was typed.
@property (nonatomic, copy) void (^onUnlock)(void);
@end

/// The home page: every room as a card.
@interface NCHomeView : UIView <NCPanelPage>
/// [here] is the room this iPad sits in, marked "Here".
- (instancetype)initWithRooms:(NSArray<NCRoom *> *)rooms here:(NSInteger)here;
@property (nonatomic) BOOL night;
@property (nonatomic, copy) void (^onOpen)(NSInteger room);
@end
