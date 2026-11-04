#import <Foundation/Foundation.h>
#include <unistd.h>

// iOS starts apps at "/"
// A writable current directory can trigger jailbreak checks
__attribute__((constructor)) static void configureWorkingDirectory(void) {
    if (chdir("/") != 0) {
        NSLog(@"unipa: Could not set the working directory to /");
    }
}
