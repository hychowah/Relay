# Shell refactor baseline

Behavior unchanged means every test below still passes after every slice.
A slice that moves or replaces a test updates its name here in the same
slice.

- Taken at: slice 8's tests that pin the chat rules.
- Command: `flutter test --reporter json`, run in `flutter/`.
- Result: 168 tests, all passed, none skipped.
- Names are grouped by test file, from the runner's own output. A name ending
  in a variant note is one test run on that platform.

## test/address_bar_test.dart (10)

- a Browser tab highlights selected text, and zooms a PDF
- address bar asks the server for visited pages as the user types
- inline completion continues the typed text with the best address
- address bar selects all on a focusing click and fills in the best page (variant: TargetPlatform.macOS)
- typing the next filled-in character returns the highlight to the typed text
- Back, Forward and Highlight follow the page
- an unsent address edit survives fullscreen and goes once the selected page's address changes, as from Browser to an app and back
- Go records the page it opens as typed only with history
- a Browser tab that could not load again shows its address, and Go from it records the page it opens as typed
- an unselected split pane whose Browser tab could not load again shows its address

## test/app_servers_test.dart (6)

- lists servers, starts and stops one, and turns auto-start on
- a failed start shows its reason and the failed state
- shows a server's logs and reads them again every 10 seconds
- an unusable servers file shows its reason
- a backend without app servers says so and stops asking
- a refresh waits for the list read still running

## test/area_capture_test.dart (10)

- screenshot selection opens inside the active tab beside chat
- picking an area moves a phone's chat aside until done or the tab changes, and its attachment stays until a conversation is chosen
- picking an area from chat only shows the page to pick on
- Capture an area waits while a snapshot is taken, an area is picked or a reply runs
- a snapshot that arrives after its tab was left shows nothing
- a snapshot that cannot be read shows in the banner, and capturing can start again
- a sent message takes its attached area along
- an attached area asks for a model that takes images until one is chosen
- picking again ends the last picture's flight at once
- in a split, the area is picked on the selected pane's page only

## test/browser_connection_test.dart (2)

- the Browser socket answers reads, transcripts and fills
- a fill sends values only to a page that still holds the read's token

## test/browser_transcript_test.dart (2)

- caption lines become timed paragraphs read in byte-bounded pages
- paragraph starts come from their time markers

## test/bug_reports_test.dart (3)

- a request the backend never answers fails plainly
- lists saved reports and opens their event timeline
- marks a report solved and deletes another

## test/chat_dock_test.dart (10)

- chat can reverse mid-slide and reduced motion closes immediately
- chat reopens closed when it was left closed
- a phone's compact chat bar names the chat, stops a reply and opens chat
- dragging the chat divider resizes chat as it moves and saves the width once
- an agent presentation closes chat on a phone and ends chat only on the desktop
- Chat only opens chat that was closed
- chat stays between 320 px and half the window wide
- chat only fills the workspace on a desktop and a phone, and a phone's sheet slides down as it closes
- chat only keeps the keyboard out of the page
- a page that fills the screen shows over chat only and hides a phone's compact chat bar

## test/chat_input_test.dart (4)

- a transcript selection stays while the page selects nothing, and goes once its pane closes
- a tap on the field reads an included page's selection again and shows it, unless the bot may not use the app
- Enter does not send while the input method is composing
- Send keeps a blank draft and an edit made while sending, and a sent draft clears and shows the newest message

## test/chat_panel_test.dart (12)

- forwarded chat shows the handoff before the first message
- compact chat keeps context, keyboard sending and grouped menus usable
- a YouTube Browser tab offers a selectable transcript beside chat
- the transcript follows the video until the user scrolls or selects
- the effort menu marks its choice and shows a failed change
- Send turns to Stop while a reply runs, and a send in flight holds history and new conversation
- the draft is saved 300 ms after typing and when the window closes
- closed chat keeps its draft and transcript, and drops a transcript selection that a newer page selection replaced
- New conversation clears the draft, and a conversation chosen from the menu opens chat
- the chat header names the conversation and its bot, and the status row shows the status, or works while a reply runs
- the page chip and Capture an area show only for a page the bot may use; the chip names the selection or the tab and follows Include
- the effort menu shows only for a model with thinking effort, and holds its choices while a reply runs

## test/confirm_delete_button_test.dart (1)

- deletes only on a second click and cancels elsewhere

## test/conversations_test.dart (3)

- snapshot activity and progress stay attached to their recorded turn
- new chat, search, Trash and restore use existing records
- late history responses cannot replace a newly selected conversation; missing saved chat recovers

## test/frame_summary_test.dart (1)

- summarizes frames within each motion range only

## test/highlight_menu_test.dart (1)

- the highlight menu sits by its text, inside the page

## test/memory_summary_test.dart (2)

- attributes only the WebKit services in the app launchd domain
- reports growth after warm-up, not the peak

## test/new_tab_page_test.dart (6)

- another device's tabs open here once, from the new tab page
- cold start publishes the app picker without a saved conversation
- the app picker shows current registrations and keeps open tabs
- desktop and phone picker, retained tabs and chat draft
- search filters the apps and hides other devices, and Enter opens the first match
- choosing an app closes chat on a phone and keeps it on the desktop

## test/page_stack_test.dart (10)

- dragging tabs splits the page without recreating either view
- split dividers resize side by side and stacked, and reset
- an app tab that cannot load opens the App servers screen
- a loading app tab shows a spinner, and a Browser tab error offers no App servers
- dragging a split divider moves the tab's split map with it; the workspace hears only the end
- what shows in place of a Browser tab's page starts below its bar, and its saved report offers no App servers
- a dragged tab highlights the half of a pane it would take, and nothing over its own page
- a saved report shows again when its loaded app view fails
- a split Browser pane's bar fits inside its frame, and a click that selects a dimmed pane is recorded
- split dividers show resize cursors, and a stacked one saves at its drag's end

## test/region_capture_test.dart (2)

- dragging over the tab attaches only the selected pixels
- a click keeps the tool open and Escape cancels it

## test/settings_test.dart (6)

- provider picker discovers models and saves effort without exposing the saved key
- an OpenAI list with non-chat models first keeps the default model
- an OpenAI list with non-chat models first leaves the model unchosen
- bot editor saves only apps that are still registered
- shared folders are listed, added and removed on the server
- memory editor keeps scope and saves an edited entry

## test/shell_actions_test.dart (5)

- closing the report question goes on recording, Discard saves nothing, and a saved report says where it went
- the App library lists the apps the server has now
- the update dialog lists test builds, stays open on a click outside and waits for a running reply
- an update restarts only once the server is idle, or unreachable when returning to stable from another server
- a conversation opened from Memory or by forwarding opens chat with an empty draft

## test/shell_test.dart (8)

- a fullscreen video takes the whole screen alone and its pane in split
- a click that moves a few pixels still selects the tab
- newest tab first is a saved setting and slides the tab left
- with newest tab first, clicking tab D of A B C D gives D A B C
- deleting a tab during insertion keeps the next tab interactive
- the toolbar names Relay from 600 px wide, records chat toggles, and New tab closes chat on a phone
- returning to the app opens the conversation last opened on another device
- the toolbar shows where chat is, and a tab or Toggle chat ends chat only

## test/sources_test.dart (3)

- native host encoding preserves nested document routes and bridge parameters
- citations select saved revisions and their applied highlight targets
- source reopening requests the exact saved revision and falls back to its report

## test/stored_data_test.dart (2)

- sizes read as people write them
- stored data shows each kind, clears it and sets auto-clean

## test/tab_memory_test.dart (3)

- tab memory reads only while on and redraws on a new figure
- a VPN tab shows a lock for the globe only where VPN is real
- a hover card pictures a hidden tab and gives its memory

## test/updates_test.dart (7)

- background download verifies bytes, reuses cache and never installs itself
- a file list downloads only changed files and assembles the app
- a started build discards replaced apps, old receipts and old downloads
- two same-version previews stay selectable and can return to Stable
- Updates shows when the installed app and each test build were built
- returning from an offline preview still respects backend restart checks
- wrong hash and other client packages cannot become installable

## test/web_page_test.dart (9)

- public browser identity follows the installed Safari and WebKit
- popup pages follow the Browser address rule
- only matching native initialization avoids manual invalidation
- a Browser address changed by the page is not a manual change
- a restored Browser page is not a visit, and each visit sends one title
- a web page highlight is kept under the page address and shown again
- a recorded bug gets the page trace in time order
- a Browser transcript arrives through the page channel
- page dialogs name the site and answer with the choice

## test/workspace_menu_test.dart (9)

- a bug report pictures the whole window with its page in place
- a dot marks the workspace menu while an update is ready
- appearance follows the system until a theme is chosen
- each workspace menu item opens its dialog, recorded by name
- Forward is offered only with a conversation, bots and no reply
- a bug report saves the window and chat state, and a failed save shows its error until dismissed
- Reconnect restarts the workspace, and the banner hides in fullscreen
- installing an update saves the draft and the open tabs first
- the menu shows the chosen appearance and tab order

## test/workspace_style_test.dart (1)

- appTheme sends the light and dark palettes to app views

## test/workspace_test.dart (30)

- a poll that fails and then succeeds clears its own error
- an error from a user action outlasts a failing and a good poll
- the conversation last opened on any device opens here
- following another device never moves a send or undoes a click
- copying tabs from a split's empty pane keeps the split
- saved tabs survive an offline start and reconnect retries a failed tab
- a bug recording keeps actions, changed replies and errors until saved
- a conversation poll redraws only when the conversation changed
- tabs are saved as they change and reopen on the next start
- the VPN switch reopens a Browser tab and is saved with it
- a VPN tab that cannot be restored stays, with its error
- newest tab first moves opened tabs left and restores saved order
- saved tabs open at once on the saved active tab and load together
- empty tabs fill in place, existing apps retain their page, closing releases it
- a message sent during a poll still leaves the workspace busy
- sends selected text and an explicit crop with the question
- current-page context, scoped presentation, retained generation and manual invalidation
- failed presentations acknowledge the actual view for a corrected retry
- contextless requests navigate only while the originating view is unchanged
- a request without context presents in the app already open
- bot scope excludes disallowed page context and saved sessions restore tabs
- a Browser tab off screen for 30 minutes unloads until shown
- only a Browser tab on screen has its form read or filled
- Reload, Go and an agent view load an unloaded tab first
- an unloaded tab keeps its address until it loads again
- a split is its own tab whose panes nest, move and leave
- split tabs are saved with the tabs and reopen on the next start
- reconnect fills a split saved before a pane it retries
- reconnect does not bring back a split tab the user closed
- unready retained pages fail without blocking refresh and failed tabs reopen
