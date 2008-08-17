#import "ViTextView.h"
#import "ViLanguageStore.h"
#import "ViThemeStore.h"
#import "ViEditController.h"  // for declaration of the message: method
#import "NSString-scopeSelector.h"
#import "ExCommand.h"

@interface ViTextView (private)
- (BOOL)move_right:(ViCommand *)command;
- (void)disableWrapping;
- (BOOL)insert:(ViCommand *)command;
- (NSUInteger)skipWhitespaceFrom:(NSUInteger)startLocation toLocation:(NSUInteger)toLocation;
- (NSUInteger)skipWhitespaceFrom:(NSUInteger)startLocation;
- (void)recordInsertInRange:(NSRange)aRange;
- (void)recordDeleteOfString:(NSString *)aString atLocation:(NSUInteger)aLocation;
@end

@implementation ViTextView

- (id)initWithFrame:(NSRect)frame textContainer:(NSTextContainer *)aTextContainer
{
	NSLog(@"%s initializing", _cmd);
	self = [super initWithFrame:frame textContainer:aTextContainer];
	if(self)
	{
		[self initEditor];
	}
	return self;
}

- (void)initEditor
{
	[self setCaret:0];

	[[self textStorage] setDelegate:self];

	undoManager = [[NSUndoManager alloc] init];
	parser = [[ViCommand alloc] init];
	buffers = [[NSMutableDictionary alloc] init];
	storage = [self textStorage];

	wordSet = [NSCharacterSet characterSetWithCharactersInString:@"_"];
	[wordSet formUnionWithCharacterSet:[NSCharacterSet alphanumericCharacterSet]];
	whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];

	inputCommands = [NSDictionary dictionaryWithObjectsAndKeys:
			 @"input_newline:", [NSNumber numberWithUnsignedInteger:0x00000024], // enter
			 @"input_newline:", [NSNumber numberWithUnsignedInteger:0x0004002e], // ctrl-m
			 @"input_newline:", [NSNumber numberWithUnsignedInteger:0x00040026], // ctrl-j
			 @"input_backspace:", [NSNumber numberWithUnsignedInteger:0x00000033], // backspace
			 @"input_backspace:", [NSNumber numberWithUnsignedInteger:0x00040004], // ctrl-h
			 @"input_forward_delete:", [NSNumber numberWithUnsignedInteger:0x00800075], // delete
			 nil];

	nonWordSet = [[NSMutableCharacterSet alloc] init];
	[nonWordSet formUnionWithCharacterSet:wordSet];
	[nonWordSet formUnionWithCharacterSet:whitespace];
	[nonWordSet invert];

	[self setRichText:NO];
	[self setImportsGraphics:NO];
	[self setUsesFontPanel:NO];
	[self setUsesFindPanel:NO];
	//[self setPageGuideValues];
	[self disableWrapping];
	[self setContinuousSpellCheckingEnabled:NO];

	[self setTheme:[[ViThemeStore defaultStore] defaultTheme]];
}

- (void)setFilename:(NSURL *)aURL
{
	if(aURL)
	{
		bundle = [[ViLanguageStore defaultStore] bundleForFilename:[aURL path] language:&language];
		[language patterns];
	}
}

- (BOOL)illegal:(ViCommand *)command
{
	[[self delegate] message:@"%C isn't a vi command", command.key];
	return NO;
}

- (BOOL)nonmotion:(ViCommand *)command
{
	[[self delegate] message:@"%C may not be used as a motion command", command.motion_key];
	return NO;
}

- (BOOL)nodot:(ViCommand *)command
{
	[[self delegate] message:@"No command to repeat"];
	return NO;
}

- (BOOL)no_previous_ftFT:(ViCommand *)command
{
	[[self delegate] message:@"No previous F, f, T or t search"];
	return NO;
}

- (void)getLineStart:(NSUInteger *)bol_ptr end:(NSUInteger *)end_ptr contentsEnd:(NSUInteger *)eol_ptr forLocation:(NSUInteger)aLocation
{
	[[storage string] getLineStart:bol_ptr end:end_ptr contentsEnd:eol_ptr forRange:NSMakeRange(aLocation, 0)];
}

- (void)getLineStart:(NSUInteger *)bol_ptr end:(NSUInteger *)end_ptr contentsEnd:(NSUInteger *)eol_ptr
{
	[self getLineStart:bol_ptr end:end_ptr contentsEnd:eol_ptr forLocation:start_location];
}

/* Like insertText:, but works within beginEditing/endEditing
 */
- (void)insertString:(NSString *)aString atLocation:(NSUInteger)aLocation
{
	[[storage mutableString] insertString:aString atIndex:aLocation];
}

- (int)insertNewlineAtLocation:(NSUInteger)aLocation indentForward:(BOOL)indentForward
{
	NSLog(@"inserting newline at %u", aLocation);
	[self insertString:@"\n" atLocation:aLocation];
	insert_end_location++;

	if(aLocation != 0 && [[NSUserDefaults standardUserDefaults] integerForKey:@"autoindent"] == NSOnState)
	{
		NSRange searchRange;
		if(indentForward)
		{
			NSUInteger bol;
			[self getLineStart:&bol end:NULL contentsEnd:NULL forLocation:aLocation - 1];
			searchRange = NSMakeRange(bol, aLocation - 1 - bol);
		}
		else
		{
			NSUInteger eol;
			[self getLineStart:NULL end:NULL contentsEnd:&eol forLocation:aLocation + 1];
			searchRange = NSMakeRange(aLocation + 1, eol - aLocation + 1);
		}
		NSLog(@"doing auto-indentation, search range %u + %u", searchRange.location, searchRange.length);

		NSRange r = [[storage string] rangeOfCharacterFromSet:[[NSCharacterSet whitespaceCharacterSet] invertedSet]
							      options:0
								range:searchRange];
		NSLog(@"r = %u + %u", r.location, r.length);
		if(r.location != NSNotFound)
		{
			NSString *leading_whitespace = [[storage string] substringWithRange:NSMakeRange(searchRange.location, r.location - searchRange.location)];
			[self insertString:leading_whitespace atLocation:aLocation + (indentForward ? 1 : 0)];
			insert_end_location += [leading_whitespace length];
			return 1 + [leading_whitespace length];
		}
	}

	return 1;
}

/* Undo support
 */
- (void)undoDeleteOfString:(NSString *)aString atLocation:(NSUInteger)aLocation
{
	NSLog(@"undoing delete of [%@] (%p) at %u", aString, aString, aLocation);
	[self insertString:aString atLocation:aLocation];
	final_location = aLocation;
	[self recordInsertInRange:NSMakeRange(aLocation, [aString length])];
}

- (void)undoInsertInRange:(NSRange)aRange
{
	NSString *deletedString = [[storage string] substringWithRange:aRange];
	[storage deleteCharactersInRange:aRange];
	final_location = aRange.location;
	[self recordDeleteOfString:deletedString atLocation:aRange.location];
}

- (void)recordInsertInRange:(NSRange)aRange
{
	NSLog(@"pushing insert of text in range %u+%u onto undo stack", aRange.location, aRange.length);
	[[undoManager prepareWithInvocationTarget:self] undoInsertInRange:aRange];
	[undoManager setActionName:@"insert text"];

	if(hasBeginUndoGroup)
		[undoManager endUndoGrouping];
	hasBeginUndoGroup = NO;
}

- (void)recordDeleteOfString:(NSString *)aString atLocation:(NSUInteger)aLocation
{
	NSLog(@"pushing delete of [%@] (%p) at %u onto undo stack", aString, aString, aLocation);
	[[undoManager prepareWithInvocationTarget:self] undoDeleteOfString:aString atLocation:aLocation];
	[undoManager setActionName:@"delete text"];
}

- (void)recordDeleteOfRange:(NSRange)aRange
{
	NSString *s = [[storage string] substringWithRange:aRange];
	[self recordDeleteOfString:s atLocation:aRange.location];
}

- (void)recordReplacementOfRange:(NSRange)aRange withLength:(NSUInteger)aLength
{
	[undoManager beginUndoGrouping];
	[self recordDeleteOfRange:aRange];
	[self recordInsertInRange:NSMakeRange(aRange.location, aLength)];
	[undoManager endUndoGrouping];
}


- (void)yankToBuffer:(unichar)bufferName append:(BOOL)appendFlag range:(NSRange)yankRange
{
	// get the unnamed buffer
	NSMutableString *buffer = [buffers objectForKey:@"unnamed"];
	if(buffer == nil)
	{
		buffer = [[NSMutableString alloc] init];
		[buffers setObject:buffer forKey:@"unnamed"];
	}

	[buffer setString:[[storage string] substringWithRange:yankRange]];
}

- (void)cutToBuffer:(unichar)bufferName append:(BOOL)appendFlag range:(NSRange)cutRange
{
	[self recordDeleteOfRange:cutRange];
	[self yankToBuffer:bufferName append:appendFlag range:cutRange];
	[storage deleteCharactersInRange:cutRange];
}

/* syntax: [buffer][count]d[count]motion */
- (BOOL)delete:(ViCommand *)command
{
	// need beginning of line for correcting caret position after deletion
	NSUInteger bol;
	[self getLineStart:&bol end:NULL contentsEnd:NULL];

	[self cutToBuffer:0 append:NO range:affectedRange];

	// correct caret position if we deleted the last character(s) on the line
	if(bol > [[storage string] length])
		bol = IMAX(0, [[storage string] length] - 1);
	NSUInteger eol;
	[self getLineStart:NULL end:NULL contentsEnd:&eol forLocation:bol];
	if(affectedRange.location >= eol)
		final_location = IMAX(bol, eol - (command.key == 'c' ? 0 : 1));
	else
		final_location = affectedRange.location;

	return YES;
}

/* syntax: [buffer][count]y[count][motion] */
- (BOOL)yank:(ViCommand *)command
{
	[self yankToBuffer:0 append:NO range:affectedRange];

	/* From nvi:
	 * !!!
	 * Historic vi moved the cursor to the from MARK if it was before the current
	 * cursor and on a different line, e.g., "yk" moves the cursor but "yj" and
	 * "yl" do not.  Unfortunately, it's too late to change this now.  Matching
	 * the historic semantics isn't easy.  The line number was always changed and
	 * column movement was usually relative.  However, "y'a" moved the cursor to
	 * the first non-blank of the line marked by a, while "y`a" moved the cursor
	 * to the line and column marked by a.  Hopefully, the motion component code
	 * got it right...   Unlike delete, we make no adjustments here.
	 */
	/* yy shouldn't move the cursor */
	if(command.motion_key != 'y')
		final_location = affectedRange.location;
	return YES;
}

/* syntax: [buffer][count]P */
- (BOOL)put_before:(ViCommand *)command
{
	// get the unnamed buffer
	NSMutableString *buffer = [buffers objectForKey:@"unnamed"];
	if([buffer length] == 0)
	{
		[[self delegate] message:@"The default buffer is empty"];
		return NO;
	}

	if([buffer hasSuffix:@"\n"])
	{
		NSUInteger bol;
		[self getLineStart:&bol end:NULL contentsEnd:NULL];

		start_location = final_location = bol;
	}
	[self insertString:buffer atLocation:start_location];
	[self recordInsertInRange:NSMakeRange(start_location, [buffer length])];

	return YES;
}

/* syntax: [buffer][count]p */
- (BOOL)put_after:(ViCommand *)command
{
	// get the unnamed buffer
	NSMutableString *buffer = [buffers objectForKey:@"unnamed"];
	if([buffer length] == 0)
	{
		[[self delegate] message:@"The default buffer is empty"];
		return NO;
	}

	NSUInteger eol;
	[self getLineStart:NULL end:NULL contentsEnd:&eol];
	if([buffer hasSuffix:@"\n"])
	{
		// puting whole lines
		final_location = eol + 1;
	}
	else if(start_location < eol)
	{
		// in contrast to move_right, we are allowed to move to EOL here
		final_location = start_location + 1;
	}

	[self insertString:buffer atLocation:final_location];
	[self recordInsertInRange:NSMakeRange(final_location, [buffer length])];

	return YES;
}

/* syntax: [count]r<char> */
- (BOOL)replace:(ViCommand *)command
{
	[self recordReplacementOfRange:NSMakeRange(start_location, 1) withLength:1];

	[[storage mutableString] replaceCharactersInRange:NSMakeRange(start_location, 1)
					withString:[NSString stringWithFormat:@"%C", command.argument]];

	return YES;
}

/* syntax: [buffer][count]c[count]motion */
- (BOOL)change:(ViCommand *)command
{
	/* The change command is implemented as delete + insert. This should be undone
	 * as a single operation, so we begin an undo group here and end it when recording
	 * the insert operation.
	 */
	[undoManager beginUndoGrouping];
	hasBeginUndoGroup = YES;
	if([self delete:command])
	{
		end_location = final_location;
		[self setInsertMode:command];
		return YES;
	}
	else
		return NO;
}

/* syntax: i */
- (BOOL)insert:(ViCommand *)command
{
	[self setInsertMode:command];
	return YES;
}

/* syntax: [buffer][count]s */
- (BOOL)substitute:(ViCommand *)command
{
	NSUInteger eol;
	[self getLineStart:NULL end:NULL contentsEnd:&eol];
	NSUInteger c = command.count;
	if(command.count == 0)
		c = 1;
	if(start_location + c >= eol)
		c = eol - start_location;
	[self cutToBuffer:0 append:NO range:NSMakeRange(start_location, c)];
	return [self insert:command];
}

/* syntax: [count]J */
- (BOOL)join:(ViCommand *)command
{
	NSUInteger bol, eol, end;
	[self getLineStart:&bol end:&end contentsEnd:&eol];
	if(end == eol)
	{
		[[self delegate] message:@"No following lines to join"];
		return NO;
	}

	/* From nvi:
	 * Historic practice:
	 *
	 * If force specified, join without modification.
	 * If the current line ends with whitespace, strip leading
	 *    whitespace from the joined line.
	 * If the next line starts with a ), do nothing.
	 * If the current line ends with ., insert two spaces.
	 * Else, insert one space.
	 *
	 * One change -- add ? and ! to the list of characters for
	 * which we insert two spaces.  I expect that POSIX 1003.2
	 * will require this as well.
	 */

	/* From nvi:
	 * Historic practice for vi was to put the cursor at the first
	 * inserted whitespace character, if there was one, or the
	 * first character of the joined line, if there wasn't, or the
	 * last character of the line if joined to an empty line.  If
	 * a count was specified, the cursor was moved as described
	 * for the first line joined, ignoring subsequent lines.  If
	 * the join was a ':' command, the cursor was placed at the
	 * first non-blank character of the line unless the cursor was
	 * "attracted" to the end of line when the command was executed
	 * in which case it moved to the new end of line.  There are
	 * probably several more special cases, but frankly, my dear,
	 * I don't give a damn.  This implementation puts the cursor
	 * on the first inserted whitespace character, the first
	 * character of the joined line, or the last character of the
	 * line regardless.  Note, if the cursor isn't on the joined
	 * line (possible with : commands), it is reset to the starting
	 * line.
	 */

	NSUInteger end2, eol2;
	[self getLineStart:NULL end:&end2 contentsEnd:&eol2 forLocation:end];
	NSLog(@"join: bol = %u, eol = %u, end = %u, eol2 = %u, end2 = %u", bol, eol, end, eol2, end2);

	if(eol2 == end || bol == eol || [whitespace characterIsMember:[[storage string] characterAtIndex:eol-1]])
	{
		/* From nvi: Empty lines just go away. */
		NSRange r = NSMakeRange(eol, end - eol);
		[self recordDeleteOfRange:r];
		[[storage mutableString] deleteCharactersInRange:r];
		if(bol == eol)
			final_location = IMAX(bol, eol2 - 1 - (end - eol));
		else
			final_location = IMAX(bol, eol - 1);
	}
	else
	{
		final_location = eol;
		NSString *joinPadding = @" ";
		if([[NSCharacterSet characterSetWithCharactersInString:@".!?"] characterIsMember:[[storage string] characterAtIndex:eol-1]])
			joinPadding = @"  ";
		else if([[storage string] characterAtIndex:end] == ')')
		{
			final_location = eol - 1;
			joinPadding = @"";
		}
		NSUInteger sol2 = [self skipWhitespaceFrom:end toLocation:eol2];
		NSRange r = NSMakeRange(eol, sol2 - eol);
		[self recordReplacementOfRange:r withLength:[joinPadding length]];
		[[storage mutableString] replaceCharactersInRange:r withString:joinPadding];
	}

	return YES;
}

/* syntax: [buffer]D */
- (BOOL)delete_eol:(ViCommand *)command
{
	NSUInteger bol, eol;
	[self getLineStart:&bol end:NULL contentsEnd:&eol];
	if(bol == eol)
	{
		[[self delegate] message:@"Already at end-of-line"];
		return NO;
	}

	NSRange range;
	range.location = start_location;
	range.length = eol - start_location;

	[self cutToBuffer:0 append:NO range:range];

	final_location = IMAX(bol, start_location - 1);
	return YES;
}

/* syntax: [buffer][count]C */
- (BOOL)change_eol:(ViCommand *)command
{
	NSUInteger bol, eol;
	[self getLineStart:&bol end:NULL contentsEnd:&eol];
	if(eol > bol)
	{
		NSRange range;
		range.location = start_location;
		range.length = eol - start_location;

		[self cutToBuffer:0 append:NO range:range];
	}

	return [self insert:command];
}

/* syntax: [count]h */
- (BOOL)move_left:(ViCommand *)command
{
	NSUInteger bol;
	[self getLineStart:&bol end:NULL contentsEnd:NULL];
	if(start_location == bol)
	{
		if(command)
		{
			/* XXX: this command is also used outside the scope of an explicit 'h' command.
			 * In such cases, we shouldn't issue an error message.
			 */
			[[self delegate] message:@"Already in the first column"];
		}
		return NO;
	}
	final_location = end_location = start_location - 1;
	return YES;
}

/* syntax: [count]l */
- (BOOL)move_right:(ViCommand *)command
{
	NSUInteger eol;
	[self getLineStart:NULL end:NULL contentsEnd:&eol];
	if(start_location + 1 >= eol)
	{
		[[self delegate] message:@"Already at end-of-line"];
		return NO;
	}
	final_location = end_location = start_location + 1;
	return YES;
}

- (void)gotoColumn:(NSUInteger)column fromLocation:(NSUInteger)aLocation
{
	NSUInteger bol, eol;
	[self getLineStart:&bol end:NULL contentsEnd:&eol forLocation:aLocation];
	if(eol - bol > column)
		final_location = end_location = bol + column;
	else if(eol - bol > 1)
		final_location = end_location = eol - 1;
	else
		final_location = end_location = bol;
}

/* syntax: [count]k */
- (BOOL)move_up:(ViCommand *)command
{
	NSUInteger bol;
	[self getLineStart:&bol end:NULL contentsEnd:NULL];
	if(bol == 0)
	{
		[[self delegate] message:@"Already at the beginning of the file"];
		return NO;
	}
		
	NSUInteger column = start_location - bol;
	final_location = end_location = bol - 1; // previous line
	[self gotoColumn:column fromLocation:end_location];
	need_scroll = YES;
	return YES;
}

/* syntax: [count]j */
- (BOOL)move_down:(ViCommand *)command
{
	NSUInteger bol, end;
	[self getLineStart:&bol end:&end contentsEnd:NULL];
	if(end >= [storage length])
	{
		[[self delegate] message:@"Already at end-of-file"];
		return NO;
	}
	NSUInteger column = start_location - bol;
	final_location = end_location = end; // next line
	[self gotoColumn:column fromLocation:end_location];
	need_scroll = YES;
	return YES;
}

/* syntax: 0 */
- (BOOL)move_bol:(ViCommand *)command
{
	[self getLineStart:&end_location end:NULL contentsEnd:NULL];
	final_location = end_location;
	need_scroll = YES;
	return YES;
}

/* syntax: _ or ^ */
- (BOOL)move_first_char:(ViCommand *)command
{
	[self getLineStart:&end_location end:NULL contentsEnd:NULL];
	end_location = [self skipWhitespaceFrom:end_location];
	final_location = end_location;
	need_scroll = YES;
	return YES;
}

/* syntax: [count]$ */
- (BOOL)move_eol:(ViCommand *)command
{
	if([storage length] > 0)
	{
		NSUInteger bol, eol;
		[self getLineStart:&bol end:NULL contentsEnd:&eol];
		final_location = end_location = IMAX(bol, eol - command.ismotion);
		need_scroll = YES;
	}
	return YES;
}

/* syntax: [count]f<char> */
- (BOOL)move_to_char:(ViCommand *)command
{
	NSUInteger eol;
	[self getLineStart:NULL end:NULL contentsEnd:&eol];
	NSUInteger i = start_location;
	int count = IMAX(command.count, 1);
	if(!command.ismotion)
		count = IMAX(command.motion_count, 1);
	while(count--)
	{
		while(++i < eol && [[storage string] characterAtIndex:i] != command.argument)
			/* do nothing */ ;
		if(i == eol)
		{
			[[self delegate] message:@"%C not found", command.argument];
			return NO;
		}
	}

	final_location = command.ismotion ? i : start_location;
	end_location = i + 1;
	return YES;

}

/* syntax: [count]t<char> */
- (BOOL)move_til_char:(ViCommand *)command
{
	if([self move_to_char:command])
	{
		end_location--;
		final_location--;
		return YES;
	}
	return NO;
}

/* syntax: [count]G */
- (BOOL)goto_line:(ViCommand *)command
{
	int count = command.count;
	if(!command.ismotion)
		count = command.motion_count;

	if(count > 0)
	{
		int line = 1;
		final_location = end_location = 0;
		while(line < count)
		{
			//NSLog(@"%s got line %i at location %u", _cmd, line, end_location);
			NSUInteger end;
			[self getLineStart:NULL end:&end contentsEnd:NULL forLocation:end_location];
			if(end_location == end)
			{
				[[self delegate] message:@"Movement past the end-of-file"];
				final_location = end_location = start_location;
				return NO;
			}
			final_location = end_location = end;
			line++;
		}
	}
	else
	{
		/* goto last line */
		NSUInteger last_location = [[storage string] length];
		if(last_location > 0)
			--last_location;
		[self getLineStart:&end_location end:NULL contentsEnd:NULL forLocation:last_location];
		final_location = end_location;
	}
	need_scroll = YES;
	return YES;
}

/* syntax: [count]a */
- (BOOL)append:(ViCommand *)command
{
	NSUInteger bol, eol;
	[self getLineStart:&bol end:NULL contentsEnd:&eol];
	if(start_location < eol)
	{
		start_location += 1;
		final_location = end_location = start_location;
	}
	return [self insert:command];
}

/* syntax: [count]A */
- (BOOL)append_eol:(ViCommand *)command
{
	[self move_eol:command];
	start_location = end_location;
	return [self append:command];
}

/* syntax: o */
- (BOOL)open_line_below:(ViCommand *)command
{
	[self getLineStart:NULL end:NULL contentsEnd:&end_location];
	int num_chars = [self insertNewlineAtLocation:end_location indentForward:YES];
	final_location = end_location + num_chars;
	[self recordInsertInRange:NSMakeRange(end_location, num_chars)];
	return [self insert:command];
}

/* syntax: O */
- (BOOL)open_line_above:(ViCommand *)command
{
	[self getLineStart:&end_location end:NULL contentsEnd:NULL];
	int num_chars = [self insertNewlineAtLocation:end_location indentForward:NO];
	final_location = end_location - 1 + num_chars;
	[self recordInsertInRange:NSMakeRange(end_location, num_chars)];
	return [self insert:command];
}

/* syntax: u */
- (BOOL)vi_undo:(ViCommand *)command
{
	if(![undoManager canUndo])
	{
		[[self delegate] message:@"Can't undo"];
		return NO;
	}
	[undoManager undo];
	return YES;
}

- (NSUInteger)skipCharactersInSet:(NSCharacterSet *)characterSet from:(NSUInteger)startLocation to:(NSUInteger)toLocation backward:(BOOL)backwardFlag
{
	NSString *s = [storage string];
	NSRange r = [s rangeOfCharacterFromSet:[characterSet invertedSet]
				       options:backwardFlag ? NSBackwardsSearch : 0
					 range:backwardFlag ? NSMakeRange(toLocation, startLocation - toLocation + 1) : NSMakeRange(startLocation, toLocation - startLocation)];
	if(r.location == NSNotFound)
		return backwardFlag ? toLocation : toLocation; // FIXME: this is strange...
	return r.location;
}

- (NSUInteger)skipCharactersInSet:(NSCharacterSet *)characterSet fromLocation:(NSUInteger)startLocation backward:(BOOL)backwardFlag
{
	return [self skipCharactersInSet:characterSet
				    from:startLocation
				      to:backwardFlag ? 0 : [storage length]
				backward:backwardFlag];
}

- (NSUInteger)skipWhitespaceFrom:(NSUInteger)startLocation toLocation:(NSUInteger)toLocation
{
	return [self skipCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]
				    from:startLocation
				      to:toLocation
				backward:NO];
}

- (NSUInteger)skipWhitespaceFrom:(NSUInteger)startLocation
{
	return [self skipCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]
			    fromLocation:startLocation
				backward:NO];
}

/* if caret on word-char:
 *      skip word-chars
 *      skip whitespace
 * else if caret on whitespace:
 *      skip whitespace
 * else:
 *      skip to first word-char-or-space
 *      skip whitespace
 */

/* syntax: [count]w */
/* syntax: [count]W */
- (BOOL)word_forward:(ViCommand *)command
{
	if([storage length] == 0)
	{
		[[self delegate] message:@"Empty file"];
		return NO;
	}
	NSString *s = [storage string];
	unichar ch = [s characterAtIndex:start_location];

	BOOL bigword = (command.ismotion ? command.key == 'W' : command.motion_key == 'W');

	if(!bigword && [wordSet characterIsMember:ch])
	{
		// skip word-chars and whitespace
		end_location = [self skipCharactersInSet:wordSet fromLocation:start_location backward:NO];
		NSLog(@"from word char: %u -> %u", start_location, end_location);
	}
	else if(![whitespace characterIsMember:ch])
	{
		// inside non-word-chars
		end_location = [self skipCharactersInSet:bigword ? [whitespace invertedSet] : nonWordSet fromLocation:start_location backward:NO];
	}
	else if(!command.ismotion && command.key != 'd' && command.key != 'y')
	{
		/* We're in whitespace. */
		/* See comment from nvi below. */
		end_location = start_location + 1;
	}
	
	/* From nvi:
	 * Movements associated with commands are different than movement commands.
	 * For example, in "abc  def", with the cursor on the 'a', "cw" is from
	 * 'a' to 'c', while "w" is from 'a' to 'd'.  In general, trailing white
	 * space is discarded from the change movement.  Another example is that,
	 * in the same string, a "cw" on any white space character replaces that
	 * single character, and nothing else.  Ain't nothin' in here that's easy. 
	 */
	if(command.ismotion || command.key == 'd' || command.key == 'y')
		end_location = [self skipWhitespaceFrom:end_location];

	if(!command.ismotion && (command.key == 'd' || command.key == 'y'))
	{
		/* Restrict to current line if deleting/yanking last word on line.
		 * However, an empty line can be deleted as a word.
		 */
		NSUInteger bol, eol;
		[self getLineStart:&bol end:NULL contentsEnd:&eol];
		if(end_location > eol && bol != eol)
		{
			NSLog(@"adjusting location from %lu to %lu at EOL", end_location, eol);
			end_location = eol;
		}
	}
	else if(end_location >= [s length])
		end_location = [s length] - 1;
	final_location = end_location;
	return YES;
}

/* syntax: [count]b */
/* syntax: [count]B */
- (BOOL)word_backward:(ViCommand *)command
{
	if([storage length] == 0)
	{
		[[self delegate] message:@"Empty file"];
		return NO;
	}
	if(start_location == 0)
	{
		[[self delegate] message:@"Already at the beginning of the file"];
		return NO;
	}
	NSString *s = [storage string];
	end_location = start_location - 1;
	unichar ch = [s characterAtIndex:end_location];

	/* From nvi:
         * !!!
         * If in whitespace, or the previous character is whitespace, move
         * past it.  (This doesn't count as a word move.)  Stay at the
         * character before the current one, it sets word "state" for the
         * 'b' command.
         */
	if([whitespace characterIsMember:ch])
	{
		end_location = [self skipCharactersInSet:whitespace fromLocation:end_location backward:YES];
		if(end_location == 0)
		{
			final_location = end_location;
			return YES;
		}
	}
	ch = [s characterAtIndex:end_location];

	BOOL bigword = (command.ismotion ? command.key == 'B' : command.motion_key == 'B');

	if(bigword)
	{
		end_location = [self skipCharactersInSet:[whitespace invertedSet] fromLocation:end_location backward:YES];
		if([whitespace characterIsMember:[s characterAtIndex:end_location]])
			end_location++;
	}
	else if([wordSet characterIsMember:ch])
	{
		// skip word-chars and whitespace
		end_location = [self skipCharactersInSet:wordSet fromLocation:end_location backward:YES];
		if(![wordSet characterIsMember:[s characterAtIndex:end_location]])
			end_location++;
	}
	else
	{
		// inside non-word-chars
		end_location = [self skipCharactersInSet:nonWordSet fromLocation:end_location backward:YES];
		if([wordSet characterIsMember:[s characterAtIndex:end_location]])
			end_location++;
	}

	final_location = end_location;
	return YES;
}

- (BOOL)end_of_word:(ViCommand *)command
{
	if([storage length] == 0)
	{
		[[self delegate] message:@"Empty file"];
		return NO;
	}
	NSString *s = [storage string];
	end_location = start_location + 1;
	unichar ch = [s characterAtIndex:end_location];

	/* From nvi:
         * !!!
         * If in whitespace, or the next character is whitespace, move past
         * it.  (This doesn't count as a word move.)  Stay at the character
         * past the current one, it sets word "state" for the 'e' command.
         */
	if([whitespace characterIsMember:ch])
	{
		end_location = [self skipCharactersInSet:whitespace fromLocation:end_location backward:NO];
		if(end_location == [s length])
		{
			final_location = end_location;
			return YES;
		}
	}

	BOOL bigword = (command.ismotion ? command.key == 'E' : command.motion_key == 'E');

	ch = [s characterAtIndex:end_location];
	if(bigword)
	{
		end_location = [self skipCharactersInSet:[whitespace invertedSet] fromLocation:end_location backward:NO];
		if(command.ismotion || (command.key != 'd' && command.key != 'e'))
			end_location--;
	}
	else if([wordSet characterIsMember:ch])
	{
		end_location = [self skipCharactersInSet:wordSet fromLocation:end_location backward:NO];
		if(command.ismotion || (command.key != 'd' && command.key != 'e'))
			end_location--;
	}
	else
	{
		// inside non-word-chars
		end_location = [self skipCharactersInSet:nonWordSet fromLocation:end_location backward:NO];
		if(command.ismotion || (command.key != 'd' && command.key != 'e'))
			end_location--;
	}

	final_location = end_location;
	return YES;
}

/* syntax: [count]I */
- (BOOL)insert_bol:(ViCommand *)command
{
	NSString *s = [storage string];
	if([s length] == 0)
		return YES;
	NSUInteger bol, eol;
	[self getLineStart:&bol end:NULL contentsEnd:&eol];

	unichar ch = [s characterAtIndex:bol];
	if([whitespace characterIsMember:ch])
	{
		// skip leading whitespace
		end_location = [self skipWhitespaceFrom:bol toLocation:eol];
	}
	else
		end_location = bol;
	final_location = end_location;
	return [self insert:command];
}

/* syntax: [count]x */
- (BOOL)delete_forward:(ViCommand *)command
{
	NSString *s = [storage string];
	if([s length] == 0)
	{
		[[self delegate] message:@"No characters to delete"];
		return NO;
	}
	NSUInteger bol, eol;
	[self getLineStart:&bol end:NULL contentsEnd:&eol];
	if(bol == eol)
	{
		[[self delegate] message:@"no characters to delete"];
		return NO;
	}

	NSRange del;
	del.location = start_location;
	del.length = IMAX(1, command.count);
	if(del.location + del.length > eol)
		del.length = eol - del.location;
	[self cutToBuffer:0 append:NO range:del];

	// correct caret position if we deleted the last character(s) on the line
	end_location = start_location;
	--eol;
	if(end_location == eol && eol > bol)
		--end_location;
	final_location = end_location;
	return YES;
}

/* syntax: [count]X */
- (BOOL)delete_backward:(ViCommand *)command
{
	if([storage length] == 0)
	{
		[[self delegate] message:@"Already in the first column"];
		return NO;
	}
	NSUInteger bol;
	[self getLineStart:&bol end:NULL contentsEnd:NULL];
	if(start_location == bol)
	{
		[[self delegate] message:@"Already in the first column"];
		return NO;
	}
	NSRange del;
	del.location = IMAX(bol, start_location - IMAX(1, command.count));
	del.length = start_location - del.location;
	[self cutToBuffer:0 append:NO range:del];
	end_location = del.location;
	final_location = end_location;
	
	return YES;
}

/* syntax: ^F */
- (BOOL)forward_screen:(ViCommand *)command
{
	NSLog(@"forward_screen");
	[self pageDown:self];
	end_location = final_location = [self caret];
	return YES;
}

/* syntax: ^B */
- (BOOL)backward_screen:(ViCommand *)command
{
	NSLog(@"backward_screen");
	[self pageUp:self];
	end_location = final_location = [self caret];
	return YES;
}

/* syntax: [count]> */
- (BOOL)shift_right:(ViCommand *)command
{
	int lines = command.count;
	if(lines == 0)
		lines = 1;

	[undoManager beginUndoGrouping];

	// process each line separately (remember that line mode is set)
	NSUInteger nextLocation = affectedRange.location;
	while(lines--)
	{
		[self insertString:@"\t" atLocation:nextLocation];
		[self recordInsertInRange:NSMakeRange(nextLocation, 1)];

		// get next line
		NSUInteger end;
		[self getLineStart:NULL end:&end contentsEnd:NULL forLocation:nextLocation];
		if(end == nextLocation || end == NSNotFound)
			break;
		nextLocation = end;
	}
	[undoManager endUndoGrouping];

	end_location = final_location = start_location + 1;

	return YES;
}

/* syntax: [count]< */
- (BOOL)shift_left:(ViCommand *)command
{
	int lines = command.count;
	if(lines == 0)
		lines = 1;

	BOOL hasUndoGrouping = NO;
	BOOL gotEndLocation = NO;

	// process each line separately (remember that line mode is set)
	NSUInteger nextLocation = affectedRange.location;
	while(lines--)
	{
		NSUInteger end;
		[self getLineStart:NULL end:&end contentsEnd:NULL forLocation:nextLocation];
		if(end == nextLocation || end == NSNotFound)
			break;
		NSRange line = NSMakeRange(nextLocation, end - nextLocation);
		nextLocation = end;

		NSString *s = [[storage string] substringWithRange:line];
		if([s hasPrefix:@"\t"])
		{
			if(!hasUndoGrouping)
			{
				[undoManager beginUndoGrouping];
				hasUndoGrouping = YES;
			}
			[self recordDeleteOfRange:NSMakeRange(line.location, 1)];
			[storage deleteCharactersInRange:NSMakeRange(line.location, 1)];
			nextLocation--;

			if(!gotEndLocation && start_location > affectedRange.location)
				end_location = final_location = start_location - 1;
		}
		gotEndLocation = YES;
	}

	if(hasUndoGrouping)
		[undoManager endUndoGrouping];

	return YES;
}

- (void)parseAndExecuteExCommand:(NSString *)exCommandString
{
	if([exCommandString length] > 0)
	{
		ExCommand *ex = [[ExCommand alloc] initWithString:exCommandString];
		NSLog(@"got ex [%@], command = [%@], method = [%@]", ex, ex.command, ex.method);
		if(ex.method == nil)
			[[self delegate] message:@"The %@ command is unknown.", ex.command];
		else
		{
			SEL selector = NSSelectorFromString([NSString stringWithFormat:@"%@:", ex.method]);
			if([self respondsToSelector:selector])
				[self performSelector:selector withObject:ex];
			else
				[[self delegate] message:@"The %@ command is not implemented.", ex.command];
		}
	}
}

- (BOOL)ex_command:(ViCommand *)command
{
	[[self delegate] getExCommandForTextView:self selector:@selector(parseAndExecuteExCommand:)];
	return YES;
}

- (void)highlightFindMatch:(OGRegularExpressionMatch *)match
{
	[self showFindIndicatorForRange:[match rangeOfMatchedString]];
}

- (BOOL)findPattern:(NSString *)pattern options:(unsigned)find_options
{
	unsigned rx_options = OgreNotBOLOption | OgreNotEOLOption;
	if([[NSUserDefaults standardUserDefaults] integerForKey:@"ignorecase"] == NSOnState)
		rx_options |= OgreIgnoreCaseOption;

	if(lastSearchRegexp == nil)
	{
		/* compile the pattern regexp */
		@try
		{
			lastSearchRegexp = [OGRegularExpression regularExpressionWithString:pattern options:rx_options];
			NSLog(@"compiled find regexp: [%@]", lastSearchRegexp);
		}
		@catch(NSException *exception)
		{
			NSLog(@"***** FAILED TO COMPILE REGEXP ***** [%@], exception = [%@]", pattern, exception);
			[[self delegate] message:@"Invalid search pattern: %@", exception];
			return NO;
		}
	}

	NSArray *foundMatches = [lastSearchRegexp allMatchesInString:[storage string] options:rx_options];

	if([foundMatches count] == 0)
	{
		NSLog(@"pattern not found");
		[[self delegate] message:@"Pattern not found"];
	}
	else
	{
		OGRegularExpressionMatch *match, *nextMatch = nil;
		for(match in foundMatches)
		{
			NSRange r = [match rangeOfMatchedString];
			if(find_options == 0)
			{
				if(nextMatch == nil && r.location > start_location)
					nextMatch = match;
			}
			else if(r.location < start_location)
			{
				nextMatch = match;
			}
		}

		if(nextMatch == nil)
		{
			if(find_options == 0)
				nextMatch = [foundMatches objectAtIndex:0];
			else
				nextMatch = [foundMatches lastObject];

			[[self delegate] message:@"Search wrapped"];
		}

		if(nextMatch)
		{
			NSRange r = [nextMatch rangeOfMatchedString];
			[self scrollRangeToVisible:r];
			final_location = end_location = r.location;
			[self performSelector:@selector(highlightFindMatch:) withObject:nextMatch afterDelay:0];
		}

		return YES;
	}

	return NO;
}

- (void)find_forward_callback:(NSString *)pattern
{
	lastSearchPattern = pattern;
	if([self findPattern:pattern options:0])
	{
		[self setCaret:final_location];
	}
}

/* syntax: /regexp */
- (BOOL)find:(ViCommand *)command
{
	lastSearchRegexp = nil;
	[[self delegate] getExCommandForTextView:self selector:@selector(find_forward_callback:)];
	// FIXME: this won't work as a motion command!
	// d/pattern will not work!
	return YES;
}

/* syntax: n */
- (BOOL)repeat_find:(ViCommand *)comand
{
	if(lastSearchPattern == nil)
	{
		[[self delegate] message:@"No previous search pattern"];
		return NO;
	}

	return [self findPattern:lastSearchPattern options:0];
}

/* syntax: N */
- (BOOL)repeat_find_backward:(ViCommand *)comand
{
	if(lastSearchPattern == nil)
	{
		[[self delegate] message:@"No previous search pattern"];
		return NO;
	}

	return [self findPattern:lastSearchPattern options:1];
}


- (BOOL)performKeyEquivalent:(NSEvent *)theEvent
{
	if([theEvent type] != NSKeyDown && [theEvent type] != NSKeyUp)
		return NO;

	if([theEvent type] == NSKeyUp)
	{
		unichar charcode = [[theEvent characters] characterAtIndex:0];
		NSLog(@"Got a performKeyEquivalent event, characters: '%@', keycode = %u, modifiers = 0x%04X",
		      [theEvent charactersIgnoringModifiers],
		      charcode,
		      [theEvent modifierFlags]);
		return YES;
	}

	NSLog(@"Letting super handle unknown performKeyEquivalent event, keycode = %04X", [theEvent keyCode]);
	return [super performKeyEquivalent:theEvent];
}

/*
 * NSAlphaShiftKeyMask = 1 << 16,  (Caps Lock)
 * NSShiftKeyMask      = 1 << 17,
 * NSControlKeyMask    = 1 << 18,
 * NSAlternateKeyMask  = 1 << 19,
 * NSCommandKeyMask    = 1 << 20,
 * NSNumericPadKeyMask = 1 << 21,
 * NSHelpKeyMask       = 1 << 22,
 * NSFunctionKeyMask   = 1 << 23,
 * NSDeviceIndependentModifierFlagsMask = 0xffff0000U
 */

- (void)setCaret:(NSUInteger)location
{
	[self setSelectedRange:NSMakeRange(location, 0)];
}

- (NSUInteger)caret
{
	return [self selectedRange].location;
}

- (void)setCommandMode
{
	mode = ViCommandMode;
}

- (void)setInsertMode:(ViCommand *)command
{
	if(command.text)
	{
		NSLog(@"replaying inserted text [%@] at %u", command.text, end_location);
		[self insertString:command.text atLocation:end_location];
		final_location = end_location + [command.text length];
		[self recordInsertInRange:NSMakeRange(end_location, [command.text length])];

		 // simulate 'escape' (back to command mode)
		start_location = final_location;
		[self move_left:nil];
	}
	else
	{
		NSLog(@"entering insert mode at location %u", end_location);
		mode = ViInsertMode;
		insert_start_location = insert_end_location = end_location;
	}
}

- (void)evaluateCommand:(ViCommand *)command
{
	/* Default start- and end-location is the current location. */
	start_location = [self caret];
	end_location = start_location;
	final_location = start_location;

	if(command.motion_method)
	{
		/* The command has an associated motion component.
		 * Run the motion method and record the start and end locations.
		 */
		if([self performSelector:NSSelectorFromString(command.motion_method) withObject:command] == NO)
		{
			/* the command failed */
			[command reset];
			final_location = start_location;
			return;
		}
	}

	/* Find out the affected range for this command */
	NSUInteger l1 = start_location, l2 = end_location;
	if(l2 < l1)
	{	/* swap if end < start */
		l2 = l1;
		l1 = end_location;
	}
	//NSLog(@"affected locations: %u -> %u (%u chars)", l1, l2, l2 - l1);

	if(command.line_mode && !command.ismotion)
	{
		/* if this command is line oriented, extend the affectedRange to whole lines */
		NSUInteger bol, end;

		[self getLineStart:&bol end:&end contentsEnd:NULL forLocation:l1];

		if(!command.motion_method)
		{
			/* This is a "doubled" command (like dd or yy).
			 * A count, or motion-count, affects that number of whole lines.
			 */
			int line_count = command.count;
			if(line_count == 0)
				line_count = command.motion_count;
			while(--line_count > 0)
			{
				l2 = end;
				[self getLineStart:NULL end:&end contentsEnd:NULL forLocation:l2];
			}
		}
		else
		{
			[self getLineStart:NULL end:&end contentsEnd:NULL forLocation:l2];
		}

		l1 = bol;
		l2 = end;
		NSLog(@"after line mode correction: affected locations: %u -> %u (%u chars)", l1, l2, l2 - l1);

		/* If a line mode range includes the last line, also include the newline before the first line.
		 * This way delete doesn't leave an empty line.
		 */
		if(l2 == [storage length])
		{
			l1 = IMAX(0, l1 - 1);	// FIXME: what about using CRLF at end-of-lines?
			NSLog(@"after including newline before first line: affected locations: %u -> %u (%u chars)", l1, l2, l2 - l1);
		}
	}
	affectedRange = NSMakeRange(l1, l2 - l1);

	BOOL ok = (NSUInteger)[self performSelector:NSSelectorFromString(command.method) withObject:command];
	if(ok && command.line_mode && !command.ismotion && (command.key != 'y' || command.motion_key != 'y') && command.key != '>' && command.key != '<')
	{
		/* For line mode operations, we always end up at the beginning of the line. */
		/* ...well, except for yy :-) */
		/* ...and > */
		/* ...and < */
		// FIXME: this is not a generic case!
		NSUInteger bol;
		[self getLineStart:&bol end:NULL contentsEnd:NULL forLocation:final_location];
		final_location = bol;
	}
}

- (void)input_newline:(NSString *)characters
{
	[self insertNewlineAtLocation:start_location indentForward:YES];
	[self setCaret:start_location + 1];
}

- (NSArray *)smartTypingPairsAtLocation:(NSUInteger)aLocation
{
	NSMutableArray *scopes = [[self layoutManager] temporaryAttribute:ViScopeAttributeName
							 atCharacterIndex:aLocation
						    longestEffectiveRange:NULL
								  inRange:NSMakeRange(aLocation, 1)];
	NSLog(@"found scopes at location %u: [%@]", aLocation, scopes);

	NSArray *allSmartTypingPairs = [[[ViLanguageStore defaultStore] allSmartTypingPairs] allKeys];

	NSString *foundScopeSelector = nil;
	NSString *scopeSelector;
	u_int64_t highest_rank = 0;
	for(scopeSelector in allSmartTypingPairs)
	{
		u_int64_t rank = [scopeSelector matchesScopes:scopes];
		if(rank > highest_rank)
		{
			foundScopeSelector = scopeSelector;
			highest_rank = rank;
		}
	}

	if(foundScopeSelector)
	{
		NSLog(@"found smart typing pair scope selector [%@] at location %i", foundScopeSelector, aLocation);
		return [[[ViLanguageStore defaultStore] allSmartTypingPairs] objectForKey:foundScopeSelector];
	}

	return nil;
}

- (void)input_backspace:(NSString *)characters
{
	if(start_location == insert_start_location)
	{
		[[self delegate] message:@"No more characters to erase"];
		return;
	}

	/* check if we're deleting the first character in a smart pair */
	NSArray *smartTypingPairs = [self smartTypingPairsAtLocation:start_location - 1];
	NSArray *pair;
	for(pair in smartTypingPairs)
	{
		if([[pair objectAtIndex:0] isEqualToString:[[storage string] substringWithRange:NSMakeRange(start_location - 1, 1)]] &&
		   [[pair objectAtIndex:1] isEqualToString:[[storage string] substringWithRange:NSMakeRange(start_location, 1)]])
		{
			[storage deleteCharactersInRange:NSMakeRange(start_location - 1, 2)];
			insert_end_location -= 2;
			[self setCaret:start_location - 1];
			return;
		}
	}

	/* else a regular character, just delete it */
	[storage deleteCharactersInRange:NSMakeRange(start_location - 1, 1)];
	insert_end_location--;

	[self setCaret:start_location - 1];
}

- (void)input_forward_delete:(NSString *)characters
{
	if(start_location >= insert_end_location)
	{
		[[self delegate] message:@"No more characters to erase"];
		return;
	}

	/* FIXME: should handle smart typing pairs here when we support arrow keys(?) in input mode
	 */

	[storage deleteCharactersInRange:NSMakeRange(start_location, 1)];
	insert_end_location--;
}

/* Input a character from the user (in insert mode). Handle smart typing pairs.
 * FIXME: assumes smart typing pairs are single characters.
 */
- (void)inputCharacters:(NSString *)characters
{
	BOOL foundSmartTypingPair = NO;
	NSArray *smartTypingPairs = [self smartTypingPairsAtLocation:start_location];
	if(smartTypingPairs)
	{
		NSArray *pair;
		for(pair in smartTypingPairs)
		{
			// check if we're inserting the end character of a smart typing pair
			// if so, just overwrite the end character
			// FIXME: should check that this really is from a smart pair!
			if([[pair objectAtIndex:1] isEqualToString:characters] &&
			   [[[storage string] substringWithRange:NSMakeRange(start_location, 1)] isEqualToString:[pair objectAtIndex:1]])
			{
				foundSmartTypingPair = YES;
				[self setCaret:start_location + 1];
				break;
			}
			// check for the start character of a smart typing pair
			else if([[pair objectAtIndex:0] isEqualToString:characters])
			{
				// don't use it if next character is alphanumeric
				if(!(start_location >= [storage length] || [[NSCharacterSet alphanumericCharacterSet] characterIsMember:[[storage string] characterAtIndex:start_location]]))
				{
					foundSmartTypingPair = YES;
					[self insertString:[pair objectAtIndex:0] atLocation:start_location];
					[self insertString:[pair objectAtIndex:1] atLocation:start_location + 1];

					insert_end_location += 2;
					[self setCaret:start_location + 1];
					break;
				}
			}
		}
	}
	
	if(!foundSmartTypingPair)
	{
		[self insertString:characters atLocation:start_location];
		insert_end_location += [characters length];
		[self setCaret:start_location + [characters length]];
	}
}

- (void)keyDown:(NSEvent *)theEvent
{
	NSLog(@"Got a keyDown event, characters: '%@', keycode = 0x%04X, modifiers = 0x%08X (0x%08X)",
	      [theEvent characters],
	      [theEvent keyCode],
	      [theEvent modifierFlags],
	      ([theEvent modifierFlags] & NSDeviceIndependentModifierFlagsMask));

	if([[theEvent characters] length] == 0)
		return [super keyDown:theEvent];
	unichar charcode = [[theEvent characters] characterAtIndex:0];

	if(mode == ViInsertMode)
	{
		if(charcode == 0x1B)
		{
			/* escape, return to command mode */
			NSString *insertedText = [[storage string] substringWithRange:NSMakeRange(insert_start_location, insert_end_location - insert_start_location)];
			NSLog(@"registering replay text: [%@] at %u + %u, count = %i", insertedText, insert_start_location, insert_end_location, parser.count);

			/* handle counts for inserted text here */
			NSString *t = insertedText;
			if(parser.count > 1)
			{
				t = [insertedText stringByPaddingToLength:[insertedText length] * (parser.count - 1)
							       withString:insertedText
							  startingAtIndex:0];
				[self insertString:t atLocation:[self caret]];
				t = [insertedText stringByPaddingToLength:[insertedText length] * parser.count
							       withString:insertedText
							  startingAtIndex:0];
			}

			[parser setText:t];
			if([t length] > 0 || hasBeginUndoGroup)
				[self recordInsertInRange:NSMakeRange(insert_start_location, [t length])];
			insertedText = nil;
			[self setCommandMode];
			start_location = end_location = [self caret];
			[self move_left:nil];
			[self setCaret:end_location];
		}
		else /* if((([theEvent modifierFlags] & ~(NSShiftKeyMask | NSAlphaShiftKeyMask | NSControlKeyMask | NSAlternateKeyMask)) >> 17) == 0) */
		{
			/* handle keys with no modifiers, or with shift, caps lock, control or alt modifier */

			NSLog(@"insert text [%@], length = %u", [theEvent characters], [[theEvent characters] length]);
			start_location = [self caret];

			/* Lookup the key in the input command map. Some keys are handled specially, or trigger macros. */
			NSUInteger code = (([theEvent modifierFlags] & NSDeviceIndependentModifierFlagsMask) | [theEvent keyCode]);
			NSString *inputCommand = [inputCommands objectForKey:[NSNumber numberWithUnsignedInteger:code]];
			if(inputCommand)
			{
				[self performSelector:NSSelectorFromString(inputCommand) withObject:[theEvent characters]];
			}
			else if((([theEvent modifierFlags] & NSDeviceIndependentModifierFlagsMask) & (NSCommandKeyMask | NSFunctionKeyMask)) == 0)
			{
				/* other keys insert themselves */
				/* but don't input control characters */
				if(([theEvent modifierFlags] & NSControlKeyMask) == NSControlKeyMask)
				{
					[[self delegate] message:@"Illegal character; quote to enter"];
				}
				else
				{
					[self inputCharacters:[theEvent characters]];
				}
			}
		}
	}
	else if(mode == ViCommandMode)
	{
		if(parser.complete)
			[parser reset];

		[parser pushKey:charcode];
		if(parser.complete)
		{
			[[self delegate] message:@""]; // erase any previous message
			[storage beginEditing];
			[self evaluateCommand:parser];
			[storage endEditing];
			[self setCaret:final_location];
			if(need_scroll)
				[self scrollRangeToVisible:NSMakeRange(final_location, 0)];
 		}
	}
}

/* Takes a string of characters and creates key events for each one.
 * Then feeds them into the keyDown method to simulate key presses.
 * Only used for unit testing.
 */
- (void)input:(NSString *)inputString
{
	int i;
	for(i = 0; i < [inputString length]; i++)
	{
		NSEvent *ev = [NSEvent keyEventWithType:NSKeyDown
					       location:NSMakePoint(0, 0)
					  modifierFlags:0
					      timestamp:[[NSDate date] timeIntervalSinceNow]
					   windowNumber:0
						context:[NSGraphicsContext currentContext]
					     characters:[inputString substringWithRange:NSMakeRange(i, 1)]
			    charactersIgnoringModifiers:[inputString substringWithRange:NSMakeRange(i, 1)]
					      isARepeat:NO
						keyCode:[inputString characterAtIndex:i]];
		[self keyDown:ev];
	}
}




/* This is stolen from Smultron.
 */
- (void)drawRect:(NSRect)rect
{
	[super drawRect:rect];

	NSRect bounds = [self bounds];
	if([self needsToDrawRect:NSMakeRect(pageGuideX, 0, 1, bounds.size.height)] == YES)
	{ // So that it doesn't draw the line if only e.g. the cursor updates
		[[self insertionPointColor] set];
		// pageGuideColour = [color colorWithAlphaComponent:([color alphaComponent] / 4)];
		[NSBezierPath strokeRect:NSMakeRect(pageGuideX, 0, 0, bounds.size.height)];
	}
}

- (void)setPageGuideValues
{
	NSDictionary *sizeAttribute = [[NSDictionary alloc] initWithObjectsAndKeys:[self font], NSFontAttributeName, nil];
	CGFloat sizeOfCharacter = [@" " sizeWithAttributes:sizeAttribute].width;
	pageGuideX = (sizeOfCharacter * (80 + 1)) - 1.5;
	// -1.5 to put it between the two characters and draw only on one pixel and
	// not two (as the system draws it in a special way), and that's also why the
	// width above is set to zero
	[self display];
}

/* This one is from CocoaDev.
 */
- (void)disableWrapping
{
	const float LargeNumberForText = 1.0e7;
	
	NSScrollView *scrollView = [self enclosingScrollView];
	[scrollView setHasVerticalScroller:YES];
	[scrollView setHasHorizontalScroller:YES];
	[scrollView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];

	NSTextContainer *textContainer = [self textContainer];
	[textContainer setContainerSize:NSMakeSize(LargeNumberForText, LargeNumberForText)];
	[textContainer setWidthTracksTextView:NO];
	[textContainer setHeightTracksTextView:NO];

	[self setMaxSize:NSMakeSize(LargeNumberForText, LargeNumberForText)];
	[self setHorizontallyResizable:YES];
	[self setVerticallyResizable:YES];
	[self setAutoresizingMask:NSViewNotSizable];
}

- (void)setTheme:(ViTheme *)aTheme
{
	NSLog(@"setting theme %@", [aTheme name]);
	theme = aTheme;
	[self setBackgroundColor:[theme backgroundColor]];
	[self setDrawsBackground:YES];
	[self setInsertionPointColor:[theme caretColor]];
	[self setSelectedTextAttributes:[NSDictionary dictionaryWithObject:[theme selectionColor] forKey:NSBackgroundColorAttributeName]];
	NSFont *font = [NSFont userFixedPitchFontOfSize:12.0];
	[self setFont:font];
	[self setTabSize:8];
	//[self highlightEverything];
	[self setNeedsDisplay:YES];
}

- (void)setTabSize:(int)tabSize
{
	NSString *tab = [@"" stringByPaddingToLength:tabSize withString:@" " startingAtIndex:0];

	NSLog(@"setting tab size %i for font %@", tabSize, [self font]);

	NSDictionary *attrs = [NSDictionary dictionaryWithObject:[self font] forKey:NSFontAttributeName];
	NSSize tabSizeInPoints = [tab sizeWithAttributes:attrs];

	NSMutableParagraphStyle *style = [[NSParagraphStyle defaultParagraphStyle] mutableCopy];

	// remove all previous tab stops
	NSArray *array = [style tabStops];
	NSTextTab *tabStop;
	for(tabStop in array)
	{
		[style removeTabStop:tabStop];
	}

	// "Tabs after the last specified in tabStops are placed at integral multiples of this distance."
	[style setDefaultTabInterval:tabSizeInPoints.width];

	NSLog(@"font = %@", [self font]);
	attrs = [NSDictionary dictionaryWithObjectsAndKeys:style, NSParagraphStyleAttributeName,
						           [self font], NSFontAttributeName, nil];
	[self setTypingAttributes:attrs];

	[storage addAttributes:attrs range:NSMakeRange(0, [[storage string] length])];
}

- (NSUndoManager *)undoManager
{
	return undoManager;
}

@end
