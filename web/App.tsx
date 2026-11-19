import { useEffect, useLayoutEffect, useRef, useState } from "react";
import type { CSSProperties } from "react";
import AgentIsland, { agentActivity } from "./AgentIsland.tsx";
import ProviderSettings from "./ProviderSettings.tsx";
import WorkspaceTabs, { type WorkspaceTab } from "./WorkspaceTabs.tsx";
import NewTab from "./NewTab.tsx";
import { supportsReasoningEffort } from "../shared/provider.ts";
import ResponseTurn, {
  conversationTurns,
  turnSources,
} from "./ResponseTurn.tsx";
import { BotEditor, ForwardDialog, MemoryDialog } from "./WorkspaceDialogs.tsx";
import type {
  AppView,
  Bot,
  Conversation,
  TrashedConversation,
  Report,
  ReasoningEffort,
  Resource,
  Run,
  Snapshot,
  Source,
  SurfaceContext,
  ViewCommand,
  ViewContext,
  ViewState,
  WorkspaceConfig,
} from "../shared/types.ts";

async function api<T>(path: string, body?: unknown, method = body === undefined ? "GET" : "POST"): Promise<T> {
  const response = await fetch(
    path,
    body === undefined
      ? { method }
      : {
          method,
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(body),
        },
  );
  if (!response.ok) {
    let problem = await response.text();
    try {
      const parsed = JSON.parse(problem) as { error?: unknown; message?: unknown };
      const detail = parsed.error ?? parsed.message;
      if (typeof detail === "string") problem = detail;
    } catch { /* Non-JSON failures already contain readable response text. */ }
    throw Object.assign(new Error(problem || `Request failed (${response.status})`), { status: response.status });
  }
  return response.json();
}
// getRandomValues also works over a private HTTP connection.
function randomId() {
  return Array.from(crypto.getRandomValues(new Uint8Array(16)), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
}

function storedId(storage: Storage, key: string) {
  let id = storage.getItem(key);
  if (!id) {
    id = randomId();
    storage.setItem(key, id);
  }
  return id;
}
const deviceId = storedId(localStorage, "relay.device");
const tabId = storedId(sessionStorage, "relay.tab");
const sameSource = (a: Source, b: Source) =>
  a.appId === b.appId &&
  a.resourceId === b.resourceId &&
  a.revision === b.revision;
const query = (values: Record<string, string>) =>
  new URLSearchParams(values).toString();
function restoredView(): ViewContext | null {
  try {
    return JSON.parse(sessionStorage.getItem("relay.view") || "null");
  } catch {
    return null;
  }
}

interface FrameState {
  token: string;
  ready: boolean;
  view?: AppView;
  source?: Source;
  appId?: string;
  protocolVersion?: 2;
  initialContextReceived?: boolean;
  restoring?: boolean;
}
interface RetainedView {
  frame: FrameState;
  report?: Report;
  context: ViewContext | null;
  surface?: SurfaceContext;
  appState: {appId?: string; viewState?: ViewState};
  loaded: boolean;
  pendingContext?: {source: Source | null; sectionId?: string; selection?: string; viewState?: ViewState};
}

export default function App() {
  const [config, setConfig] = useState<WorkspaceConfig>();
  const [providerSettingsOpen, setProviderSettingsOpen] = useState(false);
  const [bots, setBots] = useState<Bot[]>([]);
  const [selectedBotId, setSelectedBotId] = useState("");
  const [botEditor, setBotEditor] = useState<Bot | "new">();
  const [memoryOpen, setMemoryOpen] = useState(false);
  const [forwardOpen, setForwardOpen] = useState(false);
  const [appsOpen, setAppsOpen] = useState(true);
  const [chatOpen, setChatOpen] = useState(false);
  const [desktop, setDesktop] = useState(() => window.matchMedia("(min-width: 1024px)").matches);
  const [desktopChatOpen, setDesktopChatOpen] = useState(true);
  const [chatWidth, setChatWidth] = useState(() => Math.min(50, Math.max(20, Number(localStorage.getItem("relay.chatWidth")) || 30)));
  const [resizingChat, setResizingChat] = useState(false);
  useEffect(() => {
    const media = window.matchMedia("(min-width: 1024px)");
    const change = () => { setDesktop(media.matches); setResizingChat(false); };
    media.addEventListener("change", change);
    return () => media.removeEventListener("change", change);
  }, []);
  useEffect(() => {
    if (!resizingChat) localStorage.setItem("relay.chatWidth", String(chatWidth));
  }, [chatWidth, resizingChat]);
  const [libraryOpen, setLibraryOpen] = useState(false);
  const [admittedRun, setAdmittedRun] = useState<Run>();
  const chatInteraction = useRef(0);
  const taskHandoff = useRef<{runId: string; interaction: number} | undefined>(undefined);
  const [historySearch, setHistorySearch] = useState("");
  const [historyResults, setHistoryResults] = useState<Conversation[]>();
  const [conversations, setConversations] = useState<Conversation[]>([]);
  const [conversationId, setConversationId] = useState(
    sessionStorage.getItem("relay.conversation") || "",
  );
  const [snapshot, setSnapshot] = useState<Snapshot>();
  const [resources, setResources] = useState<Resource[]>([]);
  const [search, setSearch] = useState("");
  const [report, setReport] = useState<Report>();
  const [appView, setAppView] = useState<AppView>();
  const [appViewUnavailable, setAppViewUnavailable] = useState(false);
  const [selectedAppId, setSelectedAppId] = useState(
    () => sessionStorage.getItem("relay.app") || restoredView()?.source.appId || "chat",
  );
  const [context, setContext] = useState<ViewContext | null>(restoredView);
  const [frameToken, setFrameToken] = useState(randomId());
  const [surface, setSurface] = useState<SurfaceContext>();
  const surfaceRef = useRef<SurfaceContext | undefined>(undefined);
  const [draft, setDraft] = useState("");
  const [sending, setSending] = useState(false);
  const [savingEffort, setSavingEffort] = useState(false);
  const [draftEffort, setDraftEffort] = useState<ReasoningEffort | null>(null);
  const [deletingConversation, setDeletingConversation] = useState<string>();
  const [confirmTrashId, setConfirmTrashId] = useState<string>();
  const [showTrash, setShowTrash] = useState(false);
  const [trash, setTrash] = useState<TrashedConversation[]>([]);
  const effortRevision = useRef(0);
  const [error, setError] = useState("");

  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [loadingReport, setLoadingReport] = useState(false);
  const [frameLoaded, setFrameLoaded] = useState(false);
  const iframe = useRef<HTMLIFrameElement>(null);
  const composer = useRef<HTMLTextAreaElement>(null);
  const island = useRef<HTMLDivElement>(null);
  const focusTarget = useRef<"composer" | "island" | null>(null);
  const contextRef = useRef(context);
  const activeViewToken = useRef<string | null>(context?.viewToken ?? null);
  const frameRef = useRef<FrameState>({ token: frameToken, ready: false });
  const retainedViews = useRef(new Map<string, RetainedView>());
  const frameElements = useRef(new Map<string, HTMLIFrameElement>());
  const [frames, setFrames] = useState<{appId: string; token: string; view: AppView}[]>([]);
  const [openApps, setOpenApps] = useState<string[]>([]);
  const [tabOrder, setTabOrder] = useState<string[]>([]);
  const [activeNewTab, setActiveNewTab] = useState<string>();
  const workspaceMenuDialog = useRef<HTMLDialogElement>(null);
  const [workspaceMenuOpen, setWorkspaceMenuOpen] = useState(false);
  const contextGeneration = useRef(0);
  const commandReport = useRef<Report | undefined>(undefined);
  const appStateRef = useRef<{ appId?: string; viewState?: ViewState }>({});
  const commandRef = useRef<ViewCommand | null>(null);
  const commandViewToken = useRef<string | null>(null);
  const processing = useRef(new Set<string>());
  const chatScroll = useRef<HTMLDivElement>(null);
  const followChat = useRef(true);
  const scrollConversation = useRef("");
  const previousMessage = useRef("");
  const [readingHistory, setReadingHistory] = useState(false);
  const loadSequence = useRef(0);
  const manualLoading = useRef(false);
  const activeConversation = useRef(conversationId);
  activeConversation.current = conversationId;

  useLayoutEffect(() => {
    const frame = frameRef.current;
    if (frame.appId && frame.view && frame.view === appView) retainedViews.current.set(frame.appId, {
      frame, report, context: contextRef.current, surface: surfaceRef.current,
      appState: appStateRef.current, loaded: frameLoaded,
    });
    iframe.current = frameElements.current.get(frame.token) || null;
  });
  function rememberApp(id: string) {
    setOpenApps(current => current.includes(id) ? current : [...current, id]);
  }
  function mountView(view: AppView) {
    const frame = frameRef.current;
    frame.view = view;
    setAppView(view);
    setFrames(current => [...current.filter(item => item.appId !== frame.appId), {appId: frame.appId!, token: frame.token, view}]);
  }
  function restoreApp(id: string) {
    const saved = retainedViews.current.get(id);
    if (!saved?.frame.ready || !saved.frame.view) return false;
    frameRef.current = saved.frame;
    iframe.current = frameElements.current.get(saved.frame.token) || null;
    setFrameToken(saved.frame.token);
    setFrameLoaded(saved.loaded);
    setAppView(saved.frame.view);
    setReport(saved.report);
    setAppViewUnavailable(false);
    surfaceRef.current = saved.surface; setSurface(saved.surface);
    appStateRef.current = saved.appState;
    const token = randomId();
    updateContext(saved.context ? {...saved.context, viewToken: token} : null, token);
    setAppsOpen(true);
    if (saved.pendingContext) void receiveNativeContext(saved.pendingContext);
    return true;
  }
  function selectApp(id: string) {
    setActiveNewTab(undefined); setLibraryOpen(false); setSearch(''); setResources([]);
    if (frameRef.current.appId === id) {setAppsOpen(true); return;}
    clearAppContext();
    setSelectedAppId(id);
    if (id === 'chat') {expandChat(); return;}
    rememberApp(id);
    setChatOpen(false); setAppsOpen(true);
    restoreApp(id);
  }
  function chooseApp(id: string) {
    try {
      const target = 'app:' + id;
      // An already-open app keeps its tab and its retained view.
      setTabOrder(workspaceTabs.flatMap(tab => tab.id === activeNewTab
        ? workspaceTabs.some(item => item.id === target) ? [] : [target]
        : [tab.id]));
      selectApp(id);
    } catch (e) {setError((e as Error).message);}
  }
  function selectNewTab(id: string) {
    clearAppContext();
    setSelectedAppId('chat'); setActiveNewTab(id);
    setAppsOpen(true); setChatOpen(false); setLibraryOpen(false);
  }
  function newTab() {
    const id = 'new:' + randomId();
    setTabOrder([...workspaceTabs.map(tab => tab.id), id]);
    selectNewTab(id);
  }
  function forgetApp(id: string) {
    retainedViews.current.delete(id);
    setFrames(current => current.filter(frame => frame.appId !== id));
    setOpenApps(current => current.filter(app => app !== id));
  }
  function selectTab(id: string) {
    try {
      if (id.startsWith('new:')) selectNewTab(id);
      else selectApp(id.slice(4));
    } catch (e) {setError((e as Error).message);}
  }
  function closeTab(id: string) {
    try {
      setTabOrder(current => current.filter(tab => tab !== id));
      if (id.startsWith('new:')) {
        if (activeNewTab === id) {
          const index = workspaceTabs.findIndex(tab => tab.id === id);
          const next = workspaceTabs[index - 1] || workspaceTabs[index + 1];
          if (next) selectTab(next.id); else selectApp('chat');
        }
        return;
      }
      const app = id.slice(4);
      if (frameRef.current.appId === app || selectedAppId === app) {
        selectApp(openApps.find(other => other !== app && allowedApps.some(item => item.id === other)) || 'chat');
      }
      forgetApp(app);
    } catch (e) {setError((e as Error).message);}
  }
  function updateContext(
    next: ViewContext | null,
    viewToken = next?.viewToken ?? null,
  ) {
    activeViewToken.current = viewToken;
    contextRef.current = next;
    setContext(next);
    if (next) sessionStorage.setItem("relay.view", JSON.stringify(next));
    else sessionStorage.removeItem("relay.view");
  }
  async function displayReport(next: Report, nextContext: ViewContext) {
    setActiveNewTab(undefined);
    setAppsOpen(true);
    setSelectedAppId(next.source.appId);
    rememberApp(next.source.appId);
    setAppViewUnavailable(false);
    ++contextGeneration.current;
    const token = randomId();
    frameRef.current = { token, ready: false, source: next.source, appId: next.source.appId };
    surfaceRef.current = undefined;
    setSurface(undefined);
    setFrameToken(token);
    setFrameLoaded(false);
    setAppView(undefined);
    setReport(next);
    updateContext(nextContext);
    try {
      const view = await api<AppView>(
        `/api/apps/${encodeURIComponent(next.source.appId)}/view?${query({ resourceId: next.source.resourceId, revision: next.source.revision, token, parentOrigin: location.origin })}`,
      );
      if (frameRef.current.token !== token) return;
      mountView(view);
    } catch (e) {
      if (frameRef.current.token !== token) return;
      setAppViewUnavailable(true);
      setError(
        `The saved content is readable, but its app view could not open: ${(e as Error).message}`,
      );
      if (commandRef.current)
        void acknowledge(commandRef.current, "failed", (e as Error).message);
    }
  }
  async function displayApp(appId: string) {
    setActiveNewTab(undefined);
    setAppsOpen(true);
    setSelectedAppId(appId);
    rememberApp(appId);
    if (restoreApp(appId)) {commandViewToken.current = activeViewToken.current; return;}
    const token = randomId();
    frameRef.current = { token, ready: false, appId, protocolVersion: 2 };
    setFrameToken(token);
    setFrameLoaded(false);
    setReport(undefined);
    setAppView(undefined);
    surfaceRef.current = undefined;
    setSurface(undefined);
    updateContext(null, randomId());
    commandViewToken.current = activeViewToken.current;
    const view = await api<AppView>(`/api/apps/${encodeURIComponent(appId)}/view?${query({ token, parentOrigin: location.origin })}`);
    if (frameRef.current.token !== token) return;
    mountView(view);
  }
  function updateSurface(next: SurfaceContext) {
    surfaceRef.current = next;
    setSurface(next);
    updateContext(null, randomId());
  }
  function cancelPresentation(command: ViewCommand) {
    if (command.kind !== "present") return;
    iframe.current?.contentWindow?.postMessage({ version: 2, type: "relay.cancel", token: frameRef.current.token, commandId: command.id }, frameRef.current.view?.origin || "*");
  }
  async function openResource(resource: Resource) {
    setAppsOpen(true);
    setChatOpen(false);
    setLibraryOpen(false);
    const sequence = ++loadSequence.current;
    manualLoading.current = true;
    setLoadingReport(true);
    setError("");
    // Invalidate pending navigation as soon as the user chooses another report.
    if (commandRef.current) void acknowledge(commandRef.current, "stale");
    setReport(undefined);
    setAppView(undefined);
    ++contextGeneration.current;
    updateContext(null);
    try {
      const next = await api<Report>(
        `/api/apps/${encodeURIComponent(resource.appId)}/read?${query({ resourceId: resource.resourceId })}`,
      );
      if (sequence === loadSequence.current)
        displayReport(next, {
          source: next.source,
          viewToken: randomId(),
        });
    } catch (e) {
      setError((e as Error).message);
    } finally {
      if (sequence === loadSequence.current) {
        manualLoading.current = false;
        setLoadingReport(false);
      }
    }
  }
  async function openSource(source: Source, focus?: Pick<ViewContext, "sectionId" | "highlightIds">) {
    setAppsOpen(true);
    const sequence = ++loadSequence.current;
    manualLoading.current = true;
    setLoadingReport(true);
    setError("");
    if (commandRef.current) void acknowledge(commandRef.current, "stale");
    setReport(undefined);
    setAppView(undefined);
    ++contextGeneration.current;
    updateContext(null);
    setChatOpen(false);
    setLibraryOpen(false);
    try {
      const next = await api<Report>(
        `/api/apps/${encodeURIComponent(source.appId)}/report?${query({ resourceId: source.resourceId, revision: source.revision })}`,
      );
      if (sequence === loadSequence.current)
        displayReport(next, {
          source: next.source,
          ...focus,
          viewToken: randomId(),
        });
    } catch (e) {
      setError((e as Error).message);
    } finally {
      if (sequence === loadSequence.current) {
        manualLoading.current = false;
        setLoadingReport(false);
      }
    }
  }
  async function acknowledge(
    command: ViewCommand,
    status: "applied" | "stale" | "failed",
    failure?: string,
    presentedContext?: SurfaceContext,
  ) {
    if (status !== "applied") cancelPresentation(command);
    if (commandRef.current?.id === command.id) commandRef.current = null;
    try {
      await api(`/api/commands/${command.id}/ack`, {
        deviceId,
        tabId,
        status,
        ...((status === "applied" || (status === "failed" && presentedContext)) && activeViewToken.current
          ? { viewToken: activeViewToken.current }
          : {}),
        ...(failure ? { error: failure } : {}),
        ...(presentedContext ? { context: presentedContext } : {}),
      });
    } catch (e) {
      processing.current.delete(command.id);
      setError((e as Error).message);
    }
  }
  function sendNavigation(command: ViewCommand) {
    if (command.kind === "present") {
      sendPresentation(command);
      return;
    }
    if (commandViewToken.current !== activeViewToken.current) {
      void acknowledge(command, "stale");
      return;
    }
    iframe.current?.contentWindow?.postMessage(
      {
        type: "relay.navigate",
        token: frameRef.current.token,
        commandId: command.id,
        source: command.source,
        sectionId: command.sectionId,
        highlightIds: command.highlightIds,
        viewState: command.viewState,
      },
      frameRef.current.view!.origin,
    );
  }
  function sendPresentation(command: Extract<ViewCommand, { kind: "present" }>) {
    if (commandViewToken.current !== activeViewToken.current || surfaceRef.current?.generation !== command.expectedGeneration || frameRef.current.appId !== command.appId) {
      void acknowledge(command, "stale");
      return;
    }
    iframe.current?.contentWindow?.postMessage({ version: 2, type: "relay.present", token: frameRef.current.token, commandId: command.id, expectedGeneration: command.expectedGeneration, intent: command.intent }, frameRef.current.view!.origin);
  }
  async function receiveNativeContext(data: {
    source: Source | null;
    sectionId?: string;
    selection?: string;
    viewState?: ViewState;
  }) {
    const generation = ++contextGeneration.current;
    appStateRef.current = {
      appId: frameRef.current.source?.appId,
      viewState: data.viewState,
    };
    manualLoading.current = true;
    if (commandRef.current) void acknowledge(commandRef.current, "stale");
    updateContext(null, randomId());
    if (!data.source) {
      manualLoading.current = false;
      setReport(undefined);
      return;
    }
    try {
      const next = await api<Report>(
        `/api/apps/${encodeURIComponent(data.source.appId)}/report?${query({ resourceId: data.source.resourceId, revision: data.source.revision })}`,
      );
      if (generation !== contextGeneration.current) return;
      setReport(next);
      updateContext({
        source: next.source,
        viewToken: randomId(),
        sectionId: data.sectionId,
        selection: data.selection,
        viewState: data.viewState,
      });
    } catch (e) {
      if (generation === contextGeneration.current) {
        setReport(undefined);
        setError(
          `Current app content could not be read: ${(e as Error).message}`,
        );
      }
    } finally {
      if (generation === contextGeneration.current)
        manualLoading.current = false;
    }
  }
  useEffect(() => {
    const listener = (event: MessageEvent) => {
      const background = [...retainedViews.current.values()].find(saved =>
        saved.frame.token !== frameRef.current.token && event.source === frameElements.current.get(saved.frame.token)?.contentWindow);
      const frame = background?.frame || frameRef.current;
      if (
        event.source !== (background ? frameElements.current.get(frame.token)?.contentWindow : iframe.current?.contentWindow) ||
        event.data?.token !== frame.token ||
        event.origin !== frame.view?.origin
      )
        return;
      const data = event.data;
      if (frame.protocolVersion === 2) {
        if (data.version !== 2) return;
        const next = data.context as SurfaceContext | undefined;
        if (!next || typeof next.viewId !== "string" || !next.viewId || !Number.isSafeInteger(next.generation) || next.generation < 0 ||
          (next.state !== undefined && (!next.state || typeof next.state !== "object" || Array.isArray(next.state))) ||
          (next.selection !== undefined && typeof next.selection !== "string") ||
          (next.targetIds !== undefined && (!Array.isArray(next.targetIds) || next.targetIds.some((id) => typeof id !== "string"))) ||
          (next.source !== undefined && (!next.source || [next.source.appId, next.source.resourceId, next.source.revision, next.source.title, next.source.sourceUrl].some((value) => typeof value !== "string") || next.source.appId !== frame.appId))) return;
        if (background) {
          if (data.type === 'relay.ready') {frame.ready = true; background.surface = next;}
          else if (data.type === 'relay.context' && (!background.surface || next.generation > background.surface.generation)) background.surface = next;
          return;
        }
        if (data.type === "relay.ready") {
          if (frame.ready) return;
          frame.ready = true;
          // Initial context describes the frame just opened, not manual intervention.
          surfaceRef.current = next;
          setSurface(next);
          if (commandRef.current) sendNavigation(commandRef.current);
        } else if (data.type === "relay.context") {
          if (!frame.ready || (surfaceRef.current && next.generation <= surfaceRef.current.generation)) return;
          if (commandRef.current) void acknowledge(commandRef.current, "stale");
          updateSurface(next);
        } else if (data.type === "relay.presented") {
          const command = commandRef.current;
          if (!command || command.kind !== "present" || command.id !== data.commandId) return;
          if (commandViewToken.current !== activeViewToken.current || surfaceRef.current?.generation !== command.expectedGeneration) {
            void acknowledge(command, "stale");
            return;
          }
          if (data.status === "stale") {
            updateSurface(next);
            void acknowledge(command, "stale", data.error);
          } else if (data.status === "failed") {
            if (next.generation >= surfaceRef.current.generation) updateSurface(next);
            void acknowledge(command, "failed", data.error || "The app did not finish the requested presentation.", next);
          } else if (data.status !== "applied" || next.generation !== command.expectedGeneration + 1 || next.viewId !== command.intent.viewId ||
            (command.intent.source && (!next.source || !sameSource(next.source, command.intent.source)))) {
            void acknowledge(command, "failed", data.error || "The app did not finish the requested presentation.");
          } else {
            updateSurface(next);
            void acknowledge(command, "applied", undefined, next);
          }
        }
        return;
      }
      if (background) {
        if (data.type === 'relay.context' && (!data.source || data.source.appId === frame.appId)) background.pendingContext = data;
        return;
      }
      if (data.type === "relay.ready") {
        if (
          !frame.source ||
          !data.source ||
          !sameSource(frame.source, data.source)
        ) {
          setError(
            "The app opened a different resource or revision than requested.",
          );
          updateContext(null);
          if (commandRef.current)
            void acknowledge(
              commandRef.current,
              "failed",
              "App view source did not match the requested revision.",
            );
          return;
        }
        const current = contextRef.current;
        if (
          current &&
          (current.sectionId || current.viewState)
        ) {
          frame.restoring = true;
          iframe.current?.contentWindow?.postMessage(
            {
              type: "relay.navigate",
              token: frame.token,
              commandId: `restore-${frame.token}`,
              source: current.source,
              sectionId: current.sectionId || "content",
              highlightIds: current.highlightIds,
              viewState: current.viewState,
            },
            frame.view!.origin,
          );
        } else {
          frame.ready = true;
          if (commandRef.current) sendNavigation(commandRef.current);
        }
      } else if (data.type === "relay.context") {
        if (data.source && data.source.appId !== frame.source?.appId) return;
        // The app publishes its initial state immediately after ready.
        // This describes the frame we just opened, rather than a user change.
        if (
          !frame.initialContextReceived &&
          data.source &&
          frame.source &&
          sameSource(data.source, frame.source)
        ) {
          frame.initialContextReceived = true;
          appStateRef.current = {
            appId: data.source.appId,
            viewState: data.viewState,
          };
          const current = contextRef.current;
          if (
            !frame.restoring &&
            current &&
            sameSource(current.source, data.source)
          )
            updateContext({
              ...current,
              sectionId: data.sectionId ?? current.sectionId,
              selection: data.selection ?? current.selection,
              viewState: data.viewState ?? current.viewState,
            });
          return;
        }
        frame.initialContextReceived = true;
        void receiveNativeContext(data);
      } else if (data.type === "relay.navigation") {
        if (frame.restoring && data.commandId === `restore-${frame.token}`) {
          frame.restoring = false;
          frame.ready = true;
          const current = contextRef.current;
          const applied =
            data.status === "applied" &&
            current &&
            data.source && sameSource(current.source, data.source);
          if (current)
            updateContext({
              ...current,
              sectionId: data.sectionId ?? current.sectionId,
              selection: undefined,
              viewState: data.viewState ?? current.viewState,
              viewToken: applied ? current.viewToken : randomId(),
            });
          if (!applied)
            setError(data.error || "The saved app view could not be restored.");
          if (commandRef.current) sendNavigation(commandRef.current);
          return;
        }
        const command = commandRef.current;
        if (!command || command.kind !== "navigate" || command.id !== data.commandId) return;
        if (commandViewToken.current !== activeViewToken.current) {
          void acknowledge(command, "stale");
          return;
        }
        if (data.status === "stale") {
          void acknowledge(command, "stale", data.error);
          return;
        }
        if (
          data.status !== "applied" ||
          !data.source || !sameSource(command.source, data.source)
        ) {
          void acknowledge(
            command,
            "failed",
            data.error || "The app did not render the requested source.",
          );
          return;
        }
        const next = commandReport.current;
        if (next) setReport(next);
        updateContext({
          source: command.source,
          sectionId: command.sectionId,
          viewState:
            data.viewState ??
            command.viewState ??
            contextRef.current?.viewState,
          viewToken: randomId(),
        });
        void acknowledge(command, "applied");
      }
    };
    window.addEventListener("message", listener);
    return () => window.removeEventListener("message", listener);
  }, []);
  useEffect(() => {
    void Promise.all([
      api<WorkspaceConfig>("/api/config"),
      api<Conversation[]>("/api/conversations"),
      api<Bot[]>("/api/bots"),
    ])
      .then(([configuration, list, botList]) => {
        setConfig(configuration);
        setBots(botList);
        setConversations(list);
        const restored = list.find(
          (item) => item.id === activeConversation.current,
        );
        if (restored) setSelectedBotId(restored.botId || "");
        else {
          setConversationId("");
          sessionStorage.removeItem("relay.conversation");
        }
      })
      .catch((e) => setError(e.message));
    const current = contextRef.current;
    if (current)
      void api<Report>(
        `/api/apps/${encodeURIComponent(current.source.appId)}/read?${query({ resourceId: current.source.resourceId })}`,
      )
        .then((next) => {
          if (contextRef.current?.viewToken !== current.viewToken) return;
          void displayReport(next, {
            ...current,
            source: next.source,
            selection: undefined,
            viewToken: current.selection || !sameSource(current.source, next.source)
              ? randomId()
              : current.viewToken,
          });
        })
        .catch(() => {
          if (contextRef.current?.viewToken === current.viewToken) updateContext(null);
        });
  }, []);
  const activeBot = bots.find((bot) => bot.id === selectedBotId);
  const allowedApps = (config?.apps || []).filter(
    (app) => !activeBot || activeBot.appIds.includes(app.id),
  );
  const appId =
    selectedAppId === "chat" ? undefined :
    allowedApps.find((app) => app.id === selectedAppId)?.id ||
    allowedApps[0]?.id;
  const currentViewAppId =
    frameRef.current.appId || frameRef.current.source?.appId || appStateRef.current.appId;
  const viewAllowed =
    !activeBot ||
    (!!currentViewAppId && activeBot.appIds.includes(currentViewAppId));
  const includedContext =
    context && (!activeBot || activeBot.appIds.includes(context.source.appId))
      ? context
      : null;
  useEffect(() => {
    if (!showTrash) return;
    let stopped = false;
    const refresh = () => void api<TrashedConversation[]>("/api/trash")
      .then((items) => { if (!stopped) setTrash(items); })
      .catch((error) => { if (!stopped) setError(error.message); });
    refresh();
    const timer = setInterval(refresh, 30_000);
    return () => { stopped = true; clearInterval(timer); };
  }, [showTrash]);
  useEffect(() => {
    if (!viewAllowed && (appView || report || context)) clearAppContext();
  }, [viewAllowed]);
  useEffect(() => {
    if (!historySearch.trim()) {
      setHistoryResults(undefined);
      return;
    }
    let cancelled = false;
    const timer = setTimeout(() => {
      void api<Conversation[]>(
        `/api/conversations?${query({ q: historySearch.trim() })}`,
      )
        .then((next) => {
          if (!cancelled) setHistoryResults(next);
        })
        .catch((e) => {
          if (!cancelled) setError(e.message);
        });
    }, 180);
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [historySearch]);
  const selectedApp = config?.apps.find((app) => app.id === appId);
  const hasLibrary = selectedApp && (selectedApp.protocolVersion !== 2 || selectedApp.capabilities?.search === true);
  useEffect(() => {
    if (selectedAppId) sessionStorage.setItem("relay.app", selectedAppId);
  }, [selectedAppId]);
  useEffect(() => {
    if (!appId || !appsOpen || !libraryOpen || !hasLibrary) return;
    let cancelled = false;
    const timer = setTimeout(() => {
      void api<Resource[]>(
        `/api/apps/${encodeURIComponent(appId)}/search?${query({ q: search })}`,
      )
        .then((next) => {
          if (!cancelled) setResources(next);
        })
        .catch((e) => {
          if (!cancelled) setError(e.message);
        });
    }, 180);
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [appId, search, appsOpen, libraryOpen, hasLibrary]);
  useEffect(() => {
    if (!appId) return;
    setAppsOpen(true);
    // Opening chat or a native app publishing a selection must never reopen home.
    if (frameRef.current.appId === appId || frameRef.current.source?.appId === appId || contextRef.current?.source.appId === appId) return;
    if (restoreApp(appId)) return;
    let cancelled = false;
    const sequence = ++loadSequence.current;
    manualLoading.current = true;
    setLoadingReport(true);
    if (commandRef.current) void acknowledge(commandRef.current, "stale");
    ++contextGeneration.current;
    frameRef.current = { token: randomId(), ready: false };
    setReport(undefined);
    setAppView(undefined);
    updateContext(null);
    const openingApp = config?.apps.find((app) => app.id === appId);
    void (async () => {
      try {
        if (openingApp?.protocolVersion === 2) {
          await displayApp(appId);
          return;
        }
        let resourceId = openingApp?.resourceId;
        if (!resourceId) {
          const list = await api<Resource[]>(`/api/apps/${encodeURIComponent(appId)}/search?${query({ q: "" })}`);
          if (cancelled || sequence !== loadSequence.current) return;
          setResources(list);
          resourceId = list[0]?.resourceId;
        }
        if (!resourceId) return;
        const next = await api<Report>(`/api/apps/${encodeURIComponent(appId)}/read?${query({ resourceId })}`);
        if (!cancelled && sequence === loadSequence.current)
          void displayReport(next, { source: next.source, viewToken: randomId() });
      } catch (e) {
        if (!cancelled && sequence === loadSequence.current) setError((e as Error).message);
      } finally {
        if (sequence === loadSequence.current) {
          manualLoading.current = false;
          setLoadingReport(false);
        }
      }
    })();
    return () => { cancelled = true; };
  }, [appId]);
  useEffect(() => {
    setDraftEffort(null);
    if (!conversationId) {
      setSnapshot(undefined);
      sessionStorage.removeItem("relay.conversation");
      return;
    }
    sessionStorage.setItem("relay.conversation", conversationId);
    setSnapshot(undefined);
    let stopped = false;
    let timer: ReturnType<typeof setTimeout>;
    async function poll() {
      let delay = 3000;
      try {
        const revision = effortRevision.current;
        const next = await api<Snapshot>(
          `/api/conversations/${conversationId}`,
        );
        if (stopped) return;
        if (revision === effortRevision.current) setSnapshot(next);
        if (
          next.runs.some((run) => run.status === "running") ||
          next.commands.some((command) => command.status === "pending")
        )
          delay = 800;
        for (const command of next.commands) {
          if (
            command.status !== "pending" ||
            command.deviceId !== deviceId ||
            command.tabId !== tabId ||
            processing.current.has(command.id)
          )
            continue;
          processing.current.add(command.id);
          const current = contextRef.current;
          if (
            manualLoading.current ||
            command.expectedViewToken !== activeViewToken.current
          ) {
            void acknowledge(command, "stale");
            continue;
          }
          const handoff = taskHandoff.current;
          if (handoff?.runId === command.runId) {
            if (handoff.interaction === chatInteraction.current) setChatOpen(false);
            taskHandoff.current = undefined;
          }
          commandReport.current = undefined;
          commandRef.current = command;
          commandViewToken.current = activeViewToken.current;
          if (command.kind === "present") {
            try {
              if (frameRef.current.appId !== command.appId || frameRef.current.protocolVersion !== 2) {
                await displayApp(command.appId);
                // A cross-app command has no generation for a retained target;
                // bind it to that view after checking the originating view token.
                if (commandRef.current?.id === command.id && surfaceRef.current)
                  commandRef.current = {...command, expectedGeneration: surfaceRef.current.generation};
              }
              if (commandRef.current?.id === command.id && frameRef.current.ready) sendPresentation(commandRef.current as Extract<ViewCommand, {kind: "present"}>);
            } catch (e) {
              void acknowledge(command, "failed", (e as Error).message);
            }
            continue;
          }
          if (current && sameSource(current.source, command.source)) {
            if (frameRef.current.ready) sendNavigation(command);
          } else {
            const expectedToken = activeViewToken.current;
            try {
              const nextReport = await api<Report>(
                `/api/apps/${encodeURIComponent(command.source.appId)}/report?${query({ resourceId: command.source.resourceId, revision: command.source.revision })}`,
              );
              if (
                manualLoading.current ||
                expectedToken !== activeViewToken.current
              ) {
                void acknowledge(command, "stale");
                continue;
              }
              if (
                frameRef.current.view &&
                frameRef.current.source?.appId === command.source.appId
              ) {
                commandReport.current = nextReport;
                if (frameRef.current.ready) sendNavigation(command);
              } else {
                void displayReport(nextReport, {
                  source: nextReport.source,
                  viewToken: randomId(),
                });
                commandViewToken.current =
                  contextRef.current?.viewToken ?? null;
              }
            } catch (e) {
              void acknowledge(command, "failed", (e as Error).message);
            }
          }
        }
      } catch (e) {
        if (!stopped && (e as Error & { status?: number }).status === 404) {
          setConversationId("");
          setSnapshot(undefined);
          setConversations((current) => current.filter((item) => item.id !== conversationId));
          setHistoryResults((current) => current?.filter((item) => item.id !== conversationId));
          return;
        }
        if (!stopped) setError((e as Error).message);
      }
      if (!stopped)
        timer = setTimeout(() => {
          void poll();
        }, delay);
    }
    void poll();
    return () => {
      stopped = true;
      clearTimeout(timer);
    };
  }, [conversationId]);
  function showLatestAnswer() {
    const container = chatScroll.current;
    if (!container) return;
    const answer = [
      ...container.querySelectorAll<HTMLElement>(".message.assistant"),
    ].at(-1);
    if (answer)
      container.scrollTop +=
        answer.getBoundingClientRect().top -
        container.getBoundingClientRect().top -
        16;
    else container.scrollTop = container.scrollHeight;
    followChat.current =
      container.scrollHeight - container.scrollTop - container.clientHeight <
      100;
    setReadingHistory(!followChat.current);
  }
  const latestMessage = snapshot?.messages.at(-1);
  useEffect(() => {
    if (!snapshot || !chatScroll.current) return;
    const initial = scrollConversation.current !== conversationId;
    const changed = previousMessage.current !== latestMessage?.id;
    scrollConversation.current = conversationId;
    previousMessage.current = latestMessage?.id || "";
    if (!initial && !followChat.current) return;
    if ((initial || changed) && latestMessage?.role === "assistant") {
      showLatestAnswer();
    } else {
      chatScroll.current.scrollTop = chatScroll.current.scrollHeight;
      followChat.current = true;
      setReadingHistory(false);
    }
  }, [conversationId, latestMessage?.id, snapshot?.tools.length]);
  function clearAppContext() {
    if (commandRef.current) void acknowledge(commandRef.current, "stale");
    ++contextGeneration.current;
    ++loadSequence.current;
    frameRef.current = { token: randomId(), ready: false };
    appStateRef.current = {};
    surfaceRef.current = undefined;
    setSurface(undefined);
    updateContext(null);
    setReport(undefined);
    setAppView(undefined);
    setAppsOpen(false);
    setLoadingReport(false);
    manualLoading.current = false;
  }
  function openConversation(id: string, list = conversations) {
    setShowTrash(false);
    setConfirmTrashId(undefined);
    const item = list.find((item) => item.id === id);
    if (item) {
      setSelectedBotId(item.botId || "");
      const nextBot = bots.find((bot) => bot.id === item.botId);
      if (
        nextBot &&
        currentViewAppId &&
        !nextBot.appIds.includes(currentViewAppId)
      )
        clearAppContext();
    }
    setSnapshot(undefined);
    setConversationId(id);
    setDraft("");
    expandChat();
    setSidebarOpen(false);
  }
  function selectBot(botId: string) {
    setShowTrash(false);
    const nextBot = bots.find((bot) => bot.id === botId);
    if (nextBot && currentViewAppId && !nextBot.appIds.includes(currentViewAppId)) clearAppContext();
    setSelectedBotId(botId);
    setConversationId("");
    setSnapshot(undefined);
    setDraft("");
    setDraftEffort(null);
    setHistorySearch("");
    expandChat();
    setSidebarOpen(false);
  }
  async function deleteConversation(conversation: Conversation) {
    setDeletingConversation(conversation.id);
    setError("");
    try {
      await api(`/api/conversations/${conversation.id}`, undefined, "DELETE");
      setConfirmTrashId(undefined);
      setConversations((current) => current.filter((item) => item.id !== conversation.id));
      setHistoryResults((current) => current?.filter((item) => item.id !== conversation.id));
      if (activeConversation.current === conversation.id) {
        setConversationId("");
        setSnapshot(undefined);
        setAdmittedRun(undefined);
        setDraft("");
      }
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setDeletingConversation(undefined);
    }
  }
  async function restoreConversation(id: string) {
    setDeletingConversation(id);
    setError("");
    try {
      const restored = await api<Conversation>(`/api/conversations/${id}/restore`, {});
      setTrash((items) => items.filter((item) => item.id !== id));
      setConversations((items) => [restored, ...items.filter((item) => item.id !== id)]);
      setHistorySearch("");
    } catch (error) { setError((error as Error).message); }
    finally { setDeletingConversation(undefined); }
  }
  async function changeEffort(reasoningEffort: ReasoningEffort | null) {
    const originalId = conversationId;
    if (!originalId) {
      setDraftEffort(reasoningEffort);
      return;
    }
    setSavingEffort(true);
    ++effortRevision.current;
    setError("");
    try {
      const updated = await api<Conversation>(`/api/conversations/${originalId}/settings`, { reasoningEffort });
      setConversations((current) => [updated, ...current.filter((item) => item.id !== updated.id)]);
      if (activeConversation.current === originalId)
        setSnapshot((current) => current?.conversation.id === updated.id
          ? { ...current, conversation: updated } : current);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      ++effortRevision.current;
      setSavingEffort(false);
    }
  }
  async function sendMessage(text = draft) {
    if (
      !text.trim() ||
      sending ||
      savingEffort ||
      deletingConversation === conversationId ||
      running
    )
      return;
    const requestAppId = includedContext?.source.appId || (viewAllowed ? currentViewAppId : undefined) || appId;
    const questionContext = includedContext;
    const questionAppContext = (appsOpen || questionContext) && requestAppId ? {
      appId: requestAppId,
      ...(activeViewToken.current && (questionContext || currentViewAppId) ? { viewToken: activeViewToken.current } : {}),
      ...(surfaceRef.current && frameRef.current.appId === requestAppId ? { surface: surfaceRef.current } : {}),
      viewState: questionContext?.viewState || (appStateRef.current.appId === requestAppId ? appStateRef.current.viewState : undefined),
    } : undefined;
    const interaction = chatInteraction.current;
    setSending(true);
    followChat.current = true;
    setError("");
    try {
      let id = conversationId;
      if (!id) {
        const next = await api<Conversation>("/api/conversations", {
          botId: selectedBotId || null,
          reasoningEffort: draftEffort,
        });
        setConversations((current) => [next, ...current]);
        id = next.id;
        setConversationId(id);
      }
      const admitted = await api<Run>(`/api/conversations/${id}/messages`, {
        text: text.trim(),
        deviceId,
        tabId,
        ...(questionAppContext ? { appContext: questionAppContext } : {}),
        ...(questionContext ? { context: questionContext } : {}),
      });
      setAdmittedRun(admitted);
      setDraft("");
      if (questionAppContext) taskHandoff.current = { runId: admitted.id, interaction };
      const next = await api<Snapshot>(`/api/conversations/${id}`);
      if (activeConversation.current === id) setSnapshot(next);
      setConversations(await api<Conversation[]>("/api/conversations"));
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setSending(false);
    }
  }
  const running = snapshot?.runs.find((run) => run.status === "running") ||
    (admittedRun?.status === "running" && admittedRun.conversationId === conversationId && !snapshot?.runs.some((run) => run.id === admittedRun.id && run.status !== "running") ? admittedRun : undefined);
  const appPrimary = appsOpen && (!!appId || !!activeNewTab);
  const appTabs: WorkspaceTab[] = openApps.filter(id => allowedApps.some(app => app.id === id)).map(id => ({
    id: 'app:' + id, title: config?.apps.find(app => app.id === id)?.name || id, kind: 'app',
  }));
  const workspaceTabs: WorkspaceTab[] = tabOrder.flatMap<WorkspaceTab>(id => {
    if (id.startsWith('new:')) return [{id, title:'New tab', kind:'new'}];
    const tab = appTabs.find(tab => tab.id === id);
    return tab ? [tab] : [];
  }).concat(appTabs.filter(tab => !tabOrder.includes(tab.id)));
  const activeTabId = activeNewTab || (appPrimary ? 'app:' + appId : undefined);
  useEffect(() => {
    if (workspaceMenuOpen) workspaceMenuDialog.current?.showModal();
  }, [workspaceMenuOpen]);
  const conversationOpen = !appPrimary || (desktop ? desktopChatOpen : chatOpen);
  const activity = agentActivity(snapshot, config?.apps || [], deviceId, tabId);
  useLayoutEffect(() => {
    if (focusTarget.current === "composer" && conversationOpen)
      composer.current?.focus({ preventScroll: true });
    else if (focusTarget.current === "island" && !conversationOpen)
      island.current?.querySelector<HTMLButtonElement>(".island-expand")?.focus({ preventScroll: true });
    focusTarget.current = null;
  }, [conversationOpen]);
  function expandChat() {
    ++chatInteraction.current;
    if (conversationOpen) composer.current?.focus({ preventScroll: true });
    else focusTarget.current = "composer";
    if (desktop) setDesktopChatOpen(true);
    else setChatOpen(true);
  }
  function minimizeChat() {
    ++chatInteraction.current;
    focusTarget.current = "island";
    if (desktop) setDesktopChatOpen(false);
    else setChatOpen(false);
  }
  async function stopRun() {
    if (!running) return;
    const pending = commandRef.current;
    if (pending) void acknowledge(pending, "stale");
    updateContext(contextRef.current, randomId());
    try {
      await api(`/api/runs/${running.id}/cancel`, {});
      setSnapshot(await api<Snapshot>(`/api/conversations/${conversationId}`));
    } catch (e) { setError((e as Error).message); }
  }
  const knownSources = turnSources(snapshot?.tools || []);

  return (
    <div className={`workspace app-workspace ${desktop ? "desktop-layout" : ""} ${appPrimary ? "app-primary" : "chat-primary"} ${sidebarOpen ? "sidebar-open" : ""}`}>
      <aside className="sidebar">
        <a className="brand" href="/" aria-label="Relay home">
          <span className="brand-symbol">r</span>relay
          <span className="prototype">01</span>
        </a>
        <button
          className={`sidebar-action ${!selectedBotId ? "selected" : ""}`}
          onClick={() => selectBot("")}
        >
          <span>＋</span> New chat
        </button>
        <button className="sidebar-action" onClick={() => setMemoryOpen(true)}>
          <span>◉</span> Memory
        </button>
        <button className={`sidebar-action ${showTrash ? "selected" : ""}`} onClick={() => {
          setShowTrash(!showTrash);
          setConfirmTrashId(undefined);
        }}>
          <span aria-hidden="true">⌫</span> {showTrash ? "Back to chats" : "Trash"}
        </button>
        <div className="sidebar-section">
          <span>BOTS</span>
          <button
            className="icon-button"
            aria-label="Create bot"
            onClick={() => setBotEditor("new")}
          >
            +
          </button>
        </div>
        <nav className="bot-list" aria-label="Bots">
          {bots.map((bot) => (
            <div
              className={`bot-row ${selectedBotId === bot.id ? "active" : ""}`}
              key={bot.id}
            >
              <button className="bot-select" onClick={() => selectBot(bot.id)}>
                <span className="bot-avatar">✳</span>
                <span>{bot.name}</span>
              </button>
              <button
                className="bot-edit"
                aria-label={`Edit ${bot.name}`}
                onClick={() => setBotEditor(bot)}
              >
                ⋯
              </button>
            </div>
          ))}
          {!bots.length && (
            <button
              className="create-bot-hint"
              onClick={() => setBotEditor("new")}
            >
              Create a bot for a recurring task ↗
            </button>
          )}
        </nav>
        {showTrash ? (
          <div className="trash-list" aria-label="Trash">
            <div className="sidebar-section"><span>TRASH</span></div>
            <p className="muted">Conversations are deleted permanently after 24 hours.</p>
            {trash.map((item) => {
              const expires = new Date(Date.parse(item.trashedAt) + 24 * 60 * 60 * 1000);
              return <div className="trash-row" key={item.id}>
                <div><strong>{item.title}</strong><small>Deletes {expires.toLocaleString()}</small></div>
                <button disabled={!!deletingConversation || expires.getTime() <= Date.now()}
                  onClick={() => void restoreConversation(item.id)} aria-label={`Restore conversation: ${item.title}`}>Restore</button>
              </div>;
            })}
            {!trash.length && <p className="muted">Trash is empty.</p>}
          </div>
        ) : <>
        <div className="sidebar-section">
          <span>{activeBot ? "BOT CONVERSATIONS" : "YOUR CHATS"}</span>
          <button
            className="icon-button"
            aria-label="New conversation"
            onClick={() => selectBot(selectedBotId)}
          >
            +
          </button>
        </div>
        <label className="history-search">
          <span aria-hidden="true">⌕</span>
          <input
            aria-label="Search conversations"
            placeholder="Search conversations"
            value={historySearch}
            onChange={(event) => setHistorySearch(event.target.value)}
          />
        </label>
        <nav className="conversation-list" aria-label="Conversation history">
          {(historyResults ?? conversations)
            .filter((item) => (item.botId || "") === selectedBotId)
            .map((item) => (
              <div className="conversation-row" key={item.id}>
              <button
                className={
                  item.id === conversationId
                    ? "conversation active"
                    : "conversation"
                }
                onClick={() =>
                  openConversation(item.id, historyResults ?? conversations)
                }
                title={item.title}
              >
                <span>⌁</span>
                <span className="conversation-title">{item.title || "New conversation"}</span>
              </button>
              <button
                className="conversation-delete"
                aria-label={`${confirmTrashId === item.id ? "Confirm move to Trash" : "Move to Trash"}: ${item.title}`}
                title="Move to Trash"
                disabled={!!deletingConversation || (item.id === conversationId && (!!running || sending || savingEffort))}
                onBlur={() => setConfirmTrashId((current) => current === item.id ? undefined : current)}
                onKeyDown={(event) => { if (event.key === "Escape") setConfirmTrashId(undefined); }}
                onClick={() => {
                  if (confirmTrashId === item.id) void deleteConversation(item);
                  else setConfirmTrashId(item.id);
                }}
              >
                {confirmTrashId === item.id ? "Confirm" : <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" aria-hidden="true">
                  <path d="M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7M14 10v7" />
                </svg>}
              </button>
              </div>
            ))}
          {historyResults &&
            !historyResults.some(
              (item) => (item.botId || "") === selectedBotId,
            ) && <p className="muted">No matching conversations.</p>}
        </nav>
        </>}
        <div className="sidebar-bottom">
          <span className="avatar">Y</span>
          <div>
            Your workspace<small>Local & persistent</small>
          </div>
          <span className="connected-dot" />
        </div>
      </aside>
      {sidebarOpen && (
        <button
          className="sidebar-overlay"
          aria-label="Close navigation"
          onClick={() => setSidebarOpen(false)}
        />
      )}
      <main className="main-shell">
        <header className="topbar">
          <button className="menu-button icon-button" onClick={() => setSidebarOpen(!sidebarOpen)} aria-label="Toggle navigation">☰</button>
          <WorkspaceTabs tabs={workspaceTabs} activeId={activeTabId} onSelect={selectTab} onClose={closeTab} onNew={newTab} />
          <div className="topbar-actions">
            {appPrimary && <button className="apps-toggle" aria-expanded={conversationOpen} aria-controls="relay-conversation" onClick={() => conversationOpen ? minimizeChat() : expandChat()}>Chat {running ? '•' : ''}</button>}
            <button className="icon-button" aria-label="Workspace menu" onClick={() => setWorkspaceMenuOpen(true)}>⋯</button>
          </div>
        </header>
        {workspaceMenuOpen && <dialog ref={workspaceMenuDialog} onCancel={() => setWorkspaceMenuOpen(false)} className="workspace-picker workspace-menu" aria-label="Workspace menu">
          <div className="workspace-picker-heading"><strong>Workspace</strong><button aria-label="Close workspace menu" onClick={() => setWorkspaceMenuOpen(false)}>×</button></div>
          <button onClick={() => {setWorkspaceMenuOpen(false); setProviderSettingsOpen(true);}}>Provider settings</button>
          {appPrimary && !activeNewTab && hasLibrary && <button onClick={() => {setWorkspaceMenuOpen(false); setLibraryOpen(!libraryOpen);}}>App library</button>}
          <button onClick={() => {setWorkspaceMenuOpen(false); selectApp('chat');}}>Chat only</button>
        </dialog>}
        {error && (
          <div className="error-banner" role="alert">
            <span>{error}</span>
            <button onClick={() => setError("")} aria-label="Dismiss error">
              ×
            </button>
          </div>
        )}
        <div
          className={`panels ${appPrimary ? "apps-open" : "chat-only"} ${conversationOpen ? "conversation-open" : "conversation-collapsed"} ${resizingChat ? "resizing-chat" : ""}`}
          style={{"--desktop-chat-width": `${chatWidth}%`} as CSSProperties}
        >
          <section
            className="report-panel"
            aria-label="Connected apps"
            aria-hidden={!appPrimary}
          >
            {libraryOpen && hasLibrary && <div className="library-drawer">
              <div className="library-drawer-heading"><strong>{selectedApp?.name} library</strong><button className="icon-button" aria-label="Close library" onClick={() => setLibraryOpen(false)}>×</button></div>
            <div className="library-toolbar">
              <label className="search-box">
                <span>⌕</span>
                <input
                  aria-label="Search saved resources"
                  placeholder="Find a resource…"
                  value={search}
                  onChange={(e) => setSearch(e.target.value)}
                />
              </label>
              <span className="report-count">{resources.length} resources</span>
            </div>
            <div className="resource-list">
              {(appId
                ? resources.filter((resource) => resource.appId === appId)
                : []
              ).map((resource) => (
                <button
                  key={resource.resourceId}
                  className={
                    report?.source.resourceId === resource.resourceId
                      ? "resource active"
                      : "resource"
                  }
                  onClick={() => void openResource(resource)}
                >
                  <span className="document-icon">▤</span>
                  <span>
                    {resource.title}
                    <small>Saved resource</small>
                  </span>
                  <span className="resource-arrow">↗</span>
                </button>
              ))}
              {!resources.length && (
                <p className="muted">
                  {search
                    ? "No resources match your search."
                    : "Saved resources will appear here."}
                </p>
              )}
            </div>
            </div>}
            <div className="report-stage">
              {(loadingReport || (appView && !frameLoaded)) && (
                <div className="report-loading" role="status">
                  Opening app…
                </div>
              )}
              {frames.map(frame => <iframe key={frame.token}
                ref={element => {if (element) frameElements.current.set(frame.token, element); else frameElements.current.delete(frame.token);}}
                hidden={frame.token !== frameToken || !appView || !viewAllowed || !appsOpen}
                inert={frame.token !== frameToken || !appView || !viewAllowed || !appsOpen}
                className="app-frame is-loaded"
                title={config?.apps.find(app => app.id === frame.appId)?.name || 'App view'}
                src={frame.view.url} sandbox={frame.view.sandbox}
                onLoad={() => {
                  const saved = retainedViews.current.get(frame.appId);
                  if (saved?.frame.token === frame.token) saved.loaded = true;
                  if (frameRef.current.token === frame.token) setFrameLoaded(true);
                }}
                onError={() => {
                  if (frameRef.current.token !== frame.token) return;
                  setFrameLoaded(true);
                  if (commandRef.current) void acknowledge(commandRef.current, 'failed', 'App view could not load');
                }} />)}
              {activeNewTab ? <NewTab key={activeNewTab} apps={allowedApps} openApps={openApps} onChoose={chooseApp} /> : (report || appView) && viewAllowed ? (
                <>
                  {!appView && (
                    <div className="readable-report">
                      {report && appViewUnavailable && (
                        <div className="report-recovery">
                          <button
                            className="text-action"
                            onClick={() => void openResource(report.source)}
                          >
                            Open current app page
                          </button>
                          <p className="settings-note">
                            Loads the latest published version.
                          </p>
                        </div>
                      )}
                      {report?.sections.map((section) => (
                        <section key={section.id}>
                          <h2>{section.title}</h2>
                          <p>{section.text}</p>
                        </section>
                      ))}
                    </div>
                  )}
                </>
              ) : (
                <div className="empty-report">
                  <div className="empty-illustration">
                    <span>▤</span>
                    <span>⌁</span>
                  </div>
                  <span className="eyebrow">YOUR CONNECTED APPS</span>
                  <h2>Bring your apps into view.</h2>
                  <p>
                    Use + to open an app, or find saved content in the app library.
                  </p>
                  <div className="empty-hint">
                    <button onClick={newTab}>Open an app ↗</button>
                  </div>
                </div>
              )}
            </div>
            {!activeNewTab && <footer className="report-footer">
              <span className="connected-dot" />{" "}
              {selectedApp?.name ?? "App workspace"}
              <span>Selections become question context</span>
            </footer>}
          </section>
          {desktop && appPrimary && conversationOpen && <div className="chat-divider"
            role="separator" aria-label="Conversation width" aria-orientation="vertical"
            aria-controls="relay-conversation" aria-valuemin={20} aria-valuemax={50} aria-valuenow={Math.round(chatWidth)}
            tabIndex={0} title="Drag to resize. Arrow keys adjust width; double-click resets it."
            onPointerDown={event => {
              if (event.button !== 0) return;
              event.currentTarget.focus();
              event.currentTarget.setPointerCapture(event.pointerId);
              setResizingChat(true);
            }}
            onPointerMove={event => {
              if (!event.currentTarget.hasPointerCapture(event.pointerId)) return;
              const bounds = event.currentTarget.parentElement!.getBoundingClientRect();
              setChatWidth(Math.min(50, Math.max(20, 320 / bounds.width * 100, (bounds.right - event.clientX) / bounds.width * 100)));
            }}
            onPointerUp={event => {
              if (event.currentTarget.hasPointerCapture(event.pointerId)) event.currentTarget.releasePointerCapture(event.pointerId);
              setResizingChat(false);
            }}
            onLostPointerCapture={() => setResizingChat(false)}
            onDoubleClick={() => setChatWidth(30)}
            onKeyDown={event => {
              if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
              event.preventDefault();
              const minimum = Math.max(20, 320 / event.currentTarget.parentElement!.clientWidth * 100);
              setChatWidth(width => event.key === "Home" ? minimum : event.key === "End" ? 50
                : Math.min(50, Math.max(minimum, width + (event.key === "ArrowLeft" ? 2 : -2))));
            }} />}
          <div className="assistant-surface" data-expanded={conversationOpen}>
          {appPrimary && <div className="assistant-compact" ref={island} aria-hidden={conversationOpen} inert={conversationOpen}><AgentIsland
            label={running && !activity.working ? "Working on your question" : activity.label}
            detail={running && !activity.working ? "Expand conversation for details" : activeNewTab && activity.phase === 'idle' ? 'Start a conversation' : activity.detail}
            phase={running ? "working" : activity.phase}
            working={!!running} onExpand={expandChat} onStop={() => void stopRun()} /></div>}
          <section id="relay-conversation" className="chat-panel" aria-label="Conversation" aria-hidden={!conversationOpen} inert={!conversationOpen}
            onKeyDown={(event) => {
              if (appPrimary && event.key === "Escape" && !event.defaultPrevented && !event.nativeEvent.isComposing) {
                event.preventDefault();
                minimizeChat();
              }
            }}>
            <div className="chat-heading">
              <div className="assistant-icon">✳</div>
              <div>
                <h2>{activeBot?.name || "Conversation"}</h2>
                <p>
                  {running
                    ? activity.working ? activity.label : "Working on your question"
                    : activeBot?.objective ||
                      "A place to think, ask, and explore"}
                </p>
              </div>
              <div className="chat-heading-actions">
                {running && <button className="text-action stop-action" onClick={() => void stopRun()}>Stop</button>}
                {appPrimary && <button className="text-action" aria-label="Minimize conversation" title="Minimize conversation · Esc" onClick={minimizeChat}>⌄</button>}
                {conversationId && (
                  <button
                    className="text-action"
                    disabled={!!running || sending}
                    onClick={() => setForwardOpen(true)}
                  >
                    Forward ↗
                  </button>
                )}
                <button
                  className="icon-button"
                  aria-label="Start new conversation"
                  title="Start new conversation"
                  onClick={() => selectBot(selectedBotId)}
                >
                  +
                </button>
              </div>
            </div>
            <div
              className="chat-scroll"
              ref={chatScroll}
              onScroll={() => {
                const container = chatScroll.current;
                if (!container) return;
                followChat.current =
                  container.scrollHeight -
                    container.scrollTop -
                    container.clientHeight <
                  100;
                setReadingHistory(!followChat.current);
              }}
            >
              {!snapshot?.messages.length && (
                <div className="chat-welcome">
                  <span className="welcome-star">✳</span>
                  <h2>
                    {activeBot
                      ? `Hello from ${activeBot.name}.`
                      : "What’s on your mind?"}
                  </h2>
                  <p>
                    {activeBot?.objective ||
                      "Start a conversation, explore an idea, or bring in an app when you need more context."}
                  </p>
                  {activeBot?.scope && (
                    <p className="bot-scope">{activeBot.scope}</p>
                  )}
                  <div className="suggestions">
                    <button
                      onClick={newTab}
                    >
                      Open your apps <span>↗</span>
                    </button>
                    <button
                      onClick={() => {
                        setMemoryOpen(true);
                        expandChat();
                      }}
                    >
                      Review memory <span>↗</span>
                    </button>
                  </div>
                  {config?.provider.mode === "fixture" && (
                    <p className="fixture-note">
                      Scripted demo, no AI calls.
                      {selectedApp && selectedApp.protocolVersion !== 2 && <> Try <button onClick={() => setDraft("Find: ")}>Find: your search</button> to search the connected app.</>}
                    </p>
                  )}
                </div>
              )}
              {snapshot?.forwards?.map((forward) => (
                <div className="forward-card" key={forward.id}>
                  <span className="eyebrow">FORWARDED CONTEXT</span>
                  <button
                    onClick={() => {
                      void api<Snapshot>(
                        `/api/conversations/${encodeURIComponent(forward.sourceConversationId)}`,
                      )
                        .then((next) =>
                          openConversation(next.conversation.id, [
                            next.conversation,
                            ...conversations,
                          ]),
                        )
                        .catch((e) => setError(e.message));
                    }}
                  >
                    {forward.sourceTitle || "Source conversation"} ↗
                  </button>
                  <small>{forward.messageIds.length} recorded messages</small>
                  {forward.note && <p>{forward.note}</p>}
                </div>
              ))}
              {snapshot &&
                conversationTurns(snapshot).map((turn) => (
                  <ResponseTurn
                    key={turn.id}
                    turn={turn}
                    knownSources={knownSources}
                    onOpenSource={(source, focus) => void openSource(source, focus)}
                  />
                ))}
              {snapshot?.checkpoint && (
                <details className="task-checkpoint tool-activity">
                  <summary>
                    Task checkpoint ·{" "}
                    {new Date(snapshot.checkpoint.updatedAt).toLocaleString()}
                  </summary>
                  <pre>{snapshot.checkpoint.content}</pre>
                </details>
              )}
              {running && (
                <div className="working" role="status">
                  <span className="working-dot" /> {activity.working ? activity.label : "Working on your question"}{" "}
                  <button onClick={() => void stopRun()}>Stop</button>
                </div>
              )}
            </div>
            {readingHistory && latestMessage && (
              <div className="latest-answer">
                <button onClick={showLatestAnswer}>Latest answer ↓</button>
              </div>
            )}
            <div className="composer-area">
              {!includedContext && appPrimary && viewAllowed && surface && (
                <div className="context-chip" title={surface.selection || surface.source?.title || selectedApp?.name}>
                  <span aria-hidden="true">▤</span>
                  <span>{surface.selection ? `Selection: ${surface.selection}` : surface.source?.title || selectedApp?.name}</span>
                </div>
              )}
              {includedContext && (
                <div
                  className="context-chip"
                  title={
                    includedContext.selection || includedContext.source.title
                  }
                >
                  <span>▤</span>
                  <span>
                    {includedContext.selection
                      ? `Selection: ${includedContext.selection}`
                      : includedContext.source.title}
                  </span>
                  {includedContext.selection ? (
                    <button
                      aria-label="Clear selected context"
                      onClick={() =>
                        updateContext({
                          source: includedContext.source,
                          sectionId: includedContext.sectionId,
                          viewToken: randomId(),
                        })
                      }
                    >
                      ×
                    </button>
                  ) : (
                    <button
                      aria-label="Remove app context"
                      onClick={() => selectApp("chat")}
                    >
                      ×
                    </button>
                  )}
                </div>
              )}
              <form
                className="composer"
                onSubmit={(e) => {
                  e.preventDefault();
                  void sendMessage();
                }}
              >
                <textarea
                  ref={composer}
                  aria-label="Message Relay"
                  placeholder={
                    activeBot ? `Message ${activeBot.name}…` : "Message Relay…"
                  }
                  value={draft}
                  onChange={(e) => setDraft(e.target.value)}
                  onKeyDown={(e) => {
                    if (
                      e.key === "Enter" &&
                      !e.shiftKey &&
                      !e.nativeEvent.isComposing
                    ) {
                      e.preventDefault();
                      void sendMessage();
                    }
                  }}
                  rows={3}
                />
                <div className="composer-actions">
                  {config && (supportsReasoningEffort(config.provider.mode, config.provider.model)) ? (
                    <label className="conversation-effort" title="Thinking effort for this conversation. Applies to the next reply.">
                      <span>Thinking</span>
                      <select
                        aria-label="Conversation thinking effort"
                        value={(conversationId ? (snapshot?.conversation.id === conversationId ? snapshot.conversation : conversations.find((item) => item.id === conversationId))?.reasoningEffort : draftEffort) ?? "inherit"}
                        disabled={sending || !!running || savingEffort || deletingConversation === conversationId || (!!conversationId && !snapshot)}
                        onChange={(event) => void changeEffort(event.target.value === "inherit" ? null : event.target.value as ReasoningEffort)}
                      >
                        <option value="inherit">Connection default</option>
                        <option value="default">Provider default</option>
                        <option value="none">Off</option>
                        <option value="low">Low</option>
                        <option value="high">High</option>
                        <option value="max">Max</option>
                      </select>
                    </label>
                  ) : <span>
                    {includedContext || (appPrimary && viewAllowed && surface)
                      ? "Current app context included"
                      : activeBot
                        ? `${activeBot.name} · ${allowedApps.length} allowed apps`
                        : "Relay · personal workspace"}
                  </span>}
                  <button
                    className="send-button"
                    type="submit"
                    disabled={!draft.trim() || sending || !!running || savingEffort || deletingConversation === conversationId}
                    aria-label="Send message"
                  >
                    ↑
                  </button>
                </div>
              </form>
              <p className="composer-note">
                {config?.provider.mode === "fixture"
                  ? "Fixture responses · provider not being called"
                  : "Check important answers against their sources."}
              </p>
            </div>
          </section>
          </div>
        </div>
      </main>
      {botEditor && (
        <BotEditor
          bot={botEditor === "new" ? undefined : botEditor}
          apps={config?.apps || []}
          onClose={() => setBotEditor(undefined)}
          onSaved={(bot) => {
            setBots((current) => [
              bot,
              ...current.filter((item) => item.id !== bot.id),
            ]);
            setBotEditor(undefined);
            if (botEditor === "new") selectBot(bot.id);
          }}
        />
      )}
      {memoryOpen && (
        <MemoryDialog
          bot={activeBot}
          onClose={() => setMemoryOpen(false)}
          onOpenConversation={(id) => {
            void api<Snapshot>(`/api/conversations/${encodeURIComponent(id)}`)
              .then((next) => {
                setMemoryOpen(false);
                openConversation(id, [next.conversation, ...conversations]);
              })
              .catch((e) => setError(e.message));
          }}
        />
      )}
      {forwardOpen && (
        <ForwardDialog
          bots={bots}
          conversationId={conversationId}
          onClose={() => setForwardOpen(false)}
          onForwarded={(next) => {
            setConversations((current) => [next, ...current]);
            setForwardOpen(false);
            openConversation(next.id, [next, ...conversations]);
          }}
        />
      )}
      {providerSettingsOpen && (
        <ProviderSettings
          running={!!running}
          onClose={() => setProviderSettingsOpen(false)}
          onSaved={async () =>
            setConfig(await api<WorkspaceConfig>("/api/config"))
          }
        />
      )}
    </div>
  );
}
