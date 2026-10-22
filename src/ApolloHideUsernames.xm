// ApolloHideUsernames.xm
// Two independent presentation-only privacy controls:
// 1) Hide Author Usernames: hide known author buttons in posts AND comments.
// 2) Hide Post Author: hide only the post author button in post info and
//    crossposts. This does not remove the rest of PostInfoNode.
//
// Reddit models, post titles, subreddit, score, comment count, and post age
// are never changed. No u/ string matching or delayed regex replacements.

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloSwiftRuntime.h"
#import "ApolloTextureDecls.h"

static NSString *const kApolloHideUsernamesKey = @"ApolloHidePostCommentUsernames";
// Keep the existing defaults key to preserve the user's switch state,
// despite renaming the option from "Hide Post Info" to "Hide Post Author".
static NSString *const kApolloHidePostAuthorKey = @"ApolloHideUsernamesInPostInfo";
static char kApolloHiddenCommentAuthorNodeKey;
static char kApolloHiddenPostAuthorNodeKey;

static BOOL ApolloHideUsernamesEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kApolloHideUsernamesKey];
}

static BOOL ApolloHidePostAuthorEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kApolloHidePostAuthorKey];
}

static NSAttributedString *ApolloEmptyAuthorText(void) {
    static NSAttributedString *emptyText;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        emptyText = [[NSAttributedString alloc] initWithString:@""];
    });
    return emptyText;
}

// No username matching or regex: this is the known author button, not an
// arbitrary text node. The first hook marks it before Texture lays it out.
// The ASTextNode hooks prevent a later attributed-title update from flashing
// the author's name even when network metadata arrives asynchronously.
static void ApolloSuppressAuthorButton(id button, BOOL isComment) {
    BOOL enabled = isComment ? ApolloHideUsernamesEnabled() :
        (ApolloHideUsernamesEnabled() || ApolloHidePostAuthorEnabled());
    if (!enabled || !button || ![button respondsToSelector:@selector(titleNode)]) return;

    id textNode = ((id (*)(id, SEL))objc_msgSend)(button, @selector(titleNode));
    if (!textNode || ![textNode respondsToSelector:@selector(setAttributedText:)]) return;

    // Different markers make the independent switches truly independent;
    // enabling "Hide Post Author" never affects comment author labels.
    const void *marker = isComment
        ? (const void *)&kApolloHiddenCommentAuthorNodeKey
        : (const void *)&kApolloHiddenPostAuthorNodeKey;
    objc_setAssociatedObject(textNode, marker, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL, id))objc_msgSend)(textNode, @selector(setAttributedText:),
                                          ApolloEmptyAuthorText());
}

static void ApolloSuppressAuthorInCell(id cell, BOOL isComment) {
    if (isComment) {
        if (ApolloHideUsernamesEnabled())
            ApolloSuppressAuthorButton(ApolloObjectIvar(cell, "authorNode"), YES);
        return;
    }
    if (!ApolloHideUsernamesEnabled() && !ApolloHidePostAuthorEnabled()) return;
    id postInfo = ApolloObjectIvar(cell, "postInfoNode");
    ApolloSuppressAuthorButton(ApolloObjectIvar(postInfo, "authorButtonNode"), NO);
}

// Crossposts can have a second author button nested inside crosspostNode.
// Only visit known byline ivars; never inspect arbitrary title/comment text.
static void ApolloHideCrosspostAuthorSubtree(id node,
                                             NSMutableSet<NSValue *> *visited,
                                             NSUInteger depth) {
    if (!node || depth > 8 || visited.count >= 100) return;
    NSValue *key = [NSValue valueWithNonretainedObject:node];
    if ([visited containsObject:key]) return;
    [visited addObject:key];

    ApolloSuppressAuthorButton(ApolloObjectIvar(node, "authorNode"), NO);
    ApolloSuppressAuthorButton(ApolloObjectIvar(node, "authorButtonNode"), NO);
    id info = ApolloObjectIvar(node, "postInfoNode");
    if (info) ApolloSuppressAuthorButton(ApolloObjectIvar(info, "authorButtonNode"), NO);

    const char *additionalNodes[] = {
        "originalPostInfoNode", "crosspostInfoNode", "authorInfoNode",
        "originalPostNode", "crosspostParentNode"
    };
    for (NSUInteger i = 0; i < sizeof(additionalNodes)/sizeof(additionalNodes[0]); i++) {
        ApolloHideCrosspostAuthorSubtree(ApolloObjectIvar(node, additionalNodes[i]),
                                         visited, depth + 1);
    }
    if ([node respondsToSelector:@selector(subnodes)]) {
        NSArray *children = ((id (*)(id, SEL))objc_msgSend)(node, @selector(subnodes));
        if ([children isKindOfClass:[NSArray class]]) {
            for (id child in children) {
                ApolloHideCrosspostAuthorSubtree(child, visited, depth + 1);
            }
        }
    }
}

static void ApolloSuppressCrosspostAuthorInCell(id cell) {
    if (!ApolloHideUsernamesEnabled() && !ApolloHidePostAuthorEnabled()) return;
    id crosspost = ApolloObjectIvar(cell, "crosspostNode");
    if (crosspost) {
        ApolloHideCrosspostAuthorSubtree(crosspost, [NSMutableSet set], 0);
    }
}

// Unlike the previous version, preserve PostInfoNode's native layout.
// Hiding the entire node accidentally removed score, comment count, post age,
// subreddit and other metadata. Only the authorButtonNode title is suppressed
// before the node is measured, and its late text changes stay hidden.
%hook _TtC6Apollo12PostInfoNode

- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)range {
    if (ApolloHideUsernamesEnabled() || ApolloHidePostAuthorEnabled()) {
        ApolloSuppressAuthorButton(ApolloObjectIvar((id)self, "authorButtonNode"), NO);
    }
    id spec = %orig;
    if (ApolloHideUsernamesEnabled() || ApolloHidePostAuthorEnabled()) {
        ApolloSuppressAuthorButton(ApolloObjectIvar((id)self, "authorButtonNode"), NO);
    }
    return spec;
}

- (void)didLoad {
    %orig;
    ApolloSuppressAuthorButton(ApolloObjectIvar((id)self, "authorButtonNode"), NO);
}

%end

%hook ASTextNode
- (void)setAttributedText:(NSAttributedString *)text {
    BOOL hideComment = ApolloHideUsernamesEnabled() &&
        [objc_getAssociatedObject(self, &kApolloHiddenCommentAuthorNodeKey) boolValue];
    BOOL hidePost = (ApolloHideUsernamesEnabled() || ApolloHidePostAuthorEnabled()) &&
        [objc_getAssociatedObject(self, &kApolloHiddenPostAuthorNodeKey) boolValue];
    if (hideComment || hidePost) {
        %orig(ApolloEmptyAuthorText());
        return;
    }
    %orig;
}
%end

%hook ASTextNode2
- (void)setAttributedText:(NSAttributedString *)text {
    BOOL hideComment = ApolloHideUsernamesEnabled() &&
        [objc_getAssociatedObject(self, &kApolloHiddenCommentAuthorNodeKey) boolValue];
    BOOL hidePost = (ApolloHideUsernamesEnabled() || ApolloHidePostAuthorEnabled()) &&
        [objc_getAssociatedObject(self, &kApolloHiddenPostAuthorNodeKey) boolValue];
    if (hideComment || hidePost) {
        %orig(ApolloEmptyAuthorText());
        return;
    }
    %orig;
}
%end

%hook _TtC6Apollo15CommentCellNode
- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)range {
    ApolloSuppressAuthorInCell(self, YES);
    return %orig;
}
- (void)didLoad {
    %orig;
    ApolloSuppressAuthorInCell(self, YES);
}
%end

%hook _TtC6Apollo17LargePostCellNode
- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)range {
    ApolloSuppressAuthorInCell(self, NO);
    ApolloSuppressCrosspostAuthorInCell(self);
    id spec = %orig;
    ApolloSuppressCrosspostAuthorInCell(self);
    return spec;
}
- (void)didLoad {
    %orig;
    ApolloSuppressAuthorInCell(self, NO);
    ApolloSuppressCrosspostAuthorInCell(self);
}
%end

%hook _TtC6Apollo19CompactPostCellNode
- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)range {
    ApolloSuppressAuthorInCell(self, NO);
    ApolloSuppressCrosspostAuthorInCell(self);
    id spec = %orig;
    ApolloSuppressCrosspostAuthorInCell(self);
    return spec;
}
- (void)didLoad {
    %orig;
    ApolloSuppressAuthorInCell(self, NO);
    ApolloSuppressCrosspostAuthorInCell(self);
}
%end

%hook _TtC6Apollo22CommentsHeaderCellNode
- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)range {
    ApolloSuppressAuthorInCell(self, NO);
    ApolloSuppressCrosspostAuthorInCell(self);
    id spec = %orig;
    ApolloSuppressCrosspostAuthorInCell(self);
    return spec;
}
- (void)didLoad {
    %orig;
    ApolloSuppressAuthorInCell(self, NO);
    ApolloSuppressCrosspostAuthorInCell(self);
}
%end
