//
//  SiriRemote-Bridging-Header.h
//  SiriRemote
//
//  Bridging header to expose MultitouchSupport private framework to Swift
//

#ifndef SiriRemote_Bridging_Header_h
#define SiriRemote_Bridging_Header_h

#import "MultitouchSupport.h"

// Remote-mic demand plus a read-only C bridge for the shared-memory atomics.
#import <notify.h>
#import "RemoteAudioState.h"

#endif /* SiriRemote_Bridging_Header_h */
