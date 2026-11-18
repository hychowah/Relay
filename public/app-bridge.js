(function () {
  function contextValue(value) {
    if (!value || typeof value !== 'object' || typeof value.viewId !== 'string' || !value.viewId) throw new Error('App context requires a viewId.');
    const { generation: ignored, ...context } = value;
    return context;
  }

  window.RelayApp = {
    connect({ token, parentOrigin, getContext, present, getExplanationTarget }) {
      if (typeof token !== 'string' || !token || new URL(parentOrigin).origin !== parentOrigin || typeof present !== 'function' || typeof getContext !== 'function') throw new Error('Invalid Relay bridge configuration.');
      let context = { ...contextValue(getContext()), generation: 0 };
      let selectedText = '';
      function withSelection(next) {
        if (next.viewId !== context.viewId) selectedText = '';
        return selectedText ? {...next, selection: selectedText} : next;
      }
      function selectionChanged() {
        if (pending) return;
        const text = window.getSelection()?.toString().trim().slice(0, 4000) || '';
        if ((!text && !document.hasFocus()) || text === selectedText) return;
        selectedText = text;
        invalidate();
        send('relay.context', {context});
      }
      let pending;
      let disposed = false;
      let note, removeNote = () => {};
      function explain(text, target, related) {
        if (!target?.isConnected || !target.getBoundingClientRect) throw new Error('The explanation target is unavailable.');
        const element = document.createElement('aside');
        element.setAttribute('data-relay-explanation', '');
        element.setAttribute('role', 'note');
        element.setAttribute('aria-label', 'Relay explanation');
        element.setAttribute('aria-live', 'polite');
        Object.assign(element.style, {
          position: 'fixed', zIndex: '2147483647', boxSizing: 'border-box',
          width: 'max-content', maxWidth: 'min(350px, calc(100vw - 24px))',
          maxHeight: 'min(240px, 40vh)', overflow: 'auto', overscrollBehavior: 'contain',
          margin: '0', padding: '13px 40px 14px 16px', border: '1px solid #ffffff20',
          borderRadius: '18px', background: '#20342e', color: '#f5faf7',
          boxShadow: '0 10px 30px -8px #10282050, 0 2px 6px #10282024',
          font: '400 14px/1.5 system-ui, sans-serif', textAlign: 'left',
          whiteSpace: 'pre-wrap', overflowWrap: 'anywhere', colorScheme: 'dark',
        });
        const label = document.createElement('div');
        Object.assign(label.style, {
          display: 'flex', alignItems: 'center', gap: '6px', marginBottom: '5px',
          font: '600 12px/16px system-ui, sans-serif', color: '#b9e8cf',
        });
        const mark = document.createElement('span');
        mark.setAttribute('aria-hidden', 'true');
        mark.textContent = '✦';
        const name = document.createElement('span');
        name.textContent = 'Relay';
        label.append(mark, name);
        const body = document.createElement('div');
        body.textContent = text;
        const close = document.createElement('button');
        close.type = 'button';
        close.textContent = '×';
        close.setAttribute('aria-label', 'Dismiss explanation');
        Object.assign(close.style, {
          position: 'absolute', top: '6px', right: '6px', width: '30px', height: '30px',
          padding: '0', margin: '0', border: '0', borderRadius: '50%',
          background: '#ffffff10', color: '#d6e5de', font: '18px/1 system-ui', cursor: 'pointer',
        });
        close.onclick = () => removeNote();
        element.append(label, body, close);
        document.body.append(element);
        note = element;
        let frame;
        const position = () => {
          frame = undefined;
          const rect = target.getBoundingClientRect();
          const width = window.innerWidth, height = window.innerHeight;
          element.hidden = !target.isConnected || rect.bottom <= 0 || rect.top >= height || rect.right <= 0 || rect.left >= width || !rect.width || !rect.height;
          if (element.hidden) return;
          const box = element.getBoundingClientRect();
          const obstacles = [target, ...related].filter(Boolean).map(node => node.getBoundingClientRect());
          const candidates = [
            [rect.right + 10, rect.top], [rect.left - box.width - 10, rect.top],
            [rect.left, rect.bottom + 10], [rect.left, rect.top - box.height - 10],
          ].map(([x, y]) => ({
            left: Math.max(12, Math.min(x, width - box.width - 12)),
            top: Math.max(12, Math.min(y, height - box.height - 12)),
          }));
          const overlap = candidate => obstacles.reduce((area, item, index) => area + (index ? 1 : 2) *
            Math.max(0, Math.min(candidate.left + box.width, item.right) - Math.max(candidate.left, item.left)) *
            Math.max(0, Math.min(candidate.top + box.height, item.bottom) - Math.max(candidate.top, item.top)), 0);
          candidates.sort((a, b) => overlap(a) - overlap(b));
          element.style.left = candidates[0].left + 'px';
          element.style.top = candidates[0].top + 'px';
        };
        const schedule = () => { if (frame === undefined) frame = window.requestAnimationFrame(position); };
        const observer = new ResizeObserver(schedule);
        observer.observe(target); observer.observe(element);
        window.addEventListener('scroll', schedule, true);
        window.addEventListener('resize', schedule);
        removeNote = () => {
          if (frame !== undefined) window.cancelAnimationFrame(frame);
          observer.disconnect();
          window.removeEventListener('scroll', schedule, true);
          window.removeEventListener('resize', schedule);
          element.remove(); note = undefined; removeNote = () => {};
        };
        position();
        if (element.hidden) { removeNote(); throw new Error('The explanation target is not visible.'); }
        if (!window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
          element.animate([{opacity: 0, translate: '0 4px'}, {opacity: 1, translate: '0 0'}],
            {duration: 160, easing: 'ease-out'});
        }
      }
      const send = (type, fields) => {
        if (!disposed) window.parent.postMessage({ version: 2, type, token, ...fields }, parentOrigin);
      };
      function invalidate() {
        removeNote();
        const previous = pending;
        pending = undefined;
        if (previous) previous.controller.abort();
        context = { ...withSelection(contextValue(getContext())), generation: context.generation + 1 };
        if (previous) {
          send('relay.presented', { commandId: previous.id, status: 'stale', context });
        }
      }
      function manualInteraction(event) {
        if (note?.contains(event?.target) && event?.key !== 'Escape') return;
        selectedText = '';
        invalidate();
        send('relay.context', { context });
      }
      async function receive(event) {
        const data = event.data;
        if (disposed || event.source !== window.parent || event.origin !== parentOrigin || data?.version !== 2 || data.token !== token) return;
        if (data.type === 'relay.cancel') {
          if (pending?.id === data.commandId) manualInteraction();
          return;
        }
        if (data.type !== 'relay.present' || typeof data.commandId !== 'string' || !Number.isSafeInteger(data.expectedGeneration) || data.expectedGeneration < 0) return;
        if (data.expectedGeneration !== context.generation) {
          send('relay.presented', { commandId: data.commandId, status: 'stale', context });
          return;
        }
        if (pending) {
          invalidate();
          send('relay.presented', { commandId: data.commandId, status: 'stale', context });
          return;
        }
        removeNote();
        const operation = { id: data.commandId, controller: new AbortController() };
        pending = operation;
        try {
          const intent = contextValue(data.intent);
          if (intent.explanation !== undefined && (typeof intent.explanation !== 'string' || !intent.explanation.trim() || intent.explanation.length > 600)) throw new Error('Explanation must be plain text of 1 to 600 characters.');
          if (intent.explanation && typeof getExplanationTarget !== 'function') throw new Error('This app does not support presentation explanations.');
          // The app resolves only after its route, targets and animation have settled.
          const result = contextValue(await present(intent, { signal: operation.controller.signal }));
          if (pending !== operation || operation.controller.signal.aborted || disposed) return;
          if (result.viewId !== intent.viewId) throw new Error('App rendered a different view than requested.');
          if (intent.explanation) {
            explain(intent.explanation, getExplanationTarget(intent), (intent.targetIds || []).slice(1).map(id => getExplanationTarget({...intent, targetIds: [id]})));
            await new Promise(resolve => window.requestAnimationFrame(() => window.requestAnimationFrame(resolve)));
            if (pending !== operation || operation.controller.signal.aborted || disposed) return;
          }
          selectedText = '';
          context = { ...result, generation: context.generation + 1 };
          pending = undefined;
          send('relay.presented', { commandId: operation.id, status: 'applied', context });
        } catch (error) {
          if (pending !== operation || disposed) return;
          removeNote();
          pending = undefined;
          context = { ...withSelection(contextValue(getContext())), generation: context.generation + 1 };
          send('relay.presented', { commandId: operation.id, status: 'failed', context, error: error instanceof Error ? error.message : String(error) });
        }
      }
      window.addEventListener('selectionchange', selectionChanged, true);
      window.addEventListener('message', receive);
      window.addEventListener('pointerdown', manualInteraction, true);
      window.addEventListener('keydown', manualInteraction, true);
      send('relay.ready', { context });
      return {
        // Call for manual state changes, never from the present callback. Generation belongs to the bridge.
        updateContext(next) {
          if (disposed) return;
          const value = contextValue(next);
          invalidate();
          context = { ...withSelection(value), generation: context.generation };
          send('relay.context', { context });
        },
        dispose() {
          if (disposed) return;
          invalidate();
          disposed = true;
          window.removeEventListener('selectionchange', selectionChanged, true);
          window.removeEventListener('message', receive);
          window.removeEventListener('pointerdown', manualInteraction, true);
          window.removeEventListener('keydown', manualInteraction, true);
        },
      };
    },
  };
})();
