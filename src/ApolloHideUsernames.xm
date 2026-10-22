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
static char kApolloPostAuthorUsernameKey;
static char kApolloPostInfoModelAuthorKey;

static BOOL ApolloHideUsernamesEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kApolloHideUsernamesKey];
}

static BOOL ApolloHidePostAuthorEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kApolloHidePostAuthorKey];
}

// Use the post's author property as an exact identity source, not a global
// substring/regex search for u/. Restrict edits to that author's text node.
// Crucially, the button title can also contain vote count, comment count,
// subreddit, and age; don't blank the whole title or those values disappear.
// The same rule applies to comment authors (score/age share a text row).
static NSString *ApolloAuthorFromModel(id model) {
    if (!model || ![model respondsToSelector:@selector(author)]) return nil;
    id result = ((id (*)(id, SEL))objc_msgSend)(model, @selector(author));
    if (![result isKindOfClass:[NSString class]]) return nil;
    NSString *name = (NSString *)result;
    if ([name hasPrefix:@"u/"] || [name hasPrefix:@"U/"]) name = [name substringFromIndex:2];
    if (name.length == 0 || [name isEqualToString:@"[deleted]"]) return nil;
    return name;
}

static BOOL ApolloAuthorBoundaryCharacter(unichar c) {
    return !((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
             (c >= '0' && c <= '9') || c == '_');
}

static NSAttributedString *ApolloPostTitleWithoutAuthor(NSAttributedString *input,
                                                         NSString *author) {
    if (![input isKindOfClass:[NSAttributedString class]] || !author.length) return nil;
    NSString *original = input.string;
    if (original.length == 0 || original.length > 300) return nil;

    // Match this post's actual author, with optional u/ and "by " prefixes.
    // The token boundary and r/ / "in " exclusion protect subreddit labels
    // when a community name happens to match the author.
    NSRange hit = [original rangeOfString:author options:NSCaseInsensitiveSearch];
    while (hit.location != NSNotFound) {
        NSUInteger start = hit.location;
        NSUInteger end = NSMaxRange(hit);
        BOOL leftOK = (start == 0) || ApolloAuthorBoundaryCharacter([original characterAtIndex:start-1]);
        BOOL rightOK = (end == original.length) || ApolloAuthorBoundaryCharacter([original characterAtIndex:end]);
        NSString *twoBefore = start >= 2
            ? [[original substringWithRange:NSMakeRange(start-2, 2)] lowercaseString] : @"";
        NSString *threeBefore = start >= 3
            ? [[original substringWithRange:NSMakeRange(start-3, 3)] lowercaseString] : @"";
        BOOL userPrefix = [twoBefore isEqualToString:@"u/"];
        BOOL subredditPrefix = [twoBefore isEqualToString:@"r/"] ||
                               [threeBefore isEqualToString:@"in "];
        // Names can coincide with subreddit names (e.g. r/piracy and
        // u/piracy). Never redact the subreddit label by mistake.
        if (leftOK && rightOK && !subredditPrefix) {
            if (userPrefix) start -= 2;
            // Remove a preceding "by " only when attached to the author.
            if (start >= 3) {
                NSString *prefix = [original substringWithRange:NSMakeRange(start-3, 3)];
                if ([prefix caseInsensitiveCompare:@"by "] == NSOrderedSame) start -= 3;
            }
            NSCharacterSet *spaces = [NSCharacterSet whitespaceCharacterSet];
            NSUInteger left = start;
            while (left > 0 && [spaces characterIsMember:[original characterAtIndex:left-1]]) left--;
            if (left > 0 && ([original characterAtIndex:left-1] == 0x00B7 ||
                             [original characterAtIndex:left-1] == 0x2022 ||
                             [original characterAtIndex:left-1] == '|')) {
                start = left - 1;
                while (start > 0 && [spaces characterIsMember:[original characterAtIndex:start-1]]) start--;
            } else if (left == 0) {
                while (end < original.length && [spaces characterIsMember:[original characterAtIndex:end]]) end++;
                if (end < original.length && ([original characterAtIndex:end] == 0x00B7 ||
                                              [original characterAtIndex:end] == 0x2022 ||
                                              [original characterAtIndex:end] == '|')) {
                    end++;
                    while (end < original.length && [spaces characterIsMember:[original characterAtIndex:end]]) end++;
                }
            } else {
                start = left;
            }
            NSMutableAttributedString *edited = [input mutableCopy];
            [edited deleteCharactersInRange:NSMakeRange(start, end-start)];
            return edited;
        }
        NSUInteger next = NSMaxRange(hit);
        if (next >= original.length) break;
        NSRange rest = NSMakeRange(next, original.length-next);
        hit = [original rangeOfString:author options:NSCaseInsensitiveSearch range:rest];
    }
    return nil;
}

// The app does not consistently place its byline in authorButtonNode.titleNode.
// Some layouts construct an ASTextNode inside PostInfoNode's returned layout
// spec instead of attaching it to authorButtonNode/subnodes at measurement time.
// Mark every *text node* belonging to that known metadata subtree and preserve
// every other word when removing the model's author (votes, age, subreddit).
static BOOL ApolloIsTextureTextNode(id object) {
    if (!object) return NO;
    Class text1 = objc_getClass("ASTextNode");
    Class text2 = objc_getClass("ASTextNode2");
    return (text1 && [object isKindOfClass:text1]) ||
           (text2 && [object isKindOfClass:text2]);
}

static void ApolloMarkPostInfoTextTree(id root, NSString *author,
                                       NSMutableSet<NSValue *> *seen,
                                       NSUInteger depth) {
    if (!root || !author.length || depth > 14 || seen.count >= 220) return;
    NSValue *key = [NSValue valueWithNonretainedObject:root];
    if ([seen containsObject:key]) return;
    [seen addObject:key];

    if (ApolloIsTextureTextNode(root) &&
        [root respondsToSelector:@selector(setAttributedText:)]) {
        objc_setAssociatedObject(root, &kApolloPostAuthorUsernameKey, author,
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
        if ([root respondsToSelector:@selector(attributedText)]) {
            NSAttributedString *value = ((id (*)(id, SEL))objc_msgSend)
                (root, @selector(attributedText));
            NSAttributedString *result = ApolloPostTitleWithoutAuthor(value, author);
            if (result) {
                ((void (*)(id, SEL, id))objc_msgSend)(root, @selector(setAttributedText:), result);
            }
        }
    }

    // Text nodes are reached either via live Texture subnodes or by walking
    // layout-spec children. In particular, nodes not yet loaded may not show
    // in -subnodes but still occur under ASInsetLayoutSpec.child, etc.
    const SEL arraySelectors[] = { @selector(subnodes), @selector(children) };
    for (NSUInteger i = 0; i < sizeof(arraySelectors)/sizeof(arraySelectors[0]); i++) {
        SEL sel = arraySelectors[i];
        if (![root respondsToSelector:sel]) continue;
        id children = ((id (*)(id, SEL))objc_msgSend)(root, sel);
        if (![children isKindOfClass:[NSArray class]]) continue;
        for (id child in (NSArray *)children) {
            ApolloMarkPostInfoTextTree(child, author, seen, depth + 1);
        }
    }
    const SEL oneSelectors[] = { @selector(child), @selector(background),
                                 @selector(titleNode) };
    for (NSUInteger i = 0; i < sizeof(oneSelectors)/sizeof(oneSelectors[0]); i++) {
        SEL sel = oneSelectors[i];
        if ([root respondsToSelector:sel]) {
            id child = ((id (*)(id, SEL))objc_msgSend)(root, sel);
            if (child && child != root) ApolloMarkPostInfoTextTree(child, author, seen, depth + 1);
        }
    }
}

static NSString *ApolloAuthorForPostInfoNode(id info) {
    NSString *author = ApolloAuthorFromModel(ApolloObjectIvar(info, "link"));
    if (!author.length) author = objc_getAssociatedObject(info, &kApolloPostInfoModelAuthorKey);
    return author;
}

static void ApolloMarkPostInfoContent(id info, id nativeLayout) {
    if ((!ApolloHideUsernamesEnabled() && !ApolloHidePostAuthorEnabled()) || !info) return;
    NSString *author = ApolloAuthorForPostInfoNode(info);
    if (!author.length) return;
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    ApolloMarkPostInfoTextTree(info, author, visited, 0);
    if (nativeLayout) ApolloMarkPostInfoTextTree(nativeLayout, author, visited, 0);
}

// Catch later async text assignments, even if the node had not been added to
// the live subnode tree at the preceding PostInfoNode layout pass. No global
// username text search: resolve model metadata only from an ancestor PostInfoNode.
static NSString *ApolloAuthorForPostInfoAncestor(id textNode) {
    Class infoClass = objc_getClass("_TtC6Apollo12PostInfoNode");
    if (!infoClass) return nil;
    id parent = textNode;
    for (NSUInteger depth = 0; depth < 12 && parent; depth++) {
        if ([parent isKindOfClass:infoClass]) return ApolloAuthorForPostInfoNode(parent);
        if (![parent respondsToSelector:@selector(supernode)]) break;
        parent = ((id (*)(id, SEL))objc_msgSend)(parent, @selector(supernode));
    }
    return nil;
}

static void ApolloSuppressAuthorButton(id button, BOOL isComment, NSString *modelAuthor) {
    BOOL enabled = isComment ? ApolloHideUsernamesEnabled() :
        (ApolloHideUsernamesEnabled() || ApolloHidePostAuthorEnabled());
    if (!enabled || !button || ![button respondsToSelector:@selector(titleNode)]) return;

    id textNode = ((id (*)(id, SEL))objc_msgSend)(button, @selector(titleNode));
    if (!textNode || ![textNode respondsToSelector:@selector(setAttributedText:)]) return;

    // A comment author button can also carry "3h ago" and vote totals.
    // Treat it exactly like a post: store the model's author, not a boolean
    // instruction to blank the entire shared attributed title.
    // When the model is unavailable, never delete the neighboring counters.
    if (!modelAuthor.length) return;
    const void *marker = isComment
        ? (const void *)&kApolloHiddenCommentAuthorNodeKey
        : (const void *)&kApolloPostAuthorUsernameKey;
    objc_setAssociatedObject(textNode, marker, modelAuthor,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    if ([textNode respondsToSelector:@selector(attributedText)]) {
        NSAttributedString *current = ((id (*)(id, SEL))objc_msgSend)
            (textNode, @selector(attributedText));
        NSAttributedString *redacted = ApolloPostTitleWithoutAuthor(current, modelAuthor);
        if (redacted) ((void (*)(id, SEL, id))objc_msgSend)
            (textNode, @selector(setAttributedText:), redacted);
    }
}

static void ApolloSuppressAuthorInCell(id cell, BOOL isComment) {
    if (isComment) {
        if (ApolloHideUsernamesEnabled())
            ApolloSuppressAuthorButton(ApolloObjectIvar(cell, "authorNode"), YES,
                                       ApolloAuthorFromModel(ApolloObjectIvar(cell, "comment")));
        return;
    }
    if (!ApolloHideUsernamesEnabled() && !ApolloHidePostAuthorEnabled()) return;
    id postInfo = ApolloObjectIvar(cell, "postInfoNode");
    id model = ApolloObjectIvar(postInfo, "link") ?: ApolloObjectIvar(cell, "link");
    NSString *author = ApolloAuthorFromModel(model);
    if (postInfo && author.length) {
        objc_setAssociatedObject(postInfo, &kApolloPostInfoModelAuthorKey, author,
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
        ApolloMarkPostInfoContent(postInfo, nil);
    }
    ApolloSuppressAuthorButton(ApolloObjectIvar(postInfo, "authorButtonNode"),
                               NO, author);
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

    id info = ApolloObjectIvar(node, "postInfoNode");
    id model = ApolloObjectIvar(info, "link") ?:
               ApolloObjectIvar(node, "crosspostParent") ?:
               ApolloObjectIvar(node, "link");
    NSString *author = ApolloAuthorFromModel(model);
    if (info && author.length) {
        objc_setAssociatedObject(info, &kApolloPostInfoModelAuthorKey, author,
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
        ApolloMarkPostInfoContent(info, nil);
    }
    ApolloSuppressAuthorButton(ApolloObjectIvar(node, "authorNode"), NO, author);
    ApolloSuppressAuthorButton(ApolloObjectIvar(node, "authorButtonNode"), NO, author);
    if (info) {
        ApolloSuppressAuthorButton(ApolloObjectIvar(info, "authorButtonNode"), NO, author);
        ApolloMarkPostInfoContent(info, nil);
    }

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
    id info = (id)self;
    if (ApolloHideUsernamesEnabled() || ApolloHidePostAuthorEnabled()) {
        ApolloSuppressAuthorButton(ApolloObjectIvar(info, "authorButtonNode"),
                                   NO, ApolloAuthorForPostInfoNode(info));
        ApolloMarkPostInfoContent(info, nil);
    }
    id spec = %orig;
    ApolloMarkPostInfoContent(info, spec);
    return spec;
}

- (void)didLoad {
    %orig;
    id info = (id)self;
    ApolloMarkPostInfoContent(info, nil);
    ApolloSuppressAuthorButton(ApolloObjectIvar(info, "authorButtonNode"),
                               NO, ApolloAuthorForPostInfoNode(info));
}

%end

%hook ASTextNode
- (void)setAttributedText:(NSAttributedString *)text {
    NSString *author = nil;
    if (ApolloHideUsernamesEnabled()) {
        author = objc_getAssociatedObject(self, &kApolloHiddenCommentAuthorNodeKey);
    }
    if (!author && (ApolloHideUsernamesEnabled() || ApolloHidePostAuthorEnabled())) {
        author = objc_getAssociatedObject(self, &kApolloPostAuthorUsernameKey);
        if (!author.length) author = ApolloAuthorForPostInfoAncestor(self);
    }
    NSAttributedString *redacted = ApolloPostTitleWithoutAuthor(text, author);
    if (redacted) {
        // Process the precise author from the model *before* Texture draws,
        // retaining vote/comment totals, post age and subreddit metadata.
        %orig(redacted);
        return;
    }
    %orig;
}
%end

%hook ASTextNode2
- (void)setAttributedText:(NSAttributedString *)text {
    NSString *author = nil;
    if (ApolloHideUsernamesEnabled()) {
        author = objc_getAssociatedObject(self, &kApolloHiddenCommentAuthorNodeKey);
    }
    if (!author && (ApolloHideUsernamesEnabled() || ApolloHidePostAuthorEnabled())) {
        author = objc_getAssociatedObject(self, &kApolloPostAuthorUsernameKey);
        if (!author.length) author = ApolloAuthorForPostInfoAncestor(self);
    }
    NSAttributedString *redacted = ApolloPostTitleWithoutAuthor(text, author);
    if (redacted) {
        // Process the precise author from the model *before* Texture draws,
        // retaining vote/comment totals, post age and subreddit metadata.
        %orig(redacted);
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
