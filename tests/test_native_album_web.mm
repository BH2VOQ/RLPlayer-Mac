// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
// Offline AppKit geometry, not a screenshot-equivalence claim. Never starts core.
#import <AppKit/AppKit.h>
#import "RLPAlbumDetailViewController.h"
#import "RLPModels.h"
@interface RLPAlbumDetailViewController (OfflineFixture)
- (void)layoutAlbum;
- (void)renderAlbumSummary:(NSDictionary *)json;
@end
#include <cmath>
#include <cstdio>
static int failures;
static void check(bool ok, const char *name) { printf("[%s] %s\n",ok?"PASS":"FAIL",name); if(!ok) ++failures; }
static bool near(CGFloat a, CGFloat b) { return std::fabs(a-b)<.6; }
static NSButton *button(NSView *v, SEL action) {
    for(NSView *s in v.subviews) { if([s isKindOfClass:NSButton.class] && ((NSButton*)s).action==action) return (NSButton*)s; NSButton *b=button(s,action); if(b)return b; } return nil;
}
int main() { @autoreleasepool {
    [NSApplication sharedApplication];
    RLPAlbumDetailViewController *vc=[[RLPAlbumDetailViewController alloc] initWithAlbumKey:@"offline"];
    vc.view.frame=NSMakeRect(0,0,954,620); // 1180px screenshot minus 226px sidebar
    [vc.view layoutSubtreeIfNeeded];
    NSImageView *cover=[vc valueForKey:@"cover"];
    NSTextField *kind=[vc valueForKey:@"kindLabel"], *name=[vc valueForKey:@"nameLabel"];
    check(near(cover.frame.size.width,168)&&near(cover.frame.size.height,168),"web cover is 168 square");
    check(near(cover.frame.origin.x,22),"web hero left inset is 22");
    check([kind.stringValue isEqualToString:@"ALBUM"]&&near(kind.font.pointSize,10),"literal ALBUM eyebrow at 10pt");
    check(near(name.font.pointSize,26)&&name.maximumNumberOfLines==1,"web title 26pt single line");
    SEL actions[]={@selector(onPlayAll:),@selector(onEnqueueAlbum:),@selector(onSetCover:),@selector(onShuffle:)};
    CGFloat last=-1; bool ordered=true;
    for(auto action:actions) { NSButton *b=button(vc.view,action); if(!b||b.frame.origin.x<=last)ordered=false; last=b.frame.origin.x; }
    check(ordered,"four hero buttons in web order play/add/cover/shuffle");
    NSTableView *table=[vc valueForKey:@"table"];
    check(table.numberOfColumns==7,"seven real columns including format");
    NSTableColumn *title=nil,*artist=nil,*add=nil;
    for(NSTableColumn *c in table.tableColumns) {if([c.identifier isEqual:@"title"])title=c;if([c.identifier isEqual:@"artist"])artist=c;if([c.identifier isEqual:@"add"])add=c;}
    check(add && near(add.width,26),"add column remains 26pt at screenshot width");
    check(title&&artist&&std::fabs(title.width/artist.width-1.8)<.01,"1180px viewport title/artist ratio is 1.8:1");
    check(table.action==@selector(onRowDoubleClick:),"single click playback entry preserved");
    RLPAlbum *album=[RLPAlbum albumFromJSON:@{ @"k":@"offline",@"name":@"Ref: rain",@"artist":@"Aimer",@"dur":@1241 }];
    NSMutableArray *tracks=[NSMutableArray array];
    for(int i=0;i<5;i++) [tracks addObject:[RLPTrack trackFromJSON:@{@"title":@"Ref:rain",@"artist":@"Aimer",@"path":[NSString stringWithFormat:@"/offline/%d.flac",i],@"dur":@248}]];
    [vc setValue:album forKey:@"album"]; [vc setValue:tracks forKey:@"tracks"];
    NSTextField *progress=[vc valueForKey:@"progressLabel"];progress.hidden=NO;
    NSView *card=[vc valueForKey:@"summaryCard"];card.hidden=NO;
    NSTextField *summary=[vc valueForKey:@"summaryLabel"];summary.stringValue=@"正在整理资料…";
    [table reloadData]; [vc layoutAlbum];
    NSScrollView *sc=[vc valueForKey:@"scroll"];
    check(table.numberOfRows==5&&near(table.rowHeight,38)&&near(sc.frame.size.height,190),"five real track rows occupy 190pt");
    check(near(sc.frame.origin.y,269)&&near(card.frame.origin.y,491)&&near(card.frame.size.height,48),"progress/table/summary match screenshot local y coordinates");
    [vc renderAlbumSummary:@{@"ok":@YES,@"fields":@{@"时长":@"fabricated AI duration",@"曲目列表":@"fabricated AI tracks",@"简介":@"real summary"}}];
    check([summary.stringValue containsString:@"20:41"]&&![summary.stringValue containsString:@"fabricated"],"summary keeps local duration and drops AI track listing");
    vc.view.frame=NSMakeRect(0,0,874,620); [vc.view layoutSubtreeIfNeeded]; [vc layoutAlbum];
    check(title&&artist&&std::fabs(title.width/artist.width-1/.9)<.01,"narrow viewport keeps web 1:.9 title/artist ratio");
    vc.view.frame=NSMakeRect(0,0,1274,620); [vc.view layoutSubtreeIfNeeded]; [vc layoutAlbum];
    NSTableColumn *format=[table tableColumnWithIdentifier:@"format"];
    check(format&&near(format.width,92)&&std::fabs(title.width/artist.width-1.6)<.01,"wide viewport exposes real 92pt format column");
    vc.view.frame=NSMakeRect(0,0,954,620); [vc.view layoutSubtreeIfNeeded]; [vc layoutAlbum];
    [table reloadData]; [table layoutSubtreeIfNeeded];
    NSView *titleCell=[table viewAtColumn:2 row:0 makeIfNecessary:YES];
    NSView *favCell=[table viewAtColumn:1 row:0 makeIfNecessary:YES];
    NSView *durCell=[table viewAtColumn:5 row:0 makeIfNecessary:YES];
    NSView *addCell=[table viewAtColumn:6 row:0 makeIfNecessary:YES];
    auto content=[](NSView *cell)->NSView * { if([cell isKindOfClass:NSControl.class])return cell;for(NSView *sub in cell.subviews)if([sub isKindOfClass:NSControl.class])return sub;return nil;};
    for(NSView *cell in @[titleCell,favCell,durCell,addCell]) { [cell setNeedsLayout:YES]; [cell layoutSubtreeIfNeeded]; }
    NSView *titleContent=content(titleCell),*favContent=content(favCell);
    NSRect titleFrame=[titleContent convertRect:titleContent.bounds toView:table],favFrame=[favContent convertRect:favContent.bounds toView:table];
    check(titleContent&&favContent&&near(NSMidY(titleFrame),NSMidY(favFrame)),"actual heart and title content centers share row baseline");
    NSRect rowRect=[table rectOfRow:0];
    check(titleFrame.size.height<30 && favFrame.size.height==22 && near(NSMidY(titleFrame),NSMidY(rowRect)) && near(NSMidY(favFrame),NSMidY(rowRect)),"actual inner text and image controls center inside 38pt row, not just equal full-row frames");
    NSRect clip=sc.contentView.bounds;
    NSRect durFrame=[durCell convertRect:durCell.bounds toView:sc.contentView],addFrame=[addCell convertRect:addCell.bounds toView:sc.contentView];
    check(durCell&&addCell&&NSContainsRect(clip,durFrame)&&NSContainsRect(clip,addFrame),"actual duration and add cells fit visible clip at 1180");
    for(int repeat=0;repeat<3;repeat++) [vc layoutAlbum];
    check(NSMaxX([table rectOfColumn:6])<=sc.contentSize.width && near(table.frame.size.width,sc.contentSize.width),"repeated layout cannot grow table or push add beyond viewport");
    printf("cell evidence title=%s heart=%s duration=%s add=%s clip=%s\n",NSStringFromRect(titleFrame).UTF8String,NSStringFromRect(favFrame).UTF8String,NSStringFromRect(durFrame).UTF8String,NSStringFromRect(addFrame).UTF8String,NSStringFromRect(clip).UTF8String);
    printf("album web geometry: %d failures\n",failures);
    return failures?1:0;
} }
