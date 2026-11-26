import type { ProviderMode, ReasoningEffort } from "./provider.ts";
export type { ProviderMode, ReasoningEffort } from "./provider.ts";

export interface Source {
  appId: string;
  resourceId: string;
  revision: string;
  title: string;
  sourceUrl: string;
}

export interface Resource {
  appId: string;
  resourceId: string;
  title: string;
  sourceUrl: string;
}

export interface Report {
  source: Source;
  sections: Array<{ id: string; title: string; text: string }>;
}

export interface ViewState {
  query?: string;
  filters?: Record<string, string>;
  language?: string;
}

export interface AppView {
  url: string;
  origin: string;
  sandbox?: string; // Omitted only for an operator-trusted native app.
  native: true;
}

export interface Operation {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>; // JSON Schema; the app owns argument semantics.
}

export interface OperationImage {
  mimeType: "image/png";
  base64: string;
}

export interface OperationResult {
  data: unknown;
  sources?: Source[];
  image?: OperationImage;
}

export interface OperationProgress {
  type: "progress";
  message: string;
}

export interface ViewIntent {
  viewId: string;
  explanation?: string; // Short plain-text remark attached to the first target or view.
  state?: Record<string, unknown>; // App-owned JSON state.
  targetIds?: string[];
  source?: Source;
}

export interface SurfaceContext extends ViewIntent {
  selection?: string;
  generation: number;
}

export interface AppContext {
  appId: string;
  viewToken?: string;
  viewState?: ViewState;
  surface?: SurfaceContext;
}

export interface ViewContext {
  source: Source;
  viewToken: string;
  sectionId?: string;
  highlightIds?: string[];
  selection?: string;
  viewState?: ViewState;
}

export interface Conversation {
  id: string;
  title: string;
  botId: string | null;
  reasoningEffort?: ReasoningEffort | null;
  createdAt: string;
}

export interface BotInput {
  name: string;
  objective: string;
  scope: string;
  appIds: string[];
}

export interface TrashedConversation extends Conversation {
  trashedAt: string;
}

export interface Bot extends BotInput {
  id: string;
  createdAt: string;
  updatedAt: string;
}

export interface MemoryInput {
  botId?: string | null;
  key: string;
  content: string;
  sourceConversationId?: string;
  sourceMessageId?: string;
}

export interface Memory extends MemoryInput {
  id: string;
  botId: string | null;
  createdAt: string;
  updatedAt: string;
  userEdited: boolean;
}

export interface Forward {
  id: string;
  sourceConversationId: string;
  targetConversationId: string;
  sourceTitle: string;
  note: string;
  createdAt: string;
  messageIds: string[];
}

export interface Checkpoint {
  content: string;
  updatedAt: string;
}

export interface HistoryMatch {
  conversationId: string;
  conversationTitle: string;
  message: Message;
  snippet: string;
}

export interface HistoryPage {
  conversation: Conversation;
  messages: Message[];
  total: number;
  nextOffset?: number;
}

export interface Message {
  hasCapture?: boolean;
  id: string;
  role: "user" | "assistant";
  text: string;
  createdAt: string;
  context?: ViewContext;
  appContext?: AppContext;
}

export interface Run {
  id: string;
  conversationId: string;
  status: "running" | "completed" | "cancelled" | "interrupted" | "failed";
  startedAt: string;
  finishedAt?: string;
  error?: string;
  usage?: Record<string, number>;
}

export interface ToolRecord {
  id: string;
  runId: string;
  name: string;
  input: unknown;
  output: unknown;
  progress?: OperationProgress[];
  status?: "running" | "completed";
  createdAt: string;
}

interface CommandBase {
  id: string;
  runId: string;
  deviceId: string;
  tabId: string;
  expectedViewToken: string | null;
  status: "pending" | "applied" | "stale" | "failed";
  error?: string;
}

export interface NavigateCommand extends CommandBase {
  kind: "navigate";
  source: Source;
  sectionId: string;
  highlightIds?: string[];
  viewState?: ViewState;
}

export interface PresentCommand extends CommandBase {
  kind: "present";
  appId: string;
  intent: ViewIntent;
  expectedGeneration: number;
  context?: SurfaceContext;
}

export type ViewCommand = NavigateCommand | PresentCommand;

export interface Snapshot {
  conversation: Conversation;
  messages: Message[];
  runs: Run[];
  tools: ToolRecord[];
  commands: ViewCommand[];
  forwards: Forward[];
  checkpoint?: Checkpoint;
}

export interface WorkspaceConfig {
  provider: {
    mode: ProviderMode;
    model: string;
    configured: boolean;
    supportsReasoningEffort?: boolean;
  };
  apps: Array<{ id: string; name: string; description: string; resourceId?: string; protocolVersion?: 2; capabilities?: Record<string, boolean>; hasView?: boolean }>;
}

export interface ProviderModel { id: string; name: string; supportsReasoningEffort?: boolean; }
export interface ProviderModelRequest { mode: ProviderMode; apiKey?: string; }

export interface ProviderSettings {
  mode: ProviderMode;
  model: string;
  hasKey: boolean;
  reasoningEffort?: ReasoningEffort;
}

export interface ProviderUpdate {
  mode: ProviderMode;
  model: string;
  apiKey?: string;
  reasoningEffort?: ReasoningEffort;
}
