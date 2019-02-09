//
//  RVLLocation.h
//  Pods
//
//  Created by Bobby Skinner on 3/1/16.
//
//  NOTE: This file is structured strangely to
//        facilitate using the file indepandantly
//        not for logical code separation

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import "Reveal.h"

/**
 *  The location manager class manages location services for the SDK.
 *  You can chose not to use this class and provide your own location 
 *  management and chose not to use this one.
 */
@interface RVLLocation : NSObject <RVLLocationService>

#pragma mark - Properties -

/**
 *  The last known location for the current user
 */
@property (nonatomic, strong, nullable) CLLocation *  userLocation;

/**
 *  The last known user coordinante
 */
@property (nonatomic, assign, readonly) CLLocationCoordinate2D userCoordinate;

/**
 *  The amount of time to consider the location current
 */
@property (nonatomic, assign) NSTimeInterval locationRetainTime;

/**
 *  Determine if the current location is recent enough to be trusted
 */
@property (readonly) BOOL isLocationCurrent;

/**
 *  provide a routine to perform logging functionality
 */
@property (nonatomic, assign) void (* _Nullable log)( NSString* _Nonnull type, NSString * _Nonnull format, ...);

/**
 *  The internal location manager
 */
@property (readonly, nullable) CLLocationManager *locationManager;

/**
 *  Delegate to forward locationManager delegate methods
 */
@property (nonatomic, weak, nullable) id <CLLocationManagerDelegate> passThroughDelegate;

/**
 The requested change to trigger notification if not using signifigant change
 */
@property (nonatomic, assign) NSInteger distanceFilter;

/**
 Enable this to allow apple to manage the notifications
 */
@property (nonatomic, assign) BOOL useSignifigantChange;

/**
 Enable this to allow apple to manage the notifications
 */
@property (nonatomic, assign) BOOL useSignifigantChangeInBackground;

/**
 The desired location accuracy
 */
@property (nonatomic, assign) CLLocationAccuracy accuracy;

/**
 The desired location accuracy while in background
 */
@property (nonatomic, assign) CLLocationAccuracy backgroundAccuracy;

#pragma mark - Primary API -

/**
 *  Get the shared location manager.
 *
 *  @return the shared instance
 */
+ (RVLLocation*_Nonnull) sharedManager;

/**
 *  Start monitoring location services. If your bundle contains the
 *  NSLocationWhenInUseUsageDescription string then requestWhenInUseAuthorization 
 *  will be called, otherwise if NSLocationAlwaysUsageDescription is provided
 *  then requestAlwaysAuthorization will be called. If neither string is present
 *  then location services will net be started.
 */
- (void) startLocationMonitoring;
- (void)startLocationMonitoring:(void (^_Nullable)(void))completed;

/**
 *  stop monitoring location changes
 */
- (void) stopLocationMonitoring;
- (void)stopLocationMonitoring:(void (^_Nullable)(void))completed;

- (void) refreshLocationState;

/**
 *  Allows functions that need a valid location to wait for a valid location to be available 
 *  If there is already a valid location available, then the callback returns immediately, otherwise, the callback waits until
 *  there is a valid location or a timeout, in which case the best location we can find will be used
 * 
 *  @param callback The method to call when a valid location is available
 */
- (void) waitForValidLocation:(void (^_Nullable)(void))callback;


@end
