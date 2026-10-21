// ApolloHideUsernames.xm
// Hide post/comment author bylines without modifying Reddit models or content.
// The author nodes are known Apollo Texture ivars (see ApolloUserAvatars.xm).
// This is a local display setting; the real author remains unchanged and links
// can still be accessed from Reddit's data or the author's profile.

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloSwiftRuntime.h"
#import "ApolloTextureDecls.h"

// Keep in sync with the switch in ApolloSettingsNativeInjections.xm.
static NSString *const kApolloHideUsernamesKey = @"ApolloHidePostCommentUsernames";
static char kApolloHiddenAuthorTextNodeKey;

static BOOL ApolloHideUsernamesEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kApolloHideUsernamesKey];
}

// Author buttons are distinct from title and flair nodes. Never scan text for
// strings matching usernames: a post title or comment body may mention one.
static id ApolloAuthorButtonForCell(id cell, BOOL isComment) {
    if (isComment) return ApolloObjectIvar(cell, "authorNode");

    id infoNode = ApolloObjectIvar(cell, "postInfoNode");
    if (!infoNode) return nil;
    // A feed showing subreddit instead of author has no authorButtonNode.
    return ApolloObjectIvar(infoNode, "authorButtonNode");
}

static NSAttributedString *ApolloEmptyAuthorText(void) {
    static NSAttributedString *empty;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        empty = [[NSAttributedString alloc] initWithString:@""];
    });
    return empty;
}

// Called at measure time before the author is laid out, and at didLoad for
// late-resolved author nodes. This affects only this button's title text node.
static void ApolloSuppressAuthorInCell(id cell, BOOL isComment) {
    if (!ApolloHideUsernamesEnabled()) return;
    id button = ApolloAuthorButtonForCell(cell, isComment);
    if (!button || ![button respondsToSelector:@selector(titleNode)]) return;

    id textNode = ((id (*)(id, SEL))objc_msgSend)(button, @selector(titleNode));
    if (!textNode || ![textNode respondsToSelector:@selector(setAttributedText:)]) return;

    // Mark the exact author node. Apollo (and the inline-avatar feature) may
    // replace the attributed title asynchronously after this cell is measured.
    // The ASTextNode hooks below keep later replacements hidden too.
    objc_setAssociatedObject(textNode, &kApolloHiddenAuthorTextNodeKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSAttributedString *current = [textNode respondsToSelector:@selector(attributedText)]
        ? ((id (*)(id, SEL))objc_msgSend)(textNode, @selector(attributedText))
        : nil;
    if (current.length) {
        ((void (*)(id, SEL, id))objc_msgSend)(textNode, @selector(setAttributedText:),
                                              ApolloEmptyAuthorText());
    }
}

static BOOL ApolloIsMarkedHiddenAuthor(id node) {
    // Most text nodes are unrelated: avoid a defaults lookup for every title,
    // comment body, flair, and button text assignment.
    return [objc_getAssociatedObject(node, &kApolloHiddenAuthorTextNodeKey) boolValue] &&
           ApolloHideUsernamesEnabled();
}

// Texture uses both text-node implementations. Do not touch ordinary nodes:
// usernames within post titles/comments, flairs, and profile screens survive.
%hook ASTextNode
- (void)setAttributedText:(NSAttributedString *)text {
    if (ApolloIsMarkedHiddenAuthor(self)) {
        %orig(ApolloEmptyAuthorText());
        return;
    }
    %orig;
}
%end

%hook ASTextNode2
- (void)setAttributedText:(NSAttributedString *)text {
    if (ApolloIsMarkedHiddenAuthor(self)) {
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
    return %orig;
}
- (void)didLoad {
    %orig;
    ApolloSuppressAuthorInCell(self, NO);
}
%end

%hook _TtC6Apollo19CompactPostCellNode
- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)range {
    ApolloSuppressAuthorInCell(self, NO);
    return %orig;
}
- (void)didLoad {
    %orig;
    ApolloSuppressAuthorInCell(self, NO);
}
%end

%hook _TtC6Apollo22CommentsHeaderCellNode
- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)range {
    ApolloSuppressAuthorInCell(self, NO);
    return %orig;
}
- (void)didLoad {
    %orig;
    ApolloSuppressAuthorInCell(self, NO);
}
%end
