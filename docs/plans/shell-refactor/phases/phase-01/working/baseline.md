# Shell refactor baseline

Behavior unchanged means every test below still passes after every slice.
A slice that moves or replaces a test updates its name here in the same
slice.

- Taken at: `506d004` (slice 1a test moves; `flutter/lib/` is unchanged from
  `main`).
- Command: `flutter test --reporter json`, run in `flutter/`.
- Result: 110 tests, all passed, none skipped.
- Names are grouped by test file, from the runner's own output. A name ending
  in a variant note is one test run on that platform.

## test/address_bar_test.dart (4)

- a Browser tab highlights selected text, and zooms a PDF
- address bar asks the server for visited pages as the user types
- inline completion continues the typed text with the best address
- address bar selects all on a focusing click and fills in the best page (variant: TargetPlatform.macOS)

## test/app_servers_test.dart (6)

- lists servers, starts and stops one, and turns auto-start on
- a failed start shows its reason and the failed state
- shows a server's logs and reads them again every 10 seconds
- an unusable servers file shows its reason
- a backend without app servers says so and stops asking
- a refresh waits for the list read still running

## test/area_capture_test.dart (1)

- screenshot selection opens inside the active tab beside chat

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

## test/chat_dock_test.dart (2)

- chat can reverse mid-slide and reduced motion closes immediately
- chat reopens closed when it was left closed

## test/chat_panel_test.dart (4)

- forwarded chat shows the handoff before the first message
- compact chat keeps context, keyboard sending and grouped menus usable
- a YouTube Browser tab offers a selectable transcript beside chat
- the transcript follows the video until the user scrolls or selects

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

## test/new_tab_page_test.dart (4)

- another device's tabs open here once, from the new tab page
- cold start publishes the app picker without a saved conversation
- the app picker shows current registrations and keeps open tabs
- desktop and phone picker, retained tabs and chat draft

## test/page_stack_test.dart (3)

- dragging tabs splits the page without recreating either view
- split dividers resize side by side and stacked, and reset
- an app tab that cannot load opens the App servers screen

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

## test/shell_test.dart (5)

- a fullscreen video takes the whole screen alone and its pane in split
- a click that moves a few pixels still selects the tab
- newest tab first is a saved setting and slides the tab left
- with newest tab first, clicking tab D of A B C D gives D A B C
- deleting a tab during insertion keeps the next tab interactive

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

## test/workspace_menu_test.dart (3)

- a bug report pictures the whole window with its page in place
- a dot marks the workspace menu while an update is ready
- appearance follows the system until a theme is chosen

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
