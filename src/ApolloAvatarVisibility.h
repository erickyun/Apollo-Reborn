// Avatar visibility is a presentation-only override. The existing
// "Show User Profile Pictures" preference remains unchanged, so turning
// this privacy switch off restores the user's original avatar preference.
#pragma once
#import "ApolloState.h"

static inline BOOL ApolloInlineUserAvatarsEnabled(void) {
    return sShowUserAvatars && !sHideAllUserAvatars;
}

// Inline avatars are part of the *author's* byline. When that username is
// hidden, rendering an avatar/placeholder beside it produces an orphan dot.
// Keep this scoped to author-bearing cells, not subreddit icons or profiles.
static inline BOOL ApolloInlineAuthorAvatarEnabledForCell(id cell) {
    if (!ApolloInlineUserAvatarsEnabled() || !cell) return NO;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL hideAllAuthors = [defaults boolForKey:@"ApolloHidePostCommentUsernames"];
    BOOL hidePostAuthors = [defaults boolForKey:@"ApolloHideUsernamesInPostInfo"];
    if (!hideAllAuthors && !hidePostAuthors) return YES;

    NSString *className = NSStringFromClass([cell class]);
    if ([className containsString:@"CommentCellNode"]) {
        return !hideAllAuthors;
    }
    if ([className containsString:@"PostCellNode"] ||
        [className containsString:@"CommentsHeaderCellNode"] ||
        [className containsString:@"SaveAsImagePreviewNode"]) {
        return !(hideAllAuthors || hidePostAuthors);
    }
    return YES;
}
