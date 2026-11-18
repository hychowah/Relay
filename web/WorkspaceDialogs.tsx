import { useEffect, useRef, useState, type ReactNode } from "react";
import type {
  Bot,
  Conversation,
  Memory,
  WorkspaceConfig,
} from "../shared/types.ts";

async function request<T>(
  path: string,
  body?: unknown,
  method = body === undefined ? "GET" : "POST",
): Promise<T> {
  const response = await fetch(path, {
    method,
    ...(body === undefined
      ? {}
      : {
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(body),
        }),
  });
  if (!response.ok) {
    const text = await response.text();
    let message = text;
    try {
      message = JSON.parse(text).error || text;
    } catch {}
    throw new Error(message || `Request failed (${response.status})`);
  }
  return response.status === 204 ? (undefined as T) : response.json();
}

function Dialog({
  title,
  onClose,
  children,
}: {
  title: string;
  onClose: () => void;
  children: ReactNode;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    ref.current?.showModal();
  }, []);
  return (
    <dialog
      ref={ref}
      className="provider-dialog workspace-dialog"
      aria-label={title}
      onCancel={(event) => {
        event.preventDefault();
        onClose();
      }}
    >
      <div className="settings-heading">
        <h2>{title}</h2>
        <button
          className="icon-button"
          aria-label={`Close ${title.toLowerCase()}`}
          onClick={onClose}
        >
          ×
        </button>
      </div>
      {children}
    </dialog>
  );
}

export function BotEditor({
  bot,
  apps,
  onClose,
  onSaved,
}: {
  bot?: Bot;
  apps: WorkspaceConfig["apps"];
  onClose: () => void;
  onSaved: (bot: Bot) => void;
}) {
  const [name, setName] = useState(bot?.name || "");
  const [objective, setObjective] = useState(bot?.objective || "");
  const [scope, setScope] = useState(bot?.scope || "");
  const [appIds, setAppIds] = useState(
    bot?.appIds || apps.map((app) => app.id),
  );
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  async function save() {
    setSaving(true);
    setError("");
    try {
      onSaved(
        await request<Bot>(
          bot ? `/api/bots/${encodeURIComponent(bot.id)}` : "/api/bots",
          {
            name: name.trim(),
            objective: objective.trim(),
            scope: scope.trim(),
            appIds,
          },
        ),
      );
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setSaving(false);
    }
  }
  return (
    <Dialog title={bot ? "Edit bot" : "Create a bot"} onClose={onClose}>
      <p className="settings-description">
        Give this bot a standing purpose. Its conversations and task memory stay
        together.
      </p>
      <form
        onSubmit={(event) => {
          event.preventDefault();
          void save();
        }}
      >
        <label className="settings-field">
          Name
          <input
            required
            value={name}
            onChange={(event) => setName(event.target.value)}
            placeholder="Research partner"
          />
        </label>
        <label className="settings-field">
          Objective
          <textarea
            required
            rows={3}
            value={objective}
            onChange={(event) => setObjective(event.target.value)}
            placeholder="What should this bot help you accomplish?"
          />
        </label>
        <label className="settings-field">
          Scope
          <textarea
            rows={3}
            value={scope}
            onChange={(event) => setScope(event.target.value)}
            placeholder="Focus areas, boundaries, or ways of working"
          />
        </label>
        <fieldset className="app-permissions">
          <legend>Allowed apps</legend>
          {apps.map((app) => (
            <label key={app.id}>
              <input
                type="checkbox"
                checked={appIds.includes(app.id)}
                onChange={(event) =>
                  setAppIds(
                    event.target.checked
                      ? [...appIds, app.id]
                      : appIds.filter((id) => id !== app.id),
                  )
                }
              />
              <span>{app.name}</span>
            </label>
          ))}
          <p className="settings-note">
            Select no apps to keep this bot focused on conversation and memory.
          </p>
        </fieldset>
        {error && (
          <p role="alert" className="settings-error">
            {error}
          </p>
        )}
        <div className="settings-actions">
          <button type="button" onClick={onClose}>
            Cancel
          </button>
          <button
            className="settings-save"
            disabled={saving || !name.trim() || !objective.trim()}
          >
            {saving ? "Saving…" : "Save bot"}
          </button>
        </div>
      </form>
    </Dialog>
  );
}

export function ForwardDialog({
  bots,
  conversationId,
  onClose,
  onForwarded,
}: {
  bots: Bot[];
  conversationId: string;
  onClose: () => void;
  onForwarded: (conversation: Conversation) => void;
}) {
  const [botId, setBotId] = useState(bots[0]?.id || "");
  const [note, setNote] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  async function forward() {
    setSaving(true);
    setError("");
    try {
      onForwarded(
        await request<Conversation>(
          `/api/conversations/${encodeURIComponent(conversationId)}/forward`,
          { botId, note: note.trim() },
        ),
      );
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setSaving(false);
    }
  }
  return (
    <Dialog title="Forward to a bot" onClose={onClose}>
      <p className="settings-description">
        Start a bot conversation with a link to this conversation and its
        recorded messages. Send a follow-up when you are ready for the bot to
        reply.
      </p>
      <form
        onSubmit={(event) => {
          event.preventDefault();
          void forward();
        }}
      >
        <label className="settings-field">
          Bot
          <select
            value={botId}
            onChange={(event) => setBotId(event.target.value)}
          >
            {bots.map((bot) => (
              <option key={bot.id} value={bot.id}>
                {bot.name}
              </option>
            ))}
          </select>
        </label>
        {!bots.length && (
          <p className="settings-note">Create a bot from the sidebar first.</p>
        )}
        <label className="settings-field">
          Handoff note <small>Optional</small>
          <textarea
            value={note}
            rows={4}
            onChange={(event) => setNote(event.target.value)}
            placeholder="What should the bot focus on?"
          />
        </label>
        {error && (
          <p role="alert" className="settings-error">
            {error}
          </p>
        )}
        <div className="settings-actions">
          <button type="button" onClick={onClose}>
            Cancel
          </button>
          <button className="settings-save" disabled={!botId || saving}>
            {saving ? "Forwarding…" : "Forward conversation"}
          </button>
        </div>
      </form>
    </Dialog>
  );
}

export function MemoryDialog({
  bot,
  onClose,
  onOpenConversation,
}: {
  bot?: Bot;
  onClose: () => void;
  onOpenConversation: (id: string) => void;
}) {
  const [scope, setScope] = useState("shared");
  const [memories, setMemories] = useState<Memory[]>([]);
  const [loading, setLoading] = useState(true);
  const [key, setKey] = useState("");
  const [content, setContent] = useState("");
  const [editing, setEditing] = useState<string>();
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const botId = scope === "bot" ? bot?.id : undefined;
  useEffect(() => {
    let stopped = false;
    setLoading(true);
    setError("");
    setEditing(undefined);
    setKey("");
    setContent("");
    void request<Memory[]>(
      `/api/memories${botId ? `?botId=${encodeURIComponent(botId)}` : ""}`,
    )
      .then((next) => {
        if (!stopped) setMemories(next);
      })
      .catch((e) => {
        if (!stopped) setError(e.message);
      })
      .finally(() => {
        if (!stopped) setLoading(false);
      });
    return () => {
      stopped = true;
    };
  }, [botId]);
  async function save() {
    setSaving(true);
    setError("");
    try {
      const next = await request<Memory>(
        editing
          ? `/api/memories/${encodeURIComponent(editing)}`
          : "/api/memories",
        editing
          ? { content: content.trim() }
          : { botId: botId || null, key: key.trim(), content: content.trim() },
      );
      setMemories((current) => [
        next,
        ...current.filter((item) => item.id !== next.id),
      ]);
      setEditing(undefined);
      setKey("");
      setContent("");
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setSaving(false);
    }
  }
  async function remove(id: string) {
    setSaving(true);
    setError("");
    try {
      await request(
        `/api/memories/${encodeURIComponent(id)}`,
        undefined,
        "DELETE",
      );
      setMemories((current) => current.filter((item) => item.id !== id));
      if (editing === id) {
        setEditing(undefined);
        setKey("");
        setContent("");
      }
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setSaving(false);
    }
  }
  return (
    <Dialog title="Memory" onClose={onClose}>
      <div className="memory-tabs" role="group" aria-label="Memory scope">
        <button
          className={scope === "shared" ? "selected" : ""}
          disabled={saving}
          onClick={() => setScope("shared")}
        >
          Shared preferences
        </button>
        {bot && (
          <button
            className={scope === "bot" ? "selected" : ""}
            disabled={saving}
            onClick={() => setScope("bot")}
          >
            {bot.name}
          </button>
        )}
      </div>
      <p className="settings-description">
        {botId
          ? "Task memory for this bot. Shared preferences are also available to it."
          : "Personal preferences available across your conversations and bots."}
      </p>
      {error && (
        <p className="settings-error" role="alert">
          {error}
        </p>
      )}
      <div className="memory-list">
        {loading ? (
          <p role="status" className="muted">
            Loading memory…
          </p>
        ) : !memories.length ? (
          <p className="muted">Nothing saved in this scope yet.</p>
        ) : (
          memories.map((item) => (
            <article className="memory-record" key={item.id}>
              <strong>{item.key}</strong>
              <p>{item.content}</p>
              <small>
                {item.userEdited ? "Edited by you" : "Saved memory"} ·{" "}
                {new Date(item.updatedAt).toLocaleDateString()}
              </small>
              <div className="memory-actions">
                {item.sourceConversationId && (
                  <button
                    onClick={() =>
                      onOpenConversation(item.sourceConversationId!)
                    }
                  >
                    Open source conversation ↗
                  </button>
                )}
                <button
                  disabled={saving}
                  onClick={() => {
                    setEditing(item.id);
                    setKey(item.key);
                    setContent(item.content);
                  }}
                >
                  Edit
                </button>
                <button disabled={saving} onClick={() => void remove(item.id)}>
                  Forget
                </button>
              </div>
            </article>
          ))
        )}
      </div>
      <form
        className="memory-form"
        onSubmit={(event) => {
          event.preventDefault();
          void save();
        }}
      >
        <h3>{editing ? "Edit memory" : "Add memory"}</h3>
        <label className="settings-field">
          Name
          <input
            required
            value={key}
            disabled={!!editing || saving}
            onChange={(event) => setKey(event.target.value)}
            placeholder="Preferred answer style"
          />
        </label>
        <label className="settings-field">
          Content
          <textarea
            required
            rows={3}
            value={content}
            disabled={saving}
            onChange={(event) => setContent(event.target.value)}
            placeholder="What should Relay remember?"
          />
        </label>
        <div className="settings-actions">
          {editing && (
            <button
              type="button"
              onClick={() => {
                setEditing(undefined);
                setKey("");
                setContent("");
              }}
            >
              Cancel edit
            </button>
          )}
          <button
            className="settings-save"
            disabled={saving || !key.trim() || !content.trim()}
          >
            {saving ? "Saving…" : "Save memory"}
          </button>
        </div>
      </form>
    </Dialog>
  );
}
