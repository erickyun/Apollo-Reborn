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

// Metadata labels can mix community and author, e.g. "in piracy · u/name".
// Redact only the username token; never delete "in piracy" or "r/piracy".
// This marker is assigned ONLY to text nodes in a known postInfoNode subtree.
static char kApolloPostMetadataTextNodeKey;

static NSAttributedString *ApolloRedactPostMetadataUsername(NSAttributedString *text) {
    if (![text isKindOfClass:[NSAttributedString class]]) return nil;
    NSString *source = text.string;
    if (source.length == 0 || source.length > 220 ||
        [source rangeOfString:@"\n"].location != NSNotFound ||
        [source rangeOfString:@"u/" options:NSCaseInsensitiveSearch].location == NSNotFound) return nil;

    static NSRegularExpression *usernameRE;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        usernameRE = [NSRegularExpression
            regularExpressionWithPattern:@"(?i)(?<![A-Za-z0-9_])u/[A-Za-z0-9_-]{2,20}(?![A-Za-z0-9_-])"
                                 options:0 error:nil];
    });
    NSArray<NSTextCheckingResult *> *matches = [usernameRE
        matchesInString:source options:0 range:NSMakeRange(0, source.length)];
    if (!matches.count) return nil;
    NSMutableAttributedString *redacted = [text mutableCopy];
    // Remove any separator that belongs only to the user label. Preserve
    // subreddit names and delimiters between OTHER metadata fields.
    NSCharacterSet *whitespace = [NSCharacterSet whitespaceCharacterSet];
    for (NSTextCheckingResult *match in matches.reverseObjectEnumerator) {
        NSUInteger start = match.range.location;
        NSUInteger end = NSMaxRange(match.range);
        NSUInteger left = start;
        while (left > 0 && [whitespace characterIsMember:[source characterAtIndex:left - 1]]) left--;
        if (left > 0 && (
            [source characterAtIndex:left - 1] == 0x00B7 || // ·
            [source characterAtIndex:left - 1] == 0x2022 || // •
            [source characterAtIndex:left - 1] == '|')) {
            start = left - 1;
            while (start > 0 &&
                   [whitespace characterIsMember:[source characterAtIndex:start - 1]]) start--;
        } else if (left == 0) {
            // First metadata field was the author: remove its following
            // delimiter, not the visible 'in piracy' field that comes next.
            while (end < source.length && [whitespace characterIsMember:[source characterAtIndex:end]]) end++;
            if (end < source.length && (
                [source characterAtIndex:end] == 0x00B7 ||
                [source characterAtIndex:end] == 0x2022 ||
                [source characterAtIndex:end] == '|')) {
                end++;
                while (end < source.length && [whitespace characterIsMember:[source characterAtIndex:end]]) end++;
            }
        } else {
            start = left; // Trim the single space before a standalone u/name.
        }
        [redacted deleteCharactersInRange:NSMakeRange(start, end - start)];
    }
    return redacted;
}

static BOOL ApolloAuthorTitleIncludesCommunity(NSString *string) {
    if (![string isKindOfClass:[NSString class]]) return NO;
    // A mixed byline must not be blanked entirely; keep its subreddit label.
    return [string rangeOfString:@" in " options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [string rangeOfString:@"r/" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static void ApolloMarkPostMetadataTextNode(id node) {
    if (![node respondsToSelector:@selector(attributedText)] ||
        ![node respondsToSelector:@selector(setAttributedText:)]) return;
    NSAttributedString *current = ((id (*)(id, SEL))objc_msgSend)
        (node, @selector(attributedText));
    NSAttributedString *newText = ApolloRedactPostMetadataUsername(current);
    if (!newText) return;
    objc_setAssociatedObject(node, &kApolloPostMetadataTextNodeKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL, id))objc_msgSend)(node, @selector(setAttributedText:), newText);
}

// Traverse ONLY the post metadata subtree. This does not visit the main
// post title, comment text, subreddit content, or general page text.
static void ApolloMarkPostInfoSubtree(id node,
                                      NSMutableSet<NSValue *> *visited,
                                      NSUInteger depth) {
    if (!node || depth > 8 || visited.count >= 100) return;
    NSValue *key = [NSValue valueWithNonretainedObject:node];
    if ([visited containsObject:key]) return;
    [visited addObject:key];
    ApolloMarkPostMetadataTextNode(node);

    if ([node respondsToSelector:@selector(titleNode)]) {
        id titleNode = ((id (*)(id, SEL))objc_msgSend)(node, @selector(titleNode));
        if (titleNode && titleNode != node) {
            ApolloMarkPostInfoSubtree(titleNode, visited, depth + 1);
        }
    }
    if ([node respondsToSelector:@selector(subnodes)]) {
        id children = ((id (*)(id, SEL))objc_msgSend)(node, @selector(subnodes));
        if ([children isKindOfClass:[NSArray class]]) {
            for (id child in children) {
                ApolloMarkPostInfoSubtree(child, visited, depth + 1);
            }
        }
    }
}

static void ApolloSuppressPostMetadataInCell(id cell) {
    if (!ApolloHideUsernamesEnabled() || !cell) return;
    id postInfo = ApolloObjectIvar(cell, "postInfoNode");
    if (postInfo) ApolloMarkPostInfoSubtree(postInfo, [NSMutableSet set], 0);
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

    NSAttributedString *current = [textNode respondsToSelector:@selector(attributedText)]
        ? ((id (*)(id, SEL))objc_msgSend)(textNode, @selector(attributedText))
        : nil;
    // Some Apollo layouts combine "in piracy" and "u/author" in one title.
    // Preserve the community substring instead of hiding the whole button.
    if (ApolloAuthorTitleIncludesCommunity(current.string)) {
        ApolloMarkPostMetadataTextNode(textNode);
        return;
    }
    // Ordinary standalone author label: hide its entire title.
    // Future async setAttributedText: updates remain hidden via the hook.
    objc_setAssociatedObject(textNode, &kApolloHiddenAuthorTextNodeKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
        // A title node may not have text at its first measure. If a later
        // async bind inserts a composite author+community label, do not wipe
        // out the visible "in piracy" / "r/piracy" portion.
        if (ApolloAuthorTitleIncludesCommunity(text.string)) {
            NSAttributedString *redacted = ApolloRedactPostMetadataUsername(text);
            %orig(redacted ?: text);
        } else {
            %orig(ApolloEmptyAuthorText());
        }
        return;
    }
    // Some post metadata nodes are composite: preserve r/subreddit or
    // "in subreddit", removing only the u/author span.
    if (ApolloHideUsernamesEnabled() &&
        [objc_getAssociatedObject(self, &kApolloPostMetadataTextNodeKey) boolValue]) {
        NSAttributedString *redacted = ApolloRedactPostMetadataUsername(text);
        if (redacted) {
            %orig(redacted);
            return;
        }
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
        // A title node may not have text at its first measure. If a later
        // async bind inserts a composite author+community label, do not wipe
        // out the visible "in piracy" / "r/piracy" portion.
        if (ApolloAuthorTitleIncludesCommunity(text.string)) {
            NSAttributedString *redacted = ApolloRedactPostMetadataUsername(text);
            %orig(redacted ?: text);
        } else {
            %orig(ApolloEmptyAuthorText());
        }
        return;
    }
    // Some post metadata nodes are composite: preserve r/subreddit or
    // "in subreddit", removing only the u/author span.
    if (ApolloHideUsernamesEnabled() &&
        [objc_getAssociatedObject(self, &kApolloPostMetadataTextNodeKey) boolValue]) {
        NSAttributedString *redacted = ApolloRedactPostMetadataUsername(text);
        if (redacted) {
            %orig(redacted);
            return;
        }
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
    ApolloSuppressPostMetadataInCell(self);
    ApolloSuppressCrosspostInCell(self);
    id spec = %orig;
    ApolloSuppressPostMetadataInCell(self);
    ApolloSuppressCrosspostInCell(self);
    return spec;
}
- (void)didLoad {
    %orig;
    ApolloSuppressAuthorInCell(self, NO);
    ApolloSuppressPostMetadataInCell(self);
    ApolloSuppressCrosspostInCell(self);
}
%end

%hook _TtC6Apollo19CompactPostCellNode
- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)range {
    ApolloSuppressAuthorInCell(self, NO);
    ApolloSuppressPostMetadataInCell(self);
    ApolloSuppressCrosspostInCell(self);
    id spec = %orig;
    ApolloSuppressPostMetadataInCell(self);
    ApolloSuppressCrosspostInCell(self);
    return spec;
}
- (void)didLoad {
    %orig;
    ApolloSuppressAuthorInCell(self, NO);
    ApolloSuppressPostMetadataInCell(self);
    ApolloSuppressCrosspostInCell(self);
}
%end

%hook _TtC6Apollo22CommentsHeaderCellNode
- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)range {
    ApolloSuppressAuthorInCell(self, NO);
    ApolloSuppressPostMetadataInCell(self);
    ApolloSuppressCrosspostInCell(self);
    id spec = %orig;
    ApolloSuppressPostMetadataInCell(self);
    ApolloSuppressCrosspostInCell(self);
    return spec;
}
- (void)didLoad {
    %orig;
    ApolloSuppressAuthorInCell(self, NO);
    ApolloSuppressPostMetadataInCell(self);
    ApolloSuppressCrosspostInCell(self);
}
%end
