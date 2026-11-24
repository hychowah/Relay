# Relay Flutter client

The Flutter app is Relay's main client, made for the Mac. It holds your tabs
and the chat with the agent; your own apps and public websites show in the
system's web views beside it. Every model call and key stays with the Relay
service on your own machine. The app needs macOS 14 or later. Windows uses
Relay's web page; a Windows desktop build is in testing.

To build, test or publish the app, see the [development guide](../docs/development.md).

## Chat

Chat supports history, search and Trash, provider/model selection,
conversation thinking effort, bots with app scopes, memory editing, forwarding,
Markdown with citations, saved sources with their revisions and highlights,
activity, checkpoints and app search. Desktop chat width is saved, and chat can
fill the window on its own (chat-only mode); phones use an overlay with a
compact progress/Stop bar.

Devices share one server. The conversation last opened on any device opens on
each device when it starts or comes back to the front, unless that device chose
or sent in a chat meanwhile. A new chat is not saved until its first message, so
it stays open on its device but a restart opens the last saved one.

**Workspace menu → Appearance** sets Relay's own screens to System (the
default), Light or Dark, saved per device. System follows the device's
appearance as it changes. Pages from apps and websites keep their own look, and
the Mac title bar follows macOS.

## Tabs

App tabs keep their views until closed, and tabs are saved as they change.
Every start, including an update
restart, reopens the previous tabs and their views, split tabs included, the
conversation, the draft and the chat panel as it was left; the Mac window keeps
its size and position. The last active tab shows first, and the other tabs load
together in the background. A tab that cannot be restored is reported;
**Reconnect** retries it during that run. A VPN tab stays open with the error
instead, though possibly without its address.

Each device keeps its own tabs and saves them on the server; the new tab page
lists the other devices, and **Open ⟨device⟩'s tabs here** opens a copy beside
the tabs already open. Nothing follows live afterwards. Saved tabs, like the
browsing history, are not given to the agent.

On desktop, a Browser tab off screen for 30 minutes unloads to free its memory,
unless its page plays sound; its time off screen counts from when it falls
silent. It keeps its address and title, and loads again, without a new history
visit, when shown or when the agent reads it. Unloading loses text typed in the
page but not sent, and closes the tab's popup windows. If the new load fails,
as when the network is not back after waking, the tab stays unloaded with the
error; clicking it, Reload, Go or the agent showing a view in it tries again. A
VPN tab loads again on the VPN. On the Mac WebKit says whether a page plays
sound; on Windows only the page's own audio and video elements are seen. The
agent's first read of an unloaded tab waits for the page, so a slow page can
run past the read's time limit; reading again works.

**Newest tab first**, in the Workspace menu, off by default and saved per
device, slides each tab you click or open, or the agent opens, to the left end
of the strip. Restoring, closing and split changes keep the order; Reduce
Motion skips the slide.

On macOS, **Show tab memory** in the Workspace menu puts each tab's memory on
its chip while it is on: the physical footprint that Activity Monitor shows.
Nothing is read while it is off or Relay is not the active app. Resting the
pointer on an app's or a website's tab for half a second shows its card: the
title, a small picture of the page when the tab is off screen (none for a PDF in
Relay's viewer), and the memory of its web process (whole, when tabs share
one), of all pages and of Relay itself. An unloaded tab's card says so, or that
it is loading again, or why loading failed. The card captures the picture, 240
points wide, and reads the memory once as it opens. The picture is kept only in
the card's memory, never saved or sent, and is gone when the card closes.

## Split view

On desktop only, drag a tab onto a page to split it. A new split tab opens in
the tab strip. The page's edge nearest the pointer (left, right, top or bottom)
is where the tab goes, and the highlighted half shows it. Drop more tabs onto
any pane to split it again, side by side or stacked; dropping a tab that is
already in the split moves it. The split tab has an accent outline and a small
map of its panes, with the last selected pane filled.

Click a pane to select it; the selected pane is the tab the chat's page context
and the agent's navigation use. Each Browser pane has its own address bar, so
selecting a pane never resizes a page; a bar narrower than 480 pixels leaves
out **Go**, the PDF zoom buttons (Enter and a pinch do the same) and the VPN
button's label. Only the selected pane's bar takes clicks and the keyboard.
Drag a divider to resize its two sides, or double-click it to return to half
and half; split tabs and their dividers are restored with the tabs.

Click an app's own tab to show it full screen, and the split tab to return to
the split. Closing the split tab ends the split and keeps every app open. Drag
a tab from the split back onto the tab strip to take it out; closing an app's
tab takes it out of every split. Narrow windows show only the selected tab.

## Browser

Browser tabs open public websites; a top-level navigation from a public tab to
a private address is checked (the Browser's address rule). All pages except VPN
tabs share WebKit's persistent website data, which keeps cookies between starts.

A click that focuses the address bar selects the whole address, as in other
browsers; a further click places the caret. On the desktop, the address bar
suggests pages visited before once you type in it, best first by how often and
how recently each was visited; an address opened from the address bar counts
more than a followed link, and pages the agent opens in a Browser tab count as
visits too. As in Chrome, the best suggestion's address fills in after what you
type when it starts with it, with the filled-in part selected; Backspace or Esc
removes it, and a paste fills nothing in. Arrow keys and Enter, or a click,
open a suggestion. With none highlighted, Enter opens the suggested page while
its address is filled in, and otherwise what was typed. The history is kept on
the Relay server, one entry per address, so every desktop using that server
shares it. The agent and app integrations never get it. Pages not visited for
90 days drop out unless **Stored data** says otherwise.

### Popup windows

On macOS only, a page in a Browser tab that opens a sized window on a user
action (`window.open` with a width or height), as **Continue with Google**
does, gets its own popup window titled with the site's host, beside its tab.
The page and its popup can talk to each other and share sign-in. The popup
closes when its page closes it, when the user closes it, or when its tab or the
main window closes. Popup pages follow the Browser's address rule, and windows
that pages open without a user action stay blocked. Any other new window, such
as a link that opens a new tab, loads in the same tab as before, so a sign-in
that opens an unsized window loses its opener. App views keep sending a new
window's address to the default browser. A page dialog or file chooser raised
inside a popup window is not shown.

### VPN tabs

On macOS only, **VPN** beside Reload sends a Browser tab's pages, its popups
and the PDFs it shows out of WSL through NordVPN, by way of the Relay backend.
New tabs start with it off; the setting is saved with the tab. While on, the
switch is a filled "VPN" button and the tab's chip shows a lock in place of the
globe. Switching reopens the tab's address in a new web view, without its back
history. Nothing falls back to the Mac's network: if the route fails, for
example while NordVPN in WSL is off, the page does not load and says so, and a
VPN tab that could not be set up loads nothing. VPN tabs share one WebKit
profile of their own, so their sign-ins persist and stay apart from normal
tabs. Video calls do not work in VPN tabs: the tunnel carries only TCP, and
WebRTC's UDP would show the Mac's own address, so WebRTC is off there.

### Fullscreen video

On macOS only, a video's fullscreen button works in a Browser tab, also for a
player embedded from another site that allows fullscreen. In split view the
video fills its own pane, address bar included. A tab shown alone takes the
whole screen: the tab strip, address bar and chat hide and the window enters
macOS fullscreen. Escape, the player's own button, or leaving macOS fullscreen
ends it, and so does another tab opening, or the player leaving the page. As in
a browser, only a click or key press can start it, and each one starts it once.
A video in a popup window fills only that window.

### PDFs

On macOS only, a PDF opened in a Browser tab shows in the Mac's own PDF viewer
(as in Preview) in place of WebKit's. **Zoom out**, **Zoom in** and **Fit to
width** appear beside an address bar at least 480 pixels wide, and a pinch
zooms too. **Highlight** works as on web pages; a PDF's highlight also keeps
where its lines are drawn, so a PDF that changes under the same address can
show old highlights in the wrong place. Text selected in the PDF shows in the
chat's page context at once and goes with the next question. The agent reads
the PDF's text from the page in view onward, with that page's number and the
page count. A link in the PDF opens in the tab, under the Browser's address
rule. If the PDF cannot be fetched again for the viewer, or needs a password,
WebKit's own view stays, without these features. A PDF embedded inside a web
page keeps the page's own viewer.

### Filling forms

On the desktop only, ask the agent to fill in a form on the page in a Browser
tab, for example with details from files you shared with it. Only a tab shown
on screen, alone or in a split, can be filled, and not while the conversation
is expanded over it. The agent sees only the fields you can see: their labels,
their choices and which one is picked, and for a text field only whether it is
empty, not what you typed. Like the rest of the chat, this goes to the model
provider. It fills those it has values for: text fields, text areas, lists,
check boxes, radio buttons and dates. Each filled field gets a blue outline,
kept until the page reloads, and the page scrolls to the first one. Relay
itself never presses a button, presses Enter or submits the form: check the
outlined fields, then press Submit yourself. A page can still act on a change
by itself, for example a list that sends the form as soon as an option is
picked; when Relay sees the page submit, the agent tells you. If the page
changed since the agent read it, the fill is refused and the agent reads it
again. Passwords, file uploads, and disabled or read-only fields are left to
you, and so are fields in a frame from another site, as many card payment
boxes are. As with typing, the website's own scripts see a filled value before
you submit.

## Highlights

On the desktop, select text on a page or PDF in a Browser tab: once the mouse
is released, a menu of five colours shows beside it, and a colour marks the
text.
Click marked text for the same menu, with its colour ticked, to change the
colour or remove the mark (a second click on **Remove** confirms). The menu
hides while the page scrolls or a PDF zooms. **Highlight** beside the address
bar marks the selected text in yellow.

Highlights are kept on the Relay server for the page's address (without its
#fragment), so they return on the next visit and on every desktop. A web page's
highlight is the quoted text and a little of the text around it, not a place in
the page: it shows wherever that text is on a page with that address, and only
while it is there. A page that redraws itself, or changes its content under one
address as single-page apps do, keeps its highlights on the right text, and a
view without that text shows none. Text inside a frame, such as an embedded
document, cannot be highlighted. Like browsing history, highlights are never
given to the agent or to app integrations. A page's own scripts can read the
highlights kept for that page's address, since they are shown in the page; they
never get another address's.

## Ask about what you see

On macOS, select page or PDF text and ask a question with page context enabled.
With a YouTube video open in a Browser tab, ask about the video: the agent
reads its full transcript page by page through the page itself (desktop only).
Videos without captions have no transcript. **Transcript** above the
conversation opens the same transcript; text selected there is sent as the
question's selection in place of the page's, until newer text is selected on
the page or the pane is clicked or closed. While the video plays, the pane
highlights the paragraph being spoken and scrolls to it, except during ads.
Scrolling or selecting in the pane stops the scrolling until **Follow video**.

Use **Capture an area** beside the model picker, then drag over the active tab
itself; chat stays open on desktop. Releasing the drag flashes the area like a
camera, and the picture flies into the composer, attached for the next
question. With Reduce Motion it attaches at once. Escape or **Cancel** leaves
the tab unchanged. Image input works with Claude and OpenAI. The service keeps
a sent screenshot with its message, so reopening the chat shows it again; Trash
hides it and the 24-hour Trash cleanup deletes it with the conversation.

## Stored data

**Workspace menu → Stored data** lists what the Relay server keeps as you
work, for every device that uses it: browsing history and highlights now, and
any kind the server adds later. Each kind shows how many items it holds and
their size, and has a clear button. **Auto-clean** forgets a kind's items once
they are older than the number of days you set; turned off, they are kept
until you clear them. Browsing history starts at 90 days and highlights start
with auto-clean off. A period is saved with **Save**; when it would delete
items now, the button first says how many and a second click agrees. The
server cleans at start, every hour and when a period is saved.

## Updates

The app checks for updates on its own and downloads a new build in the
background, usually only the few files that changed. A dot on the Workspace
menu button and its Updates item marks a downloaded update ready to install.
**Workspace menu → Updates** shows progress; **Install and restart** stays your
choice and waits for this window's agent work. Each update is checked before it
replaces the app, and the previous app is kept until the new one starts.
