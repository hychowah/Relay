import { useEffect, useRef, useState } from "react";
import type { ProviderModel, ProviderSettings as ProviderStatus } from "../shared/types.ts";
import { defaultModels, providerNames, supportsReasoningEffort } from "../shared/provider.ts";

async function providerRequest<T = ProviderStatus>(path = "", body?: object, signal?: AbortSignal): Promise<T> {
  const response = await fetch("/api/settings/provider" + path, {
    signal,
    ...(body ? {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify(body)} : {}),
  });
  if (!response.ok) {
    const text = await response.text();
    let message = text;
    try { const problem = JSON.parse(text); message = problem.error || problem.message || text; } catch {}
    throw new Error(message || `Settings could not be loaded (${response.status}).`);
  }
  return response.json();
}

export default function ProviderSettings({running, onClose, onSaved}: {
  running: boolean; onClose: () => void; onSaved: () => Promise<void>;
}) {
  const dialog = useRef<HTMLDialogElement>(null);
  const modelRequest = useRef<AbortController | undefined>(undefined);
  const [settings, setSettings] = useState<ProviderStatus>();
  const [apiKey, setApiKey] = useState("");
  const [saving, setSaving] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [models, setModels] = useState<ProviderModel[]>();
  const [loadingModels, setLoadingModels] = useState(false);
  const [modelsError, setModelsError] = useState("");

  useEffect(() => {
    dialog.current?.showModal();
    const controller = new AbortController();
    void providerRequest("", undefined, controller.signal).then(setSettings).catch(error => {
      if (!controller.signal.aborted) setError(error.message);
    });
    return () => { controller.abort(); modelRequest.current?.abort(); };
  }, []);

  function resetModels() {
    modelRequest.current?.abort();
    modelRequest.current = undefined;
    setModels(undefined);
    setLoadingModels(false);
    setModelsError("");
  }

  async function loadModels(current: ProviderStatus, key: string) {
    modelRequest.current?.abort();
    const controller = new AbortController();
    modelRequest.current = controller;
    setLoadingModels(true);
    setModelsError("");
    try {
      const result = await providerRequest<{models: ProviderModel[]}>("/models", {
        mode: current.mode, ...(key.trim() ? {apiKey: key.trim()} : {}),
      }, controller.signal);
      if (controller.signal.aborted) return;
      setModels(result.models);
      setSettings(previous => {
        if (!previous || previous.mode !== current.mode) return previous;
        const model = result.models.some(item => item.id === previous.model) ? previous.model : result.models[0]?.id || "";
        return {...previous, model, ...(!supportsReasoningEffort(previous.mode, model) ? {reasoningEffort: "default" as const} : {})};
      });
    } catch (error) {
      if (!controller.signal.aborted) setModelsError((error as Error).message);
    } finally {
      if (modelRequest.current === controller) setLoadingModels(false);
    }
  }

  useEffect(() => {
    resetModels();
    if (!settings) return;
    if (settings.mode === "fixture") {
      setModels([{id: defaultModels.fixture, name: "Scripted demo"}]);
      setSettings(previous => previous ? {...previous, model: defaultModels.fixture} : previous);
    }
    else if (settings.hasKey) void loadModels(settings, "");
    else setSettings(previous => previous ? {...previous, model: ""} : previous);
    return () => modelRequest.current?.abort();
  }, [settings?.mode, settings?.hasKey]);

  function close() {
    modelRequest.current?.abort();
    setApiKey("");
    dialog.current?.close();
    onClose();
  }

  async function save() {
    if (!settings || saving || loading || loadingModels || running) return;
    setSaving(true); setError("");
    try {
      await providerRequest("", {
        mode: settings.mode, model: settings.model.trim(),
        reasoningEffort: settings.reasoningEffort ?? "default",
        ...(apiKey.trim() ? {apiKey: apiKey.trim()} : {}),
      });
      setApiKey("");
      await onSaved(); close();
    } catch (error) { setError((error as Error).message); }
    finally { setSaving(false); }
  }

  return (
    <dialog ref={dialog} className="provider-dialog" aria-labelledby="provider-title"
      onCancel={event => { event.preventDefault(); close(); }}>
      <div className="settings-heading">
        <div><span className="eyebrow">WORKSPACE SETTINGS</span><h2 id="provider-title">Model connection</h2></div>
        <button className="icon-button" aria-label="Close provider settings" onClick={close}>×</button>
      </div>
      <p className="settings-description">Connect Claude or DeepSeek, or use the scripted demo.</p>
      {error && <p className="settings-error" role="alert">{error}</p>}
      {!settings ? <p className="muted" role="status">{error ? "Settings are unavailable. Close and try again." : "Loading settings…"}</p> : (
        <form onSubmit={event => { event.preventDefault(); void save(); }}>
          <label className="settings-field">
            Provider
            <select aria-label="Provider" value={settings.mode} disabled={saving || loading}
              onChange={async event => {
                resetModels(); setLoading(true); setApiKey(""); setError("");
                try { setSettings(await providerRequest(`?mode=${event.target.value}`)); }
                catch (error) { setError((error as Error).message); }
                finally { setLoading(false); }
              }}>
              {Object.entries(providerNames).map(([mode, name]) => (
                <option key={mode} value={mode}>{name}{mode === "fixture" ? " · scripted responses" : ""}</option>
              ))}
            </select>
          </label>
          {settings.mode !== "fixture" && <label className="settings-field">
            <span>{providerNames[settings.mode]} API key <small>{settings.hasKey ? "Key configured" : "No key configured"}</small></span>
            <input type="password" value={apiKey} onChange={event => {setApiKey(event.target.value); resetModels();}}
              placeholder={settings.hasKey ? "Leave blank to keep the current key" : `Enter your ${providerNames[settings.mode]} API key`}
              autoComplete="new-password" spellCheck={false} disabled={saving || loading}/>
          </label>}
          <label className="settings-field">
            Model
            <select aria-label="Model" value={settings.model} required disabled={saving || loading || loadingModels || !models?.length}
              onChange={event => setSettings({...settings, model: event.target.value,
                ...(!supportsReasoningEffort(settings.mode, event.target.value) ? {reasoningEffort: "default"} : {})})}>
              {!models?.length && <option value={settings.model}>{settings.model ? `${settings.model} · current model` : "Load models to choose"}</option>}
              {models?.map(model => <option key={model.id} value={model.id}>{model.name === model.id ? model.id : `${model.name} · ${model.id}`}</option>)}
            </select>
          </label>
          {settings.mode !== "fixture" && <>
            <button type="button" onClick={() => void loadModels(settings, apiKey)}
              disabled={saving || loading || loadingModels || (!settings.hasKey && !apiKey.trim())}>
              {loadingModels ? "Loading models…" : models ? "Refresh models" : "Load models"}
            </button>
            {modelsError && <p className="settings-error" role="alert">{modelsError}</p>}
            {models?.length === 0 && <p className="settings-note">No models are available for this key.</p>}
            {!settings.hasKey && !apiKey.trim() && <p className="settings-note">Enter your key, then load the models available to it.</p>}
          </>}
          {supportsReasoningEffort(settings.mode, settings.model) && <>
            <label className="settings-field">
              Thinking effort
              <select aria-label="Thinking effort" value={settings.reasoningEffort ?? "default"}
                onChange={event => setSettings({...settings, reasoningEffort: event.target.value as ProviderStatus["reasoningEffort"]})}
                disabled={saving || loading}>
                <option value="default">Provider default · currently High</option>
                <option value="none">Off</option><option value="low">Low</option><option value="high">High</option><option value="max">Max</option>
              </select>
            </label>
            <p className="settings-note">Higher effort can take longer and use more tokens. Applies to your next reply, including existing conversations.</p>
          </>}
          <p className="settings-note">Loading models checks your key without changing the active connection. Your key is saved only when you choose Save connection.</p>
          {running && <p className="settings-note">Finish or stop the active reply before changing the connection.</p>}
          <div className="settings-actions">
            <button type="button" onClick={close}>Cancel</button>
            <button className="settings-save" type="submit" disabled={saving || loading || loadingModels || running || !settings.model.trim()}>
              {saving ? "Applying…" : "Save connection"}
            </button>
          </div>
        </form>
      )}
    </dialog>
  );
}
