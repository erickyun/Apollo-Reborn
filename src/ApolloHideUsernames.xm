// ApolloHideUsernames.xm
// Two independent presentation-only privacy controls:
// 1) Hide Author Usernames: blank known author buttons in posts/comments.
// 2) Hide Post Info: suppress the entire PostInfoNode layout, not strings
//    matching u/ or any other textual identifier.
//
// Reddit models, post titles and comment bodies are never changed.
// The second preference deliberately also removes subreddit and time labels
// when they share the same metadata row. This avoids a visible flash while
// waiting for text processing, because the node produces an empty layout
// before the feed measures/draws the cell.

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloSwiftRuntime.h"
#import "ApolloTextureDecls.h"

static NSString *const kApolloHideUsernamesKey = @"ApolloHidePostCommentUsernames";
// Preserve the existing defaults key so the old selective toggle's on/off
// state migrates to the new GENERAL "Hide Post Info" switch.
static NSString *const kApolloHidePostInfoKey = @"ApolloHideUsernamesInPostInfo";
static char kApolloHiddenAuthorTextNodeKey;

static BOOL ApolloHideUsernamesEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kApolloHideUsernamesKey];
}

static BOOL ApolloHidePostInfoEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kApolloHidePostInfoKey];
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
static void ApolloSuppressAuthorButton(id button) {
    if (!button || ![button respondsToSelector:@selector(titleNode)]) return;
    id textNode = ((id (*)(id, SEL))objc_msgSend)(button, @selector(titleNode));
    if (!textNode || ![textNode respondsToSelector:@selector(setAttributedText:)]) return;

    objc_setAssociatedObject(textNode, &kApolloHiddenAuthorTextNodeKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL, id))objc_msgSend)(textNode, @selector(setAttributedText:),
                                          ApolloEmptyAuthorText());
}

static void ApolloSuppressAuthorInCell(id cell, BOOL isComment) {
    if (!ApolloHideUsernamesEnabled()) return;
    if (isComment) {
        ApolloSuppressAuthorButton(ApolloObjectIvar(cell, "authorNode"));
        return;
    }
    id postInfo = ApolloObjectIvar(cell, "postInfoNode");
    ApolloSuppressAuthorButton(ApolloObjectIvar(postInfo, "authorButtonNode"));
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

    ApolloSuppressAuthorButton(ApolloObjectIvar(node, "authorNode"));
    ApolloSuppressAuthorButton(ApolloObjectIvar(node, "authorButtonNode"));
    id info = ApolloObjectIvar(node, "postInfoNode");
    if (info) ApolloSuppressAuthorButton(ApolloObjectIvar(info, "authorButtonNode"));

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
    if (!ApolloHideUsernamesEnabled()) return;
    id crosspost = ApolloObjectIvar(cell, "crosspostNode");
    if (crosspost) {
        ApolloHideCrosspostAuthorSubtree(crosspost, [NSMutableSet set], 0);
    }
}

// This runs for ALL post info layouts: feed (compact/large), post detail
// header and nested crosspost post-info nodes. No scanning of "u/" tokens,
// username guessing, attributed-string mutation, or delayed hiding.
%hook _TtC6Apollo12PostInfoNode

- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)range {
    if (!ApolloHidePostInfoEnabled()) return %orig;
    Class stackClass = objc_getClass("ASStackLayoutSpec");
    if (stackClass &&
        [stackClass respondsToSelector:@selector(stackLayoutSpecWithDirection:spacing:justifyContent:alignItems:children:)]) {
        return [(id)stackClass stackLayoutSpecWithDirection:0
                                                  spacing:0
                                           justifyContent:0
                                               alignItems:0
                                                 children:@[]];
    }
    return %orig;
}

- (void)didLoad {
    %orig;
    // A loaded metadata view must not show retained children from a previous
    // layout while the parent is remeasured. Restart Apollo to fully restore
    // existing cached cells when this preference is disabled.
    if (ApolloHidePostInfoEnabled() && [self respondsToSelector:@selector(setHidden:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(self, @selector(setHidden:), YES);
    }
}

%end

%hook ASTextNode
- (void)setAttributedText:(NSAttributedString *)text {
    if (ApolloHideUsernamesEnabled() &&
        [objc_getAssociatedObject(self, &kApolloHiddenAuthorTextNodeKey) boolValue]) {
        %orig(ApolloEmptyAuthorText());
        return;
    }
    %orig;
}
%end

%hook ASTextNode2
- (void)setAttributedText:(NSAttributedString *)text {
    if (ApolloHideUsernamesEnabled() &&
        [objc_getAssociatedObject(self, &kApolloHiddenAuthorTextNodeKey) boolValue]) {
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
