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
// late-resolved author nodes. Also used for nested crosspost author buttons.
static void ApolloSuppressAuthorButton(id button) {
    if (!ApolloHideUsernamesEnabled()) return;
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

static void ApolloSuppressAuthorInCell(id cell, BOOL isComment) {
    ApolloSuppressAuthorButton(ApolloAuthorButtonForCell(cell, isComment));
}

// Apollo also renders original-author information INSIDE a crosspost/repost
// node. Those are separate from the parent postInfoNode.authorButtonNode,
// which is why the normal hide-author switch misses them.
static char kApolloCrosspostCreditNodeKey;

// Only alter *crosspost attribution*, never post titles, comments, link text,
// subreddit names or the author's underlying RDKLink model. Limit the pattern
// to a short, single-line credit explicitly describing a crosspost/repost.
static NSAttributedString *ApolloRedactCrosspostCredit(NSAttributedString *text) {
    NSString *source = text.string;
    if (![source isKindOfClass:[NSString class]] ||
        source.length < 5 || source.length > 140 ||
        [source rangeOfString:@"\\n"].location != NSNotFound) return nil;

    NSString *lower = source.lowercaseString;
    BOOL isCredit = [lower containsString:@"crosspost"] ||
        [lower containsString:@"cross-post"] ||
        [lower containsString:@"repost"] ||
        [lower containsString:@"re-post"] ||
        [lower containsString:@"originally posted by"] ||
        [lower containsString:@"shared by"];
    if (!isCredit || [lower rangeOfString:@"u/"].location == NSNotFound) return nil;

    static NSRegularExpression *usernamePattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        usernamePattern = [NSRegularExpression
            regularExpressionWithPattern:@"(?i)(?<![A-Za-z0-9_])u/[A-Za-z0-9_-]{2,20}"
                                 options:0 error:nil];
    });
    NSArray<NSTextCheckingResult *> *matches = [usernamePattern
        matchesInString:source options:0 range:NSMakeRange(0, source.length)];
    if (!matches.count) return nil;
    NSMutableAttributedString *redacted = [text mutableCopy];
    for (NSTextCheckingResult *match in matches.reverseObjectEnumerator) {
        NSRange range = match.range;
        // Remove the space before u/name but keep punctuation and attribution.
        if (range.location > 0 &&
            [source characterAtIndex:range.location - 1] == ' ') {
            range.location--;
            range.length++;
        }
        [redacted deleteCharactersInRange:range];
    }
    return redacted;
}

static void ApolloSuppressCrosspostCreditNode(id node) {
    if (![node respondsToSelector:@selector(attributedText)] ||
        ![node respondsToSelector:@selector(setAttributedText:)]) return;
    NSAttributedString *current = ((id (*)(id, SEL))objc_msgSend)
        (node, @selector(attributedText));
    NSAttributedString *redacted = ApolloRedactCrosspostCredit(current);
    if (!redacted) return;
    objc_setAssociatedObject(node, &kApolloCrosspostCreditNodeKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // The setter hook below also redacts future asynchronous attribution edits.
    ((void (*)(id, SEL, id))objc_msgSend)(node, @selector(setAttributedText:), current);
}

// Runtime probing is restricted to the *crosspost subtree* and known author
// ivars. No generic scan of the entire post cell: titles containing u/name
// must stay intact. Walk child Texture subnodes because original-post
// attribution can be constructed only after the first layout pass.
static void ApolloSuppressCrosspostSubtree(id node,
                                           NSMutableSet<NSValue *> *visited,
                                           NSUInteger depth) {
    if (!node || depth > 8 || visited.count > 100) return;
    NSValue *key = [NSValue valueWithNonretainedObject:node];
    if ([visited containsObject:key]) return;
    [visited addObject:key];

    ApolloSuppressAuthorButton(ApolloObjectIvar(node, "authorNode"));
    ApolloSuppressAuthorButton(ApolloObjectIvar(node, "authorButtonNode"));
    ApolloSuppressCrosspostCreditNode(node);

    const char *nested[] = {
        "postInfoNode", "originalPostInfoNode", "crosspostInfoNode",
        "authorInfoNode", "originalPostNode", "crosspostParentNode"
    };
    for (NSUInteger i = 0; i < sizeof(nested) / sizeof(nested[0]); i++) {
        ApolloSuppressCrosspostSubtree(ApolloObjectIvar(node, nested[i]),
                                       visited, depth + 1);
    }
    if ([node respondsToSelector:@selector(subnodes)]) {
        id children = ((id (*)(id, SEL))objc_msgSend)(node, @selector(subnodes));
        if ([children isKindOfClass:[NSArray class]]) {
            for (id child in (NSArray *)children) {
                ApolloSuppressCrosspostSubtree(child, visited, depth + 1);
            }
        }
    }
}

static void ApolloSuppressCrosspostInCell(id cell) {
    if (!ApolloHideUsernamesEnabled()) return;
    id crosspost = ApolloObjectIvar(cell, "crosspostNode");
    if (crosspost) {
        ApolloSuppressCrosspostSubtree(crosspost, [NSMutableSet set], 0);
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
    if (ApolloHideUsernamesEnabled() &&
        [objc_getAssociatedObject(self, &kApolloCrosspostCreditNodeKey) boolValue]) {
        NSAttributedString *redacted = ApolloRedactCrosspostCredit(text);
        if (redacted) {
            %orig(redacted);
            return;
        }
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
    if (ApolloHideUsernamesEnabled() &&
        [objc_getAssociatedObject(self, &kApolloCrosspostCreditNodeKey) boolValue]) {
        NSAttributedString *redacted = ApolloRedactCrosspostCredit(text);
        if (redacted) {
            %orig(redacted);
            return;
        }
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
    ApolloSuppressCrosspostInCell(self);
    id spec = %orig;
    ApolloSuppressCrosspostInCell(self);
    return spec;
}
- (void)didLoad {
    %orig;
    ApolloSuppressAuthorInCell(self, NO);
    ApolloSuppressCrosspostInCell(self);
}
%end

%hook _TtC6Apollo19CompactPostCellNode
- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)range {
    ApolloSuppressAuthorInCell(self, NO);
    ApolloSuppressCrosspostInCell(self);
    id spec = %orig;
    ApolloSuppressCrosspostInCell(self);
    return spec;
}
- (void)didLoad {
    %orig;
    ApolloSuppressAuthorInCell(self, NO);
    ApolloSuppressCrosspostInCell(self);
}
%end

%hook _TtC6Apollo22CommentsHeaderCellNode
- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)range {
    ApolloSuppressAuthorInCell(self, NO);
    ApolloSuppressCrosspostInCell(self);
    id spec = %orig;
    ApolloSuppressCrosspostInCell(self);
    return spec;
}
- (void)didLoad {
    %orig;
    ApolloSuppressAuthorInCell(self, NO);
    ApolloSuppressCrosspostInCell(self);
}
%end
