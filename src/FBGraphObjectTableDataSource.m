/*
 * Copyright 2012 Facebook
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * 
 *    http://www.apache.org/licenses/LICENSE-2.0
 
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "FBGraphObjectTableDataSource.h"
#import "FBGraphObjectTableCell.h"
#import "FBGraphObject.h"
#import "FBURLConnection.h"

@interface FBGraphObjectTableDataSource ()

@property (nonatomic, retain) NSArray *data;
@property (nonatomic, retain) NSArray *indexKeys;
@property (nonatomic, retain) NSDictionary *indexMap;
@property (nonatomic, retain) NSMutableSet *pendingURLConnections;
@property (nonatomic) BOOL expectingMoreGraphObjects;

- (BOOL)filterIncludesItem:(FBGraphObject *)item;
- (FBGraphObjectTableCell *)cellWithTableView:(UITableView *)tableView;
- (NSString *)indexKeyOfItem:(FBGraphObject *)item;
- (UIImage *)tableView:(UITableView *)tableView imageForItem:(FBGraphObject *)item;
- (void)addOrRemovePendingConnection:(FBURLConnection *)connection;
- (BOOL)isActivityIndicatorIndexPath:(NSIndexPath *)indexPath;
- (BOOL)isLastSection:(NSInteger)section;

@end

@implementation FBGraphObjectTableDataSource

@synthesize data = _data;
@synthesize defaultPicture = _defaultPicture;
@synthesize controllerDelegate = _controllerDelegate;
@synthesize groupByField = _groupByField;
@synthesize indexKeys = _indexKeys;
@synthesize indexMap = _indexMap;
@synthesize itemPicturesEnabled = _itemPicturesEnabled;
@synthesize itemSubtitleEnabled = _itemSubtitleEnabled;
@synthesize pendingURLConnections = _pendingURLConnections;
@synthesize selectionDelegate = _selectionDelegate;
@synthesize sortDescriptors = _sortDescriptors;
@synthesize dataNeededDelegate = _dataNeededDelegate;
@synthesize expectingMoreGraphObjects = _expectingMoreGraphObjects;

- (id)init
{
    self = [super init];
    
    if (self) {
        NSMutableSet *pendingURLConnections = [[NSMutableSet alloc] init];
        self.pendingURLConnections = pendingURLConnections;
        [pendingURLConnections release];
        self.expectingMoreGraphObjects = YES;
    }
    
    return self;
}

- (void)dealloc
{
    NSAssert(![_pendingURLConnections count],
             @"FBGraphObjectTableDataSource pending connection did not retain self");

    [_data release];
    [_defaultPicture release];
    [_groupByField release];
    [_indexKeys release];
    [_indexMap release];
    [_pendingURLConnections release];
    [_sortDescriptors release];

    [super dealloc];
}

#pragma mark - Public Methods

- (NSString *)fieldsForRequestIncluding:(NSSet *)customFields, ...
{
    // Start with custom fields.
    NSMutableSet *nameSet = [[NSMutableSet alloc] initWithSet:customFields];

    // Iterate through varargs after the initial set, and add them
    id vaName;
    va_list vaArguments;
    va_start(vaArguments, customFields);
    while ((vaName = va_arg(vaArguments, id))) {
        [nameSet addObject:vaName];
    }
    va_end(vaArguments);

    // Add fields needed for data source functionality.
    if (self.groupByField) {
        [nameSet addObject:self.groupByField];
    }

    // Build the comma-separated string
    NSMutableString *fields = [[[NSMutableString alloc] init] autorelease];

    for (NSString *field in nameSet) {
        if ([fields length]) {
            [fields appendString:@","];
        }
        [fields appendString:field];
    }

    [nameSet release];

    return fields;
}

- (void)clearGraphObjects {
    self.data = nil;
    self.expectingMoreGraphObjects = YES;
}

- (void)appendGraphObjects:(NSArray *)data
{
    if (self.data) {
        self.data = [self.data arrayByAddingObjectsFromArray:data];
    } else {
        self.data = data;
    }
    if (data == nil) {
        self.expectingMoreGraphObjects = NO;
    }
}

- (BOOL)hasGraphObjects {
    return self.data && self.data.count > 0;
}

- (void)bindTableView:(UITableView *)tableView
{
    tableView.dataSource = self;
    tableView.rowHeight = [FBGraphObjectTableCell rowHeight];
}

- (void)cancelPendingRequests
{
    // Cancel all active connections.
    for (FBURLConnection *connection in _pendingURLConnections) {
        [connection cancel];
    }
}

// Called after changing any properties.  To simplify the code here,
// since this class is internal, we do not auto-update on property
// changes.
//
// This builds indexMap and indexKeys, the data structures used to
// respond to UITableDataSource protocol requests.  UITable expects
// a list of section names, and then ask for items given a section
// index and item index within that section.  In addition, we need
// to do reverse mapping from item to table location.
//
// To facilitate both of these, we build an array of section titles,
// and a dictionary mapping title -> item array.  We could consider
// building a reverse-lookup map too, but this seems unnecessary.
- (void)update
{
    NSMutableDictionary *indexMap = [[[NSMutableDictionary alloc] init] autorelease];
    NSMutableArray *indexKeys = [[[NSMutableArray alloc] init] autorelease];
    
    for (FBGraphObject *item in self.data) {
        if (![self filterIncludesItem:item]) {
            continue;
        }
        
        NSString *key = [self indexKeyOfItem:item];
        NSMutableArray *existingSection = [indexMap objectForKey:key];
        NSMutableArray *section = existingSection;
        
        if (!section) {
            section = [[[NSMutableArray alloc] init] autorelease];
        }
        [section addObject:item];
        
        if (!existingSection) {
            [indexMap setValue:section forKey:key];
            [indexKeys addObject:key];
        }
    }
    
    if (self.sortDescriptors) {
        for (NSString *key in indexKeys) {
            [[indexMap objectForKey:key]
             sortUsingDescriptors:self.sortDescriptors];
        }
    }
    [indexKeys sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    
    self.indexKeys = indexKeys;
    self.indexMap = indexMap;
}

#pragma mark - Private Methods

- (BOOL)filterIncludesItem:(FBGraphObject *)item
{
    if (![self.controllerDelegate respondsToSelector:
          @selector(graphObjectTableDataSource:filterIncludesItem:)]) {
        return YES;
    }

    return [self.controllerDelegate graphObjectTableDataSource:self
                                            filterIncludesItem:item];
}

- (void)setSortingBySingleField:(NSString*)fieldName ascending:(BOOL)ascending {
    NSSortDescriptor *sortBy = [NSSortDescriptor
                                sortDescriptorWithKey:fieldName
                                ascending:ascending
                                selector:@selector(localizedCaseInsensitiveCompare:)];
    self.sortDescriptors = [NSArray arrayWithObjects:sortBy, nil];
}

- (FBGraphObjectTableCell *)cellWithTableView:(UITableView *)tableView
{
    static NSString * const cellKey = @"fbTableCell";
    FBGraphObjectTableCell *cell =
    (FBGraphObjectTableCell*)[tableView dequeueReusableCellWithIdentifier:cellKey];

    if (!cell) {
        cell = [[FBGraphObjectTableCell alloc]
                initWithStyle:UITableViewCellStyleDefault
                reuseIdentifier:cellKey];
        [cell autorelease];

        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    
    return cell;
}

- (NSString *)indexKeyOfItem:(FBGraphObject *)item
{
    NSString *text = @"";
    
    if (self.groupByField) {
        text = [item objectForKey:self.groupByField];
    }
    
    if ([text length] > 1) {
        text = [text substringToIndex:1];
    }
    
    text = [text uppercaseString];
    
    return text;
}

- (FBGraphObject *)itemAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section >= 0 && indexPath.section < self.indexKeys.count) {
        id key = [self.indexKeys objectAtIndex:indexPath.section];
        NSArray *sectionItems = [self.indexMap objectForKey:key];
        if (indexPath.row >= 0 && indexPath.row < sectionItems.count) {
            return [sectionItems objectAtIndex:indexPath.row];
        }
    }
    return nil;
}

- (NSIndexPath *)indexPathForItem:(FBGraphObject *)item
{
    NSString *key = [self indexKeyOfItem:item];
    NSMutableArray *sectionItems = [self.indexMap objectForKey:key];
    if (!sectionItems) {
        return nil;
    }
    
    NSInteger sectionIndex = [self.indexKeys indexOfObject:key];
    if (sectionIndex == NSNotFound) {
        return nil;
    }
    
    NSInteger itemIndex = [sectionItems indexOfObjectIdenticalTo:item];
    if (itemIndex == NSNotFound) {
        return nil;
    }
    
    return [NSIndexPath indexPathForRow:itemIndex inSection:sectionIndex];
}

- (BOOL)isLastSection:(NSInteger)section {
    return section == self.indexKeys.count - 1;
}

- (BOOL)isActivityIndicatorIndexPath:(NSIndexPath *)indexPath {
    if ([self isLastSection:indexPath.section]) {
        id key = [self.indexKeys objectAtIndex:indexPath.section];
        NSArray *sectionItems = [self.indexMap objectForKey:key];
        
        if (indexPath.row == sectionItems.count) {
            // Last section has one more row that items if we are expecting more objects.
            return YES;
        }
    }
    return NO;
}

- (UIImage *)tableView:(UITableView *)tableView imageForItem:(FBGraphObject *)item
{
    __block UIImage *image = nil;
    NSString *urlString = [self.controllerDelegate graphObjectTableDataSource:self
                                                             pictureUrlOfItem:item];
    if (urlString) {
        FBURLConnectionHandler handler =
        ^(FBURLConnection *connection, NSError *error, NSURLResponse *response, NSData *data) {
            [self addOrRemovePendingConnection:connection];
            if (!error) {
                image = [UIImage imageWithData:data];

                NSIndexPath *indexPath = [self indexPathForItem:item];
                if (indexPath) {
                    FBGraphObjectTableCell *cell =
                    (FBGraphObjectTableCell*)[tableView cellForRowAtIndexPath:indexPath];

                    if (cell) {
                        cell.picture = image;
                    }
                }
            }
        };

        FBURLConnection *connection = [[[FBURLConnection alloc]
                                        initWithURL:[NSURL URLWithString:urlString]
                                        completionHandler:handler]
                                       autorelease];

        [self addOrRemovePendingConnection:connection];
    }

    // If the picture had not been fetched yet by this object, but is cached in the
    // URL cache, we can complete synchronously above.  In this case, we will not
    // find the cell in the table because we are in the process of creating it. We can
    // just return the object here.
    if (image) {
        return image;
    }

    return self.defaultPicture;
}

// In tableView:imageForItem:, there are two code-paths, and both always run.
// Whichever runs first adds the connection to the collection of pending requests,
// and whichever runs second removes it.  This allows us to track all requests
// for which one code-path has run and the other has not.
- (void)addOrRemovePendingConnection:(FBURLConnection *)connection
{
    if ([self.pendingURLConnections containsObject:connection]) {
        [self.pendingURLConnections removeObject:connection];
    } else {
        [self.pendingURLConnections addObject:connection];
    }
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return [self.indexKeys count];
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section
{
    id key = [self.indexKeys objectAtIndex:section];
    NSArray *sectionItems = [self.indexMap objectForKey:key];
    
    int count = [sectionItems count];
    // If we are expecting more objects to be loaded via paging, add 1 to the
    // row count for the last section.
    if (self.expectingMoreGraphObjects &&
        self.dataNeededDelegate &&
        [self isLastSection:section]) {
        ++count;
    }
    return count;
}

- (NSArray *)sectionIndexTitlesForTableView:(UITableView *)tableView
{
    return self.indexKeys;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return NO;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    FBGraphObjectTableCell *cell = [self cellWithTableView:tableView];
    
    if ([self isActivityIndicatorIndexPath:indexPath]) {
        cell.picture = nil;
        cell.subtitle = nil;
        cell.title = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selected = NO;
        
        [cell startAnimatingActivityIndicator];
        
        [self.dataNeededDelegate graphObjectTableDataSourceNeedsData:self
                                                triggeredByIndexPath:indexPath];
    } else {
        FBGraphObject *item = [self itemAtIndexPath:indexPath];

        // This is a no-op if it doesn't have an activity indicator.
        [cell stopAnimatingActivityIndicator];
        
        if (item) {            
            if (self.itemPicturesEnabled) {
                cell.picture = [self tableView:tableView imageForItem:item];
            } else {
                cell.picture = nil;
            }
            
            if (self.itemSubtitleEnabled) {
                cell.subtitle = [self.controllerDelegate graphObjectTableDataSource:self
                                                                     subtitleOfItem:item];
            } else {
                cell.subtitle = nil;
            }
            
            cell.title = [self.controllerDelegate graphObjectTableDataSource:self
                                                                 titleOfItem:item];
            
            if ([self.selectionDelegate graphObjectTableDataSource:self
                                             selectionIncludesItem:item]) {
                cell.accessoryType = UITableViewCellAccessoryCheckmark;
                cell.selected = YES;
            } else {
                cell.accessoryType = UITableViewCellAccessoryNone;
                cell.selected = NO;
            }
        } else {
            cell.picture = nil;
            cell.subtitle = nil;
            cell.title = nil;
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selected = NO;
        }
    }
    
    return cell;
}

@end
