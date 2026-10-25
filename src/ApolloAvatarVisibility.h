// Avatar visibility is a presentation-only override. The existing
// "Show User Profile Pictures" preference remains unchanged, so turning
// this privacy switch off restores the user's original avatar preference.
#pragma once
#import "ApolloState.h"

static inline BOOL ApolloInlineUserAvatarsEnabled(void) {
    return sShowUserAvatars && !sHideAllUserAvatars;
}
