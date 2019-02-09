//
//  RVLLocation.m
//  Pods
//
//  Created by Bobby Skinner on 3/1/16.
//
//  NOTE: This file is structured strangely to
//        facilitate using the file indepandantly
//        not for logical code separation

#import <UIKit/UIKit.h>
#import "RVLLocation.h"
#import "Reveal.h"
#import <AdSupport/AdSupport.h>

#define LOG       \
    if (self.log) \
    self.log

#ifndef objc_dynamic_cast
#define objc_dynamic_cast(TYPE, object)                                       \
    ({                                                                        \
        TYPE *dyn_cast_object = (TYPE *)(object);                             \
        [dyn_cast_object isKindOfClass:[TYPE class]] ? dyn_cast_object : nil; \
    })
#endif

typedef void (^Callback)(void);

@interface LocationListener : NSObject

@property (nonatomic, strong) NSTimer * timeoutTimer;
@property (nonatomic, strong) Callback callback;
@property (nonatomic, strong) Callback completion;
@property (nonatomic, readonly) BOOL didExecute;

@end

@implementation LocationListener

- (instancetype)initWithTimeout:(NSTimeInterval)timeout
{
    self = [super init];
    
    if (timeout)
    {
        _timeoutTimer = [NSTimer scheduledTimerWithTimeInterval:timeout target:self selector:@selector(listenerExpired:) userInfo:nil repeats:NO];
    }
    
    return self;
}

-(void)listenerExpired:(NSTimer*)timer
{
    [self executeCallback];
}

-(void)executeCallback
{
    @synchronized(self)
    {
        if (_didExecute != YES) {
            if (_callback != nil) {
                dispatch_async(dispatch_get_main_queue(), ^{
                   _callback();
                });
            }
            _didExecute = YES;
            if (self.timeoutTimer != nil) {
                [self.timeoutTimer invalidate];
            }
            if (_completion != nil) {
                dispatch_async(dispatch_get_main_queue(), ^{
                   _completion();
                });
            }
        }
    }
}

-(void)dealloc {
    if (self.timeoutTimer != nil) {
        [self.timeoutTimer invalidate];
    }
}
@end

@interface RVLLocation () <CLLocationManagerDelegate>

// Core location reference
@property (nonatomic, strong) CLLocationManager *locationManager;

// time of the last geolocation update
@property (nonatomic, strong) NSDate *locationTime;

// list of active monitors for location changes
@property (nonatomic, strong) NSMutableArray * locationListeners;

@end

@implementation RVLLocation

@synthesize locationUpdated;

+ (RVLLocation *)sharedManager
{
    static dispatch_once_t onceToken;
    static RVLLocation *sharedInstance = nil;

    dispatch_once(&onceToken, ^{
      sharedInstance = [[RVLLocation alloc] init];
    });

    return sharedInstance;
}

- (instancetype)init
{
    self = [super init];

    if (self)
    {
        // setup defaults
        self.locationRetainTime = 60000.0;
        self.distanceFilter = 100;
        self.accuracy = kCLLocationAccuracyHundredMeters;
        self.backgroundAccuracy = kCLLocationAccuracyThreeKilometers;
        self.useSignifigantChange = NO;
        self.useSignifigantChangeInBackground = YES;
        
        self.locationListeners = [NSMutableArray array];

        dispatch_async( dispatch_get_main_queue(), ^{
            // stop any pre-existing manager
            [self.locationManager stopUpdatingLocation];
            
            // create a new one
            self.locationManager = [[CLLocationManager alloc] init];
            self.locationManager.delegate = self;
            self.locationManager.distanceFilter = self.distanceFilter;
            self.locationManager.desiredAccuracy = self.accuracy;
            self.locationManager.pausesLocationUpdatesAutomatically = NO;
            self.userLocation = [self.locationManager location];
        });
    }

    return self;
}

- (void) refreshLocationState
{
    [self stopLocationMonitoring:^{
        [self startLocationMonitoring];
    }];
}

- (void)startLocationMonitoring
{
    [self startLocationMonitoring: nil];
}

- (void)startLocationMonitoring:(void (^_Nullable)(void))completed
{
    [[Reveal sharedInstance] setStatus: STATUS_LOCATION  value: 0 message: @"Starting location monitoring"];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if ( [[Reveal sharedInstance] inBackground] )
            self.locationManager.desiredAccuracy = self.backgroundAccuracy;
        else
            self.locationManager.desiredAccuracy = self.accuracy;
    });
    LOG( @"LOCATION", @"startLocationManager with accuracy: %.1f", self.locationManager.desiredAccuracy );
    
    if ( ![[ASIdentifierManager sharedManager] isAdvertisingTrackingEnabled] ) {
        LOG( @"LOCATION", @"Not requesting location since ad tracking is disabled");
        [[Reveal sharedInstance] setStatus: STATUS_BLUETOOTH value: 2 message: @"Disabled because no Ad ID provided"];
    }
    else if ([CLLocationManager authorizationStatus] == kCLAuthorizationStatusAuthorizedAlways || [CLLocationManager authorizationStatus] == kCLAuthorizationStatusAuthorizedWhenInUse ) {
        LOG( @"LOCATION", @"Location Authorization already granted, beginning location updates");
        [self beginLocationUpdates];
    }
    else if ([[Reveal sharedInstance] canRequestLocationPermission]) {
        // Must set up locationManager on main thread or no callbacks!
        switch ([[Reveal sharedInstance] locationServiceType])
        {
            case RVLLocationServiceTypeAlways:
                LOG(@"INFO", @"Requesting location permission ALWAYS");
                if ( [self.locationManager respondsToSelector: @selector(requestAlwaysAuthorization)] ) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.locationManager requestAlwaysAuthorization];
                    });
                }
                [self beginLocationUpdates];
                break;

            case RVLLocationServiceTypeInUse:
                LOG(@"INFO", @"Requesting location permission IN USE");
                if ( [self.locationManager respondsToSelector: @selector(requestWhenInUseAuthorization)] ) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.locationManager requestWhenInUseAuthorization];
                    });
                }
                [self beginLocationUpdates];
                break;

            default:
                LOG(@"ERROR", @"Locations services must be setup for proper operation");
                break;
        }
    }
}

- (void)beginLocationUpdates {
    // If we are in the background and using significant change in background or we are just by default using significant change, then start that
    if ( ( [[Reveal sharedInstance] inBackground] && self.useSignifigantChangeInBackground ) || ( self.useSignifigantChange ) ) {
        LOG( @"INFO", @"Starting location monitoring (SIGNIFIGANT CHANGE)" );
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.locationManager startMonitoringSignificantLocationChanges];
        });
    }
    else {
        LOG( @"INFO", @"Starting location monitoring with distance filter (%dm)", (int) self.distanceFilter );
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.locationManager startUpdatingLocation];
        });
    }
}

- (void)stopLocationMonitoring
{
    [[Reveal sharedInstance] setStatus: STATUS_LOCATION  value: 0 message: @"Stopped location monitoring"];
    [self stopLocationMonitoring: nil];
}

- (void)stopLocationMonitoring:(void (^_Nullable)(void))completed
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.locationManager stopUpdatingLocation];
        
        if ( completed )
            completed();
    });
}

- (BOOL)isLocationCurrent
{
    NSTimeInterval interval = [self.userLocation.timestamp timeIntervalSinceNow];
    
    if (self.userLocation == nil || interval < -60000.0)
        return NO;
    else
        return YES;
}

- (void) waitForValidLocation:(void (^)(void))callback
{
    if ( self.isLocationCurrent )
    {
        callback();
    }
    else
    {
        __weak RVLLocation* me = self;
        LocationListener * locationListener = [[LocationListener alloc] initWithTimeout:30];
        __weak LocationListener* weakListener = locationListener;
        
        [locationListener setCallback:callback];
        [locationListener setCompletion:^{
            // upon completion, remove object from array of location listeners
            
            @synchronized(me.locationListeners)
            {
                [me.locationListeners removeObject: weakListener];
            }
        }];
        @synchronized(self.locationListeners)
        {
            [self.locationListeners addObject:locationListener];
        }
    }
}

- (void)setUserLocation:(CLLocation *)userLocation
{
    if (userLocation != nil)
    {
        _userLocation = userLocation;
        if (self.isLocationCurrent) {
            dispatch_async( dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_DEFAULT, 0 ), ^{
                for (LocationListener* locationListener in self.locationListeners) {
                    [locationListener executeCallback];
                }
            });
        }
    }
}

#pragma mark - CLLocationManagerDelegate -

- (void)locationManager:(CLLocationManager *)manager didChangeAuthorizationStatus:(CLAuthorizationStatus)status {
    if ( ( status == kCLAuthorizationStatusAuthorizedAlways )
        || ( status == kCLAuthorizationStatusAuthorizedWhenInUse ) ) {
        [[Reveal sharedInstance] setStatus: STATUS_LOCATION  value: 0 message: @"Starting location monitoring"];
        [[Reveal sharedInstance] restart];
    }
    else {
        [[Reveal sharedInstance] setStatus: STATUS_LOCATION  value: 0 message: @"No permission to monitor location provided"];
        
        [[Reveal sharedInstance] stop];
    }
}

-(void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    LOG(@"LOCATION", @"Location error: %@", error );
    [[Reveal sharedInstance] setStatus: STATUS_LOCATION  value: 0 message: [error localizedDescription]];
}

- (void)locationManager:(CLLocationManager *)manager
     didUpdateLocations:(NSArray *)locations
{
    CLLocation *newLocation = [locations lastObject];
    
    LOG(@"LOCATION", @"New location from OS: %@", newLocation );
    [[Reveal sharedInstance] setStatus: STATUS_LOCATION  value: 1 message: @"Received location update"];

    CLLocation* oldLocation = [self userLocation];
    [self setUserLocation:newLocation];

    if ([self.passThroughDelegate respondsToSelector:@selector(locationManager:didUpdateLocations:)])
        [self.passThroughDelegate locationManager:manager didUpdateLocations:locations];
    
    if ( newLocation && [self locationUpdated] ) {
        self.locationUpdated( newLocation, oldLocation );
    }
}

- (void)locationManager:(CLLocationManager *)manager
      didDetermineState:(CLRegionState)state
              forRegion:(CLRegion *)region
{
    if ([self.passThroughDelegate respondsToSelector:@selector(locationManager:didDetermineState:forRegion:)])
        [self.passThroughDelegate locationManager:manager
                                didDetermineState:state
                                        forRegion:region];
}

- (void)locationManager:(CLLocationManager *)manager
    monitoringDidFailForRegion:(CLRegion *)region
                     withError:(NSError *)error
{
    if ([self.passThroughDelegate respondsToSelector:@selector(locationManager:monitoringDidFailForRegion:withError:)])
        [self.passThroughDelegate locationManager:manager
                       monitoringDidFailForRegion:region
                                        withError:error];
}

- (void)locationManager:(CLLocationManager *)manager
    rangingBeaconsDidFailForRegion:(CLBeaconRegion *)region
                         withError:(NSError *)error
{
    if ([self.passThroughDelegate respondsToSelector:@selector(locationManager:rangingBeaconsDidFailForRegion:withError:)])
        [self.passThroughDelegate locationManager:manager
                   rangingBeaconsDidFailForRegion:region
                                        withError:error];
}

- (void)locationManager:(CLLocationManager *)manager didRangeBeacons:(NSArray *)beacons inRegion:(CLBeaconRegion *)region
{
    if ([self.passThroughDelegate respondsToSelector:@selector(locationManager:didRangeBeacons:inRegion:)])
        [self.passThroughDelegate locationManager:manager
                                  didRangeBeacons:beacons
                                         inRegion:region];
}

@end
