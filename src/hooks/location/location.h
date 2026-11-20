#import <Foundation/Foundation.h>

typedef struct {
    double latitude;
    double longitude;
} UnipaCoordinate;

BOOL unipaLocationAvailable(void);
BOOL unipaSimulatedCoordinate(UnipaCoordinate *coordinate);
void unipaSimulateLocation(UnipaCoordinate coordinate);
void unipaUseRealLocation(void);
BOOL unipaParseCoordinate(NSString *text, UnipaCoordinate *coordinate);
